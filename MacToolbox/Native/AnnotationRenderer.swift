import CoreGraphics
import CoreImage
import CoreText
import Foundation

/// Preview, export, color and OCR use the same compositor. Only outputs encode PNG.
public actor AnnotationRenderer {
    private let effects = CIContext(options: [.cacheIntermediates: false])
    private var cachedBase: (png: Data, image: CGImage)?
    public init() {}

    public func crop(png: Data, rect: CGRect) throws -> Data {
        _ = try DesktopRect(rect)
        let source = try ImageCodec.decode(png)
        let bounds = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1,
              let image = source.cropping(to: clipped) else { throw CoreError.invalidGeometry }
        return try ImageCodec.png(image)
    }

    public func render(basePNG: Data, snapshot: DocumentSnapshot) throws -> Data {
        try ImageCodec.png(renderImage(basePNG: basePNG,snapshot: snapshot))
    }

    public func renderImage(basePNG: Data, snapshot: DocumentSnapshot) throws -> CGImage {
        guard basePNG.count <= AppLimits.historyQueueBytes else { throw CoreError.contentTooLarge }
        let base: CGImage
        if let cachedBase,cachedBase.png == basePNG { base = cachedBase.image }
        else { base = try ImageCodec.decode(basePNG); cachedBase = (basePNG,base) }
        guard base.width == snapshot.pixels.width, base.height == snapshot.pixels.height,
              snapshot.annotations.count <= AppLimits.annotationCount else { throw CoreError.invalidContent }
        let context = try ImageCodec.context(width: base.width, height: base.height)
        let canvas = CGRect(x: 0, y: 0, width: base.width, height: base.height)
        context.draw(base, in: canvas)
        context.translateBy(x: 0, y: canvas.height); context.scaleBy(x: 1, y: -1)
        for annotation in snapshot.annotations {
            try Task.checkCancellation(); try annotation.validate()
            context.saveGState()
            let style = annotation.style
            if let angle = style.rotation,angle != 0 {
                let rect = annotation.geometry.bounds
                context.translateBy(x: rect.midX,y: rect.midY); context.rotate(by: angle)
                context.translateBy(x: -rect.midX,y: -rect.midY)
            }
            context.setStrokeColor(color(style.color)); context.setFillColor(color(style.color))
            context.setLineWidth(style.lineWidth); context.setLineCap(.round); context.setLineJoin(.round)
            switch annotation.geometry {
            case .shape(let kind, let box, let rotation):
                let path = try GeometryPaths.shape(kind, box: box, rotation: rotation)
                switch style.fill {
                case .solid: context.addPath(path); context.fillPath()
                case .translucent, .dashedTranslucent:
                    context.setFillColor(color(style.color, opacity: 0.22)); context.addPath(path); context.fillPath()
                case .hatch:
                    context.saveGState(); context.addPath(path); context.clip()
                    let spacing = max(6, style.lineWidth*3)
                    let visible = box.intersection(canvas)
                    var x = visible.minX-visible.height
                    while !visible.isNull && x < visible.maxX {
                        context.move(to: CGPoint(x: x, y: visible.minY)); context.addLine(to: CGPoint(x: x+visible.height, y: visible.maxY)); x += spacing
                    }
                    context.strokePath(); context.restoreGState()
                case .outline, .dashedOutline: break
                }
                if style.fill == .dashedOutline || style.fill == .dashedTranslucent { context.setLineDash(phase: 0, lengths: [style.lineWidth*3, style.lineWidth*2]) }
                context.addPath(path); context.strokePath()
            case .arrow(let start, let end, let control):
                let paths = try GeometryPaths.arrow(start: start, end: end, control: control, lineWidth: style.lineWidth, style: style.arrow)
                if let tapered = paths.taperedShaft { context.addPath(tapered); context.fillPath() }
                else {
                    if style.arrow.dashed { context.setLineDash(phase: 0, lengths: [style.lineWidth*3, style.lineWidth*2]) }
                    context.addPath(paths.shaft); context.strokePath(); context.setLineDash(phase: 0, lengths: [])
                }
                for head in [paths.startHead, paths.endHead].compactMap({ $0 }) {
                    context.addPath(head)
                    if style.arrow.headShape == .open { context.strokePath() } else { context.fillPath() }
                }
            case .text(let value, let box): drawText(value, box: box, style: style, context: context)
            case .numbered(let number, let center, let label, let box, let connector):
                let radius = max(12, style.text.fontSize*0.65)
                context.move(to: center); context.addLine(to: connector); context.strokePath()
                let circle = CGRect(x: center.x-radius, y: center.y-radius, width: radius*2, height: radius*2)
                context.fillEllipse(in: circle)
                var numberStyle = style; numberStyle.color = RGBAColor(red: 1, green: 1, blue: 1)
                drawText(String(number), box: circle.insetBy(dx: radius*0.3, dy: radius*0.1), style: numberStyle, context: context)
                drawText(label, box: box, style: style, context: context)
            case .remark(let value, let box, let connector):
                context.move(to: CGPoint(x: box.midX, y: box.midY)); context.addLine(to: connector); context.strokePath()
                context.setFillColor(CGColor(red: 1, green: 0.95, blue: 0.65, alpha: 1)); context.fill(box)
                var textStyle = style; textStyle.color = RGBAColor(red: 0.15, green: 0.15, blue: 0.15)
                drawText(value, box: box.insetBy(dx: 6, dy: 6), style: textStyle, context: context)
            case .highlight(let box):
                context.setFillColor(CGColor(gray: 0, alpha: 0.45)); context.addRect(canvas); context.addRect(box); context.fillPath(using: .evenOdd)
            case .stroke(let points, let highlighter):
                if highlighter { context.setAlpha(0.3); context.setBlendMode(.multiply) }
                context.addPath(try GeometryPaths.stroke(points)); context.strokePath()
            case .effect(let kind, let mask):
                guard let prior = context.makeImage() else { throw CoreError.invalidContent }
                let source = CIImage(cgImage: prior)
                let filtered: CIImage
                switch kind {
                case .pixelate(let strength): filtered = source.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: strength.blockSize])
                case .blur(let strength): filtered = source.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: strength.radius])
                }
                guard let output = effects.createCGImage(filtered, from: source.extent) else { throw CoreError.invalidContent }
                switch mask {
                case .rectangle(let box): context.clip(to: box)
                case .brush(let points, let width):
                    let path = try GeometryPaths.stroke(points)
                    context.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 1)); context.clip()
                }
                context.translateBy(x: 0, y: canvas.height); context.scaleBy(x: 1, y: -1); context.draw(output, in: canvas)
            case .magnifier(let source, let lens, let scale):
                guard let prior = context.makeImage() else { throw CoreError.invalidContent }
                let sourceRect = CGRect(x: source.x-lens.width/scale.rawValue/2, y: source.y-lens.height/scale.rawValue/2,
                    width: lens.width/scale.rawValue, height: lens.height/scale.rawValue)
                let clip = sourceRect.intersection(canvas)
                if !clip.isNull, let crop = prior.cropping(to: clip) {
                    context.saveGState(); context.addEllipse(in: lens); context.clip()
                    let destination = CGRect(x: lens.minX+(clip.minX-sourceRect.minX)*scale.rawValue,
                        y: lens.minY+(clip.minY-sourceRect.minY)*scale.rawValue, width: clip.width*scale.rawValue, height: clip.height*scale.rawValue)
                    context.translateBy(x: destination.minX, y: destination.maxY); context.scaleBy(x: 1, y: -1)
                    context.draw(crop, in: CGRect(origin: .zero, size: destination.size)); context.restoreGState()
                }
                context.strokeEllipse(in: lens)
            }
            context.restoreGState()
        }
        guard let result = context.makeImage() else { throw CoreError.invalidContent }
        return result
    }

    public func colorHex(png: Data, x: Int, y: Int) throws -> String {
        let image = try ImageCodec.decode(png)
        guard x >= 0, y >= 0, x < image.width, y < image.height else { throw CoreError.invalidGeometry }
        let context = try ImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { throw CoreError.invalidContent }
        let offset = y*context.bytesPerRow+x*4
        let alpha = Int(bytes[offset+3])
        guard alpha > 0 else { throw CoreError.invalidContent }
        return String(format: "#%02X%02X%02X", min(255, Int(bytes[offset])*255/alpha), min(255, Int(bytes[offset+1])*255/alpha), min(255, Int(bytes[offset+2])*255/alpha))
    }

    private func color(_ value: RGBAColor, opacity: Double = 1) -> CGColor {
        CGColor(red: value.red, green: value.green, blue: value.blue, alpha: value.alpha*opacity)
    }

    private func drawText(_ value: String, box: CGRect, style: AnnotationStyle, context: CGContext) {
        guard !value.isEmpty else { return }
        if let background = style.text.background { context.setFillColor(color(background)); context.fill(box) }
        let font = style.text.fontName.isEmpty ? CTFontCreateUIFontForLanguage(.system, style.text.fontSize, nil)!
            : CTFontCreateWithName(style.text.fontName as CFString, style.text.fontSize, nil)
        var traits: CTFontSymbolicTraits = []
        if style.text.bold { traits.insert(.boldTrait) }; if style.text.italic { traits.insert(.italicTrait) }
        let resolved = CTFontCreateCopyWithSymbolicTraits(font, 0, nil, traits, traits) ?? font
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): resolved,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(style.color)]
        if style.text.underline { attributes[NSAttributedString.Key(kCTUnderlineStyleAttributeName as String)] = 1 }
        if style.text.strikethrough { attributes[NSAttributedString.Key("NSStrikethrough")] = 1 }
        if let outline = style.text.outline {
            attributes[NSAttributedString.Key(kCTStrokeColorAttributeName as String)] = color(outline)
            attributes[NSAttributedString.Key(kCTStrokeWidthAttributeName as String)] = -style.text.outlineWidth
        }
        let text = NSAttributedString(string: value, attributes: attributes)
        context.saveGState(); context.translateBy(x: box.minX, y: box.maxY); context.scaleBy(x: 1, y: -1)
        context.textMatrix = .identity
        let path = CGPath(rect: CGRect(origin: .zero, size: box.size), transform: nil)
        CTFrameDraw(CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text), CFRange(location: 0, length: 0), path, nil), context)
        context.restoreGState()
    }
}
