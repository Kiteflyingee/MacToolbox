import CoreGraphics
import Foundation

public extension Annotation {
    var canRotate: Bool {
        switch geometry { case .shape,.text,.remark,.numbered: true; default: false }
    }
    var rotation: Double {
        if case .shape(_,_,let angle) = geometry { return angle }
        return style.rotation ?? 0
    }
    var bounds: CGRect {
        let rect = geometry.bounds, angle = style.rotation ?? 0
        guard angle != 0 else { return rect }
        let transform = CGAffineTransform(translationX: rect.midX,y: rect.midY)
            .rotated(by: angle).translatedBy(x: -rect.midX,y: -rect.midY)
        return rect.applying(transform)
    }
    func rotated(to angle: Double) throws -> Annotation {
        guard canRotate,angle.isFinite else { throw CoreError.invalidGeometry }
        var result = self
        if case .shape(let kind,let box,_) = geometry { result.geometry = .shape(kind,box: box,rotation: angle); result.style.rotation = nil }
        else { result.style.rotation = angle }
        try result.validate(); return result
    }
}

public extension AnnotationGeometry {
    var bounds: CGRect {
        func envelope(_ points: [CGPoint]) -> CGRect {
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) {
                $0.union(CGRect(origin: $1, size: .zero))
            }
        }
        switch self {
        case .shape(let kind, let box, let angle):
            return (try? GeometryPaths.shape(kind, box: box, rotation: angle).boundingBoxOfPath) ?? box
        case .text(_, let box), .highlight(let box), .effect(_, .rectangle(let box)), .magnifier(_, let box, _): return box
        case .arrow(let a, let b, let c): return envelope([a, b, c]).insetBy(dx: -8, dy: -8)
        case .stroke(let points, _): return envelope(points).insetBy(dx: -4, dy: -4)
        case .effect(_, .brush(let points, let width)): return envelope(points).insetBy(dx: -width/2, dy: -width/2)
        case .numbered(_, let center, _, let box, let connector):
            return CGRect(x: center.x-18, y: center.y-18, width: 36, height: 36).union(box).union(CGRect(origin: connector, size: .zero))
        case .remark(_, let box, let connector): return box.union(CGRect(origin: connector, size: .zero))
        }
    }

    /// Resizes an object in image coordinates without flattening its editable geometry.
    func resized(from old: CGRect, to new: CGRect) throws -> AnnotationGeometry {
        _ = try DesktopRect(old); _ = try DesktopRect(new)
        func point(_ p: CGPoint) -> CGPoint {
            CGPoint(x: new.minX+(p.x-old.minX)*new.width/old.width,
                    y: new.minY+(p.y-old.minY)*new.height/old.height)
        }
        func box(_ r: CGRect) -> CGRect {
            CGRect(origin: point(r.origin), size: CGSize(width: r.width*new.width/old.width, height: r.height*new.height/old.height))
        }
        let result: AnnotationGeometry
        switch self {
        case .shape(let kind, let r, let rotation): result = .shape(kind, box: box(r), rotation: rotation)
        case .arrow(let a, let b, let c): result = .arrow(start: point(a), end: point(b), control: point(c))
        case .text(let text, let r): result = .text(text, box: box(r))
        case .numbered(let n, let center, let text, let r, let c):
            result = .numbered(n, center: point(center), label: text, labelBox: box(r), connector: point(c))
        case .remark(let text, let r, let c): result = .remark(text, box: box(r), connector: point(c))
        case .highlight(let r): result = .highlight(box(r))
        case .stroke(let points, let highlighter): result = .stroke(points.map(point), highlighter: highlighter)
        case .effect(let effect, .rectangle(let r)): result = .effect(effect, .rectangle(box(r)))
        case .effect(let effect, .brush(let points, let width)): result = .effect(effect, .brush(points.map(point), width: width))
        case .magnifier(let source, let lens, let scale): result = .magnifier(source: point(source), lens: box(lens), scale: scale)
        }
        try result.validate()
        return result
    }
}
