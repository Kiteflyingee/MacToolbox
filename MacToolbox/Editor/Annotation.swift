import CoreGraphics
import Foundation

public struct RGBAColor: Codable, Equatable, Sendable {
    public var red: Double, green: Double, blue: Double, alpha: Double
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
    public static let red = RGBAColor(red: 1, green: 0.231, blue: 0.188)
    public func validate() throws {
        guard [red, green, blue, alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw CoreError.invalidGeometry }
    }
}

public enum ShapeKind: String, Codable, CaseIterable, Sendable {
    case rectangle, roundedRectangle, ellipse, triangle, star, pentagon, hexagon, speechBubble
}
public enum ShapeFill: String, Codable, CaseIterable, Sendable {
    case outline, translucent, solid, dashedOutline, dashedTranslucent, hatch
}
public enum ArrowHeads: String, Codable, CaseIterable, Sendable { case none, single, double }
public enum ArrowHeadShape: String, Codable, CaseIterable, Sendable { case open, triangle, stealth }

public struct ArrowStyle: Codable, Equatable, Sendable {
    public var heads: ArrowHeads = .single
    public var headShape: ArrowHeadShape = .triangle
    public var dashed = false
    public var tapered = false
    public init() {}
}

public struct TextStyle: Codable, Equatable, Sendable {
    /// Empty means the native system font; the UI resolves its actual name.
    public var fontName = ""
    public var fontSize: Double = 24
    public var bold = false, italic = false, underline = false, strikethrough = false
    public var background: RGBAColor?
    public var outline: RGBAColor?
    public var outlineWidth: Double = 1
    public init() {}
}

public struct AnnotationStyle: Codable, Equatable, Sendable {
    public var color: RGBAColor = .red
    public var lineWidth: Double = 6
    public var fill: ShapeFill = .outline
    public var text = TextStyle()
    public var arrow = ArrowStyle()
    public var rotation: Double?
    public init() {}

    public func validate() throws {
        if let rotation, !rotation.isFinite { throw CoreError.invalidGeometry }
        try color.validate()
        try text.background?.validate()
        try text.outline?.validate()
        guard lineWidth.isFinite, (0.1...256).contains(lineWidth),
              text.fontSize.isFinite, (1...512).contains(text.fontSize),
              text.outlineWidth.isFinite, (0...64).contains(text.outlineWidth),
              text.fontName.utf8.count <= 1_024 else { throw CoreError.invalidGeometry }
    }
}

public enum PixelStrength: String, Codable, CaseIterable, Sendable {
    case fine, medium, coarse
    public var blockSize: Double { switch self { case .fine: 6; case .medium: 12; case .coarse: 24 } }
}
public enum BlurStrength: String, Codable, CaseIterable, Sendable {
    case light, gaussian, strong
    public var radius: Double { switch self { case .light: 4; case .gaussian: 10; case .strong: 20 } }
}
public enum EffectKind: Codable, Equatable, Sendable { case pixelate(PixelStrength), blur(BlurStrength) }
public enum EffectMask: Codable, Equatable, Sendable { case rectangle(CGRect), brush([CGPoint], width: Double) }
public enum Magnification: Double, Codable, CaseIterable, Sendable { case onePointFive = 1.5, two = 2, three = 3, four = 4 }

/// Every coordinate and width in this enum is in original image pixels.
public enum AnnotationGeometry: Codable, Equatable, Sendable {
    case shape(ShapeKind, box: CGRect, rotation: Double)
    case arrow(start: CGPoint, end: CGPoint, control: CGPoint)
    case text(String, box: CGRect)
    case numbered(Int, center: CGPoint, label: String, labelBox: CGRect, connector: CGPoint)
    case remark(String, box: CGRect, connector: CGPoint)
    case highlight(CGRect)
    case stroke([CGPoint], highlighter: Bool)
    case effect(EffectKind, EffectMask)
    case magnifier(source: CGPoint, lens: CGRect, scale: Magnification)

    public func validate() throws {
        func point(_ value: CGPoint) throws {
            let ceiling = Double(AppLimits.imagePixels) * 4
            guard value.x.isFinite, value.y.isFinite, abs(value.x) <= ceiling, abs(value.y) <= ceiling else { throw CoreError.invalidGeometry }
        }
        func box(_ value: CGRect) throws {
            _ = try DesktopRect(value)
            try point(value.origin); try point(CGPoint(x: value.maxX, y: value.maxY))
        }
        func points(_ values: [CGPoint]) throws {
            guard values.count >= 2, values.count <= 50_000 else { throw CoreError.invalidGeometry }
            for value in values { try point(value) }
        }
        func text(_ value: String) throws {
            guard value.utf8.count <= AppLimits.annotationBytes else { throw CoreError.contentTooLarge }
        }
        switch self {
        case .shape(_, let rect, let rotation):
            try box(rect)
            guard rotation.isFinite else { throw CoreError.invalidGeometry }
        case .arrow(let start, let end, let control):
            try point(start); try point(end); try point(control)
            guard QuadraticCurve.length(start: start, end: end, control: control) >= 2 else { throw CoreError.invalidGeometry }
        case .text(let value, let rect): try text(value); try box(rect)
        case .numbered(let number, let center, let label, let rect, let connector):
            guard (1...999_999).contains(number) else { throw CoreError.invalidContent }
            try point(center); try text(label); try box(rect); try point(connector)
        case .remark(let value, let rect, let connector): try text(value); try box(rect); try point(connector)
        case .highlight(let rect): try box(rect)
        case .stroke(let values, _): try points(values)
        case .effect(_, let mask):
            switch mask {
            case .rectangle(let rect): try box(rect)
            case .brush(let values, let width):
                try points(values)
                guard width.isFinite, (1...256).contains(width) else { throw CoreError.invalidGeometry }
            }
        case .magnifier(let source, let lens, _): try point(source); try box(lens)
        }
    }

    public func translated(x: Double, y: Double) -> AnnotationGeometry {
        func move(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x+x, y: p.y+y) }
        func moveBox(_ r: CGRect) -> CGRect { r.offsetBy(dx: x, dy: y) }
        switch self {
        case .shape(let kind, let rect, let rotation): return .shape(kind, box: moveBox(rect), rotation: rotation)
        case .arrow(let start, let end, let control): return .arrow(start: move(start), end: move(end), control: move(control))
        case .text(let text, let rect): return .text(text, box: moveBox(rect))
        case .numbered(let number, let center, let label, let rect, let connector):
            return .numbered(number, center: move(center), label: label, labelBox: moveBox(rect), connector: move(connector))
        case .remark(let text, let rect, let connector): return .remark(text, box: moveBox(rect), connector: move(connector))
        case .highlight(let rect): return .highlight(moveBox(rect))
        case .stroke(let points, let highlighter): return .stroke(points.map(move), highlighter: highlighter)
        case .effect(let kind, let mask):
            let translated: EffectMask
            switch mask {
            case .rectangle(let rect): translated = .rectangle(moveBox(rect))
            case .brush(let points, let width): translated = .brush(points.map(move), width: width)
            }
            return .effect(kind, translated)
        case .magnifier(let source, let lens, let scale): return .magnifier(source: move(source), lens: moveBox(lens), scale: scale)
        }
    }
}

public struct Annotation: Codable, Equatable, Sendable {
    public let id: UUID
    public var geometry: AnnotationGeometry
    public var style: AnnotationStyle
    public init(id: UUID = UUID(), geometry: AnnotationGeometry, style: AnnotationStyle = AnnotationStyle()) {
        self.id = id; self.geometry = geometry; self.style = style
    }
    public func validate() throws { try geometry.validate(); try style.validate() }
}

public enum AnnotationClipboard {
    public static let typeIdentifier = "local.mactoolbox.annotations"
    private struct Envelope: Codable { let version: Int; let annotations: [Annotation] }

    public static func encode(_ annotations: [Annotation]) throws -> Data {
        try validate(annotations)
        let data = try JSONEncoder().encode(Envelope(version: 1, annotations: annotations))
        guard data.count <= AppLimits.annotationBytes else { throw CoreError.contentTooLarge }
        return data
    }

    public static func decodeForPaste(_ data: Data) throws -> [Annotation] {
        guard data.count <= AppLimits.annotationBytes else { throw CoreError.contentTooLarge }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1 else { throw CoreError.unsupportedVersion }
        try validate(envelope.annotations)
        return try envelope.annotations.map { annotation in
            let copy = Annotation(geometry: annotation.geometry.translated(x: 12, y: 12), style: annotation.style)
            try copy.validate()
            return copy
        }
    }

    private static func validate(_ annotations: [Annotation]) throws {
        guard !annotations.isEmpty, annotations.count <= AppLimits.annotationCount,
              Set(annotations.map(\.id)).count == annotations.count else { throw CoreError.invalidContent }
        for annotation in annotations { try annotation.validate() }
    }
}
