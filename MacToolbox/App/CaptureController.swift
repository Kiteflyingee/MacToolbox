import AppKit
import ImageIO
import MacToolboxCore

@MainActor
private final class CapturePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
private final class CaptureTextView: BrokerTextView {
    var commit: (() -> Void)?
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36, event.modifierFlags.contains(.command) { unmarkText(); commit?() }
        else { super.keyDown(with: event) }
    }
}

@MainActor
final class CaptureController {
    private unowned let coordinator: AppCoordinator
    private let service = ScreenCaptureService()
    private let renderer = AnnotationRenderer()
    private let codec = ImageCodec()
    private var panel: CapturePanel?
    private var canvas: CaptureCanvas?
    private var captureID: UUID?
    private var basePNG: Data?
    private var frozenPNG: Data?
    private var committedSelection = CGRect.zero
    private var lastSelections: [CGRect] = []
    private var hasRequestedPermission = false
    private var isFixture = false
    private var document: AnnotationDocument?
    private var preview = PreviewScheduler()
    private var work: Task<Void, Never>?
    private var previousApplication: NSRunningApplication?
    private var suspendedForSettings = false
    private var textEditor: CaptureTextView?
    private var editedAnnotation: Annotation?

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        hasRequestedPermission = coordinator.screenPermissionRequested
    }

    var permissionGranted: Bool { CGPreflightScreenCaptureAccess() }
    func requestPermission(explicit: Bool = true) {
        guard ScreenCaptureAuthorization.shouldRequest(isGranted: permissionGranted,explicit: explicit,hasRequestedBefore: hasRequestedPermission) else { return }
        hasRequestedPermission = true
        coordinator.screenPermissionRequested = true
        if !CGRequestScreenCaptureAccess(),let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") { NSWorkspace.shared.open(url) }
    }

    func begin() {
        close(restoreFocus: false)
        guard permissionGranted else {
            coordinator.status = "请在系统设置允许 MacToolbox 屏幕采集，再重新点击截图。"
            coordinator.showSettings()
            requestPermission(explicit: false)
            return
        }
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main,
              let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return }
        let id = UUID(); captureID = id; coordinator.captureIsActive = true
        coordinator.translation.close(); previousApplication = NSWorkspace.shared.frontmostApplication
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let pixels = try PixelSize(width: Int(screen.frame.width*screen.backingScaleFactor), height: Int(screen.frame.height*screen.backingScaleFactor))
                let scene = try await self.service.captureScene(displayID: number.uint32Value, pixels: pixels)
                guard self.captureID == id, !Task.isCancelled else { return }
                try self.present(scene.png, screen: screen)
                let top = NSScreen.screens.first?.frame.maxY ?? screen.frame.maxY
                self.canvas?.windowRegions = scene.windows.map {
                    CGRect(x: $0.minX-screen.frame.minX, y: $0.minY-(top-screen.frame.maxY), width: $0.width,height: $0.height)
                        .intersection(CGRect(origin: .zero,size: screen.frame.size))
                }.filter { !$0.isNull && $0.width >= 2 && $0.height >= 2 }
            } catch is CancellationError { }
            catch { self.close(); showError("截图未完成", errorMessage(error)) }
        }
    }

    // Uses a local test image; exercises the real editor/OCR without reading a screen.
    func beginFixture(png: Data) throws {
        close(restoreFocus: false)
        isFixture = true
        guard let screen = NSScreen.main else { throw CaptureError.displayUnavailable }
        captureID = UUID(); coordinator.captureIsActive = true; coordinator.translation.close()
        previousApplication = NSWorkspace.shared.frontmostApplication
        try present(png, screen: screen)
        #if DEBUG
        if CommandLine.arguments.contains("--capture-window-fixture"), let canvas {
            canvas.windowRegions = [canvas.bounds.insetBy(dx: 100,dy: 80)]
        }
        #endif
    }

    private func present(_ png: Data, screen: NSScreen) throws {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let meta = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = meta[kCGImagePropertyPixelWidth] as? Int, let h = meta[kCGImagePropertyPixelHeight] as? Int,
              let image = NSImage(data: png) else { throw CoreError.invalidContent }
        let pixels = try PixelSize(width: w, height: h)
        basePNG = png; frozenPNG = png; committedSelection = .zero
        var frame = screen.frame
        #if DEBUG
        if isFixture, CommandLine.arguments.contains("--capture-preview-windowed") {
            let width = min(1000,screen.visibleFrame.width-80)
            let height = min(screen.visibleFrame.height-100,width*CGFloat(h)/CGFloat(w))
            frame = CGRect(x: screen.visibleFrame.midX-width/2,y: screen.visibleFrame.midY-height/2,width: width,height: height)
        }
        #endif
        let panel = CapturePanel(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        panel.title = "截图"; panel.isReleasedWhenClosed = false; panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]; panel.hidesOnDeactivate = false
        panel.acceptsMouseMovedEvents = true
        let view = CaptureCanvas(frame: CGRect(origin: .zero, size: frame.size), image: image, pixels: pixels)
        let insets = screen.safeAreaInsets
        let safeScreen = CGRect(x: screen.frame.minX+insets.left,y: screen.frame.minY+insets.bottom,
            width: screen.frame.width-insets.left-insets.right,
            height: screen.frame.height-insets.bottom-max(insets.top,NSStatusBar.system.thickness))
        view.chromeBounds = ToolbarPlacement.chromeBounds(captureFrame: frame,visibleScreenFrame: screen.visibleFrame.intersection(safeScreen))
        view.controller = self; panel.contentView = view
        self.panel = panel; canvas = view
        NSApp.activate(); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(view)
    }

    func close(restoreFocus: Bool = true) {
        let hadCapture = captureID != nil
        captureID = nil; work?.cancel(); work = nil; preview.cancel()
        textEditor = nil; editedAnnotation = nil; panel?.orderOut(nil); panel = nil; canvas = nil; basePNG = nil; frozenPNG = nil; document = nil; NSColorPanel.shared.orderOut(nil)
        coordinator.captureIsActive = false; suspendedForSettings = false
        if hadCapture { coordinator.translation.close() }
        if restoreFocus, hadCapture { previousApplication?.activate() }
        previousApplication = nil
        isFixture = false
    }

    func suspendForSettings() { if captureID != nil { suspendedForSettings = true; panel?.orderOut(nil) } }
    func resumeAfterSettings() {
        guard captureID != nil, suspendedForSettings else { return }
        suspendedForSettings = false; panel?.makeKeyAndOrderFront(nil)
    }

    func select(_ rect: CGRect) {
        guard let png = frozenPNG, let id = captureID, let canvas else { return }
        canvas.setBusy(true)
        let pixels = canvas.pixelRect(rect).integral.intersection(CGRect(x: 0, y: 0, width: canvas.pixels.width, height: canvas.pixels.height))
        let oldOrigin = canvas.pixelRect(committedSelection).origin
        let previousDocument = document
        preview.cancel()
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let cropped = try await self.renderer.crop(png: png, rect: pixels)
                guard self.captureID == id else { return }
                self.basePNG = cropped
                let size = try PixelSize(width: Int(pixels.width),height: Int(pixels.height))
                if var previousDocument {
                    try previousDocument.reframe(pixels: size,translation: CGPoint(x: oldOrigin.x-pixels.minX,y: oldOrigin.y-pixels.minY))
                    self.document = previousDocument
                } else { self.document = AnnotationDocument(sessionID: id,baseImageID: UUID(),pixels: size) }
                canvas.selection = canvas.viewRect(pixels); self.committedSelection = canvas.selection
                self.lastSelections.removeAll { $0 == pixels }; self.lastSelections.insert(pixels, at: 0)
                self.lastSelections = Array(self.lastSelections.prefix(5))
                canvas.editedImage = NSImage(data: cropped)
                canvas.setBusy(false); canvas.isEditing = true; canvas.installToolbar(); canvas.needsDisplay = true
                self.requestPreview()
            } catch { self.close(); showError("选区未完成", errorMessage(error)) }
        }
    }

    func commit(_ annotation: Annotation) {
        guard var document else { return }
        do { try document.replace(with: document.annotations + [annotation]); self.document = document; canvas?.selectedID = annotation.id; canvas?.installToolbar(); requestPreview() }
        catch { coordinator.status = errorMessage(error) }
    }
    func undo() { guard canvas?.isBusy != true else { return }; commitText(); if document?.undo() == true { canvas?.selectedID = nil; canvas?.installToolbar(); requestPreview() } }
    func changeTool(_ tool: CaptureCanvas.Tool) { commitText(); canvas?.tool = tool; panel?.makeFirstResponder(canvas) }

    var annotations: [Annotation] { document?.snapshot(includingDraft: true).annotations ?? [] }
    var diagnostics: [String: Any] {
        let rect = canvas.map { $0.pixelRect($0.selection) } ?? .zero
        return ["active": captureID != nil,"busy": canvas?.isBusy == true,"screenPermissionGranted": permissionGranted,
                "selectionMouseDownCount": canvas?.selectionMouseDownCount ?? 0,
                "lastSelectionWasDrag": canvas?.lastSelectionWasDrag == true,
                "windowRegionCount": canvas?.windowRegions.count ?? 0,
                "toolbar": canvas?.toolbarDiagnostics ?? [:],
                "selectionPixels": [rect.minX,rect.minY,rect.width,rect.height],
                "annotationCount": annotations.count,
                "annotationBounds": annotations.map { [$0.bounds.minX,$0.bounds.minY,$0.bounds.width,$0.bounds.height] },
                "annotationRotations": annotations.map(\.rotation),
                "revision": document?.revision ?? 0,"canUndo": canUndo,"canRedo": canRedo]
    }
    var canUndo: Bool { document?.canUndo == true }
    var canRedo: Bool { document?.canRedo == true }
    func redo() { commitText(); if document?.redo() == true { canvas?.selectedID = nil; canvas?.installToolbar(); requestPreview() } }
    func update(_ value: Annotation) {
        guard var doc = document else { return }
        do {
            try doc.replace(with: doc.annotations.map { $0.id == value.id ? value : $0 })
            document = doc; canvas?.installToolbar(); requestPreview()
        } catch { coordinator.status = errorMessage(error) }
    }
    func previewEdit(_ value: Annotation) {
        guard var doc = document else { return }
        do {
            if !doc.hasDraft { try doc.beginDraft() }
            try doc.updateDraft(doc.annotations.map { $0.id == value.id ? value : $0 })
            document = doc; requestPreview(includingDraft: true)
        } catch { coordinator.status = errorMessage(error) }
    }
    func finishEdit() {
        do { try document?.commitDraft(); canvas?.installToolbar(); requestPreview() }
        catch { coordinator.status = errorMessage(error) }
    }
    func previewDrawing(_ value: Annotation) {
        guard var doc = document else { return }
        do {
            if !doc.hasDraft { try doc.beginDraft() }
            try doc.updateDraft(doc.annotations+[value]); document = doc; requestPreview(includingDraft: true)
        } catch { coordinator.status = errorMessage(error) }
    }
    func finishDrawing(_ value: Annotation?) {
        document?.cancelDraft()
        if let value { commit(value) } else { requestPreview() }
    }
    func deleteSelected() {
        guard let id = canvas?.selectedID, var doc = document else { return }
        do { try doc.replace(with: doc.annotations.filter { $0.id != id }); document = doc; canvas?.selectedID = nil; canvas?.installToolbar(); requestPreview() }
        catch { coordinator.status = errorMessage(error) }
    }
    func copySelected() {
        guard let id = canvas?.selectedID, let value = annotations.first(where: { $0.id == id }) else { output(.copy); return }
        do { try coordinator.broker.copyAnnotations([value]) } catch { coordinator.status = errorMessage(error) }
    }
    func pasteAnnotations() {
        do {
            guard let values = try coordinator.broker.annotationsForPaste(), var doc = document else { return }
            try doc.replace(with: doc.annotations+values); document = doc; canvas?.selectedID = values.last?.id; canvas?.installToolbar(); requestPreview()
        } catch { coordinator.status = errorMessage(error) }
    }
    func recentSelections() -> [CGRect] { lastSelections }
    func copyPointerColor(_ hex: String?) {
        guard let hex else { return }
        Task { @MainActor [weak self] in
            do { try await self?.coordinator.broker.write(.text(TextPayload(plain: hex)), origin: .colorCopy) }
            catch { self?.coordinator.status = errorMessage(error) }
        }
    }

    private func requestPreview(includingDraft: Bool = false) {
        guard let snapshot = document?.snapshot(includingDraft: includingDraft), let start = preview.submit(snapshot) else { return }
        renderPreview(start)
    }
    private func renderPreview(_ snapshot: DocumentSnapshot) {
        guard let png = basePNG else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let result = try await self.renderer.renderImage(basePNG: png, snapshot: snapshot)
                guard self.captureID == snapshot.sessionID else { return }
                let finished = self.preview.finish(snapshot)
                if finished.display { self.canvas?.editedImage = NSImage(cgImage: result,size: .zero); self.canvas?.needsDisplay = true }
                if finished.display { self.exportFixture() }
                if let next = finished.next { self.renderPreview(next) }
            } catch {
                guard self.captureID == snapshot.sessionID else { return }
                self.preview.cancel(); self.coordinator.status = errorMessage(error)
            }
        }
    }

    func exportFixture() {
        #if DEBUG
        guard isFixture,let canvas,
              let index = CommandLine.arguments.firstIndex(of: "--capture-preview-export"),
              CommandLine.arguments.indices.contains(index+1) else { return }
        let url = URL(fileURLWithPath: CommandLine.arguments[index+1])
        Task { @MainActor [weak canvas] in
            await Task.yield()
            guard let canvas,let bitmap = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds) else { return }
            canvas.cacheDisplay(in: canvas.bounds,to: bitmap)
            if let png = bitmap.representation(using: .png,properties: [:]) { try? png.write(to: url,options: .atomic) }
            canvas.exportToolbar(to: url.deletingLastPathComponent().appendingPathComponent("capture-toolbar.png"))
            canvas.exportStylePanel(to: url.deletingLastPathComponent().appendingPathComponent("capture-style-panel.png"))
        }
        #endif
    }

    func editText(at point: CGPoint, annotation: Annotation? = nil) {
        commitText()
        guard let canvas else { return }
        var frame = CGRect(x: point.x, y: point.y, width: min(300, canvas.selection.maxX-point.x), height: min(110, canvas.selection.maxY-point.y))
        if let annotation {
            switch annotation.geometry {
            case .text(_,let box), .remark(_,let box,_): frame = canvas.objectRect(box)
            default: return
            }
        }
        guard frame.width >= 2,frame.height >= 2 else { return }
        editedAnnotation = annotation
        let editor = CaptureTextView(frame: frame)
        editor.font = .systemFont(ofSize: max(12, 24*canvas.selection.width/CGFloat(document?.pixels.width ?? 1)))
        editor.textColor = canvas.style.color.nsColor
        let c = canvas.style.color
        editor.backgroundColor = c.red*0.21+c.green*0.72+c.blue*0.07 > 0.6 ? NSColor(white: 0.1,alpha: 0.95) : NSColor(white: 1,alpha: 0.95)
        editor.font = .systemFont(ofSize: max(10, canvas.style.text.fontSize*canvas.selection.width/CGFloat(document?.pixels.width ?? 1)))
        editor.isEditable = true; editor.isRichText = false
        editor.copyText = { [weak self] value in try await self?.coordinator.broker.write(.text(TextPayload(plain: value)), origin: .ownTextCopy) }
        editor.commit = { [weak self] in self?.commitText() }
        if let annotation {
            if case .text(let value,_) = annotation.geometry { editor.string = value }
            if case .remark(let value,_,_) = annotation.geometry { editor.string = value }
        }
        editor.onEscape = { [weak self] in self?.textEditor?.removeFromSuperview(); self?.textEditor = nil; self?.editedAnnotation = nil; self?.panel?.makeFirstResponder(self?.canvas) }
        canvas.addSubview(editor); textEditor = editor; panel?.makeFirstResponder(editor)
    }
    private func commitText() {
        guard let editor = textEditor, let canvas else { return }
        editor.unmarkText()
        let text = editor.string, existing = editedAnnotation
        var frame = editor.frame
        if let container = editor.textContainer,let layout = editor.layoutManager {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container), inset = editor.textContainerInset
            frame.size.width = min(frame.width,max(4,ceil(used.maxX+inset.width*2+2)))
            frame.size.height = min(canvas.selection.maxY-frame.minY,max(4,ceil(used.height+inset.height*2+2)))
        }
        editedAnnotation = nil
        editor.removeFromSuperview(); textEditor = nil; panel?.makeFirstResponder(canvas)
        guard !text.isEmpty else { return }
        let box = canvas.annotationRect(frame)
        let geometry: AnnotationGeometry
        if let existing,case .remark(_,_,let connector) = existing.geometry { geometry = .remark(text,box: box,connector: connector) }
        else { geometry = canvas.tool == .remark ? .remark(text,box: box,connector: CGPoint(x: box.minX-24,y: box.maxY+20)) : .text(text,box: box) }
        if let existing { update(Annotation(id: existing.id,geometry: geometry,style: canvas.style)) }
        else { commit(Annotation(geometry: geometry,style: canvas.style)) }
    }

    func refreshTextStyle() {
        guard let editor = textEditor,let canvas else { return }
        let style = canvas.style, size = max(1,style.text.fontSize*canvas.selection.width/CGFloat(document?.pixels.width ?? 1))
        var font = style.text.fontName.isEmpty ? NSFont.systemFont(ofSize: size) : NSFont(name: style.text.fontName,size: size) ?? .systemFont(ofSize: size)
        if style.text.bold { font = NSFontManager.shared.convert(font,toHaveTrait: .boldFontMask) }
        if style.text.italic { font = NSFontManager.shared.convert(font,toHaveTrait: .italicFontMask) }
        editor.font = font; editor.textColor = style.color.nsColor
    }

    enum Output { case copy, save, translate, color }
    func output(_ purpose: Output) {
        commitText()
        guard let snapshot = document?.snapshot(), let basePNG, let canvas else { return }
        canvas.setBusy(true)
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                let png = try await self.renderer.render(basePNG: basePNG, snapshot: snapshot)
                guard self.captureID == snapshot.sessionID, self.document?.revision == snapshot.revision, !Task.isCancelled else { return }
                switch purpose {
                case .copy:
                    let image = try await self.codec.normalize(png)
                    guard self.captureID == snapshot.sessionID else { return }
                    try await self.coordinator.broker.write(.image(image), origin: .screenshotExport); self.close()
                case .save:
                    let save = NSSavePanel(); save.allowedContentTypes = [.png, .heic]; save.nameFieldStringValue = "截图.png"
                    if save.runModal() == .OK, let url = save.url { try await self.codec.export(png: png, to: url); self.close() }
                    else { canvas.setBusy(false) }
                case .translate:
                    let anchor = self.panel?.convertPoint(toScreen: CGPoint(x: canvas.selection.maxX, y: canvas.bounds.height-canvas.selection.maxY)) ?? NSEvent.mouseLocation
                    self.coordinator.translation.translateScreenshot(png: png, captureID: snapshot.sessionID,
                        revision: snapshot.revision, anchor: anchor) { [weak self] in
                            guard let self, self.captureID == snapshot.sessionID else { return }
                            self.canvas?.setBusy(false)
                            if !self.suspendedForSettings { self.panel?.makeKeyAndOrderFront(nil) }
                        }
                case .color:
                    guard let frame = self.panel?.frame else { return }
                    self.coordinator.colorPicker.presentImage(png: png,screenFrame: frame,imageFrame: canvas.selection) { [weak self] in
                        guard let self, self.captureID == snapshot.sessionID else { return }
                        self.canvas?.setBusy(false)
                        if !self.suspendedForSettings { self.panel?.makeKeyAndOrderFront(nil) }
                    }
                }
            } catch is CancellationError { }
            catch { canvas.setBusy(false); showError("操作未完成", errorMessage(error), window: self.panel) }
        }
    }
}

