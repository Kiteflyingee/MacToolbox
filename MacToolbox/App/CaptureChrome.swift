import AppKit
import QuartzCore
import MacToolboxCore

extension RGBAColor {
    @MainActor var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    @MainActor init(_ color: NSColor) {
        let value = color.usingColorSpace(.sRGB) ?? color
        self.init(red: value.redComponent, green: value.greenComponent, blue: value.blueComponent, alpha: value.alphaComponent)
    }
}

@MainActor
final class CaptureMenuItem: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, checked: Bool = false, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self; state = checked ? .on : .off
    }
    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func run() { handler() }
}

@MainActor
final class CaptureButton: NSButton {
    private let handler: () -> Void
    let helpText: String
    var selected = false { didSet { state = selected ? .on : .off; needsDisplay = true } }
    var swatch: NSColor?
    var accent: NSColor = .controlAccentColor
    var primary = false
    var tint: NSColor?
    var onHover: ((Bool) -> Void)?
    @objc dynamic var hoverFraction: CGFloat = 0 { didSet { needsDisplay = true } }
    init(_ title: String, symbol: String, compact: Bool = false, action: @escaping () -> Void) {
        handler = action; helpText = title
        super.init(frame: .zero)
        self.title = ""; toolTip = title; setAccessibilityLabel(title)
        image = CaptureIcons.image(symbol)
        imagePosition = .imageOnly; isBordered = false
        setButtonType(.momentaryChange); target = self; self.action = #selector(run)
        widthAnchor.constraint(equalToConstant: compact ? 32 : 36).isActive = true
        heightAnchor.constraint(equalToConstant: compact ? 32 : 42).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,options: [.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner: self))
        super.updateTrackingAreas()
    }
    override class func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        key == "hoverFraction" ? CABasicAnimation() : super.defaultAnimation(forKey: key)
    }
    private func setHover(_ hovered: Bool) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().hoverFraction = hovered ? 1 : 0
        }
        onHover?(hovered)
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    @objc private func run() { handler() }
    override func draw(_ dirtyRect: NSRect) {
        let side = max(1,min(bounds.width,bounds.height)-2)
        let tile = CGRect(x: bounds.midX-side/2,y: bounds.midY-side/2,width: side,height: side)
        let color = selected ? NSColor.labelColor.withAlphaComponent(0.09) : NSColor.labelColor.withAlphaComponent(isHighlighted ? 0.14 : 0.07*hoverFraction)
        color.setFill(); NSBezierPath(roundedRect: tile, xRadius: 7, yRadius: 7).fill()
        if let swatch {
            let diameter = max(1,side-12)
            swatch.setFill(); let circle = NSBezierPath(ovalIn: CGRect(x: bounds.midX-diameter/2,y: bounds.midY-diameter/2,width: diameter,height: diameter)); circle.fill()
            (selected ? accent : NSColor.separatorColor).setStroke(); circle.lineWidth = selected ? 2 : 1; circle.stroke()
        } else {
            contentTintColor = isEnabled ? (tint ?? (primary ? .systemGreen : .labelColor)) : .tertiaryLabelColor
            super.draw(dirtyRect)
        }
    }
}

@MainActor
class CaptureSurface: NSView {
    override var isFlipped: Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        let shadow = NSShadow(); shadow.shadowColor = NSColor.black.withAlphaComponent(0.18)
        shadow.shadowBlurRadius = 12; shadow.shadowOffset = NSSize(width: 0,height: -2)
        NSGraphicsContext.saveGraphicsState(); shadow.set()
        NSColor.controlBackgroundColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(roundedRect: bounds,xRadius: 13,yRadius: 13).fill()
        NSGraphicsContext.restoreGraphicsState()
        NSColor.separatorColor.withAlphaComponent(0.4).setStroke()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25,dy: 0.25),xRadius: 13,yRadius: 13).stroke()
    }
}

@MainActor
final class CaptureBar: CaptureSurface {
    let content: NSStackView
    var onMoved: (() -> Void)?
    var movementBounds: CGRect?
    private var dragStart: CGPoint?
    private var originalOrigin = CGPoint.zero
    override var isFlipped: Bool { true }
    init(rows: [NSView]) {
        content = stack(rows, spacing: 5)
        content.edgeInsets = NSEdgeInsets(top: 0, left: 7, bottom: 0, right: 7)
        super.init(frame: .zero)
        addSubview(content); content.frame = CGRect(origin: .zero, size: content.fittingSize)
        frame.size = content.fittingSize
    }
    required init?(coder: NSCoder) { nil }
    override func mouseDown(with event: NSEvent) { dragStart = event.locationInWindow; originalOrigin = frame.origin }
    override func mouseDragged(with event: NSEvent) {
        guard let dragStart,let bounds = movementBounds ?? superview?.bounds else { return }
        let point = event.locationInWindow
        frame = ToolbarPlacement.clamped(CGRect(x: originalOrigin.x+point.x-dragStart.x,
            y: originalOrigin.y-point.y+dragStart.y,width: frame.width,height: frame.height),to: bounds)
        onMoved?()
    }
    override func mouseUp(with event: NSEvent) { dragStart = nil }
}

