import AppKit

@MainActor
private final class CapturePropertyButton: NSButton {
    private let choices: NSMenu
    private let caption: String
    private let glyph: String?
    private let swatch: NSColor?
    private let iconColor: NSColor?
    private let interaction: () -> Void
    init(_ caption: String, label: String, menu: NSMenu, width: CGFloat = 56,
         glyph: String? = nil, swatch: NSColor? = nil, iconColor: NSColor? = nil, interaction: @escaping () -> Void) {
        self.caption = caption; choices = menu; self.glyph = glyph; self.swatch = swatch; self.interaction = interaction
        self.iconColor = iconColor
        super.init(frame: .zero)
        isBordered = false; title = ""; setButtonType(.momentaryChange)
        setAccessibilityLabel(label); toolTip = label
        target = self; action = #selector(openChoices)
        widthAnchor.constraint(equalToConstant: width).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }
    required init?(coder: NSCoder) { nil }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc private func openChoices() {
        interaction()
        choices.popUp(positioning: nil,at: CGPoint(x: 0,y: bounds.minY-4),in: self)
    }
    override func draw(_ dirtyRect: NSRect) {
        if isHighlighted {
            NSColor.labelColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1,dy: 1),xRadius: 6,yRadius: 6).fill()
        }
        let area = CGRect(x: 3,y: 3,width: bounds.width-20,height: bounds.height-6)
        if let swatch {
            swatch.setFill()
            let chip = NSBezierPath(roundedRect: CGRect(x: area.midX-10,y: area.midY-10,width: 20,height: 20),xRadius: 5,yRadius: 5)
            chip.fill(); NSColor.separatorColor.setStroke(); chip.lineWidth = 0.6; chip.stroke()
        } else if let glyph {
            let config = NSImage.SymbolConfiguration(pointSize: 17,weight: .regular)
                .applying(.init(paletteColors: [iconColor ?? .secondaryLabelColor]))
            NSImage(systemSymbolName: glyph,accessibilityDescription: nil)?.withSymbolConfiguration(config)?
                .draw(in: CGRect(x: area.midX-10,y: area.midY-10,width: 20,height: 20),from: .zero,
                      operation: .sourceOver,fraction: 1,respectFlipped: true,hints: nil)
        } else {
            let attributes: [NSAttributedString.Key:Any] = [.font:NSFont.systemFont(ofSize: 13,weight: .medium),.foregroundColor:NSColor.secondaryLabelColor]
            let size = (caption as NSString).size(withAttributes: attributes)
            (caption as NSString).draw(at: CGPoint(x: area.midX-size.width/2,y: area.midY-size.height/2),withAttributes: attributes)
        }
        let chevron = NSBezierPath(), x = bounds.maxX-12, y = bounds.midY
        let dy: CGFloat = isFlipped ? -1.5 : 1.5
        chevron.move(to: CGPoint(x: x,y: y+dy)); chevron.line(to: CGPoint(x: x+3,y: y-dy)); chevron.line(to: CGPoint(x: x+6,y: y+dy))
        NSColor.secondaryLabelColor.setStroke(); chevron.lineWidth = 1.2; chevron.lineCapStyle = .round; chevron.lineJoinStyle = .round; chevron.stroke()
    }
}

@MainActor
final class CaptureGrip: NSView {
    init() {
        super.init(frame: .zero)
        widthAnchor.constraint(equalToConstant: 12).isActive = true
        heightAnchor.constraint(equalToConstant: 30).isActive = true
        setAccessibilityLabel("拖动截图工具栏")
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.tertiaryLabelColor.setFill()
        for x in [bounds.midX-2,bounds.midX+2] {
            for y in [bounds.midY-5,bounds.midY,bounds.midY+5] {
                NSBezierPath(ovalIn: CGRect(x: x-0.8,y: y-0.8,width: 1.6,height: 1.6)).fill()
            }
        }
    }
}

@MainActor
final class CaptureStylePanel: CaptureSurface {
    let requiredHeight: CGFloat = 48
    var arrowX: CGFloat = 24
    var appearsBelow = false
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero,options: [.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner: self))
        super.updateTrackingAreas()
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
    init(title: String, menu: NSMenu, colorMenu: NSMenu?, color: NSColor, background: NSColor?, outline: NSColor?, maxWidth: CGFloat, onInteraction: @escaping () -> Void) {
        var controls: [NSView] = []
        let format = NSMenu()
        for item in menu.items where !item.isSeparatorItem {
            if let choices = item.submenu {
                let selected = choices.items.first { $0.state == .on }?.title ?? item.title
                let text: String
                let glyph: String?
                let width: CGFloat
                var swatch: NSColor?
                var iconColor: NSColor?
                switch item.title {
                case "字体": text = "Aa"; glyph = nil; width = 50
                case "字号", "线条粗细": text = String(selected.split(separator: " ").first ?? Substring(selected)); glyph = nil; width = 50
                case "文字底色": text = ""; glyph = "square.slash"; width = 50; swatch = background
                case "文字描边": text = ""; glyph = outline == nil ? "square.slash" : "square"; width = 50; iconColor = outline
                default: text = selected; glyph = nil; width = min(112,max(62,(selected as NSString).size(withAttributes: [.font:NSFont.systemFont(ofSize: 13)]).width+24))
                }
                controls.append(CapturePropertyButton(text,label: "\(item.title)：\(selected)",menu: choices,width: width,glyph: glyph,swatch: swatch,iconColor: iconColor,interaction: onInteraction))
            } else {
                menu.removeItem(item); format.addItem(item)
            }
        }
        if !format.items.isEmpty {
            let index = controls.count >= 2 && menu.items.contains(where: { $0.title == "字号" }) ? 2 : controls.count
            controls.insert(CapturePropertyButton("格式",label: "格式",menu: format,width: 64,interaction: onInteraction),at: index)
        }
        if let colorMenu { controls.append(CapturePropertyButton("",label: "标注颜色",menu: colorMenu,width: 48,swatch: color,interaction: onInteraction)) }
        let row = stack(controls,horizontal: true,spacing: 1)
        let naturalWidth = row.fittingSize.width+24, width = min(naturalWidth,maxWidth)
        super.init(frame: CGRect(x: 0,y: 0,width: width,height: 48))
        setAccessibilityLabel("\(title)样式条")
        let scroll = NSScrollView(frame: CGRect(x: 12,y: 9,width: width-24,height: 30))
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = naturalWidth > width
        scroll.autohidesScrollers = true
        row.frame = CGRect(x: 0,y: 0,width: naturalWidth-24,height: 30)
        scroll.documentView = row; addSubview(scroll); row.layoutSubtreeIfNeeded()
    }
    required init?(coder: NSCoder) { nil }
    override func draw(_ dirtyRect: NSRect) {
        let body = bounds.insetBy(dx: 0,dy: 4)
        let outline = NSBezierPath(roundedRect: body,xRadius: 13,yRadius: 13)
        let x = max(16,min(arrowX,bounds.width-16)), edge = appearsBelow ? body.minY : body.maxY
        outline.move(to: CGPoint(x: x-6,y: edge)); outline.line(to: CGPoint(x: x,y: appearsBelow ? 0 : bounds.maxY))
        outline.line(to: CGPoint(x: x+6,y: edge)); outline.close()
        NSColor.controlBackgroundColor.withAlphaComponent(0.98).setFill(); outline.fill()
    }
}
