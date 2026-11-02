import AppKit
import MacToolboxCore

@MainActor
final class ActionButton: NSButton {
    private var handler: () -> Void
    init(_ title: String, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.title = title; bezelStyle = .rounded; target = self; self.action = #selector(performAction)
    }
    required init?(coder: NSCoder) { nil }
    @objc private func performAction() { handler() }
}

@MainActor
func stack(_ views: [NSView], horizontal: Bool = false, spacing: CGFloat = 12) -> NSStackView {
    let view = NSStackView(views: views)
    view.orientation = horizontal ? .horizontal : .vertical
    view.alignment = horizontal ? .centerY : .leading
    view.spacing = spacing
    return view
}

@MainActor
func label(_ text: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
    let field = NSTextField(wrappingLabelWithString: text)
    field.font = .systemFont(ofSize: size)
    field.textColor = secondary ? .secondaryLabelColor : .labelColor
    return field
}

@MainActor
func showError(_ title: String, _ detail: String, window: NSWindow? = nil) {
    let alert = NSAlert(); alert.messageText = title; alert.informativeText = detail
    alert.addButton(withTitle: "好")
    if let window { alert.beginSheetModal(for: window) }
    else { NSApp.activate(); alert.runModal() }
}

func errorMessage(_ error: any Error) -> String {
    if let error = error as? TranslationError {
        switch error {
        case .invalidEndpoint, .insecureEndpoint: return "请检查 API 地址。远程服务使用 HTTPS，本地服务可使用 localhost。"
        case .invalidModel: return "请填写模型名称。"
        case .missingKey, .invalidKey: return "请填写有效的 API Key。"
        case .newOriginNeedsConfirmation: return "服务地址已更改，请重新填写 Key，或确认将已保存的 Key 用于这个服务。"
        case .noText: return "没有可翻译的文字。"
        case .inputTooLarge: return "文字过长，请缩小范围（最多20,000字符）。"
        case .responseTooLarge: return "服务返回内容过大，请缩小原文后重试。"
        case .refused: return "模型未完成翻译，请检查原文或服务设置。"
        case .http(let status, let retry):
            if status == 401 || status == 403 { return "服务拒绝访问，请检查 Key 和模型权限。" }
            if status == 404 { return "地址或模型不存在，请检查完整 API 路径。" }
            if status == 429 { return "服务限流。" + (retry.map { "建议\($0)秒后重试。" } ?? "请稍后重试。") }
            return "服务返回错误（HTTP \(status)），可稍后重试。"
        case .timedOut: return "请求超时，请检查网络或稍后重试。"
        case .transport: return "无法连接服务，请检查网络、地址和证书。"
        case .recognitionFailed: return "未能识别截图文字，请重新选择清晰区域。"
        case .invalidResponse: return "服务返回的内容不符合 Chat Completions 协议。"
        }
    }
    if error is KeychainError { return "钥匙串暂不可读取。请在设置中点击“授权已保存的 Key”，或解锁钥匙串后重启。" }
    if let error = error as? ClipboardAccessError {
        switch error {
        case .permission: return "剪贴板读取尚未获准。请在系统隐私设置中允许后重新启用。"
        case .missingFiles(let count): return "\(count) 个文件引用已失效或无法访问，整条记录未复制。"
        case .unavailable: return "这条内容无法回放。"
        case .changed: return "复制时剪贴板被其他应用改写，请重试。"
        case .writeFailed: return "未能写入剪贴板，请重试。"
        }
    }
    if error is CaptureError { return "屏幕采集未获准或显示器已变化，请允许屏幕录制后重试。" }
    if error is SettingsError { return "请先设置翻译服务的 API 地址、模型和 Key。" }
    if error is HistoryStorageError { return "历史存储不可用，请检查磁盘空间。已有数据未被删除。" }
    return "操作未完成，请检查输入或重试。"
}

@MainActor
class BrokerTextView: NSTextView {
    var copyText: ((String) async throws -> Void)?
    var onEscape: (() -> Void)?
    override var needsPanelToBecomeKey: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey(); window?.makeFirstResponder(self)
        super.mouseDown(with: event)
    }
    override func cancelOperation(_ sender: Any?) {
        if let onEscape { onEscape() } else { super.cancelOperation(sender) }
    }
    override func copy(_ sender: Any?) { performCopy(cut: false) }
    override func cut(_ sender: Any?) { if isEditable { performCopy(cut: true) } }
    private func performCopy(cut: Bool) {
        let range = selectedRange()
        guard range.length > 0, let copyText else { return }
        let original = string
        let selected = (original as NSString).substring(with: range)
        Task { @MainActor [weak self] in
            do {
                try await copyText(selected)
                guard cut, let self, self.string == original, self.selectedRange() == range,
                      self.shouldChangeText(in: range, replacementString: "") else { return }
                self.replaceCharacters(in: range, with: ""); self.didChangeText()
            } catch { showError("复制未完成", errorMessage(error), window: self?.window) }
        }
    }
}

@MainActor
final class BrokerWindow: NSWindow {
    var editor: BrokerTextView?
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSText? {
        if object is NSSecureTextField { return super.fieldEditor(createFlag, for: object) }
        if let editor { return editor }
        return super.fieldEditor(createFlag, for: object)
    }
}
