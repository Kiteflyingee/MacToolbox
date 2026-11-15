import AppKit
import MacToolboxCore

@MainActor
final class CaptureShortcutRecorder: NSButton {
    private let controller: CaptureShortcutController
    private var monitor: Any?
    private(set) var isRecording = false
    var onStatusChange: ((String) -> Void)?

    init(controller: CaptureShortcutController) {
        self.controller = controller
        super.init(frame: .zero)
        bezelStyle = .rounded; target = self; action = #selector(beginRecording)
        setAccessibilityLabel("截图快捷键")
        toolTip = "点击后按组合键；Esc 取消，Delete 清除。"
        widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        refresh()
    }
    required init?(coder: NSCoder) { nil }
    override var acceptsFirstResponder: Bool { true }

    func refresh() {
        guard !isRecording else { return }
        title = controller.shortcut?.title ?? "点击录入快捷键"
        onStatusChange?(controller.registrationError ?? "全局生效，需包含 ⌘ 或 ⌃；Esc 取消，Delete 清除。")
    }

    @objc private func beginRecording() {
        guard !isRecording, window?.makeFirstResponder(self) == true else { return }
        controller.suspend()
        isRecording = true; title = "请按快捷键…"
        onStatusChange?("请按组合键；Esc 取消，Delete 清除。")
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let consumed = MainActor.assumeIsolated {
                guard let self, self.isRecording, event.window === self.window else { return false }
                self.record(event)
                return true
            }
            return consumed ? nil : event
        }
    }

    private func record(_ event: NSEvent) {
        guard !event.isARepeat else { return }
        if event.keyCode == 53 { cancelRecording(); return }
        if event.keyCode == 51 || event.keyCode == 117 { clearShortcut(); return }
        do {
            let shortcut = try CaptureShortcut(event: event)
            try controller.setShortcut(shortcut)
            cancelRecording()
            onStatusChange?("已保存，\(shortcut.title) 可在任意应用中启动截图。")
        } catch CaptureShortcutError.invalid {
            onStatusChange?(CaptureShortcutError.invalid.localizedDescription)
        } catch {
            cancelRecording()
            onStatusChange?(error.localizedDescription)
        }
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        controller.resume()
        refresh()
    }

    func clearShortcut() {
        do {
            try controller.setShortcut(nil)
            cancelRecording(); refresh()
            onStatusChange?("已清除快捷键，仍可从菜单栏点击“截图”。")
        } catch { onStatusChange?(error.localizedDescription) }
    }

    override func resignFirstResponder() -> Bool {
        cancelRecording()
        return super.resignFirstResponder()
    }
}
