import AppKit
import MacToolboxCore

@MainActor
private final class ColorPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class ColorPickerController {
    private struct Source {
        let id: UInt32
        let frame: CGRect
        let imageFrame: CGRect
        let png: Data
        let transparent: Bool
    }
    private struct Hover {
        let id: UInt32
        let pixel: CGPoint
        let screenPoint: CGPoint
        let generation: UInt64
    }
    private unowned let coordinator: AppCoordinator
    private var sampler: ColorSampler?
    private var windows: [ColorPanel] = []
    private var session: UUID?
    private var work: Task<Void, Never>?
    private var sampling = false
    private var copying = false
    private var pending: Hover?
    private var generation: UInt64 = 0
    private var previousApplication: NSRunningApplication?
    private var onClose: (() -> Void)?
    private let loupe = ColorPanel(contentRect: CGRect(x: 0,y: 0,width: 160,height: 196),
        styleMask: [.borderless,.nonactivatingPanel], backing: .buffered, defer: false)
    private let loupeView = ColorLoupeView(frame: CGRect(x: 0,y: 0,width: 160,height: 196))

    init(coordinator: AppCoordinator) {
        self.coordinator = coordinator
        loupe.isOpaque = false; loupe.backgroundColor = .clear; loupe.hasShadow = true
        loupe.ignoresMouseEvents = true; loupe.hidesOnDeactivate = false
        loupe.level = .init(rawValue: NSWindow.Level.floating.rawValue+3)
        loupe.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
        loupe.contentView = loupeView
    }

    func presentImage(png: Data, screenFrame: CGRect, imageFrame: CGRect, onClose: @escaping () -> Void) {
        close(restoreFocus: false)
        let id = startSession(); self.onClose = onClose
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.present([Source(id: 1,frame: screenFrame,imageFrame: imageFrame,png: png,transparent: true)],session: id) }
            catch { guard self.session == id else { return }; self.close(); showError("取色未完成",errorMessage(error)) }
        }
    }

    func beginFixture(png: Data) {
        close(restoreFocus: false)
        guard let screen = NSScreen.main else { return }
        let id = startSession()
        work = Task { @MainActor [weak self] in
            guard let self else { return }
            do { try await self.present([Source(id: 1,frame: screen.frame,imageFrame: CGRect(origin: .zero,size: screen.frame.size),png: png,transparent: false)],session: id) }
            catch { self.close(); showError("取色测试未完成", errorMessage(error)) }
        }
    }

    private func startSession() -> UUID {
        let id = UUID(); session = id; copying = false
        previousApplication = NSWorkspace.shared.frontmostApplication
        coordinator.colorIsActive = true; coordinator.translation.close()
        return id
    }

    private func present(_ sources: [Source], session id: UUID) async throws {
        guard !sources.isEmpty else { throw CaptureError.displayUnavailable }
        let sampler = ColorSampler(); self.sampler = sampler
        for source in sources {
            let pixels = try await sampler.load(png: source.png,id: source.id)
            guard session == id, !Task.isCancelled else { return }
            guard let image = NSImage(data: source.png) else { throw CoreError.invalidContent }
            let window = ColorPanel(contentRect: source.frame,styleMask: [.borderless],backing: .buffered,defer: false)
            window.title = "取色"; window.isReleasedWhenClosed = false; window.hidesOnDeactivate = false
            window.acceptsMouseMovedEvents = true
            window.level = .init(rawValue: NSWindow.Level.floating.rawValue+1)
            window.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary]
            window.isOpaque = !source.transparent; window.backgroundColor = .clear
            let view = ColorCanvas(frame: CGRect(origin: .zero,size: source.frame.size),id: source.id,
                image: image,imageFrame: source.imageFrame,pixels: pixels)
            view.controller = self; window.contentView = view; windows.append(window)
        }
        guard session == id else { return }
        NSApp.activate()
        for window in windows { window.orderFrontRegardless() }
        let key = windows.first { NSMouseInRect(NSEvent.mouseLocation,$0.frame,false) } ?? windows.first
        key?.makeKeyAndOrderFront(nil); key?.makeFirstResponder(key?.contentView)
        updateAtMouse()
    }

    func close(restoreFocus: Bool = true) {
        let hadSession = session != nil
        session = nil; work?.cancel(); work = nil; pending = nil; generation &+= 1
        sampler = nil; sampling = false; copying = false
        for window in windows { window.orderOut(nil) }; windows.removeAll(); loupe.orderOut(nil)
        coordinator.colorIsActive = false
        let callback = onClose; onClose = nil
        if let callback { callback() }
        else if restoreFocus, hadSession { previousApplication?.activate() }
        previousApplication = nil
    }

    fileprivate func hover(id: UInt32, pixel: CGPoint, screenPoint: CGPoint) {
        generation &+= 1
        pending = Hover(id: id,pixel: pixel,screenPoint: screenPoint,generation: generation)
        drainHover()
    }
    private func drainHover() {
        guard !sampling, !copying, let sampler, let id = session, let request = pending else { return }
        pending = nil; sampling = true
        Task { @MainActor [weak self] in
            let sample = try? await sampler.sample(id: request.id,point: request.pixel)
            guard let self, self.session == id else { return }
            self.sampling = false
            if request.generation == self.generation {
                if let sample { self.showLoupe(sample,at: request.screenPoint) } else { self.loupe.orderOut(nil) }
            }
            self.drainHover()
        }
    }
    fileprivate func updateAtMouse() {
        guard let source = sourceAtMouse() else { loupe.orderOut(nil); return }
        hover(id: source.0,pixel: source.1,screenPoint: NSEvent.mouseLocation)
    }
    fileprivate func copyAtMouse() {
        guard !copying, let sampler, let id = session, let source = sourceAtMouse() else { return }
        copying = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.session == id { self.copying = false } }
            do {
                guard let sample = try await sampler.sample(id: source.0,point: source.1), self.session == id else { return }
                try await self.coordinator.broker.write(.text(TextPayload(plain: sample.hex)),origin: .colorCopy)
                self.close()
            } catch { self.coordinator.status = errorMessage(error) }
        }
    }
    private func sourceAtMouse() -> (UInt32,CGPoint)? {
        let mouse = NSEvent.mouseLocation
        guard let window = windows.first(where: { NSMouseInRect(mouse,$0.frame,false) }),
              let view = window.contentView as? ColorCanvas,
              let point = view.pixel(at: view.convert(window.convertPoint(fromScreen: mouse),from: nil)) else { return nil }
        return (view.id,point)
    }
    private func showLoupe(_ sample: ColorSample, at mouse: CGPoint) {
        loupeView.sample = sample; loupeView.needsDisplay = true
        let bounds = NSScreen.screens.first { NSMouseInRect(mouse,$0.frame,false) }?.visibleFrame ?? CGRect(x: 0,y: 0,width: 1024,height: 768)
        var x = mouse.x+20, y = mouse.y-loupe.frame.height-20
        if x+loupe.frame.width > bounds.maxX { x = mouse.x-loupe.frame.width-20 }
        if y < bounds.minY { y = mouse.y+20 }
        loupe.setFrameOrigin(CGPoint(x: max(bounds.minX,min(x,bounds.maxX-loupe.frame.width)),
            y: max(bounds.minY,min(y,bounds.maxY-loupe.frame.height))))
        loupe.orderFrontRegardless()
    }
}

@MainActor
private final class ColorCanvas: NSView {
    weak var controller: ColorPickerController?
    let id: UInt32
    private let image: NSImage
    private let imageFrame: CGRect
    private let pixels: PixelSize
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    init(frame: CGRect,id: UInt32,image: NSImage,imageFrame: CGRect,pixels: PixelSize) {
        self.id = id; self.image = image; self.imageFrame = imageFrame; self.pixels = pixels
        super.init(frame: frame); setAccessibilityLabel("取色：移动查看原始像素，单击或按C复制色值，Esc取消")
    }
    required init?(coder: NSCoder) { nil }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,options: [.mouseMoved,.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner: self,userInfo: nil))
        super.updateTrackingAreas()
    }
    override func resetCursorRects() { addCursorRect(bounds,cursor: .crosshair) }
    override func draw(_ dirtyRect: NSRect) { image.draw(in: imageFrame,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil) }
    func pixel(at point: CGPoint) -> CGPoint? {
        guard imageFrame.contains(point) else { return nil }
        return CGPoint(x: (point.x-imageFrame.minX)/imageFrame.width*CGFloat(pixels.width),
            y: (point.y-imageFrame.minY)/imageFrame.height*CGFloat(pixels.height))
    }
    override func mouseMoved(with event: NSEvent) { controller?.updateAtMouse() }
    override func mouseEntered(with event: NSEvent) { controller?.updateAtMouse() }
    override func mouseDown(with event: NSEvent) {
        if pixel(at: convert(event.locationInWindow,from: nil)) == nil { controller?.close() }
        else { controller?.copyAtMouse() }
    }
    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command,.shift,.control,.option])
        if event.keyCode == 53 { controller?.close() }
        else if event.keyCode == 8, flags.isEmpty || flags == .command { controller?.copyAtMouse() }
        else { super.keyDown(with: event) }
    }
    override func cancelOperation(_ sender: Any?) { controller?.close() }
}

@MainActor
private final class ColorLoupeView: NSView {
    var sample: ColorSample?
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill(); NSBezierPath(roundedRect: bounds,xRadius: 12,yRadius: 12).fill()
        guard let sample, let image = NSImage(data: sample.neighborhoodPNG) else { return }
        let lens = CGRect(x: 20,y: 12,width: 120,height: 120), cell: CGFloat = 8
        NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect: lens).addClip()
        NSColor.controlBackgroundColor.setFill(); lens.fill(); NSGraphicsContext.current?.imageInterpolation = .none
        let frame = CGRect(x: lens.midX-(sample.focusInNeighborhood.x+0.5)*cell,
            y: lens.midY-(sample.focusInNeighborhood.y+0.5)*cell,width: image.size.width*cell,height: image.size.height*cell)
        image.draw(in: frame,from: .zero,operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
        NSColor.controlAccentColor.setStroke(); let mark = NSBezierPath(rect: CGRect(x: lens.midX-4,y: lens.midY-4,width: 8,height: 8)); mark.lineWidth = 1.5; mark.stroke()
        NSGraphicsContext.restoreGraphicsState()
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.monospacedSystemFont(ofSize: 14,weight: .semibold),.foregroundColor: NSColor.labelColor]
        sample.hex.draw(at: CGPoint(x: 20,y: 140),withAttributes: attributes)
        "\(sample.x), \(sample.y) · C复制".draw(at: CGPoint(x: 20,y: 166),withAttributes: [.font: NSFont.systemFont(ofSize: 11),.foregroundColor: NSColor.secondaryLabelColor])
    }
}
