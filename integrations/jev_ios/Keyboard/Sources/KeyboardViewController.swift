import UIKit
import ReplayKit

/// Offline typing plus user-invoked relationship advice; it never sends a chat message.
@MainActor
final class KeyboardViewController: UIInputViewController {
    private enum Mode { case idle, setup, screenshot, review, loading, result, details, insertConfirmation, gate }
    private var mode: Mode = .idle
    private var store: GoutouStore?
    private var config = AppConfig()
    private var relationship = Relationship(id: "current")
    private var transcript = ""
    private var confirmed = false
    private var advice: Advice?
    private var notice = ""
    private var documentID: UUID?
    private var revision = 0
    private var task: Task<Void, Never>?
    private let transport = HTTPTransport()
    private let content = UIStackView()
    private let scroll = UIScrollView()
    private let header = UIStackView()
    private let footer = UILabel()
    private var height: NSLayoutConstraint?
    private var typingConstraints = [NSLayoutConstraint]()
    private var confirmButton: UIButton?
    private var analyzeButton: UIButton?
    private var showTyping = true
    private var pendingScreenshot: Data?
    private var recognizedScreenshot: Data?
    private var captureTimer: Timer?
    private var waitingCapture: KeyboardCaptureRequest?
    private var receivedCaptureID: UUID?
    private var showBroadcastExperiment = false
    private var isKeyboardVisible = false
    private var persistedSession: KeyboardSession?
    private var draftInsertion = DraftInsertion()
    private var expandedReasons = Set<Int>()
    private var setupDeepseekModel = ""
    private var setupDeepseekKey = ""
    private var setupOpenRouterKey = ""
    private var setupJevKey = ""
    private lazy var typingView: TypingKeyboardView = {
        let keyboard = TypingKeyboardView()
        keyboard.onInsert = { [weak self] text in self?.textDocumentProxy.insertText(text) }
        keyboard.onDelete = { [weak self] in self?.textDocumentProxy.deleteBackward() }
        keyboard.onMove = { [weak self] offset in self?.textDocumentProxy.adjustTextPosition(byCharacterOffset: offset) }
        keyboard.onKeyboardButtonCreated = { [weak self] button in
            guard let self = self else { return }
            button.addTarget(self, action: #selector(self.handleInputModeList(from:with:)), for: .allTouchEvents)
        }
        return keyboard
    }()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = KB.cream
        view.tintColor = BrandTheme.accent
        scroll.delaysContentTouches = false
        scroll.showsVerticalScrollIndicator = true
        content.axis = .vertical; content.spacing = 12
        header.axis = .horizontal; header.spacing = 6; header.alignment = .center
        footer.font = .preferredFont(forTextStyle: .caption2)
        footer.numberOfLines = 0; footer.textColor = KB.secondary
        for item in [header, scroll, footer, typingView] { view.addSubview(item); item.translatesAutoresizingMaskIntoConstraints = false }
        scroll.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        height = view.heightAnchor.constraint(equalToConstant: 326)
        height?.priority = .init(999)
        height?.isActive = true
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.topAnchor, constant: 6),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            scroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6),
            content.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            content.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            content.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        ])
        typingConstraints = [
            typingView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 6),
            typingView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 6),
            typingView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -6),
            typingView.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -6)
        ]
        NSLayoutConstraint.activate(typingConstraints)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        isKeyboardVisible = true
        do {
            documentID = textDocumentProxy.documentIdentifier
            showTyping = true
            guard hasFullAccess else {
                invalidate(clearTranscript: true); mode = .gate; store = nil
                notice = "本地打字可用；军师分析需要开启完全访问。"; render(); return
            }
            invalidate(clearTranscript: true, clearSession: false)
            waitingCapture = nil; receivedCaptureID = nil; showBroadcastExperiment = false
            store = try GoutouStore()
            config = store!.config(); relationship = store!.relationship()
            documentID = textDocumentProxy.documentIdentifier
            store?.setKeyboardStatus(fullAccess: true)
            let importedConfig = importClipboardConfigIfPresent()
            config = store!.config(); relationship = store!.relationship()
            if let handoff = store?.takeHandoff() {
                transcript = handoff.transcript; advice = handoff.advice; confirmed = false
                mode = .result
                showTyping = false
                notice = "主 App 的本轮结果已取用；填入前请核对当前收件人。"
            } else if let request = store?.captureMailbox.request() {
                mode = .screenshot; showTyping = false
                waitingCapture = request
                notice = "等待系统快捷指令截屏 · \(config.ocr.rawValue)。"
            } else if let saved = store?.keyboardSession() {
                persistedSession = saved
                transcript = saved.transcript; advice = saved.advice; confirmed = false
                mode = advice == nil ? .review : .result
                showTyping = false
                notice = "已恢复本轮内容（暂存 5 分钟）；请重新核对原文、双方身份与当前收件人。"
            } else {
                mode = .idle
                if importedConfig {
                    notice = "配置已从主 App 自动同步；顶栏确认 Key 状态后即可分析。"
                } else {
                    notice = store?.isUsingSharedGroup == false
                        ? "App Group 未连接；请先在主 App 复制独立配置，键盘出现后会自动同步。"
                        : ""
                }
            }
            receiveCapture()
        } catch { mode = .gate; notice = error.localizedDescription }
        render()
    }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        captureTimer?.invalidate()
        captureTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.receiveCapture() }
        }
    }
    private func receiveCapture() {
        guard isKeyboardVisible, hasFullAccess, mode != .loading, mode != .insertConfirmation, mode != .setup,
              let store = store else { return }
        guard let result = store.captureMailbox.peek(relationship: store.relationship(), config: store.config()) else {
            if receivedCaptureID != nil, mode == .screenshot, pendingScreenshot != nil {
                receivedCaptureID = nil; pendingScreenshot = nil
                notice = "截图暂存已过期或配置已变化，请重新截屏。"; render()
            }
            if let pending = waitingCapture, !pending.valid(at: Date()) {
                waitingCapture = nil
                if mode == .screenshot {
                    notice = "90 秒内未收到截图。点“重新等待截图”后，用悬浮球运行“截屏 → 截图交给键盘（按配置）”。"
                    render()
                }
            }
            return
        }
        if result.screenshot != nil, receivedCaptureID == result.request.id,
           pendingScreenshot == result.screenshot { return }
        if result.screenshot == nil {
            guard store.captureMailbox.take(relationship: store.relationship(), config: store.config()) != nil else { return }
        }
        waitingCapture = nil; showBroadcastExperiment = false
        invalidate(clearTranscript: true)
        config = store.config(); relationship = store.relationship(); showTyping = false
        receivedCaptureID = result.screenshot == nil ? nil : result.request.id
        if let error = result.error {
            mode = .screenshot; notice = error
        } else if let image = result.screenshot {
            pendingScreenshot = image; mode = .screenshot
            notice = "已收到截图 · \(config.ocr.rawValue)；点“发送截图并识别”后开始。"
        } else {
            transcript = result.transcript; mode = .review; confirmed = false
            notice = "截图文字已到键盘 · \(result.request.config.ocr.rawValue)；请核对原文、双方身份及当前收件人。"
        }
        render()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateHeight()
    }
    private func updateHeight() {
        let screen = view.window?.windowScene?.coordinateSpace.bounds ?? CGRect(x: 0, y: 0, width: 390, height: 844)
        let compact = screen.width > screen.height
        typingView.setCompactLayout(compact)
        let desired = showTyping ? (compact ? 244.0 : 326.0) + view.safeAreaInsets.bottom
            : min(450, max(220, screen.height * 0.46))
        if height?.constant != desired { height?.constant = desired }
    }
    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        isKeyboardVisible = false
        captureTimer?.invalidate(); captureTimer = nil
        persistSession()
        // A keyboard may disappear while the system shortcut runs, and iOS may
        // destroy its process. Keep text in the short-lived session and keep the
        // armed capture mailbox, while canceling in-flight network work.
        invalidate(clearTranscript: false)
        recognizedScreenshot = nil
        typingView.clearComposition()
    }
    override func textDidChange(_ textInput: UITextInput?) {
        super.textDidChange(textInput)
        guard isKeyboardVisible else { return }
        if let previous = documentID, previous != textDocumentProxy.documentIdentifier {
            store?.captureMailbox.clear()
            waitingCapture = nil; receivedCaptureID = nil
            invalidate(clearTranscript: true)
            typingView.clearComposition()
            documentID = textDocumentProxy.documentIdentifier
            mode = hasFullAccess ? .idle : .gate
            notice = "输入目标已变化，请重新读取并核对。"; render()
        }
        guard hasFullAccess else {
            store?.captureMailbox.clear()
            waitingCapture = nil; receivedCaptureID = nil
            invalidate(clearTranscript: true); mode = .gate
            // Typing remains available without networking/shared-storage permission.
            if !showTyping { notice = "完全访问已关闭；仍可使用本地打字。"; render() }
            return
        }
    }
    private func invalidate(clearTranscript: Bool, clearSession: Bool = true) {
        revision += 1; task?.cancel(); task = nil
        draftInsertion.cancel()
        confirmed = false
        pendingScreenshot = nil
        if clearTranscript {
            transcript = ""; advice = nil; recognizedScreenshot = nil
            expandedReasons.removeAll()
            persistedSession = nil
            if clearSession { store?.clearKeyboardSession() }
        }
    }
    private func persistSession() {
        guard hasFullAccess, let store = store, !transcript.trimmed.isEmpty,
              store.config() == config, store.relationship() == relationship else { return }
        // Layout changes and reopening must not renew the five-minute lifetime.
        let unchanged = persistedSession?.transcript == transcript && persistedSession?.advice == advice &&
            persistedSession?.relationship == relationship && persistedSession?.config == config
        // Settings may have explicitly cleared the file while this controller
        // was alive. Hiding or relayout must not silently recreate that round.
        if unchanged && store.keyboardSession() == nil { return }
        let saved = KeyboardSession(transcript: transcript, advice: advice, relationship: relationship,
                                    config: config, createdAt: unchanged ? (persistedSession?.createdAt ?? Date()) : Date())
        guard saved.valid(at: Date(), relationship: relationship, config: config) else {
            store.clearKeyboardSession(); return
        }
        do { try store.saveKeyboardSession(saved); persistedSession = saved }
        catch { notice = "本轮暂存失败，收起键盘后可能无法恢复：" + error.localizedDescription }
    }
    private func clearRound() {
        store?.captureMailbox.clear()
        waitingCapture = nil; receivedCaptureID = nil; showBroadcastExperiment = false
        invalidate(clearTranscript: true)
        mode = .idle; notice = "已清空本轮原文与结果。"; render()
    }
    private func render() {
        persistSession()
        header.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        confirmButton = nil; analyzeButton = nil
        view.backgroundColor = KB.cream
        typingView.isHidden = !showTyping; scroll.isHidden = showTyping; footer.isHidden = showTyping
        if showTyping { NSLayoutConstraint.activate(typingConstraints) }
        else { NSLayoutConstraint.deactivate(typingConstraints) }
        let badge = UIImageView(image: UIImage(named: "ShibaMascot"))
        badge.contentMode = .scaleAspectFit
        badge.layer.cornerRadius = 8; badge.clipsToBounds = true
        badge.isAccessibilityElement = true
        badge.accessibilityLabel = "狗头军师"
        badge.widthAnchor.constraint(equalToConstant: 28).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 28).isActive = true
        header.addArrangedSubview(badge)
        let toggle = UISegmentedControl(items: ["打字", "军师"])
        toggle.selectedSegmentIndex = showTyping ? 0 : 1
        toggle.selectedSegmentTintColor = KB.highlight
        toggle.setTitleTextAttributes([.foregroundColor: KB.ink], for: .normal)
        toggle.setTitleTextAttributes([.foregroundColor: KB.ink], for: .selected)
        toggle.widthAnchor.constraint(equalToConstant: 120).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 34).isActive = true
        toggle.addAction(UIAction { [weak self, weak toggle] _ in
            guard let self = self, let toggle = toggle else { return }
            if self.mode == .insertConfirmation {
                self.draftInsertion.cancel(); self.mode = .result
                self.notice = "已取消填入，草稿保持原样。"
            }
            self.showTyping = toggle.selectedSegmentIndex == 0; self.render()
        }, for: .valueChanged)
        toggle.accessibilityIdentifier = "keyboardModeToggle"
        header.addArrangedSubview(toggle)
        header.addArrangedSubview(UIView())
        let screenshot = toolbarButton("viewfinder", label: "识图：等待系统截图") { [weak self] in self?.openScreenshot() }
        var captureStyle = UIButton.Configuration.tinted()
        captureStyle.title = "识图"
        captureStyle.baseForegroundColor = KB.ink; captureStyle.baseBackgroundColor = KB.highlight
        captureStyle.cornerStyle = .capsule
        captureStyle.contentInsets = .init(top: 5, leading: 6, bottom: 5, trailing: 6)
        captureStyle.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes; attributes.font = .systemFont(ofSize: 14, weight: .semibold); return attributes
        }
        screenshot.configuration = captureStyle
        for constraint in screenshot.constraints where constraint.firstAttribute == .width { constraint.constant = 56 }
        screenshot.accessibilityIdentifier = "keyboardScreenshot"
        screenshot.isEnabled = mode != .loading
        header.addArrangedSubview(screenshot)
        if !showTyping {
            let globe = toolbarButton("globe", label: "切换到其他键盘")
            globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
            header.addArrangedSubview(globe)
        }
        header.addArrangedSubview(toolbarButton("keyboard.chevron.compact.down", label: "收起键盘") { [weak self] in self?.dismissKeyboard() })
        footer.text = notice.isEmpty ? "仅填入草稿 · 发送由你决定 · 分析会调用所选接口" : notice
        updateHeight()
        if showTyping { return }
        if mode == .gate {
            content.addArrangedSubview(KB.card([
                KB.label("先启用键盘完全访问", size: 17, bold: true),
                KB.label("设置 → 通用 → 键盘 → 键盘 → 狗头军师 → 允许完全访问。联网分析与共享配置需要这个开关。点顶部“打字”可继续本地输入。", size: 14)
            ]))
            return
        }
        if store != nil, mode != .setup, mode != .gate { content.addArrangedSubview(contextButton()) }
        switch mode {
        case .idle:
            content.addArrangedSubview(KB.label(
                hasSecret("deepseek") ? "键盘状态 · DeepSeek Key 已配置" : "键盘状态 · DeepSeek Key 未配置",
                size: 13, bold: true
            ))
            if store?.isUsingSharedGroup == false {
                content.addArrangedSubview(KB.card([
                    KB.label("全能签兼容模式", size: 17, bold: true),
                    KB.label("当前签名没有保留 App Group。请在主 App 填好 Key 后点“复制键盘独立配置”，再切回键盘；本键盘出现时会自动同步，不再依赖手填。", size: 14)
                ], highlighted: true))
            }
            content.addArrangedSubview(KB.label("从聊天截图或已复制的消息读取，再核对并分析。", size: 14))
            content.addArrangedSubview(KB.row([
                KB.button("截图识别", icon: "photo", primary: true) { [weak self] in self?.openScreenshot() },
                KB.button("读取剪贴板", icon: "doc.on.clipboard") { [weak self] in self?.read(.clipboard) }
            ]))
            content.addArrangedSubview(KB.button("读取输入框里的草稿", icon: "text.cursor") { [weak self] in self?.read(.input) })
            content.addArrangedSubview(KB.button("键盘内 API Key 配置", icon: "key") { [weak self] in self?.openSetup() })
            content.addArrangedSubview(KB.label("相册选图：打开狗头军师 App → 从截图读取聊天。核对分析后交给键盘。输入框读取只取得自己的草稿。", size: 13))
        case .setup: setupView()
        case .screenshot: screenshotView()
        case .review: reviewView()
        case .loading:
            let spinner = UIActivityIndicatorView(style: .medium); spinner.startAnimating()
            content.addArrangedSubview(KB.row([spinner, KB.label(transcript.isEmpty ? "正在识别聊天截图…" : "军师正在分析…", size: 16)]))
            content.addArrangedSubview(KB.button("取消") { [weak self] in
                guard let self = self else { return }
                self.invalidate(clearTranscript: false); self.mode = self.advice == nil ? .review : .result
                if self.transcript.isEmpty { self.mode = .screenshot }
                self.notice = "已取消，已发出的请求无法撤回。"; self.render()
            })
        case .result: resultView()
        case .details: detailView()
        case .insertConfirmation: insertionView()
        case .gate: break
        }
    }
    private func openScreenshot() {
        guard mode != .loading else { return }
        guard hasFullAccess, store != nil else {
            showTyping = false; mode = .gate
            notice = "键盘接收截图文字需要完全访问；本地打字仍可使用。"; render(); return
        }
        invalidate(clearTranscript: true)
        waitingCapture = nil; receivedCaptureID = nil
        showBroadcastExperiment = false
        showTyping = false; mode = .screenshot
        notice = "已准备等待截图。请双击系统悬浮球，运行“截屏 → 截图交给键盘（按配置）”。"
        if hasFullAccess, let store = store {
            do {
                config = store.config(); relationship = store.relationship()
                let screen = view.window?.windowScene?.coordinateSpace.bounds.height ?? 844
                // The capture panel is taller than typing mode; arm with its final height.
                let panelHeight = min(450, max(220, screen * 0.46))
                let request = KeyboardCaptureRequest(relationship: relationship, config: config,
                    excludedBottomFraction: min(0.7, Double(panelHeight / screen)))
                try store.captureMailbox.arm(request)
                waitingCapture = request
            } catch { notice = error.localizedDescription }
        }
        render()
    }
    private func toolbarButton(_ icon: String, label: String, action: (() -> Void)? = nil) -> UIButton {
        let button = UIButton(type: .system)
        var style = UIButton.Configuration.plain()
        style.image = UIImage(systemName: icon); style.baseForegroundColor = KB.ink
        style.contentInsets = .init(top: 5, leading: 5, bottom: 5, trailing: 5)
        button.configuration = style; button.accessibilityLabel = label
        button.widthAnchor.constraint(equalToConstant: 36).isActive = true
        button.heightAnchor.constraint(equalToConstant: 34).isActive = true
        if let action = action { button.addAction(UIAction { _ in action() }, for: .touchUpInside) }
        return button
    }
    private func screenshotView() {
        content.addArrangedSubview(KB.label("从截图读取聊天", size: 17, bold: true))
        content.addArrangedSubview(KB.card([
            KB.label("系统截屏 → 按配置识图", size: 16, bold: true),
            KB.label("双击已绑定的系统悬浮球，运行“截屏 → 截图交给键盘（按配置）”。已有快捷指令会沿用新配置，无需重建。", size: 14),
            KB.label(config.ocr == .local ? "当前：Apple Vision 本地。截图在本机识别，文字直接回到键盘。"
                : "当前：\(config.ocr.rawValue)。截图先回到键盘预览，点“发送截图并识别”后上传。", size: 12),
            KB.label("等待有效期 90 秒；收到的截图最多暂存 5 分钟。", size: 12)
        ]))
        content.addArrangedSubview(KB.button("重新等待截图", icon: "arrow.clockwise", primary: true) { [weak self] in self?.openScreenshot() })
        content.addArrangedSubview(KB.label("键盘按钮准备接收截图，系统截屏由悬浮球快捷指令触发。", size: 12))
        if hasFullAccess, store != nil {
            if #available(iOS 27.0, *) {
                content.addArrangedSubview(KB.label("此实验入口支持 iOS 16–26；当前系统请使用快捷指令或复制截图。", size: 14))
            } else if showBroadcastExperiment {
                let picker = RPSystemBroadcastPickerView(frame: CGRect(x: 0, y: 0, width: 54, height: 54))
                let mainID = Bundle.main.bundleIdentifier?.replacingOccurrences(of: ".keyboard", with: "") ?? "ai.goutoujunshi.chatios"
                picker.preferredExtension = mainID + ".capture"
                picker.showsMicrophoneButton = false
                picker.widthAnchor.constraint(equalToConstant: 54).isActive = true
                picker.heightAnchor.constraint(equalToConstant: 54).isActive = true
                picker.accessibilityIdentifier = "keyboardSystemCapture"
                content.addArrangedSubview(KB.row([picker, KB.label("屏幕捕获实验：点圆形按钮 → 开始直播", size: 14, bold: true)]))
                content.addArrangedSubview(KB.label("此方式从屏幕广播取一帧，尚未在你的手机跑通。若没有弹窗，请使用上面的快捷指令。识图方式沿用当前配置，云端识图仍需确认上传。", size: 12))
            } else {
                content.addArrangedSubview(KB.button("屏幕捕获（实验）", icon: "record.circle") { [weak self] in
                    guard let self = self else { return }
                    self.openScreenshot(); self.showBroadcastExperiment = true
                    self.notice = "这是广播取帧实验；还需点圆形按钮并由你确认系统授权。"
                    self.render()
                })
            }
        }
        if let data = pendingScreenshot, let image = try? LocalOCR.image(data, maxPixelSize: 480) {
            let preview = UIImageView(image: UIImage(cgImage: image))
            preview.contentMode = .scaleAspectFit
            preview.heightAnchor.constraint(equalToConstant: 130).isActive = true
            preview.isAccessibilityElement = true; preview.accessibilityLabel = "本次待识别的聊天截图"
            content.addArrangedSubview(preview)
            let provider = config.ocr
            content.addArrangedSubview(KB.label(provider == .local
                ? "Apple Vision 本地 OCR · 图片留在本机。识别后核对原文与双方身份。"
                : "所选截图将发送至 \(provider.rawValue)，产生接口用量；需要支持图片的模型。识别后仍需核对。", size: 13))
            let recognize = KB.button(provider == .local ? "识别聊天文字" : "发送截图并识别", primary: true) { [weak self] in
                self?.recognizeScreenshot(data, provider: provider)
            }
            recognize.accessibilityIdentifier = "keyboardRecognizeScreenshot"
            content.addArrangedSubview(recognize)
        } else {
            content.addArrangedSubview(KB.label("也可截屏后在照片中拷贝图片，点下方读取。", size: 13))
        }
        let paste = KB.button(pendingScreenshot == nil ? "读取已复制的截图" : "换一张已复制的截图", icon: "doc.on.clipboard", primary: pendingScreenshot == nil) { [weak self] in
            self?.readScreenshot()
        }
        paste.accessibilityIdentifier = "keyboardPasteScreenshot"
        paste.isEnabled = hasFullAccess && store != nil
        content.addArrangedSubview(paste)
        if !hasFullAccess {
            content.addArrangedSubview(KB.label("键盘读取剪贴板需要允许完全访问；可先在主 App 里选择截图，使用本地 OCR。", size: 13))
        }
        content.addArrangedSubview(KB.button("返回军师") { [weak self] in
            guard let self = self else { return }
            self.store?.captureMailbox.clear()
            self.waitingCapture = nil; self.receivedCaptureID = nil; self.showBroadcastExperiment = false
            self.pendingScreenshot = nil
            self.mode = !self.hasFullAccess || self.store == nil ? .gate : (self.advice == nil ? .idle : .result)
            self.render()
        })
    }
    private func readScreenshot(recognizeLocally: Bool = false) {
        guard hasFullAccess, store != nil else { return }
        store?.captureMailbox.clear()
        waitingCapture = nil; receivedCaptureID = nil
        do {
            let data = try ClipboardScreenshot.read()
            let jpeg = try LocalOCR.boundedJPEG(data, maxPixelSize: 1600)
            pendingScreenshot = jpeg
            if recognizeLocally && config.ocr == .local {
                recognizeScreenshot(jpeg, provider: .local); return
            }
            notice = "已读取截图；确认识别方式后再开始。"; render()
        } catch { notice = error.localizedDescription; footer.text = notice }
    }
    private func recognizeScreenshot(_ data: Data, provider: OCRProvider) {
        guard hasFullAccess, let store = store else { return }
        let updated = store.config(), context = store.relationship()
        guard updated == config, context == relationship else {
            store.captureMailbox.clear(); receivedCaptureID = nil; waitingCapture = nil
            config = updated; relationship = context
            invalidate(clearTranscript: true); mode = .screenshot
            notice = "配置或对象已变化，请重新读取截图。"; render(); return
        }
        let api: ModelAPI?
        do {
            api = provider == .local ? nil : ModelAPI(transport: transport, config: config, secrets: try CredentialVault.load())
        } catch { notice = error.localizedDescription; footer.text = notice; return }
        invalidate(clearTranscript: true)
        let generation = revision
        documentID = textDocumentProxy.documentIdentifier
        mode = .loading
        notice = provider == .local ? "Apple Vision 本地识别中…" : "正在发送本次确认的截图至 \(provider.rawValue)…"
        render()
        task = Task { [weak self] in
            do {
                let text: String
                if provider == .local { text = try await LocalOCR.recognize(data, maxPixelSize: 1600) }
                else {
                    guard let api = api else { return }
                    text = try await api.recognizeImage(base64: data.base64EncodedString(),
                        provider: provider == .deepseek ? .deepseek : .openrouter)
                }
                try Task.checkCancellation()
                guard let self = self, self.revision == generation, self.hasFullAccess else { return }
                guard store.config() == self.config, store.relationship() == self.relationship else {
                    store.captureMailbox.clear(); self.receivedCaptureID = nil
                    self.invalidate(clearTranscript: true); self.mode = .screenshot
                    self.notice = "配置或对象已变化，请重新读取截图。"; self.render(); return
                }
                if self.receivedCaptureID != nil { store.captureMailbox.clear(); self.receivedCaptureID = nil }
                self.transcript = text; self.confirmed = false; self.mode = .review
                self.recognizedScreenshot = try? LocalOCR.boundedJPEG(data, maxPixelSize: 480)
                self.notice = "截图已识别 · \(provider.rawValue)；请核对错字、双方身份和当前对象，再分析。"; self.render()
            } catch {
                guard let self = self, self.revision == generation else { return }
                self.mode = .screenshot
                self.pendingScreenshot = data
                self.notice = error is CancellationError ? "已取消截图识别" : error.localizedDescription; self.render()
            }
        }
    }
    private func contextButton() -> UIButton {
        let button = KB.button("\(relationship.label) · \(relationship.stage) · \(relationship.goal)", icon: "person.crop.circle")
        let profiles = store?.archived() ?? []
        let objects = profiles.map { profile in UIAction(title: profile.label) { [weak self] _ in self?.changeContext(profile, clearTranscript: true) } }
        let stages = Relationship.stages.map { stage in UIAction(title: stage, state: stage == relationship.stage ? .on : .off) { [weak self] _ in
            guard let self = self else { return }; var profile = self.relationship; profile.stage = stage
            self.changeContext(profile, clearTranscript: false)
        } }
        let goals = Relationship.goals.map { goal in UIAction(title: goal, state: goal == relationship.goal ? .on : .off) { [weak self] _ in
            guard let self = self else { return }; var profile = self.relationship; profile.goal = goal
            self.changeContext(profile, clearTranscript: false)
        } }
        let reset = UIAction(title: "切换为无背景的当前对象") { [weak self] _ in self?.changeContext(Relationship(id: "current"), clearTranscript: true) }
        let configure = UIAction(title: "键盘内 API Key 与模型配置", image: UIImage(systemName: "key")) { [weak self] _ in self?.openSetup() }
        button.menu = UIMenu(children: [UIMenu(title: "选择对象", children: objects + [reset]),
                                       UIMenu(title: "关系阶段", children: stages), UIMenu(title: "本轮目标", children: goals),
                                       UIMenu(title: "配置", children: [configure])])
        button.showsMenuAsPrimaryAction = true
        button.isEnabled = mode != .loading
        return button
    }

    private func openSetup() {
        setupDeepseekModel = config.deepseekModel
        setupDeepseekKey = ""
        setupOpenRouterKey = ""
        setupJevKey = ""
        showTyping = false
        mode = .setup
        notice = store?.isUsingSharedGroup == false
            ? "此配置只保存在键盘自身容器；卸载或重签可能清除。"
            : "这里保存后会覆盖主 App 下发到键盘的接口配置。"
        render()
    }

    private func setupView() {
        content.addArrangedSubview(KB.card([
            KB.label("键盘内 API Key 配置", size: 17, bold: true),
            KB.label("推荐从主 App 复制独立配置，再点下方导入。自定义键盘内直接输入可能无法唤起系统输入法，文本框仅作备用。", size: 13)
        ]))
        content.addArrangedSubview(KB.button("从剪贴板导入配置", icon: "doc.on.clipboard", primary: true) { [weak self] in
            self?.importClipboardConfig()
        })
        content.addArrangedSubview(KB.label("也可只复制一个 DeepSeek API Key 后导入。", size: 12))
        content.addArrangedSubview(KB.label("DeepSeek 模型 ID", size: 13, bold: true))
        content.addArrangedSubview(setupTextField(placeholder: "deepseek-flash", tag: 100, secure: false))
        content.addArrangedSubview(KB.label("DeepSeek API Key（必填）", size: 13, bold: true))
        content.addArrangedSubview(setupTextField(placeholder: hasSecret("deepseek") ? "已配置，留空保留" : "sk-...", tag: 101, secure: true))
        content.addArrangedSubview(KB.label("OpenRouter API Key（可选）", size: 13, bold: true))
        content.addArrangedSubview(setupTextField(placeholder: hasSecret("openrouter") ? "已配置，留空保留" : "仅 OpenRouter 回复/识图需要", tag: 102, secure: true))
        content.addArrangedSubview(KB.label("TypeSafe Jev API Key（可选）", size: 13, bold: true))
        content.addArrangedSubview(setupTextField(placeholder: hasSecret("jev") ? "已配置，留空保留" : "仅 Jev 判断需要", tag: 103, secure: true))
        content.addArrangedSubview(KB.row([
            KB.button("返回") { [weak self] in
                guard let self = self else { return }
                self.mode = .idle; self.notice = "未保存配置。"; self.render()
            },
            KB.button("保存并启用", primary: true) { [weak self] in self?.saveSetup() }
        ]))
        content.addArrangedSubview(KB.label("注意：共享配置使用系统容器保护，兼容重签工具，但不等同于硬件级密钥隔离。不要在共享设备保存长期大额 Key。", size: 12))
    }

    private func importClipboardConfig() {
        do {
            guard let raw = UIPasteboard.general.string?.trimmed, !raw.isEmpty else {
                throw GoutouError.invalid("剪贴板为空；请先在主 App 点“复制键盘独立配置”")
            }
            guard let store = store else { throw GoutouError.invalid("键盘配置存储不可用") }
            if raw.hasPrefix(KeyboardConfigTransfer.clipboardPrefix) {
                let transfer = try KeyboardConfigTransfer.decodeClipboardText(raw)
                try apply(transfer, store: store)
            } else if raw.hasPrefix("{"), let data = raw.data(using: .utf8),
               let transfer = try? JSONDecoder().decode(KeyboardConfigTransfer.self, from: data) {
                try transfer.validate()
                try apply(transfer, store: store)
            } else {
                guard raw.count <= 1024 else {
                    throw GoutouError.invalid("剪贴板内容过长；请复制主 App 生成的独立配置")
                }
                try CredentialVault.write(raw, name: "deepseek")
                config = store.config()
            }
            setupDeepseekModel = config.deepseekModel
            setupDeepseekKey = ""; setupOpenRouterKey = ""; setupJevKey = ""
            UIPasteboard.general.string = "狗头军师键盘配置已导入"
            mode = .idle
            notice = hasSecret("deepseek")
                ? "独立配置已导入，可读取剪贴板开始分析。"
                : "配置已导入，但还没有 DeepSeek Key。"
            render()
        } catch {
            notice = error.localizedDescription
            render()
        }
    }

    private func importClipboardConfigIfPresent() -> Bool {
        guard hasFullAccess, let raw = UIPasteboard.general.string?.trimmed,
              raw.hasPrefix(KeyboardConfigTransfer.clipboardPrefix), let store = store else { return false }
        do {
            let transfer = try KeyboardConfigTransfer.decodeClipboardText(raw)
            try apply(transfer, store: store)
            UIPasteboard.general.string = "狗头军师键盘配置已导入"
            return true
        } catch {
            notice = error.localizedDescription
            return false
        }
    }

    private func apply(_ transfer: KeyboardConfigTransfer, store: GoutouStore) throws {
        for (name, value) in transfer.secrets {
            try CredentialVault.write(value, name: name)
        }
        try store.saveConfig(transfer.config)
        config = store.config()
        relationship = store.relationship()
    }

    private func setupTextField(placeholder: String, tag: Int, secure: Bool) -> UITextField {
        let field = UITextField()
        field.placeholder = placeholder
        field.tag = tag
        field.text = tag == 100 ? setupDeepseekModel : ""
        field.isSecureTextEntry = secure
        field.textContentType = secure ? .password : nil
        field.autocapitalizationType = .none
        field.autocorrectionType = .no
        field.spellCheckingType = .no
        field.borderStyle = .roundedRect
        field.backgroundColor = KB.surface
        field.textColor = KB.ink
        field.clearButtonMode = .whileEditing
        field.heightAnchor.constraint(equalToConstant: 44).isActive = true
        field.addTarget(self, action: #selector(setupFieldChanged(_:)), for: .editingChanged)
        return field
    }

    @objc private func setupFieldChanged(_ sender: UITextField) {
        let value = sender.text ?? ""
        switch sender.tag {
        case 100: setupDeepseekModel = value
        case 101: setupDeepseekKey = value
        case 102: setupOpenRouterKey = value
        case 103: setupJevKey = value
        default: break
        }
    }

    private func hasSecret(_ name: String) -> Bool {
        ((try? CredentialVault.read(name))?.isEmpty == false)
    }

    private func saveSetup() {
        do {
            var updated = config
            let model = setupDeepseekModel.trimmed
            if !model.isEmpty { updated.deepseekModel = model }
            try updated.validate()
            for (name, value) in [("deepseek", setupDeepseekKey), ("openrouter", setupOpenRouterKey), ("jev", setupJevKey)]
            where !value.trimmed.isEmpty {
                try CredentialVault.write(value, name: name)
            }
            guard let store = store else { throw GoutouError.invalid("键盘配置存储不可用") }
            try store.saveConfig(updated)
            config = store.config()
            relationship = store.relationship()
            setupDeepseekKey = ""; setupOpenRouterKey = ""; setupJevKey = ""
            mode = .idle
            notice = "键盘配置已保存；可读取剪贴板开始分析。"
            render()
        } catch {
            notice = error.localizedDescription
            render()
        }
    }
    private func changeContext(_ value: Relationship, clearTranscript: Bool) {
        do {
            try store?.saveRelationship(value, archive: false)
            waitingCapture = nil; receivedCaptureID = nil
            relationship = value; invalidate(clearTranscript: clearTranscript); advice = nil
            mode = transcript.isEmpty ? .idle : .review
            notice = "对象或目标已变化，请重新核对并分析。"; render()
        } catch { notice = error.localizedDescription; footer.text = notice }
    }

    private enum Source { case clipboard, input }
    private func read(_ source: Source) {
        guard hasFullAccess else { mode = .gate; render(); return }
        let raw = (source == .clipboard ? UIPasteboard.general.string : textDocumentProxy.documentContextBeforeInput) ?? ""
        guard !raw.trimmed.isEmpty, raw.count <= 12_000 else {
            notice = "未读到文字或超过 12000 字；请先复制消息，或在输入框整理好原文。"; footer.text = notice; return
        }
        store?.captureMailbox.clear(); waitingCapture = nil; receivedCaptureID = nil
        invalidate(clearTranscript: true)
        let marked = raw.hasPrefix("我：") || raw.hasPrefix("我:") || raw.hasPrefix("对方：") || raw.hasPrefix("对方:")
        transcript = marked ? raw : (source == .clipboard ? "对方：" : "我：") + raw
        documentID = textDocumentProxy.documentIdentifier
        mode = .review
        notice = source == .clipboard ? "剪贴板不会自动提供完整聊天历史；请核对双方身份。" : "这里只能读取输入光标附近的文字，请核对内容是否完整。"
        render()
    }
    private func reviewView() {
        content.addArrangedSubview(KB.label("核对本轮对话", size: 17, bold: true))
        if let data = recognizedScreenshot, let image = try? LocalOCR.image(data, maxPixelSize: 480) {
            let preview = UIImageView(image: UIImage(cgImage: image))
            preview.contentMode = .scaleAspectFit; preview.heightAnchor.constraint(equalToConstant: 110).isActive = true
            preview.isAccessibilityElement = true; preview.accessibilityLabel = "本轮已识别的聊天截图"
            content.addArrangedSubview(preview)
        }
        let lines = transcript.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() where !line.trimmed.isEmpty {
            let button = KB.button(line, icon: "pencil.circle")
            button.contentHorizontalAlignment = .leading
            button.titleLabel?.numberOfLines = 0
            button.menu = UIMenu(children: [
                UIAction(title: "这行是我说的") { [weak self] _ in self?.reviewLine(index, speaker: "我") },
                UIAction(title: "这行是对方说的") { [weak self] _ in self?.reviewLine(index, speaker: "对方") },
                UIAction(title: "忽略这行（标题 / 非聊天文字）", attributes: .destructive) { [weak self] _ in self?.reviewLine(index, speaker: nil) }
            ])
            button.showsMenuAsPrimaryAction = true
            content.addArrangedSubview(button)
        }
        content.addArrangedSubview(KB.label("点一行可修改说话人，或忽略标题等非聊天文字。", size: 12))
        content.addArrangedSubview(KB.button("复制原文供核对", icon: "doc.on.doc") { [weak self] in
            guard let self = self else { return }
            UIPasteboard.general.string = self.transcript
            self.footer.text = "已复制；可到狗头军师 App 的核对区粘贴修正。"
        })
        content.addArrangedSubview(KB.label("需修改错字：复制原文，到主 App 核对区编辑。不要把待核对原文发给聊天对象。", size: 12))
        content.addArrangedSubview(KB.row([
            KB.button("本条是对方说的") { [weak self] in self?.markSingleSpeaker("对方") },
            KB.button("本条是我说的") { [weak self] in self?.markSingleSpeaker("我") }
        ]))
        let confirm = KB.button(confirmed ? "✓ 已核对原文、身份与对象" : "□ 已核对原文、身份与对象") { [weak self] in
            guard let self = self else { return }
            self.confirmed.toggle(); self.render()
        }
        confirm.accessibilityIdentifier = "keyboardConfirmSource"
        confirmButton = confirm; content.addArrangedSubview(confirm)
        let analyze = KB.button("确认并分析", primary: true) { [weak self] in self?.analyze() }
        analyze.isEnabled = confirmed
        analyze.accessibilityIdentifier = "keyboardAnalyze"
        analyzeButton = analyze
        content.addArrangedSubview(KB.row([analyze, KB.button("重新读取") { [weak self] in self?.clearRound() }]))
        content.addArrangedSubview(KB.button("清空本轮") { [weak self] in self?.clearRound() })
    }
    private func reviewLine(_ index: Int, speaker: String?) {
        var lines = transcript.components(separatedBy: .newlines)
        guard lines.indices.contains(index) else { return }
        if let speaker = speaker {
            let raw = lines[index]
            if let separator = raw.firstIndex(where: { $0 == "：" || $0 == ":" }) {
                lines[index] = speaker + "：" + raw[raw.index(after: separator)...]
            }
        } else { lines.remove(at: index) }
        transcript = lines.joined(separator: "\n"); confirmed = false; advice = nil
        notice = "已更新这行，请继续核对后确认分析。"; render()
    }
    private func markSingleSpeaker(_ speaker: String) {
        let lines = transcript.components(separatedBy: .newlines)
        guard lines.count == 1 else { notice = "多轮对话请到主 App 逐条核对，避免把全部消息归到同一人。"; footer.text = notice; return }
        var raw = transcript
        for prefix in ["我：", "我:", "对方：", "对方:"] where raw.hasPrefix(prefix) { raw = String(raw.dropFirst(prefix.count)); break }
        transcript = speaker + "：" + raw
        confirmed = false; render()
    }
    private func analyze(rewrite: Bool = false) {
        guard hasFullAccess else { mode = .gate; render(); return }
        do {
            let updated = store?.config() ?? config, context = store?.relationship() ?? relationship
            guard updated == config, context == relationship else {
                config = updated; relationship = context; invalidate(clearTranscript: false); advice = nil
                mode = .review; notice = "配置已变化，请重新核对"; render(); return
            }
            let text = Transcript(text: transcript, confirmed: confirmed || rewrite)
            try text.validate()
            let api = ModelAPI(transport: transport, config: config, secrets: try CredentialVault.load())
            try api.preflight(); try relationship.validate()
            let previous = advice
            revision += 1; task?.cancel()
            let generation = revision
            if !rewrite { advice = nil }
            mode = .loading; notice = "分析内容只发往你配置的接口。"; render()
            task = Task { [weak self] in
                do {
                    let pipeline = GoutouPipeline(api: api)
                    let result: Advice
                    if rewrite, let previous = previous {
                        result = try await pipeline.rewrite(previous, transcript: text, relationship: context)
                    } else {
                        result = try await pipeline.analyze(text, relationship: context) { [weak self] stage in
                            Task { @MainActor in
                                guard let self = self, self.revision == generation, self.mode == .loading else { return }
                                self.footer.text = stage
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard let self = self, self.revision == generation else { return }
                    self.advice = result; self.mode = .result; self.notice = "分析完成 · \(Advice.weightNote)"; self.render()
                } catch {
                    guard let self = self, self.revision == generation else { return }
                    self.mode = self.advice == nil ? .review : .result
                    self.notice = error is CancellationError ? "已取消" : error.localizedDescription; self.render()
                }
            }
        } catch { notice = error.localizedDescription; footer.text = notice }
    }
    private func resultView() {
        guard let advice = advice else { return }
        content.addArrangedSubview(KB.card([
            KB.label("对方可能的意图", size: 14, bold: true),
            KB.label(advice.intent, size: 16, bold: true),
            KB.label(advice.confidenceLabel, size: 12),
            KB.label("军师建议 · \(advice.strategy.rawValue)", size: 14, bold: true),
            KB.label(advice.recommendation, size: 14)
        ], highlighted: true))
        content.addArrangedSubview(KB.label("候选回复排序", size: 14, bold: true))
        if advice.candidates.isEmpty { content.addArrangedSubview(KB.label("本轮建议不回复。", size: 16)) }
        for (index, candidate) in advice.candidates.enumerated() {
            let title = "#\(index + 1)" + (candidate.weight.map { " · \($0)%" } ?? " · 权重暂不可用")
            let reason = KB.button(expandedReasons.contains(index) ? "收起理由" : "为什么这样回") { [weak self] in
                guard let self = self else { return }
                if self.expandedReasons.contains(index) { self.expandedReasons.remove(index) }
                else { self.expandedReasons.insert(index) }
                self.render()
            }
            var views: [UIView] = [
                KB.label(title, size: 14, bold: true), KB.label(candidate.text, size: 18),
                KB.row([KB.button("复制") { UIPasteboard.general.string = candidate.text },
                        KB.button("填入草稿", primary: true) { [weak self] in self?.confirmInsert(candidate.text) }]), reason
            ]
            if expandedReasons.contains(index) {
                views.append(KB.label("理由：\(candidate.reason)\n\n代价：\(candidate.tradeoff)", size: 14))
            }
            content.addArrangedSubview(KB.card(views, highlighted: index == 0))
        }
        content.addArrangedSubview(KB.row([
            KB.button("重新分析") { [weak self] in self?.mode = .review; self?.confirmed = false; self?.render() },
            KB.button("更像我一点") { [weak self] in self?.analyze(rewrite: true) },
            KB.button("详细分析") { [weak self] in self?.mode = .details; self?.render() }
        ]))
        content.addArrangedSubview(KB.button("清空本轮") { [weak self] in self?.clearRound() })
    }
    private func detailView() {
        guard let advice = advice else { return }
        content.addArrangedSubview(KB.button("返回候选", icon: "chevron.left") { [weak self] in self?.mode = .result; self?.render() })
        let sections: [(String, String)] = [
            ("对方可能的意图", advice.intent + "\n" + advice.confidenceLabel + "\n" + Advice.intentNote),
            ("先照顾好自己的感受", advice.support),
            ("已知事实", advice.facts.map { "• " + $0 }.joined(separator: "\n")),
            ("合理推测", advice.hypotheses.map { "• " + $0 }.joined(separator: "\n")),
            ("仍未知", advice.unknowns.map { "• " + $0 }.joined(separator: "\n")),
            ("下一步", advice.nextStep), ("停止条件", advice.stopCondition),
            ("策略判断", advice.decision?.summary ?? "未提供"), ("核对原文", transcript)
        ]
        for (title, text) in sections where !text.isEmpty {
            content.addArrangedSubview(KB.card([KB.label(title, size: 15, bold: true), KB.label(text, size: 14)]))
        }
        if let decision = advice.decision, !decision.probabilities.isEmpty {
            let text = Strategy.allCases.map { "\($0.rawValue)：\(Decision.percent(decision.probabilities[$0.rawValue]))" }.joined(separator: " · ")
            content.addArrangedSubview(KB.card([KB.label("七策略相对权重", size: 15, bold: true), KB.label(text, size: 13)]))
        }
    }
    private func confirmInsert(_ text: String) {
        guard !typingView.hasComposition else {
            showTyping = true; render()
            footer.text = "请先选字或删除待输入拼音，再回到军师填入回复。"
            return
        }
        guard documentID == textDocumentProxy.documentIdentifier, hasFullAccess else {
            invalidate(clearTranscript: true); mode = .idle; notice = "输入目标已变化，请重新读取。"; render(); return
        }
        do {
            try draftInsertion.prepare(text: text, documentID: textDocumentProxy.documentIdentifier,
                revision: revision, relationship: relationship, config: config)
            mode = .insertConfirmation; showTyping = false
            notice = "请核对当前收件人，确认后只填入草稿。"; render()
            scroll.setContentOffset(.zero, animated: false)
        } catch { notice = error.localizedDescription; footer.text = notice }
    }
    private func insertionView() {
        guard let pending = draftInsertion.pending else { return }
        content.addArrangedSubview(KB.card([
            KB.label("确认当前收件人", size: 17, bold: true),
            KB.label("当前对象：\(pending.relationship.label)", size: 14, bold: true),
            KB.label(pending.text, size: 18),
            KB.label("请确认聊天页的收件人。文字会追加到当前光标处，保留已有草稿；发送由你决定。", size: 13)
        ], highlighted: true))
        let confirm = KB.button("确认填入", primary: true) { [weak self] in self?.insertConfirmedDraft() }
        confirm.accessibilityIdentifier = "keyboardConfirmDraft"
        let cancel = KB.button("取消") { [weak self] in
            guard let self = self else { return }
            self.draftInsertion.cancel(); self.mode = .result
            self.notice = "已取消填入，草稿保持原样。"; self.render()
        }
        cancel.accessibilityIdentifier = "keyboardCancelDraft"
        content.addArrangedSubview(KB.row([cancel, confirm]))
    }
    private func insertConfirmedDraft() {
        guard mode == .insertConfirmation else { return }
        do {
            let text = try draftInsertion.consume(documentID: textDocumentProxy.documentIdentifier,
                revision: revision, relationship: store?.relationship() ?? relationship,
                config: store?.config() ?? config, visible: isKeyboardVisible,
                fullAccess: hasFullAccess && store != nil, hasComposition: typingView.hasComposition)
            // Remain in this input view: no modal, keyboard dismissal or input-mode switch.
            mode = .result; showTyping = true
            textDocumentProxy.insertText(text)
            notice = "已填入草稿，可继续打字修改；发送由你决定。"; render()
        } catch {
            mode = advice == nil ? .idle : .result
            notice = error.localizedDescription; render()
        }
    }
}
