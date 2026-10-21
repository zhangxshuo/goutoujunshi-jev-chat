import Foundation
#if os(iOS)
import Security
#endif

struct KeyboardHandoff: Codable {
    var transcript: String
    var advice: Advice
    var relationship: Relationship
    var config: AppConfig
    var createdAt: Date

    func valid(at date: Date, relationship current: Relationship, config currentConfig: AppConfig) -> Bool {
        let age = date.timeIntervalSince(createdAt)
        return (0...300).contains(age) && current == relationship && currentConfig == config
    }
}

/// A single resumable round, never an archive or an authorization to analyze/insert.
/// Images, typing composition, credentials and confirmation state are excluded.
struct KeyboardSession: Codable {
    var transcript: String
    var advice: Advice?
    var relationship: Relationship
    var config: AppConfig
    var createdAt: Date

    func valid(at date: Date, relationship current: Relationship, config currentConfig: AppConfig) -> Bool {
        (0...300).contains(date.timeIntervalSince(createdAt)) &&
        current == relationship && currentConfig == config &&
        !transcript.trimmed.isEmpty && transcript.count <= 12_000
    }
}

/// Explicit user-mediated transfer for signers that strip App Groups.
/// The payload is copied through UIPasteboard and expires quickly.
struct KeyboardConfigTransfer: Codable {
    static let currentVersion = 1
    static let maximumAge: TimeInterval = 600
    static let clipboardPrefix = "GOUTOU_CONFIG_V1:"

    var version = currentVersion
    var createdAt = Date()
    var config: AppConfig
    var secrets: [String: String]

    func validate(at date: Date = Date()) throws {
        let age = date.timeIntervalSince(createdAt)
        guard version == Self.currentVersion, (0...Self.maximumAge).contains(age) else {
            throw GoutouError.invalid("独立配置已过期，请在主 App 重新复制")
        }
        try config.validate()
        let allowed: Set<String> = ["deepseek", "openrouter", "jev"]
        guard !secrets.isEmpty, Set(secrets.keys).isSubset(of: allowed),
              secrets.values.allSatisfy({ !$0.trimmed.isEmpty && $0.count <= 1024 }) else {
            throw GoutouError.invalid("独立配置中的 Key 不完整或格式错误")
        }
    }

    func clipboardText() throws -> String {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 64_000 else { throw GoutouError.invalid("键盘配置过大，无法复制") }
        return Self.clipboardPrefix + data.base64EncodedString()
    }

    static func decodeClipboardText(_ raw: String) throws -> KeyboardConfigTransfer {
        guard raw.hasPrefix(clipboardPrefix) else {
            throw GoutouError.invalid("剪贴板中没有狗头军师独立配置")
        }
        let encoded = String(raw.dropFirst(clipboardPrefix.count))
        guard let data = Data(base64Encoded: encoded), data.count <= 64_000 else {
            throw GoutouError.invalid("独立配置格式错误，请在主 App 重新复制")
        }
        let transfer = try JSONDecoder().decode(KeyboardConfigTransfer.self, from: data)
        try transfer.validate()
        return transfer
    }
}

final class GoutouStore {
    static var group: String { Bundle.main.object(forInfoDictionaryKey: "GoutouAppGroup") as? String ?? "group.ai.goutoujunshi.chatios" }
    private let defaults: UserDefaults
    private let container: URL
    let isUsingSharedGroup: Bool

    init() throws {
        #if os(iOS)
        if let sharedContainer = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group),
           let sharedDefaults = UserDefaults(suiteName: Self.group) {
            container = sharedContainer
            defaults = sharedDefaults
            isUsingSharedGroup = true
        } else {
            container = try Self.makeLocalContainer()
            defaults = .standard
            isUsingSharedGroup = false
        }
        #else
        container = FileManager.default.temporaryDirectory.appendingPathComponent("goutou-ios-core-tests")
        defaults = UserDefaults(suiteName: "ai.goutoujunshi.core-tests")!
        isUsingSharedGroup = true
        #endif
        purgeExpiredHandoff()
        captureMailbox.purge(relationship: relationship(), config: config())
        _ = keyboardSession()
    }

    init(defaults: UserDefaults, container: URL, isUsingSharedGroup: Bool = true) {
        self.defaults = defaults
        self.container = container
        self.isUsingSharedGroup = isUsingSharedGroup
        purgeExpiredHandoff()
        captureMailbox.purge(relationship: relationship(), config: config())
        _ = keyboardSession()
    }

    /// Sideload signers can strip App Group entitlements. Keep the App useful
    /// in that case, with keyboard-local settings and no cross-process features.
    private static func makeLocalContainer() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("GoutouJunshi", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return directory
        } catch {
            throw GoutouError.invalid("无法创建本地配置目录：\(error.localizedDescription)")
        }
    }

    func config() -> AppConfig { decode("config", fallback: AppConfig()) }
    func saveConfig(_ value: AppConfig) throws {
        try value.validate()
        try save(value, key: "config")
        clearHandoff()
        captureMailbox.clear()
        clearKeyboardSession()
    }
    func relationship() -> Relationship { decode("relationship", fallback: Relationship(id: "current")) }
    func saveRelationship(_ value: Relationship, archive: Bool) throws {
        try value.validate()
        if archive {
            var profiles = archived()
            profiles.removeAll { $0.id == value.id }
            profiles.append(value)
            guard profiles.count <= 100 else { throw GoutouError.invalid("对象档案最多 100 个，请先清理") }
            try save(profiles, key: "profiles")
        }
        try save(value, key: "relationship")
        clearHandoff()
        captureMailbox.clear()
        clearKeyboardSession()
    }
    func archived() -> [Relationship] { decode("profiles", fallback: []) }
    func deleteProfile(_ id: String) throws {
        try save(archived().filter { $0.id != id }, key: "profiles")
        if relationship().id == id { try saveRelationship(Relationship(id: "current"), archive: false) }
    }
    func clearProfiles() {
        defaults.removeObject(forKey: "profiles")
        defaults.removeObject(forKey: "relationship")
        clearHandoff()
        captureMailbox.clear()
        clearKeyboardSession()
    }
    func setKeyboardStatus(fullAccess: Bool) {
        defaults.set(fullAccess, forKey: "keyboardFullAccess")
        defaults.set(Date().timeIntervalSince1970, forKey: "keyboardLastSeen")
    }
    var keyboardStatus: String {
        guard isUsingSharedGroup else {
            return "App Group 未连接；请在键盘内独立配置 API Key"
        }
        guard let seen = defaults.object(forKey: "keyboardLastSeen") as? Double, Date().timeIntervalSince1970 - seen < 86_400 else {
            return "尚未检测到键盘；请到聊天输入框切换一次"
        }
        return defaults.bool(forKey: "keyboardFullAccess") ? "最近已连接 · 完全访问已开启" : "最近已连接 · 需要开启完全访问"
    }
    private func save<T: Encodable>(_ value: T, key: String) throws {
        defaults.set(try JSONEncoder().encode(value), forKey: key)
        defaults.synchronize()
    }
    private func decode<T: Decodable>(_ key: String, fallback: T) -> T {
        guard let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(T.self, from: data) else { return fallback }
        return value
    }

    /// This is an explicit one-time handoff, never an automatic chat archive.
    func handoff(_ value: KeyboardHandoff) throws {
        let data = try JSONEncoder().encode(value)
        guard data.count <= 512_000 else { throw GoutouError.invalid("本轮内容过大，无法交给键盘") }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let path = container.appendingPathComponent("handoff.json")
        #if os(iOS)
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            var excluded = path
            var resource = URLResourceValues()
            resource.isExcludedFromBackup = true
            try excluded.setResourceValues(resource)
        } catch { clearHandoff(); throw error }
        #else
        try data.write(to: path, options: .atomic)
        #endif
    }
    func takeHandoff() -> KeyboardHandoff? {
        let path = container.appendingPathComponent("handoff.json")
        defer { clearHandoff() }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
              let data = try? Data(contentsOf: path), let result = try? JSONDecoder().decode(KeyboardHandoff.self, from: data),
              result.valid(at: Date(), relationship: relationship(), config: config()) else { return nil }
        return result
    }
    /// iOS cannot guarantee background deletion at an exact deadline. Expired data
    /// is unusable immediately and is removed when either process next opens it.
    func purgeExpiredHandoff() {
        let path = container.appendingPathComponent("handoff.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
              let data = try? Data(contentsOf: path),
              let value = try? JSONDecoder().decode(KeyboardHandoff.self, from: data),
              value.valid(at: Date(), relationship: relationship(), config: config()) else {
            clearHandoff(); return
        }
    }
    func clearHandoff() { try? FileManager.default.removeItem(at: container.appendingPathComponent("handoff.json")) }
    func saveKeyboardSession(_ value: KeyboardSession) throws {
        guard value.valid(at: Date(), relationship: relationship(), config: config()) else {
            throw GoutouError.invalid("本轮暂存已过期或对象已变化，请重新读取")
        }
        let data = try JSONEncoder().encode(value)
        guard data.count <= 512_000 else { throw GoutouError.invalid("本轮内容过大，无法暂存") }
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let path = container.appendingPathComponent("keyboard-session.json")
        #if os(iOS)
        try data.write(to: path, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        do {
            var file = path, values = URLResourceValues()
            values.isExcludedFromBackup = true
            try file.setResourceValues(values)
        } catch { clearKeyboardSession(); throw error }
        #else
        try data.write(to: path, options: .atomic)
        #endif
    }
    /// Read without consuming so dismissing/recreating the keyboard can resume.
    func keyboardSession() -> KeyboardSession? {
        let path = container.appendingPathComponent("keyboard-session.json")
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        guard let size = try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= 512_000,
              let data = try? Data(contentsOf: path), let value = try? JSONDecoder().decode(KeyboardSession.self, from: data),
              value.valid(at: Date(), relationship: relationship(), config: config()) else {
            clearKeyboardSession(); return nil
        }
        return value
    }
    func clearKeyboardSession() {
        try? FileManager.default.removeItem(at: container.appendingPathComponent("keyboard-session.json"))
    }
    var captureMailbox: CaptureMailbox { CaptureMailbox(container: container) }
}

#if !GOUTOU_CAPTURE
enum CredentialVault {
    static let services = ["deepseek", "openrouter", "jev"]

    /// Shared defaults are the primary store because some sideload signers
    /// preserve App Groups but reject Keychain Sharing. Keychain remains a
    /// best-effort backup and migration source for normally signed builds.
    private static var storage: UserDefaults {
        #if os(iOS)
        if FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: GoutouStore.group) != nil,
           let shared = UserDefaults(suiteName: GoutouStore.group) {
            return shared
        }
        #endif
        return .standard
    }

    private static func key(_ name: String) -> String { "providerSecret." + name }

    #if os(iOS)
    private static func keychainQuery(_ name: String) -> [String: Any]? {
        guard services.contains(name),
              let group = Bundle.main.object(forInfoDictionaryKey: "GoutouKeychainGroup") as? String,
              !group.contains("$("), !group.isEmpty else { return nil }
        return [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "ai.goutoujunshi.ios." + name,
                kSecAttrAccount as String: "default", kSecAttrAccessGroup as String: group]
    }

    private static func keychainRead(_ name: String) -> String {
        guard var query = keychainQuery(name) else { return "" }
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return "" }
        return value
    }

    private static func keychainWrite(_ value: String, name: String) {
        guard let query = keychainQuery(name) else { return }
        let attributes: [String: Any] = [kSecValueData as String: Data(value.utf8),
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes, uniquingKeysWith: { _, new in new }) as CFDictionary, nil)
        }
        _ = status
    }

    private static func keychainDelete(_ name: String) {
        guard let query = keychainQuery(name) else { return }
        SecItemDelete(query as CFDictionary)
    }
    #else
    private static func keychainRead(_ name: String) -> String { "" }
    private static func keychainWrite(_ value: String, name: String) {}
    private static func keychainDelete(_ name: String) {}
    #endif

    static func read(_ name: String) throws -> String {
        guard services.contains(name) else { throw GoutouError.invalid("未知的服务密钥") }
        if let value = storage.string(forKey: key(name)), !value.isEmpty { return value }
        return keychainRead(name)
    }

    static func write(_ value: String, name: String) throws {
        let value = value.trimmed
        guard services.contains(name), !value.isEmpty, value.count <= 1024 else {
            throw GoutouError.invalid("请输入有效的 API Key")
        }
        storage.set(value, forKey: key(name))
        storage.synchronize()
        keychainWrite(value, name: name)
    }

    static func delete(_ name: String) throws {
        guard services.contains(name) else { throw GoutouError.invalid("未知的服务密钥") }
        storage.removeObject(forKey: key(name))
        storage.synchronize()
        keychainDelete(name)
    }

    static func load() throws -> ProviderSecrets {
        try ProviderSecrets(deepseek: read("deepseek"), openrouter: read("openrouter"), jev: read("jev"))
    }
}
#endif
