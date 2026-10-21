import SwiftUI

struct ProviderView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = AppConfig()
    @State private var deepseekKey = ""
    @State private var openrouterKey = ""
    @State private var jevKey = ""
    @State private var savedKeys = Set<String>()
    @State private var message = ""
    @State private var testing = false
    @State private var testTask: Task<Void, Never>?
    @State private var testRevision = 0

    var body: some View {
        Form {
            if model.store?.isUsingSharedGroup == false {
                Section("全能签兼容模式") {
                    Text("App Group 未被当前签名保留。填写并测试 DeepSeek Key 后，点下方“复制键盘独立配置”，再切回聊天键盘；键盘出现时会自动同步，顶栏会显示 DeepSeek Key 是否已配置。")
                        .font(.footnote).foregroundStyle(Palette.secondary)
                    Button("复制键盘独立配置") { copyKeyboardConfig() }
                        .accessibilityIdentifier("copyKeyboardConfigButton")
                }
            }
            Section("策略判断与回复生成") {
                Picker("策略判断", selection: $draft.judge) { ForEach(JudgeProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Picker("回复生成", selection: $draft.reply) { ForEach(ReplyProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Button("判断＋回复均使用 DeepSeek") { draft.judge = .deepseek; draft.reply = .deepseek }
                Text("只用 DeepSeek 时只需配置 DeepSeek Key。策略先整理证据，再检查首 token 权重；缺失或不稳定时标注不可用。")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
            Section("DeepSeek 官方") {
                Text("https://api.deepseek.com").font(.caption).foregroundStyle(Palette.secondary)
                modelField("模型 ID", value: $draft.deepseekModel)
                keyField("deepseek", value: $deepseekKey)
                testButton("测试 DeepSeek", provider: .deepseek)
            }
            Section("OpenRouter") {
                Text("https://openrouter.ai/api/v1").font(.caption).foregroundStyle(Palette.secondary)
                modelField("回复模型 ID", value: $draft.openrouterModel)
                modelField("识图模型 ID（独立配置）", value: $draft.visionModel)
                keyField("openrouter", value: $openrouterKey)
                testButton("测试 OpenRouter 回复", provider: .openrouter)
                Text("识图模型须支持图片输入。模型 ID 可从服务商模型页复制；免费模型的可用性和限额由服务商决定。")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
            Section("TypeSafe Jev（选用）") {
                modelField("模型 ID", value: $draft.jevModel)
                keyField("jev", value: $jevKey)
                Button("测试 Jev 判断") { testJev() }.disabled(testing)
            }
            Section("截图识别") {
                Picker("识别方式", selection: $draft.ocr) { ForEach(OCRProvider.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                Text("Apple Vision 在手机本地识别。云端识图会发送你选的截图，使用对应服务的 Key 并产生用量；键盘自身不截屏，日常拼音和英文输入在本机完成。")
                    .font(.caption).foregroundStyle(Palette.secondary)
            }
            Section("回复偏好") {
                Picker("口吻", selection: $draft.tone) { ForEach(["稳健", "会撩", "直接"], id: \.self) { Text($0).tag($0) } }
                Picker("长度", selection: $draft.length) { ForEach(["简短", "适中", "详细"], id: \.self) { Text($0).tag($0) } }
                Stepper("最多 \(draft.count) 条候选", value: $draft.count, in: 1...3)
            }
            Section {
                Button("保存并应用配置") { save() }.buttonStyle(BrandPrimaryButtonStyle())
                    .disabled(testing || model.store == nil).accessibilityIdentifier("saveConfigButton")
                if testing { HStack { ProgressView(); Button("取消测试") { cancelTest(); message = "已取消" } } }
                Text(message).font(.footnote).foregroundStyle(Palette.secondary).textSelection(.enabled)
            } footer: {
                Text("密钥优先保存在 App 与键盘共享的本机配置容器，可用时同步备份到钥匙串；已存 Key 不回显，空白表示保留原 Key。聊天仅在你确认分析时发送到所选接口。")
            }
            Section("本地数据") {
                Button("清除键盘暂存与等待取用的内容") {
                    model.store?.clearHandoff(); model.store?.captureMailbox.clear(); model.store?.clearKeyboardSession()
                    message = "已清除键盘本轮暂存、临时交接与截屏内容"
                }
                Button("清空本轮原文与结果") { model.transcript = ""; model.invalidate(clear: true); message = "已清空本轮" }
            }
        }
        .scrollContentBackground(.hidden).background(Palette.cream)
        .onAppear { draft = model.config; refreshKeys() }
        .onDisappear { cancelTest(); deepseekKey = ""; openrouterKey = ""; jevKey = "" }
    }

    private func cancelTest() {
        testRevision += 1; testTask?.cancel(); testTask = nil; testing = false
    }
    private func modelField(_ title: String, value: Binding<String>) -> some View {
        TextField(title, text: value).textInputAutocapitalization(.never).autocorrectionDisabled()
    }
    private func keyField(_ name: String, value: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SecureField(savedKeys.contains(name) ? "已配置，填写新 Key 可替换" : "填写 API Key", text: value)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
                .accessibilityIdentifier(name + "KeyField")
            if savedKeys.contains(name) {
                Button("删除此服务的 Key", role: .destructive) {
                    do { try CredentialVault.delete(name); value.wrappedValue = ""; refreshKeys(); model.cancel(); message = "已删除此服务的 Key" }
                    catch { message = error.localizedDescription }
                }.font(.caption)
            }
        }
    }
    private func refreshKeys() {
        do {
            savedKeys = []
            for name in CredentialVault.services where !(try CredentialVault.read(name)).isEmpty { savedKeys.insert(name) }
        } catch { message = error.localizedDescription }
    }
    private func secrets() throws -> ProviderSecrets {
        var result = try CredentialVault.load()
        if !deepseekKey.trimmed.isEmpty { result.deepseek = deepseekKey.trimmed }
        if !openrouterKey.trimmed.isEmpty { result.openrouter = openrouterKey.trimmed }
        if !jevKey.trimmed.isEmpty { result.jev = jevKey.trimmed }
        return result
    }
    private func save() {
        do {
            try draft.validate()
            guard let store = model.store else { throw GoutouError.invalid("App Group 未连接") }
            for (name, value) in [("deepseek", deepseekKey), ("openrouter", openrouterKey), ("jev", jevKey)] where !value.trimmed.isEmpty {
                try CredentialVault.write(value, name: name)
            }
            try store.saveConfig(draft)
            deepseekKey = ""; openrouterKey = ""; jevKey = ""
            refreshKeys(); model.reload(); message = "已保存，下一次键盘分析使用新配置。"
        } catch { message = error.localizedDescription }
    }
    private func copyKeyboardConfig() {
        do {
            try draft.validate()
            let values = try secrets()
            var keys = [String: String]()
            if !values.deepseek.trimmed.isEmpty { keys["deepseek"] = values.deepseek.trimmed }
            if !values.openrouter.trimmed.isEmpty { keys["openrouter"] = values.openrouter.trimmed }
            if !values.jev.trimmed.isEmpty { keys["jev"] = values.jev.trimmed }
            let transfer = KeyboardConfigTransfer(config: draft, secrets: keys)
            try transfer.validate()
            UIPasteboard.general.string = try transfer.clipboardText()
            message = "独立配置已复制（含 API Key）。请在 10 分钟内切到键盘；键盘出现后会自动同步并覆盖剪贴板。"
        } catch { message = error.localizedDescription }
    }
    private func testButton(_ title: String, provider: ReplyProvider) -> some View {
        Button(title) {
            do {
                let api = ModelAPI(transport: model.transport, config: draft, secrets: try secrets())
                cancelTest()
                let generation = testRevision
                testing = true; message = "连接测试中，会产生少量接口用量…"
                testTask = Task {
                    do {
                        try await api.test(provider); try Task.checkCancellation()
                        guard testRevision == generation else { return }
                        message = "连接成功；真实分析与识图还需分别验证。"
                    } catch {
                        guard testRevision == generation else { return }
                        message = error is CancellationError ? "已取消" : error.localizedDescription
                    }
                    testing = false
                }
            } catch { message = error.localizedDescription }
        }.disabled(testing)
    }
    private func testJev() {
        do {
            let api = ModelAPI(transport: model.transport, config: draft, secrets: try secrets())
            cancelTest()
            let generation = testRevision
            testing = true; message = "测试 Jev 判断中，会产生接口用量…"
            testTask = Task {
                do {
                    _ = try await GoutouPipeline(api: api).jevDecision("连接测试。对方说今天工作忙，用户希望自然接话。")
                    try Task.checkCancellation()
                    guard testRevision == generation else { return }
                    message = "Jev 策略接口连接成功。"
                } catch {
                    guard testRevision == generation else { return }
                    message = error is CancellationError ? "已取消" : error.localizedDescription
                }
                testing = false
            }
        } catch { message = error.localizedDescription }
    }
}

struct RelationshipView: View {
    @EnvironmentObject var model: AppModel
    @State private var draft = Relationship(id: "current")
    @State private var archive = false
    @State private var profiles = [Relationship]()
    @State private var message = ""
    @State private var deleteAll = false

    var body: some View {
        Form {
            Section {
                TextField("称呼或代号", text: $draft.label)
                Picker("关系阶段", selection: $draft.stage) { ForEach(Relationship.stages, id: \.self) { Text($0).tag($0) } }
                Picker("本轮目标", selection: $draft.goal) { ForEach(Relationship.goals, id: \.self) { Text($0).tag($0) } }
                TextField("最近发生了什么（最多 200 字）", text: $draft.background, axis: .vertical).lineLimit(3...6)
                TextField("需要遵守的边界或备注（最多 200 字）", text: $draft.notes, axis: .vertical).lineLimit(2...4)
                Toggle("同时保存为可切换的对象档案", isOn: $archive)
                Button("保存当前对象与目标") {
                    do {
                        guard let store = model.store else { throw GoutouError.invalid("共享配置未连接") }
                        try store.saveRelationship(draft, archive: archive); model.reload(); profiles = store.archived()
                        message = "已保存；下次分析前请核对聊天对象。"
                    } catch { message = error.localizedDescription }
                }.buttonStyle(BrandPrimaryButtonStyle())
                Text(message).font(.footnote).foregroundStyle(Palette.secondary)
            } header: {
                Text("当前对象")
            } footer: {
                Text("只保存你主动填写的对象资料，不保存整份聊天。分析时会把当前对象的阶段、目标、背景与本轮原文交给所选模型。键盘无法自动识别聊天对象，换会话后请手动选择。")
            }
            Section("已保存的对象") {
                Button("新建对象") { draft = Relationship(); archive = true }
                ForEach(profiles) { profile in
                    Button { draft = profile; archive = true; message = "已载入，点保存后应用到键盘。" } label: {
                        VStack(alignment: .leading) { Text(profile.label); Text(profile.stage + " · " + profile.goal).font(.caption).foregroundStyle(Palette.secondary) }
                    }
                }.onDelete { indices in
                    do {
                        guard let store = model.store else { return }
                        for index in indices { try store.deleteProfile(profiles[index].id) }
                        profiles = store.archived(); model.reload(); draft = model.relationship
                    } catch { message = error.localizedDescription }
                }
                Button("删除所有对象资料", role: .destructive) { deleteAll = true }
            }
        }.scrollContentBackground(.hidden).background(Palette.cream)
            .onAppear { draft = model.relationship; profiles = model.store?.archived() ?? [] }
            .confirmationDialog("删除所有本机对象资料？", isPresented: $deleteAll, titleVisibility: .visible) {
                Button("删除所有资料", role: .destructive) { model.store?.clearProfiles(); model.reload(); draft = model.relationship; profiles = [] }
            }
    }
}
