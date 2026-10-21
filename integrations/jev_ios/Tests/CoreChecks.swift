import Foundation

enum CheckError: Error { case failed(String) }

final class MockTransport: JSONTransport {
    struct Call { var body: [String: Any]; var url: URL; var key: String }
    var calls = [Call]()
    var replies: [[String: Any]]
    var failAt: Int?
    var cancelAt: Int?
    init(_ replies: [[String: Any]]) { self.replies = replies }
    func post(_ body: [String: Any], to url: URL, key: String) async throws -> [String: Any] {
        let index = calls.count
        calls.append(Call(body: body, url: url, key: key))
        if cancelAt == index { throw CancellationError() }
        if failAt == index { throw GoutouError.http(429) }
        guard index < replies.count else { throw CheckError.failed("Unexpected extra model request") }
        return replies[index]
    }
}

@main
struct CoreChecks {
    static var count = 0
    static func check(_ name: String, _ value: @autoclosure () throws -> Bool) throws {
        count += 1
        guard try value() else { throw CheckError.failed(name) }
    }
    static func rejects(_ name: String, _ operation: () throws -> Void) throws {
        count += 1
        do { try operation() }
        catch { return }
        throw CheckError.failed(name)
    }
    static func completion(_ raw: String, logprobs: [String: Any]? = nil, finish: String = "stop") -> [String: Any] {
        var choice: [String: Any] = ["message": ["content": raw], "finish_reason": finish]
        if let logprobs = logprobs { choice["logprobs"] = logprobs }
        return ["choices": [choice]]
    }
    static let evidence = #"{"strategy":"降压","confidence":0.6,"facts":["对方说这周忙"],"unknowns":["下周时间"],"boundary":"none"}"#
    static let response = #"{"support":"先缓一缓","intent":"可能工作忙，时间未定","intent_confidence":0.6,"facts":["对方说这周忙"],"hypotheses":["可能还没确定安排"],"unknowns":["下周时间"],"strategy":"降压","recommendation":"先接住安排","next_step":"等新信息","stop_condition":"明确要求停止联系就停止","question":"","candidates":[{"text":"好，你先忙","reason":"不追加压力","tradeoff":"没有确认见面"},{"text":"行，忙完再说","reason":"表达简短","tradeoff":"比较直接"}]}"#
    static let scores = #"{"scores":[{"id":0,"score":80},{"id":1,"score":60}]}"#
    static let secrets = ProviderSecrets(deepseek: "test-deepseek-not-a-real-key", openrouter: "test-router-not-a-real-key", jev: "test-jev-not-a-real-key")

    static func token(_ offset: Int, winner: Strategy = .ease) -> Completion {
        let labels = StrategyWeights.labels(offset)
        let selected = labels.first { $0.value == winner }!.key
        let rows = StrategyWeights.letters.map { ["token": $0, "logprob": $0 == selected ? -0.1 : -5.0] as [String: Any] }
        return Completion(content: selected, logprobs: ["content": [["token": selected, "top_logprobs": rows]]])
    }
    static func tokenReply(_ offset: Int) -> [String: Any] {
        let value = token(offset); return completion(value.content, logprobs: value.logprobs)
    }
    static func main() async {
        do {
            try contracts()
            try await pipelines()
            try await visionRequests()
            try persistenceAndTrends()
            try captures()
            try keyboardSessions()
            try draftInsertions()
            print("PASS: \(count) iOS core checks; no live API requests or private chat data")
        } catch {
            fputs("FAIL: \(error)\n", stderr)
            exit(1)
        }
    }

    static func contracts() throws {
        try check("Default uses DeepSeek independently", AppConfig().judge == .deepseek && AppConfig().reply == .deepseek)
        let transfer = KeyboardConfigTransfer(config: AppConfig(), secrets: ["deepseek": "test-only-key"])
        let encodedTransfer = try JSONEncoder().encode(transfer)
        let decodedTransfer = try JSONDecoder().decode(KeyboardConfigTransfer.self, from: encodedTransfer)
        try decodedTransfer.validate()
        try check("Keyboard config transfer round-trips", decodedTransfer.secrets["deepseek"] == "test-only-key")
        let clipboardTransfer = try decodedTransfer.clipboardText()
        let decodedClipboard = try KeyboardConfigTransfer.decodeClipboardText(clipboardTransfer)
        try check("Keyboard config clipboard marker and base64 round-trip",
                  clipboardTransfer.hasPrefix(KeyboardConfigTransfer.clipboardPrefix) &&
                  decodedClipboard.secrets["deepseek"] == "test-only-key")
        try rejects("Expired keyboard config transfer rejected") {
            var expired = transfer; expired.createdAt = Date().addingTimeInterval(-601); try expired.validate()
        }
        try rejects("Unknown keyboard secret rejected") {
            try KeyboardConfigTransfer(config: AppConfig(), secrets: ["other": "value"]).validate()
        }
        try rejects("Unmarked clipboard config rejected") {
            _ = try KeyboardConfigTransfer.decodeClipboardText("{\"version\":1}")
        }
        try check("Seven project strategies", Strategy.allCases.count == 7)
        try check("Natural voice guide bundled", GoutouGuidance.common.contains("先像本人") && GoutouGuidance.common.contains("别演自然"))
        try check("Repair guide bundled", GoutouGuidance.scene["修复冲突"] != nil)
        try check("Goal mapping retained", Relationship.goals.count == 6 && Relationship.stages.count == 7)
        try check("DeepSeek root URL", try ModelAPI.chatURL("https://api.deepseek.com").absoluteString == "https://api.deepseek.com/chat/completions")
        try check("DeepSeek v1 URL", try ModelAPI.chatURL("https://api.deepseek.com/v1/").absoluteString == "https://api.deepseek.com/v1/chat/completions")
        try check("Full action URL", try ModelAPI.chatURL("https://openrouter.ai/api/v1/chat/completions").path == "/api/v1/chat/completions")
        try rejects("Reject HTTP") { _ = try ModelAPI.chatURL("http://untrusted.example") }
        try rejects("Reject credentials in URL") { _ = try ModelAPI.chatURL("https://key@untrusted.example") }
        try rejects("Reject query in URL") { _ = try ModelAPI.chatURL("https://untrusted.example?k=secret") }
        try rejects("Require transcript review") { try Transcript(text: "对方：忙", confirmed: false).validate() }
        try rejects("Reject pending OCR labels") { try Transcript(text: "说话人待确认：忙", confirmed: true).validate() }
        try rejects("Reject empty transcript") { try Transcript(text: " ", confirmed: true).validate() }
        try check("Learn only my lines", Transcript(text: "我：嗯\n对方：哈哈\n我:好", confirmed: true).myLines == ["我：嗯", "我:好"])
        try rejects("Reject invalid candidate preference") { var config = AppConfig(); config.count = 4; try config.validate() }
        try rejects("Require vision model for OpenRouter") { var config = AppConfig(); config.ocr = .openrouter; try config.validate() }
        try check("Allow complete fenced JSON", try ModelJSON.object("FENCEjson\n{\"ok\":true}\nFENCE".replacingOccurrences(of: "FENCE", with: String(repeating: "`", count: 3)))["ok"] as? Bool == true)
        try rejects("Reject explanatory text around JSON") { _ = try ModelJSON.object("Here is it: {\"ok\":true}") }
        try rejects("Reject multiple JSON objects") { _ = try ModelJSON.object("{}{}") }
        try rejects("Reject boolean confidence") { _ = try ModelJSON.confidence(true) }
        try rejects("Reject confidence above one") { _ = try ModelJSON.confidence(2.0) }
        try check("Unknown confidence remains nil", try ModelJSON.confidence(NSNull()) == nil)
        try check("Normalize string evidence", try ModelJSON.rows("对方说忙") == ["对方说忙"])
        try check("Normalize text object evidence", try ModelJSON.rows([["text": "事实"]]) == ["事实"])
        try rejects("Reject other evidence object") { _ = try ModelJSON.rows(["invented": "事实"]) }
        let api = ModelAPI(transport: MockTransport([]), config: AppConfig(), secrets: secrets)
        let pipeline = GoutouPipeline(api: api)
        let decision = try pipeline.parseEvidence(evidence)
        let advice = try ModelJSON.advice(response, config: AppConfig(), decision: decision)
        try check("Advice contract accepted", advice.candidates.count == 2 && advice.strategy == .ease)
        try rejects("Reject conflicting strategy") {
            _ = try ModelJSON.advice(response.replacingOccurrences(of: "\"strategy\":\"降压\"", with: "\"strategy\":\"约见\""), config: AppConfig(), decision: decision)
        }
        try rejects("Reject intent confidence without facts") {
            _ = try ModelJSON.advice(response.replacingOccurrences(of: "\"facts\":[\"对方说这周忙\"]", with: "\"facts\":[]"), config: AppConfig(), decision: decision)
        }
        try rejects("Require stop strategy for explicit boundary") {
            _ = try pipeline.parseEvidence(evidence.replacingOccurrences(of: "\"none\"", with: "\"explicit_refusal\""))
        }
        for offset in StrategyWeights.rotations {
            let distribution = try StrategyWeights.parse(token(offset), labels: StrategyWeights.labels(offset))
            try check("Rotation \(offset) maps back to same strategy", distribution["降压"]! > 0.9)
            try check("Rotation \(offset) sums to one", abs(distribution.values.reduce(0, +) - 1) < 0.00001)
        }
        try rejects("Never use a later token") {
            var value = token(0); value.logprobs = ["content": [["token": " ", "top_logprobs": []], value.logprobs!["content"]!]]
            _ = try StrategyWeights.parse(value, labels: StrategyWeights.labels(0))
        }
        try rejects("Reject missing logprobs") { _ = try StrategyWeights.parse(Completion(content: "A"), labels: StrategyWeights.labels(0)) }
        let rounds = try StrategyWeights.rotations.map { try StrategyWeights.parse(token($0), labels: StrategyWeights.labels($0)) }
        try check("Stable rotation distribution accepted", StrategyWeights.merge(rounds, evidence: decision).method == "deepseek_logprobs")
        var unstable = rounds; unstable[1] = ["约见": 1]
        try check("Unstable rotation retains evidence fallback", StrategyWeights.merge(unstable, evidence: decision).probabilities.isEmpty)
        let tied = Dictionary(uniqueKeysWithValues: Strategy.allCases.map { ($0.rawValue, 1.0 / 7) })
        try check("Tied labels never imply a stable winner", StrategyWeights.merge([tied, tied, tied], evidence: decision).probabilities.isEmpty)
        let ranked = try CandidateRanking.apply(advice.candidates, raw: scores)
        try check("Ranking normalizes to 100", ranked.compactMap(\.weight).reduce(0, +) == 100)
        try check("Largest remainder retained", ranked.map(\.weight) == [57, 43])
        try rejects("Duplicate ranking IDs rejected") { _ = try CandidateRanking.apply(advice.candidates, raw: #"{"scores":[{"id":0,"score":1},{"id":0,"score":1}]}"#) }
        try rejects("Boolean ranking IDs rejected") { _ = try CandidateRanking.apply(advice.candidates, raw: #"{"scores":[{"id":true,"score":1},{"id":0,"score":1}]}"#) }
        try rejects("Zero total scores rejected") { _ = try CandidateRanking.apply(advice.candidates, raw: #"{"scores":[{"id":0,"score":0},{"id":1,"score":0}]}"#) }
        try rejects("Non-integral ID rejected") { _ = try CandidateRanking.apply(advice.candidates, raw: #"{"scores":[{"id":0.5,"score":1},{"id":1,"score":2}]}"#) }
    }
    static func draftInsertions() throws {
        var transfer = DraftInsertion()
        let config = AppConfig(), relationship = Relationship(id: "recipient-a")
        let document = UUID(), now = Date()
        func approve(_ value: inout DraftInsertion, documentID: UUID = document, revision: Int = 3,
                     context: Relationship = relationship, settings: AppConfig = config,
                     visible: Bool = true, access: Bool = true, composition: Bool = false,
                     at date: Date = now) throws -> String {
            try value.consume(documentID: documentID, revision: revision, relationship: context,
                config: settings, visible: visible, fullAccess: access, hasComposition: composition, at: date)
        }
        func prepare(_ value: inout DraftInsertion) throws {
            try value.prepare(text: "好，你先忙", documentID: document, revision: 3,
                relationship: relationship, config: config, at: now)
        }
        try prepare(&transfer)
        try check("Draft preview is exact text for the confirmed recipient", transfer.pending?.text == "好，你先忙" && transfer.pending?.relationship == relationship)
        try check("Draft confirmation returns one insert without changing context", try approve(&transfer) == "好，你先忙" && transfer.pending == nil)
        try rejects("Repeated confirm cannot duplicate draft") { _ = try approve(&transfer) }
        try prepare(&transfer); transfer.cancel()
        try rejects("Cancel prevents later draft insertion") { _ = try approve(&transfer) }
        try prepare(&transfer)
        try rejects("Changed host document cannot receive old candidate") { _ = try approve(&transfer, documentID: UUID()) }
        try prepare(&transfer)
        try rejects("Changed analysis invalidates candidate confirmation") { _ = try approve(&transfer, revision: 4) }
        try prepare(&transfer)
        try rejects("Changed recipient cannot receive candidate") { _ = try approve(&transfer, context: Relationship(id: "recipient-b")) }
        var changed = config; changed.ocr = .deepseek
        try prepare(&transfer)
        try rejects("Changed configuration invalidates draft confirmation") { _ = try approve(&transfer, settings: changed) }
        try prepare(&transfer)
        try rejects("Hidden keyboard cannot fill a draft") { _ = try approve(&transfer, visible: false) }
        try prepare(&transfer)
        try rejects("Lost Full Access cancels pending fill") { _ = try approve(&transfer, access: false) }
        try prepare(&transfer)
        try rejects("Pending Pinyin must be handled before draft insertion") { _ = try approve(&transfer, composition: true) }
        try prepare(&transfer)
        try rejects("Old confirmation expires") { _ = try approve(&transfer, at: now.addingTimeInterval(61)) }
        try prepare(&transfer)
        try rejects("Future confirmation timestamp rejected") { _ = try approve(&transfer, at: now.addingTimeInterval(-1)) }
        try check("Failed confirmation is consumed, not reused", transfer.pending == nil)
        try rejects("Empty candidate cannot be confirmed") {
            try transfer.prepare(text: " ", documentID: document, revision: 3, relationship: relationship, config: config)
        }
        try rejects("Oversized candidate cannot be inserted") {
            try transfer.prepare(text: String(repeating: "字", count: config.maxCharacters + 1), documentID: document,
                revision: 3, relationship: relationship, config: config)
        }
    }
    static func captures() throws {
        let suite = "goutou-capture-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = GoutouStore(defaults: defaults, container: directory)
        let config = store.config(), relationship = store.relationship(), now = Date()
        let mailbox = store.captureMailbox
        let request = KeyboardCaptureRequest(relationship: relationship, config: config, excludedBottomFraction: 0.4)
        let result = KeyboardCaptureResult(request: request, transcript: "对方：下周再看看吧")
        try check("Capture request expires after 90 seconds", !request.valid(at: now.addingTimeInterval(91)))
        try check("Future capture request rejected", !request.valid(at: now.addingTimeInterval(-1)))
        try check("Capture result expires after 5 minutes", !result.valid(at: now.addingTimeInterval(301), relationship: relationship, config: config))
        try mailbox.arm(request); try mailbox.publish(result)
        try check("Capture text crosses process boundary", GoutouStore(defaults: defaults, container: directory).captureMailbox.take(relationship: relationship, config: config)?.transcript == result.transcript)
        try check("Capture consumed once", mailbox.take(relationship: relationship, config: config) == nil)
        try rejects("Capture without user-armed request refused") { try mailbox.publish(result) }
        try mailbox.arm(request)
        var wrong = result; wrong.request.id = UUID()
        try rejects("Capture nonce mismatch refused") { try mailbox.publish(wrong) }
        try mailbox.publish(result)
        var another = relationship; another.id = "other"
        try check("Capture cannot follow switched recipient", mailbox.take(relationship: another, config: config) == nil)
        try mailbox.arm(request)
        var changed = config; changed.tone = "直接"
        try store.saveConfig(changed)
        try check("Changing settings clears capture request", mailbox.request() == nil)
        try store.saveConfig(config); try mailbox.arm(request)
        try mailbox.publish(KeyboardCaptureResult(request: request, transcript: "", error: "系统返回全黑画面"))
        try check("Capture failure crosses without fake transcript", mailbox.take(relationship: relationship, config: config)?.error == "系统返回全黑画面")
        try mailbox.arm(request)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("capture-result.json"))
        try check("Corrupt capture removed", mailbox.take(relationship: relationship, config: config) == nil && mailbox.request() == nil)
        try mailbox.arm(request)
        try Data(repeating: 0, count: 5_500_001).write(to: directory.appendingPathComponent("capture-result.json"))
        try check("Oversized capture rejected", mailbox.take(relationship: relationship, config: config) == nil)
        var empty = result; empty.transcript = ""
        try mailbox.arm(request)
        try rejects("Empty success capture refused") { try mailbox.publish(empty) }
        var oversized = result; oversized.transcript = String(repeating: "字", count: 12_001)
        try rejects("Overlong capture refused") { try mailbox.publish(oversized) }
        try store.saveRelationship(another, archive: false)
        try check("Changing profile clears capture request", mailbox.request() == nil)

        try store.saveRelationship(relationship, archive: false)
        var cloud = config; cloud.ocr = .deepseek
        try store.saveConfig(cloud)
        let cloudRequest = KeyboardCaptureRequest(relationship: relationship, config: cloud, excludedBottomFraction: 0.4)
        // Only mailbox validation is exercised here; ImageChecks uses a real JPEG.
        let image = Data([0xff, 0xd8, 0xff, 0x01])
        let cloudResult = KeyboardCaptureResult(request: cloudRequest, transcript: "", screenshot: image)
        try mailbox.arm(cloudRequest); try mailbox.publish(cloudResult)
        try check("Cloud capture contains image only", mailbox.peek(relationship: relationship, config: cloud)?.screenshot == image)
        try check("Preview polling does not consume upload confirmation", mailbox.peek(relationship: relationship, config: cloud)?.screenshot == image)
        let reopened = GoutouStore(defaults: defaults, container: directory)
        try check("Pending cloud image survives keyboard process recreation", reopened.captureMailbox.peek(relationship: relationship, config: cloud)?.screenshot == image)
        try check("Cloud preview expires after five minutes", !cloudResult.valid(at: cloudResult.createdAt.addingTimeInterval(301), relationship: relationship, config: cloud))
        try check("Cloud preview cannot be used under local config", !cloudResult.valid(at: Date(), relationship: relationship, config: config))
        try check("Explicit consumption clears image", mailbox.take(relationship: relationship, config: cloud)?.screenshot == image && mailbox.peek(relationship: relationship, config: cloud) == nil)
        try mailbox.arm(cloudRequest)
        var mixed = cloudResult; mixed.transcript = "对方：忙"
        try rejects("Cloud image and local transcript cannot coexist") { try mailbox.publish(mixed) }
        var tooLarge = cloudResult; tooLarge.screenshot = image + Data(count: 4_000_001)
        try rejects("Reject oversized pending screenshot") { try mailbox.publish(tooLarge) }
        var malformed = cloudResult; malformed.screenshot = Data("not JPEG".utf8)
        try rejects("Reject non-JPEG mailbox image") { try mailbox.publish(malformed) }
        try mailbox.publish(cloudResult)
        try store.saveConfig(config)
        try check("Changing OCR provider clears pending cloud image", mailbox.peek(relationship: relationship, config: cloud) == nil)
        try mailbox.arm(request)
        let localImage = KeyboardCaptureResult(request: request, transcript: "", screenshot: image)
        try rejects("Local captures cannot produce cloud upload image") { try mailbox.publish(localImage) }
        try store.saveConfig(cloud); try mailbox.arm(cloudRequest); try mailbox.publish(cloudResult)
        mailbox.clear()
        try check("Cancel removes image and request", mailbox.peek(relationship: relationship, config: cloud) == nil && mailbox.request() == nil)
    }

    static func visionRequests() async throws {
        var config = AppConfig()
        config.deepseekModel = "test-ds-vision"
        config.openrouterModel = "test-router-text"
        config.visionModel = "test-router-vision"
        let image = Data([0xff, 0xd8, 0xff]).base64EncodedString()
        let raw = #"{"transcript":"对方：下周再看看吧"}"#
        for provider in ReplyProvider.allCases {
            let mock = MockTransport([completion(raw)])
            let api = ModelAPI(transport: mock, config: config, secrets: secrets)
            let text = try await api.recognizeImage(base64: image, provider: provider)
            try check("\(provider) OCR uses returned text", text == "对方：下周再看看吧")
            try check("\(provider) OCR makes one image request", mock.calls.count == 1)
            let call = mock.calls[0]
            try check("\(provider) OCR uses selected endpoint", call.url.host == (provider == .deepseek ? "api.deepseek.com" : "openrouter.ai"))
            try check("\(provider) OCR uses selected credential", call.key == (provider == .deepseek ? secrets.deepseek : secrets.openrouter))
            try check("\(provider) OCR uses selected vision model", call.body["model"] as? String == (provider == .deepseek ? config.deepseekModel : config.visionModel))
            let messages = call.body["messages"] as? [[String: Any]]
            let content = messages?.last?["content"] as? [[String: Any]]
            try check("\(provider) OCR includes confirmed image", (content?.last?["image_url"] as? [String: Any])?["url"] as? String == "data:image/jpeg;base64," + image)
        }
        let failed = MockTransport([]); failed.failAt = 0
        do {
            _ = try await ModelAPI(transport: failed, config: config, secrets: secrets).recognizeImage(base64: image, provider: .deepseek)
            throw CheckError.failed("Cloud failure silently returned local OCR")
        } catch GoutouError.http(429) { try check("Cloud failure surfaces without fallback", failed.calls.count == 1) }
        let missing = MockTransport([])
        do {
            _ = try await ModelAPI(transport: missing, config: config, secrets: ProviderSecrets()).recognizeImage(base64: image, provider: .deepseek)
            throw CheckError.failed("Missing cloud key returned OCR")
        } catch GoutouError.invalid { try check("Missing key makes no OCR request", missing.calls.isEmpty) }
    }

    static func keyboardSessions() throws {
        let suite = "goutou-keyboard-session-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = GoutouStore(defaults: defaults, container: directory)
        let relationship = store.relationship(), config = store.config(), now = Date()
        var session = KeyboardSession(transcript: "我：周末看展吗\n对方：这周忙，下周再说", advice: nil,
                                      relationship: relationship, config: config, createdAt: now)
        try store.saveKeyboardSession(session)
        let reopened = GoutouStore(defaults: defaults, container: directory)
        try check("Keyboard transcript survives controller/process recreation", reopened.keyboardSession()?.transcript == session.transcript)
        try check("Reopening does not consume resumable round", reopened.keyboardSession() != nil && reopened.keyboardSession() != nil)
        try check("Reopening does not extend expiry", reopened.keyboardSession()?.createdAt == now)
        session.advice = DemoConversation.advice
        try store.saveKeyboardSession(session)
        try check("Advice survives closing and reopening keyboard", GoutouStore(defaults: defaults, container: directory).keyboardSession()?.advice == session.advice)
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session)) as! [String: Any]
        try check("Confirmation, image and typing state are not persisted", Set(json.keys) == ["transcript", "advice", "relationship", "config", "createdAt"])
        try check("Session expires after five minutes", !session.valid(at: now.addingTimeInterval(301), relationship: relationship, config: config))
        try check("Future session rejected", !session.valid(at: now.addingTimeInterval(-1), relationship: relationship, config: config))
        var expired = session; expired.createdAt = now.addingTimeInterval(-301)
        try rejects("Expired session cannot be saved") { try store.saveKeyboardSession(expired) }
        try JSONEncoder().encode(expired).write(to: directory.appendingPathComponent("keyboard-session.json"))
        _ = GoutouStore(defaults: defaults, container: directory)
        try check("Expired session removed on next process entry", store.keyboardSession() == nil && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("keyboard-session.json").path))
        try store.saveKeyboardSession(session)
        var changed = config; changed.tone = "直接"
        try store.saveConfig(changed)
        try check("Settings change clears resumable round", store.keyboardSession() == nil)
        try rejects("Stale settings cannot restore old round") { try store.saveKeyboardSession(session) }
        try store.saveConfig(config); try store.saveKeyboardSession(session)
        var other = relationship; other.id = "another-recipient"
        try store.saveRelationship(other, archive: false)
        try check("Recipient change clears resumable round", store.keyboardSession() == nil)
        try store.saveRelationship(relationship, archive: false); try store.saveKeyboardSession(session)
        store.clearKeyboardSession()
        try check("Explicit clear removes round across processes", reopened.keyboardSession() == nil)
        try Data("broken".utf8).write(to: directory.appendingPathComponent("keyboard-session.json"))
        try check("Corrupt session is removed", store.keyboardSession() == nil && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("keyboard-session.json").path))
        try Data(repeating: 0, count: 512_001).write(to: directory.appendingPathComponent("keyboard-session.json"))
        try check("Oversized session rejected", store.keyboardSession() == nil)
        var huge = session; huge.transcript = String(repeating: "字", count: 12_001)
        try rejects("Oversized transcript cannot be cached") { try store.saveKeyboardSession(huge) }
        var empty = session; empty.transcript = " "
        try rejects("Empty round cannot be cached") { try store.saveKeyboardSession(empty) }
        let request = KeyboardCaptureRequest(relationship: relationship, config: config, excludedBottomFraction: 0.4)
        try store.captureMailbox.arm(request)
        try store.saveKeyboardSession(session)
        try check("Round restoration preserves pending capture", reopened.captureMailbox.request()?.id == request.id)
        try store.captureMailbox.publish(KeyboardCaptureResult(request: request, transcript: "对方：下周再说"))
        try check("Screenshot can finish while keyboard is closed", reopened.captureMailbox.take(relationship: relationship, config: config)?.transcript == "对方：下周再说")
        try check("Capture consumption does not delete resumable round", reopened.keyboardSession()?.transcript == session.transcript)
    }

    static func pipelines() async throws {
        let transcript = Transcript(text: "我：周末看展？\n对方：这周忙，下周再说", confirmed: true)
        let replies = [completion(evidence)] + StrategyWeights.rotations.map(tokenReply) + [completion(response), completion(scores)]
        let mock = MockTransport(replies)
        let api = ModelAPI(transport: mock, config: AppConfig(), secrets: secrets)
        let advice = try await GoutouPipeline(api: api).analyze(transcript, relationship: Relationship())
        try check("DeepSeek-only end to end", advice.decision?.method == "deepseek_logprobs" && advice.candidates.count == 2)
        try check("Expected explicit pipeline stages", mock.calls.count == 6)
        try check("No Jev call in DeepSeek mode", mock.calls.allSatisfy { $0.url.host == "api.deepseek.com" && $0.key == secrets.deepseek })
        try check("Only classification calls request logprobs", mock.calls.filter { $0.body["logprobs"] as? Bool == true }.count == 3)
        try check("No stream or reasoning mode", mock.calls.allSatisfy { $0.body["stream"] as? Bool == false && ($0.body["thinking"] as? [String: String])?["type"] == "disabled" })
        var config = AppConfig(); config.reply = .openrouter
        let mixed = MockTransport(replies)
        _ = try await GoutouPipeline(api: ModelAPI(transport: mixed, config: config, secrets: secrets)).analyze(transcript, relationship: Relationship())
        try check("DeepSeek judge and router draft keep keys separate", mixed.calls.prefix(4).allSatisfy { $0.key == secrets.deepseek }
                  && mixed.calls.suffix(2).allSatisfy { $0.key == secrets.openrouter && $0.url.host == "openrouter.ai" })
        let missing = MockTransport([completion(evidence), completion("A"), completion(response), completion(scores)])
        let fallback = try await GoutouPipeline(api: ModelAPI(transport: missing, config: AppConfig(), secrets: secrets)).analyze(transcript, relationship: Relationship())
        try check("Missing token data keeps DeepSeek evidence", fallback.decision?.method == "deepseek_self_report" && fallback.decision?.probabilities.isEmpty == true)
        try check("Does not silently fall back to Jev", missing.calls.allSatisfy { $0.url.host == "api.deepseek.com" })
        let repair = MockTransport([completion("{}"), completion(evidence), completion("A"), completion(response), completion(scores)])
        _ = try await GoutouPipeline(api: ModelAPI(transport: repair, config: AppConfig(), secrets: secrets)).analyze(transcript, relationship: Relationship())
        try check("One bounded evidence repair", repair.calls.count == 5)
        let malformed = MockTransport([completion("{}"), completion("{}")])
        do {
            _ = try await GoutouPipeline(api: ModelAPI(transport: malformed, config: AppConfig(), secrets: secrets)).analyze(transcript, relationship: Relationship())
            throw CheckError.failed("Malformed evidence must stop generation")
        } catch is GoutouError {}
        try check("Malformed evidence never generates candidates", malformed.calls.count == 2)
        let failedRank = MockTransport(replies); failedRank.failAt = 5
        let unranked = try await GoutouPipeline(api: ModelAPI(transport: failedRank, config: AppConfig(), secrets: secrets)).analyze(transcript, relationship: Relationship())
        try check("Ranking failure preserves candidates without fabricated scores", unranked.rankingStatus == "unavailable" && unranked.candidates.allSatisfy { $0.weight == nil })
        let cancelled = MockTransport(replies); cancelled.cancelAt = 1
        do {
            _ = try await GoutouPipeline(api: ModelAPI(transport: cancelled, config: AppConfig(), secrets: secrets)).analyze(transcript, relationship: Relationship())
            throw CheckError.failed("Cancellation must propagate")
        } catch is CancellationError {}
        try check("Cancellation does not continue drafting", cancelled.calls.count == 2)
        let invalidReview = MockTransport([])
        do {
            _ = try await GoutouPipeline(api: ModelAPI(transport: invalidReview, config: AppConfig(), secrets: secrets)).analyze(Transcript(text: "对方：忙", confirmed: false), relationship: Relationship())
            throw CheckError.failed("Unconfirmed transcript must stop")
        } catch is GoutouError {}
        try check("Unconfirmed text never reaches provider", invalidReview.calls.isEmpty)
        var jevConfig = AppConfig(); jevConfig.judge = .jev
        let probabilities = Dictionary(uniqueKeysWithValues: Strategy.allCases.map { ($0.rawValue, $0 == .ease ? 0.7 : 0.05) })
        let jevRaw: [String: Any] = ["answers": ["reply_strategy": ["type": "choice", "choice": "降压", "confidence": 0.7, "probabilities": probabilities]]]
        let jevMock = MockTransport([jevRaw, completion(response), completion(scores)])
        let jevResult = try await GoutouPipeline(api: ModelAPI(transport: jevMock, config: jevConfig, secrets: secrets)).analyze(transcript, relationship: Relationship())
        try check("Jev can be selected independently", jevResult.decision?.method == "jev" && jevMock.calls.first?.url.host == "api.typesafe.ai")
        try check("Jev key only goes to Jev", jevMock.calls.first?.key == secrets.jev && jevMock.calls.dropFirst().allSatisfy { $0.key == secrets.deepseek })
        let rewriteRaw = #"{"intent":"ignored new intent","strategy":"降压","candidates":[{"text":"嗯，你先忙","reason":"朴素接话","tradeoff":"没有确定时间"}]}"#
        let rewriteMock = MockTransport([completion(rewriteRaw)])
        let rewritten = try await GoutouPipeline(api: ModelAPI(transport: rewriteMock, config: AppConfig(), secrets: secrets)).rewrite(advice, transcript: transcript, relationship: Relationship())
        try check("Rewrite preserves accepted analysis", rewritten.intent == advice.intent && rewritten.facts == advice.facts && rewritten.decision == advice.decision)
        try check("Single candidate weight is comparison share", rewritten.candidates.first?.weight == 100)
    }

    static func persistenceAndTrends() throws {
        let relationship = Relationship(id: "test-profile")
        let now = Date()
        let handoff = KeyboardHandoff(transcript: "对方：忙", advice: DemoConversation.advice, relationship: relationship, config: AppConfig(), createdAt: now)
        try check("Fresh handoff accepted", handoff.valid(at: now, relationship: relationship, config: AppConfig()))
        try check("Expired handoff rejected", !handoff.valid(at: now.addingTimeInterval(301), relationship: relationship, config: AppConfig()))
        try check("Future handoff rejected", !handoff.valid(at: now.addingTimeInterval(-1), relationship: relationship, config: AppConfig()))
        var changed = relationship; changed.goal = "主动邀约"
        try check("Wrong relationship rejected", !handoff.valid(at: now, relationship: changed, config: AppConfig()))
        var changedConfig = AppConfig(); changedConfig.reply = .openrouter
        try check("Wrong configuration rejected", !handoff.valid(at: now, relationship: relationship, config: changedConfig))
        let suite = "goutou-core-checks-" + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: directory) }
        let store = GoutouStore(defaults: defaults, container: directory)
        try store.saveRelationship(relationship, archive: false)
        try check("Current context does not auto-archive", store.archived().isEmpty)
        try store.saveRelationship(relationship, archive: true)
        try check("Archive requires explicit save", store.archived().count == 1)
        try store.handoff(handoff)
        try check("Handoff can be consumed once", store.takeHandoff() != nil && store.takeHandoff() == nil)
        var expired = handoff; expired.createdAt = now.addingTimeInterval(-301)
        try store.handoff(expired)
        _ = GoutouStore(defaults: defaults, container: directory)
        try check("Expired handoff is removed on process entry", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("handoff.json").path))
        try Data("invalid".utf8).write(to: directory.appendingPathComponent("handoff.json"))
        store.purgeExpiredHandoff()
        try check("Corrupted handoff is removed", !FileManager.default.fileExists(atPath: directory.appendingPathComponent("handoff.json").path))
        try store.handoff(handoff)
        try store.saveConfig(changedConfig)
        try check("Config change clears pending handoff", store.takeHandoff() == nil)
        try store.deleteProfile(relationship.id)
        try check("Deleting active profile clears current context", store.archived().isEmpty && store.relationship().id == "current")
        let csv = "timestamp,sender,message,event\n2026-08-01 10:00:00,me,\"hello, there\",\n2026-08-01 10:01:00,other,hi,确认见面\n2026-08-01 10:02:00,other,\"two\nlines\",\n2026-08-02 10:00:00,me,ok,\n"
        let trend = try ChatCSV.load(Data(csv.utf8))
        try check("CSV daily candles", trend.candles.count == 2 && trend.candles[0].open == 0 && trend.candles[0].close == 1)
        try check("CSV high low and message count", trend.candles[0].low == -1 && trend.candles[0].high == 1 && trend.candles[0].mine == 1 && trend.candles[0].other == 2)
        try check("CSV event annotations", trend.candles[0].events == ["确认见面"])
        try check("Quoted commas/newlines preserved", try ChatCSV.records("a,\"b,b\",\"c\nc\"")[0] == ["a", "b,b", "c\nc"])
        try check("Windows CRLF supported", try ChatCSV.records("a,b\r\nc,d\r\n").count == 2)
        try rejects("Reject duplicate headers") { _ = try ChatCSV.load(Data("timestamp,sender,message,message\nx,me,a,a".utf8)) }
        try rejects("Reject unknown sender") { _ = try ChatCSV.load(Data("timestamp,sender,message\n2026-08-01 10:00:00,them,a".utf8)) }
        try rejects("Reject unordered times") { _ = try ChatCSV.load(Data("timestamp,sender,message\n2026-08-02 10:00:00,me,a\n2026-08-01 10:00:00,other,b".utf8)) }
        try rejects("Reject incomplete quoted records") { _ = try ChatCSV.records("a,\"b") }
        try rejects("Reject invalid dates") { _ = try ChatCSV.load(Data("timestamp,sender,message\n2026-02-31 10:00:00,me,a".utf8)) }
        try rejects("Reject oversized CSV") { _ = try ChatCSV.load(Data(repeating: 65, count: 4_000_001)) }
        let iso = try ChatCSV.load(Data("timestamp,sender,message\n2026-08-02T00:00:00+08:00,other,a\n2026-08-02T00:10:00+08:00,me,b".utf8))
        try check("Timezone-aware daily grouping is normalized", iso.candles.first?.date == "2026-08-01")
    }
}
