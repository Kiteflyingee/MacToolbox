import AppKit
import MacToolboxCore
import ServiceManagement

@MainActor
final class SettingsWindow: NSWindowController, NSTextFieldDelegate, NSWindowDelegate {
    private unowned let coordinator: AppCoordinator
    private let endpoint = NSTextField(string: "")
    private let model = NSTextField(string: "")
    private let key = NSSecureTextField(string: "")
    private let reuse = NSButton(checkboxWithTitle: "将已保存的 Key 用于当前服务地址", target: nil, action: nil)
    private let resultLabel = label("", secondary: true)
    private let accessibilityLabel = label("", secondary: true)
    private var accessibilityButton: ActionButton!
    private let screenLabel = label("", secondary: true)
    private var screenButton: ActionButton!
    private var save: ActionButton!
    private var test: ActionButton!
    private var authorize: ActionButton!
    private var confirmedOrigin: ServiceOrigin?
    private let translationTarget = NSPopUpButton(frame: .zero, pullsDown: false)
    private let cutSound = NSButton(checkboxWithTitle: "Command X 剪切音效", target: nil, action: nil)
    private let launchAtLogin = NSButton(checkboxWithTitle: "开机自启动", target: nil, action: nil)
    private let loginItemLabel = label("", size: 11, secondary: true)
    private var captureShortcut: CaptureShortcutRecorder!
    private let shortcutLabel = label("", size: 11, secondary: true)

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        let window = BrokerWindow(contentRect: CGRect(x: 0, y: 0, width: 560, height: 480),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init(window: window)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        window.title = "MacToolbox \(version) 偏好设置"; window.isReleasedWhenClosed = false; window.center()
        window.delegate = self
        let editor = BrokerTextView(); editor.isFieldEditor = true
        editor.copyText = { [weak coordinator] text in try await coordinator?.broker.write(.text(TextPayload(plain: text)), origin: .ownTextCopy) }
        window.editor = editor
        endpoint.placeholderString = "https://api.example.com/v1"
        model.placeholderString = "填写服务提供的模型名称"
        key.placeholderString = "已保存时留空沿用；本地服务可不填"
        endpoint.setAccessibilityLabel("API 地址")
        model.setAccessibilityLabel("模型名称")
        key.setAccessibilityLabel("API Key")
        endpoint.delegate = self
        reuse.target = self; reuse.action = #selector(confirmAddress)
        for field in [endpoint, model, key] { field.widthAnchor.constraint(equalToConstant: 504).isActive = true }
        save = ActionButton("保存") { [weak self] in self?.submit(testOnly: false) }
        test = ActionButton("测试连接") { [weak self] in self?.submit(testOnly: true) }
        authorize = ActionButton("授权已保存的 Key") { [weak self] in self?.authorizeSavedKey() }
        authorize.isEnabled = false
        accessibilityButton = ActionButton("打开辅助功能设置…") { [weak self] in self?.coordinator.selection.requestPermission(enableSelection: false) }
        screenButton = ActionButton("设置屏幕采集权限…") { [weak self] in self?.coordinator.captureController.requestPermission(); self?.refreshStatus() }
        translationTarget.addItems(withTitles: TargetLanguage.allCases.map(\.title))
        translationTarget.selectItem(at: TargetLanguage.allCases.firstIndex(of: coordinator.translationTarget) ?? 0)
        translationTarget.setAccessibilityLabel("默认目标语言")
        translationTarget.target = self; translationTarget.action = #selector(targetChanged)
        cutSound.state = coordinator.finderCutSoundEnabled ? .on : .off
        cutSound.target = self; cutSound.action = #selector(cutSoundChanged)
        cutSound.toolTip = "Finder 文件剪切准备成功后播放一次提示音。"
        let previewSound = ActionButton("试听") { [weak coordinator] in coordinator?.finderCut.previewCutSound() }
        launchAtLogin.target = self; launchAtLogin.action = #selector(launchAtLoginChanged)
        launchAtLogin.toolTip = "登录 Mac 时自动启动，保持在菜单栏运行。"
        let loginItems = ActionButton("登录项设置…") { SMAppService.openSystemSettingsLoginItems() }
        captureShortcut = CaptureShortcutRecorder(controller: coordinator.captureShortcut)
        captureShortcut.onStatusChange = { [weak self] message in self?.shortcutLabel.stringValue = message }
        let clearShortcut = ActionButton("清除") { [weak self] in self?.captureShortcut.clearShortcut() }
        let website = ActionButton("www.fortumap.com") {
            if let url = URL(string: "https://www.fortumap.com") { NSWorkspace.shared.open(url) }
        }
        let copyright = Bundle.main.object(forInfoDictionaryKey: "NSHumanReadableCopyright") as? String
            ?? "© 富途网络科技（盐城）有限公司"
        let root = stack([label("翻译服务", size: 19),
            stack([label("原文自动识别 · 默认译为"), translationTarget], horizontal: true),
            label("WPS 等划词不响应的场景，可复制文字后翻译，或使用截图翻译。",size: 11,secondary: true),
            label("Chat Completions 兼容 API 地址"), endpoint,
            label("模型"), model, label("API Key · 存入系统钥匙串"), key, stack([reuse,authorize],horizontal: true),
            stack([save, test], horizontal: true), resultLabel,
            NSBox.separator(), label("通用", size: 19),
            stack([launchAtLogin, loginItems], horizontal: true), loginItemLabel,
            stack([cutSound, previewSound], horizontal: true),
            stack([label("截图快捷键"), captureShortcut, clearShortcut], horizontal: true), shortcutLabel,
            NSBox.separator(), label("权限", size: 19),
            stack([accessibilityLabel, accessibilityButton], horizontal: true),
            stack([screenLabel, screenButton], horizontal: true),
            label("在系统设置中开启 MacToolbox。开启后如仍未就绪，请退出并重新打开应用。",size: 11,secondary: true),
            NSBox.separator(), stack([label(copyright, size: 11, secondary: true), website], horizontal: true)], spacing: 9)
        root.edgeInsets = NSEdgeInsets(top: 22, left: 28, bottom: 22, right: 28)
        window.contentView = root
        window.setContentSize(NSSize(width: max(560, root.fittingSize.width), height: max(480, root.fittingSize.height)))
        refreshStatus()
        Task { @MainActor [weak self] in
            guard let self, let saved = await coordinator.settings.current else { return }
            self.endpoint.stringValue = saved.endpointInput; self.model.stringValue = saved.model
            self.authorize.isEnabled = saved.keyReference != nil
            if coordinator.needsKeyAuthorization { self.resultLabel.stringValue = "已保存的 Key 需要授权，请点击“授权已保存的 Key”。" }
        }
    }
    required init?(coder: NSCoder) { nil }

    @objc private func cutSoundChanged() { coordinator.finderCutSoundEnabled = cutSound.state == .on }

    @objc private func launchAtLoginChanged() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin.state == .on {
                if service.status == .notRegistered || service.status == .notFound { try service.register() }
                if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            } else if service.status != .notRegistered { try service.unregister() }
        } catch {
            if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
            else { showError("无法更新开机自启动", error.localizedDescription, window: window) }
        }
        refreshLoginItemStatus()
    }

    private func refreshLoginItemStatus() {
        let status = SMAppService.mainApp.status
        launchAtLogin.state = status == .enabled ? .on : .off
        switch status {
        case .enabled: loginItemLabel.stringValue = "已开启，登录 Mac 后在菜单栏后台运行。"
        case .notRegistered, .notFound: loginItemLabel.stringValue = "开启后，登录 Mac 时自动在菜单栏运行。"
        case .requiresApproval: loginItemLabel.stringValue = "尚未开启，请在系统“登录项”中允许 MacToolbox。"
        @unknown default: loginItemLabel.stringValue = "无法读取登录项状态，请在系统设置中检查。"
        }
    }

    @objc private func targetChanged() {
        guard TargetLanguage.allCases.indices.contains(translationTarget.indexOfSelectedItem) else { return }
        coordinator.translationTarget = TargetLanguage.allCases[translationTarget.indexOfSelectedItem]
    }

    private func authorizeSavedKey() {
        authorize.isEnabled = false
        resultLabel.stringValue = "请在系统窗口决定是否允许访问；选择“始终允许”可沿用授权。"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.authorize.isEnabled = true }
            do {
                if let digest = try await self.coordinator.settings.authorizeSavedKey() { try await self.coordinator.broker.registerSensitive(digest) }
                self.coordinator.translation.settingsChanged()
                try await self.coordinator.credentialsBecameAvailable()
                self.resultLabel.stringValue = "已更新保存的 Key 授权记录。"
            } catch { self.resultLabel.stringValue = errorMessage(error) }
        }
    }

    func refreshStatus() {
        captureShortcut?.refresh()
        refreshLoginItemStatus()
        let accessibilityAllowed = coordinator.selection.permissionGranted
        accessibilityLabel.stringValue = accessibilityAllowed ? "辅助功能已就绪" : "辅助功能尚未就绪"
        accessibilityButton?.isEnabled = !accessibilityAllowed
        let screenAllowed = coordinator.captureController.permissionGranted
        screenLabel.stringValue = screenAllowed ? "屏幕采集已就绪" : "屏幕采集尚未就绪"
        screenButton?.isEnabled = !screenAllowed
    }
    func windowDidBecomeKey(_ notification: Notification) { coordinator.selection.refreshPermission(forceReinstall: true); refreshStatus() }
    func windowDidResignKey(_ notification: Notification) { captureShortcut.cancelRecording() }
    func windowWillClose(_ notification: Notification) { captureShortcut.cancelRecording(); coordinator.captureController.resumeAfterSettings() }

    @objc private func confirmAddress() {
        confirmedOrigin = reuse.state == .on ? try? ChatEndpoint(endpoint.stringValue).origin : nil
        if confirmedOrigin == nil { reuse.state = .off }
    }

    func controlTextDidChange(_ notification: Notification) {
        guard notification.object as? NSTextField === endpoint else { return }
        if (try? ChatEndpoint(endpoint.stringValue).origin) != confirmedOrigin {
            confirmedOrigin = nil; reuse.state = .off
        }
    }

    private func submit(testOnly: Bool) {
        let endpointInput = endpoint.stringValue, modelName = model.stringValue, entered = key.stringValue
        let confirmed = confirmedOrigin
        save.isEnabled = false; test.isEnabled = false
        resultLabel.stringValue = testOnly ? "正在测试连接…" : "正在保存…"
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.save.isEnabled = true; self.test.isEnabled = true }
            do {
                let choice: KeyChoice
                if !entered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { choice = .provided(try SecretKey(entered)) }
                else if await self.coordinator.settings.current?.keyReference != nil { choice = .saved(confirmedOrigin: confirmed) }
                else { choice = .none }
                let service = try await self.coordinator.settings.resolveDraft(endpointInput: endpointInput, model: modelName, keyChoice: choice)
                if testOnly {
                    _ = try await self.coordinator.client.translate(endpoint: service.endpoint, model: service.model, key: service.key, text: "Hello.", target: .simplifiedChinese)
                    self.resultLabel.stringValue = "连接成功"
                } else {
                    _ = try await self.coordinator.settings.save(endpointInput: endpointInput, model: modelName, keyChoice: choice)
                    self.coordinator.translation.settingsChanged()
                    if let digest = service.key?.digest { try await self.coordinator.broker.registerSensitive(digest) }
                    try await self.coordinator.credentialsBecameAvailable()
                    self.authorize.isEnabled = await self.coordinator.settings.current?.keyReference != nil
                    self.key.stringValue = ""; self.reuse.state = .off; self.confirmedOrigin = nil
                    self.resultLabel.stringValue = "翻译配置已保存。"
                }
            } catch { self.resultLabel.stringValue = errorMessage(error) }
        }
    }
}

private extension NSBox {
    @MainActor static func separator() -> NSBox { let box = NSBox(); box.boxType = .separator; return box }
}
