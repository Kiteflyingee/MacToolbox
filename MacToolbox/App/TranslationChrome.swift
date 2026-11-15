import AppKit

@MainActor
enum TranslationStyle {
    static let cardWidth: CGFloat = 356
    static let padding: CGFloat = 18
    static let textWidth = cardWidth - padding * 2
    static let cardRadius: CGFloat = 18
    static let triggerSize = NSSize(width: 86, height: 34)
}

/// The clear host and the native material use the same silhouette. A layer's
/// cornerRadius alone does not reliably clip the visual-effect backdrop.
@MainActor
final class TranslationSurface: NSView {
    private let radius: CGFloat
    private let material = NSVisualEffectView()
    private var maskSize = NSSize.zero
    override var isOpaque: Bool { false }

    init(content: NSView, radius: CGFloat) {
        self.radius = radius
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.cornerRadius = radius
        layer?.masksToBounds = true
        material.material = .popover
        material.blendingMode = .behindWindow
        material.state = .active
        material.alphaValue = 0.15
        material.translatesAutoresizingMaskIntoConstraints = false
        addSubview(material)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            material.leadingAnchor.constraint(equalTo: leadingAnchor),
            material.trailingAnchor.constraint(equalTo: trailingAnchor),
            material.topAnchor.constraint(equalTo: topAnchor),
            material.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
    required init?(coder: NSCoder) { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func layout() {
        super.layout()
        guard bounds.size != maskSize, bounds.width > 0, bounds.height > 0 else { return }
        maskSize = bounds.size
        let radius = radius
        material.maskImage = NSImage(size: bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
    }
}

@MainActor
final class TranslationAction: NSButton {
    enum Style { case trigger, quiet, icon }
    var onAction: (() -> Void)?
    private let appearanceStyle: Style
    private let originalTitle: String
    private let originalSymbol: String
    private var symbol: String
    private var hovered = false
    private var tracking: NSTrackingArea?

    init(_ title: String, symbol: String, style: Style = .quiet, action: (() -> Void)? = nil) {
        self.originalTitle = title
        self.originalSymbol = symbol
        self.symbol = symbol
        self.appearanceStyle = style
        self.onAction = action
        super.init(frame: .zero)
        self.title = title
        isBordered = false
        setButtonType(.momentaryPushIn)
        target = self
        self.action = #selector(performAction)
        font = .systemFont(ofSize: style == .trigger ? 13 : 12, weight: .medium)
        setAccessibilityLabel(title)
        heightAnchor.constraint(equalToConstant: intrinsicContentSize.height).isActive = true
        widthAnchor.constraint(equalToConstant: intrinsicContentSize.width).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override var intrinsicContentSize: NSSize {
        switch appearanceStyle {
        case .trigger: return TranslationStyle.triggerSize
        case .icon: return NSSize(width: 24, height: 24)
        case .quiet:
            let width = (originalTitle as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
            return NSSize(width: ceil(width) + 36, height: 28)
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hovered = false; needsDisplay = true }
    override func highlight(_ flag: Bool) { super.highlight(flag); needsDisplay = true }
    override func viewDidChangeEffectiveAppearance() { super.viewDidChangeEffectiveAppearance(); needsDisplay = true }
    @objc private func performAction() { onAction?() }

    override func draw(_ dirtyRect: NSRect) {
        let pressed = cell?.isHighlighted == true
        if hovered || pressed {
            NSColor.controlAccentColor.withAlphaComponent(pressed ? 0.15 : 0.08).setFill()
            let radius: CGFloat = appearanceStyle == .trigger ? bounds.height / 2 : 7
            NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        }
        let foreground: NSColor = appearanceStyle == .icon ? .labelColor.withAlphaComponent(0.65) : .labelColor
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let accent = isDark ? NSColor.controlAccentColor.blended(withFraction: 0.35, of: .white) ?? .controlAccentColor : .controlAccentColor
        let iconColor: NSColor = appearanceStyle == .icon ? foreground : accent
        let iconSize: CGFloat = appearanceStyle == .trigger ? 15 : appearanceStyle == .icon ? 10 : 12
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: isEnabled ? foreground : foreground.withAlphaComponent(0.4)
        ]
        let textSize = (title as NSString).size(withAttributes: attributes)
        let gap: CGFloat = title.isEmpty ? 0 : 6
        let width = iconSize + gap + (title.isEmpty ? 0 : textSize.width)
        let x = (bounds.width - width) / 2
        let config = NSImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
            .applying(.init(paletteColors: [iconColor]))
        NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(config)?
            .draw(in: NSRect(x: x, y: (bounds.height-iconSize)/2, width: iconSize, height: iconSize),
                  from: .zero, operation: .sourceOver, fraction: isEnabled ? 1 : 0.4,
                  respectFlipped: true, hints: nil)
        if !title.isEmpty {
            (title as NSString).draw(at: NSPoint(x: x+iconSize+gap, y: (bounds.height-textSize.height)/2),
                                    withAttributes: attributes)
        }
        if window?.firstResponder === self, NSApp.isFullKeyboardAccessEnabled {
            NSColor.keyboardFocusIndicatorColor.setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 2), xRadius: 6, yRadius: 6)
            ring.lineWidth = 2; ring.stroke()
        }
    }

    func confirmCopy() {
        title = "已复制"; symbol = "checkmark"; needsDisplay = true
        setAccessibilityLabel("译文已复制")
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.4))
            guard let self else { return }
            self.title = self.originalTitle; self.symbol = self.originalSymbol
            self.setAccessibilityLabel(self.originalTitle); self.needsDisplay = true
        }
    }
}
