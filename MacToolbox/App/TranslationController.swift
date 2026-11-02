import AppKit
import MacToolboxCore

@MainActor
private final class TranslationPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

@MainActor
final class TranslationController: NSObject, NSWindowDelegate {
    private unowned let coordinator: AppCoordinator
    private var state = TranslationStateMachine()
    private let panel = TranslationPanel(contentRect: .zero,
        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
    private let ocr = OCRService()
    private var extraction: Task<Void, Never>?
    private var screenshotPNG: Data?
    private var ocrErrorMessage: String?
    private var onClose: (() -> Void)?
    private var network: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private var monitors: [Any] = []
    private var observer: NSObjectProtocol?
    private var sourcePID: pid_t?
    private var flowPresentedAt: TimeInterval?
    private var fixtureIsPinned = false
    private var fixtureExportDirectory: URL?
    private var targetChangeID = UUID()
    private var shownButtons = 0
    private var lastCloseReason = "none"
    var isInteracting: Bool { panel.isVisible && (panel.isKeyWindow || NSMouseInRect(NSEvent.mouseLocation, panel.frame, false)) }
    var diagnostics: [String: Any] {
        let isButton: Bool
        if case .button = state.phase { isButton = true } else { isButton = false }
        return ["panelVisible": panel.isVisible,"isButton": isButton,"shownButtons": shownButtons,
                "lastCloseReason": lastCloseReason,"sourcePID": sourcePID ?? 0]
    }

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        super.init()
        panel.title = "翻译"; panel.isReleasedWhenClosed = false
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.close() }
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .init(rawValue: NSWindow.Level.floating.rawValue+2)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.delegate = self
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            let timestamp = event.timestamp
            Task { @MainActor in
                guard let self, !self.fixtureIsPinned, let presented = self.flowPresentedAt, timestamp >= presented else { return }
                self.close(reason: "outside-click")
            }
        }) { monitors.append(monitor) }
        if let monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] event in
            MainActor.assumeIsolated {
                if let self, !self.fixtureIsPinned, event.window !== self.panel { self.close(reason: "own-window-click") }
            }
            return event
        }) { monitors.append(monitor) }
        observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] notification in
            let pid = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.processIdentifier
            Task { @MainActor in
                guard let self, !self.fixtureIsPinned, let pid, pid != ProcessInfo.processInfo.processIdentifier, pid != self.sourcePID else { return }
                self.close(reason: "front-app-changed")
            }
        }
    }

    func externalCopy(count: Int, text: String?) {
        if case .selection? = state.currentOrigin { return }
        let previous = state.activeRequest?.id
        state.externalVersionChanged(count, allowsCandidates: !coordinator.ownInteraction)
        if previous != state.activeRequest?.id { network?.cancel() }
        if let text {
            _ = state.offerClipboardText(text, changeCount: count, anchor: NSEvent.mouseLocation, allowsCandidates: !coordinator.ownInteraction)
        }
        if case .button(let snapshot) = state.phase {
            presentButton(snapshot, pid: NSWorkspace.shared.frontmostApplication?.processIdentifier)
        }
        render()
    }

    func selectedText(_ text: String, anchor: CGPoint, pid: pid_t) {
        guard !coordinator.ownInteraction, !coordinator.broker.isSensitiveText(text),
              let snapshot = state.offerSelectionText(text, anchor: anchor, allowsCandidates: true) else { return }
        network?.cancel(); extraction?.cancel()
        presentButton(snapshot, pid: pid); render()
    }

    private func presentButton(_ snapshot: TranslationSnapshot, pid: pid_t?) {
        shownButtons += 1
        flowPresentedAt = ProcessInfo.processInfo.systemUptime; sourcePID = pid
        expiry?.cancel()
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled, let self else { return }
            if case .button(let current) = self.state.phase,current.id == snapshot.id { self.lastCloseReason = "expired" }
            self.state.expireButton(snapshotID: snapshot.id); self.render()
        }
    }

    func translateScreenshot(png: Data, captureID: UUID, revision: UInt64, anchor: CGPoint, onClose: @escaping () -> Void) {
        close()
        self.onClose = onClose; screenshotPNG = png
        flowPresentedAt = ProcessInfo.processInfo.systemUptime
        sourcePID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ticket = state.beginScreenshot(captureID: captureID, revision: revision, anchor: anchor)
        startOCR(ticket)
    }

    private func startOCR(_ ticket: OCRTicket) {
        guard let png = screenshotPNG else { return }
        ocrErrorMessage = nil; render()
        extraction?.cancel()
        extraction = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let service = try await self.coordinator.settings.configuredService()
                let text = try await self.ocr.recognize(png: png)
                guard let request = self.state.completeOCR(ticket, text: text, settingsRevision: service.settingsRevision,
                    target: self.coordinator.translationTarget) else { return }
                self.launch(request, service: service)
            } catch is CancellationError { }
            catch {
                if self.state.failOCR(ticket, error: (error as? TranslationError) ?? .recognitionFailed) {
                    self.ocrErrorMessage = errorMessage(error); self.render()
                }
            }
        }
    }

    func close(reason: String = "explicit") {
        lastCloseReason = reason
        targetChangeID = UUID()
        state.close(); network?.cancel(); network = nil; expiry?.cancel(); expiry = nil
        extraction?.cancel(); extraction = nil; screenshotPNG = nil
        flowPresentedAt = nil
        panel.orderOut(nil)
        let callback = onClose; onClose = nil; callback?()
    }
    func settingsChanged() { state.settingsChanged(); close() }
    func windowShouldClose(_ sender: NSWindow) -> Bool { close(); return false }

    #if DEBUG
    /// Uses the actual translation state/network/UI with a caller-supplied fixture
    /// and isolated profile. Never enabled in ordinary launches.
    func beginFixture(text: String, exportDirectory: URL?) {
        fixtureIsPinned = true
        fixtureExportDirectory = exportDirectory
        let bounds = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        selectedText(text, anchor: CGPoint(x: bounds.midX-180, y: bounds.midY+120),
                     pid: ProcessInfo.processInfo.processIdentifier)
        expiry?.cancel(); expiry = nil
    }
    #endif

    private func request(_ snapshot: TranslationSnapshot, retry: Bool = false) {
        expiry?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let service = try await self.coordinator.settings.configuredService()
                let ticket = retry ? self.state.retry(snapshotID: snapshot.id, settingsRevision: service.settingsRevision)
                    : self.state.click(snapshotID: snapshot.id, settingsRevision: service.settingsRevision,
                                       target: self.coordinator.translationTarget)
                guard let ticket else { self.render(); return }
                self.launch(ticket, service: service)
            } catch {
                guard case .button(let current) = self.state.phase, current.id == snapshot.id else { return }
                self.showContent([self.message(errorMessage(error)),
                    TranslationAction("打开设置", symbol: "gearshape") { [weak self] in self?.coordinator.showSettings() }],
                    anchor: snapshot.anchor, title: "翻译设置")
            }
        }
    }

    private func launch(_ ticket: TranslationTicket, service: ConfiguredTranslationService) {
        network?.cancel(); render()
        network = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.coordinator.client.translate(endpoint: service.endpoint,
                    model: service.model, key: service.key, text: ticket.snapshot.text, target: ticket.target)
                try Task.checkCancellation()
                if self.state.complete(ticket, response: result) { self.render() }
            } catch is CancellationError { }
            catch {
                guard !Task.isCancelled else { return }
                if self.state.fail(ticket, error: (error as? TranslationError) ?? .transport) { self.render() }
            }
        }
    }

    private func render() {
        switch state.phase {
        case .hidden: panel.orderOut(nil)
        case .button(let snapshot):
            let button = TranslationAction("翻译", symbol: "character.bubble", style: .trigger) { [weak self] in self?.request(snapshot) }
            showContent([button], anchor: snapshot.anchor, compact: true)
        case .loading(let ticket):
            let spinner = NSProgressIndicator()
            spinner.style = .spinning; spinner.controlSize = .small
            spinner.startAnimation(nil)
            showContent([targetPicker(ticket.snapshot), row([spinner, label("正在翻译…", size: 14), spacer()]),
                         message("译文将显示在这里。", secondary: true)], anchor: ticket.snapshot.anchor)
        case .ready(let ticket, let result):
            let width = TranslationStyle.textWidth
            let text = BrokerTextView(frame: CGRect(x: 0, y: 0, width: width, height: 180))
            text.isEditable = false; text.isSelectable = true; text.isRichText = false
            text.font = .systemFont(ofSize: 15); text.textColor = .labelColor; text.drawsBackground = false
            text.textContainerInset = .zero
            text.textContainer?.lineFragmentPadding = 0
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 8
            text.defaultParagraphStyle = paragraph
            text.string = result.text
            text.isVerticallyResizable = true; text.isHorizontallyResizable = false
            text.textContainer?.widthTracksTextView = true
            text.textContainer?.containerSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            text.maxSize = NSSize(width: width, height: CGFloat.greatestFiniteMagnitude)
            if let container = text.textContainer { text.layoutManager?.ensureLayout(for: container) }
            let glyphHeight = text.textContainer.flatMap { text.layoutManager?.usedRect(for: $0).height } ?? 20
            let textHeight = max(28, min(240, ceil(glyphHeight)+2))
            text.minSize = .zero; text.autoresizingMask = [.width]
            text.setFrameSize(NSSize(width: width, height: max(textHeight, ceil(glyphHeight)+2)))
            text.setAccessibilityLabel("译文，可选中文字后复制")
            text.copyText = { [weak self] value in try await self?.coordinator.broker.write(.text(TextPayload(plain: value)), origin: .translationResultCopy) }
            text.onEscape = { [weak self] in self?.close() }
            let scroll = NSScrollView(frame: CGRect(x: 0, y: 0, width: width, height: textHeight))
            scroll.documentView = text; scroll.hasVerticalScroller = true
            scroll.scrollerStyle = .overlay
            scroll.autohidesScrollers = true
            scroll.drawsBackground = false; scroll.borderType = .noBorder
            scroll.contentView.drawsBackground = false
            scroll.heightAnchor.constraint(equalToConstant: textHeight).isActive = true
            scroll.widthAnchor.constraint(equalToConstant: width).isActive = true
            let copy = TranslationAction("复制译文", symbol: "doc.on.doc")
            copy.onAction = { [weak self, weak copy] in
                Task { @MainActor in
                    guard let self else { return }
                    do {
                        try await self.coordinator.broker.write(.text(TextPayload(plain: result.text)), origin: .translationResultCopy)
                        copy?.confirmCopy()
                    } catch { self.coordinator.status = errorMessage(error) }
                }
            }
            let caption = result.completion == .truncated ? "译文可能不完整"
                : result.completion == .unknown ? "完整性未确认"
                : "原文自动识别"
            let footerLabel = label(caption, size: 11)
            showContent([targetPicker(ticket.snapshot), scroll, row([footerLabel, spacer(), copy])], anchor: ticket.snapshot.anchor, title: "译文")
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
            text.scrollRangeToVisible(NSRange(location: 0, length: 0))
        case .failure(.text(let snapshot, _, let error)):
            showContent([targetPicker(snapshot), message(errorMessage(error)), row([
                TranslationAction("重试", symbol: "arrow.clockwise") { [weak self] in self?.request(snapshot, retry: true) },
                spacer(), TranslationAction("设置", symbol: "gearshape") { [weak self] in self?.coordinator.showSettings() }
            ])], anchor: snapshot.anchor, title: "翻译未完成")
        case .extracting(let ticket):
            showContent([message("正在识别截图文字…")], anchor: ticket.anchor)
        case .failure(.ocr(let ticket, let error)):
            showContent([message(ocrErrorMessage ?? errorMessage(error)), row([
                TranslationAction("重试", symbol: "arrow.clockwise") { [weak self] in
                    guard let self, let next = self.state.retryOCR(id: ticket.id) else { return }
                    self.startOCR(next)
                }, spacer(), TranslationAction("设置", symbol: "gearshape") { [weak self] in self?.coordinator.showSettings() }
            ])], anchor: ticket.anchor, title: "识别未完成")
        }
    }

    private func targetPicker(_ snapshot: TranslationSnapshot) -> NSView {
        let picker = NSPopUpButton(frame: .zero, pullsDown: false)
        picker.controlSize = .small; picker.isBordered = false
        picker.font = .systemFont(ofSize: 12, weight: .medium)
        picker.addItems(withTitles: TargetLanguage.allCases.map(\.title))
        picker.selectItem(at: TargetLanguage.allCases.firstIndex(of: coordinator.translationTarget) ?? 0)
        picker.setAccessibilityLabel("目标语言，原文自动识别")
        picker.target = self; picker.action = #selector(targetChanged(_:))
        picker.identifier = NSUserInterfaceItemIdentifier(snapshot.id.uuidString)
        return row([label("译为", size: 12), picker, spacer()])
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }),
              TargetLanguage.allCases.indices.contains(sender.indexOfSelectedItem) else { return }
        coordinator.translationTarget = TargetLanguage.allCases[sender.indexOfSelectedItem]
        let changeID = UUID(); targetChangeID = changeID
        let target = coordinator.translationTarget
        network?.cancel()
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let service = try await self.coordinator.settings.configuredService()
                guard self.targetChangeID == changeID else { return }
                guard let ticket = self.state.changeTarget(snapshotID: id, settingsRevision: service.settingsRevision,
                                                          target: target) else { return }
                self.launch(ticket, service: service)
            } catch { self.coordinator.status = errorMessage(error) }
        }
    }

    private func message(_ value: String, size: CGFloat = 13, secondary: Bool = false) -> NSTextField {
        let field = label(value, size: size, secondary: secondary)
        field.preferredMaxLayoutWidth = TranslationStyle.textWidth
        field.widthAnchor.constraint(equalToConstant: TranslationStyle.textWidth).isActive = true
        return field
    }

    private func spacer() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let view = stack(views, horizontal: true, spacing: 8)
        view.widthAnchor.constraint(equalToConstant: TranslationStyle.textWidth).isActive = true
        return view
    }

    private func showContent(_ views: [NSView], anchor: CGPoint, compact: Bool = false, title: String = "翻译") {
        let heading = label(title, size: 12)
        heading.font = .systemFont(ofSize: 12, weight: .medium)
        let close = TranslationAction("", symbol: "xmark", style: .icon) { [weak self] in self?.close() }
        close.toolTip = "关闭翻译"; close.setAccessibilityLabel("关闭翻译")
        let root = stack(compact ? views : [row([heading, spacer(), close])] + views, spacing: 12)
        root.edgeInsets = compact ? .init() : NSEdgeInsets(top: 14, left: TranslationStyle.padding, bottom: 14, right: TranslationStyle.padding)
        let width: CGFloat = compact ? TranslationStyle.triggerSize.width : TranslationStyle.cardWidth
        root.widthAnchor.constraint(equalToConstant: width).isActive = true
        let bubble = TranslationSurface(content: root, radius: compact ? TranslationStyle.triggerSize.height/2 : TranslationStyle.cardRadius)
        panel.contentView = bubble
        panel.layoutIfNeeded()
        let size = root.fittingSize
        panel.setContentSize(NSSize(width: width, height: max(compact ? TranslationStyle.triggerSize.height : 80, ceil(size.height))))
        bubble.layoutSubtreeIfNeeded()
        panel.invalidateShadow()
        let screen = NSScreen.screens.first { NSMouseInRect(anchor, $0.frame, false) } ?? NSScreen.main
        let bounds = screen?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1024, height: 768)
        var x = anchor.x + 12, y = anchor.y - panel.frame.height - 12
        x = max(bounds.minX, min(x, bounds.maxX-panel.frame.width))
        y = max(bounds.minY, min(y, bounds.maxY-panel.frame.height))
        panel.setFrameOrigin(CGPoint(x: x, y: y))
        if case .screenshot? = state.currentOrigin { panel.makeKeyAndOrderFront(nil) }
        else { panel.orderFrontRegardless() }
        #if DEBUG
        if let directory = fixtureExportDirectory {
            let name: String
            switch state.phase {
            case .button: name = "trigger"
            case .ready: name = "result"
            case .loading: name = "loading"
            default: name = "other"
            }
            Task { @MainActor [weak self, weak bubble] in
                await Task.yield()
                guard let self, let bubble, self.panel.contentView === bubble,
                      let bitmap = bubble.bitmapImageRepForCachingDisplay(in: bubble.bounds) else { return }
                bubble.cacheDisplay(in: bubble.bounds, to: bitmap)
                if let png = bitmap.representation(using: .png, properties: [:]) {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? png.write(to: directory.appendingPathComponent(name+".png"), options: .atomic)
                }
            }
        }
        #endif
    }
}
