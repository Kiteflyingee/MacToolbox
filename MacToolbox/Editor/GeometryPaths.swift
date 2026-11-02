import CoreGraphics
import Foundation

enum QuadraticCurve {
    static func point(start: CGPoint, end: CGPoint, control: CGPoint, t: Double) -> CGPoint {
        let u = 1-t
        return CGPoint(x: u*u*start.x + 2*u*t*control.x + t*t*end.x,
                       y: u*u*start.y + 2*u*t*control.y + t*t*end.y)
    }
    static func length(start: CGPoint, end: CGPoint, control: CGPoint) -> Double {
        var previous = start, total = 0.0
        for index in 1...32 {
            let next = point(start: start, end: end, control: control, t: Double(index)/32)
            total += hypot(next.x-previous.x, next.y-previous.y)
            previous = next
        }
        return total
    }
}

public enum GeometryPaths {
    public static func stroke(_ points: [CGPoint]) throws -> CGPath {
        try AnnotationGeometry.stroke(points,highlighter: false).validate()
        let path = CGMutablePath(); path.move(to: points[0])
        for index in 1..<points.count-1 {
            let midpoint = CGPoint(x: (points[index].x+points[index+1].x)/2,y: (points[index].y+points[index+1].y)/2)
            path.addQuadCurve(to: midpoint,control: points[index])
        }
        path.addLine(to: points[points.count-1]); return path
    }
    public static func shape(_ kind: ShapeKind, box: CGRect, rotation: Double = 0) throws -> CGPath {
        try AnnotationGeometry.shape(kind, box: box, rotation: rotation).validate()
        let path = CGMutablePath()
        switch kind {
        case .rectangle: path.addRect(box)
        case .roundedRectangle:
            let radius = min(box.width, box.height) * 0.15
            path.addRoundedRect(in: box, cornerWidth: radius, cornerHeight: radius)
        case .ellipse: path.addEllipse(in: box)
        case .triangle, .pentagon, .hexagon, .star:
            let count = kind == .triangle ? 3 : kind == .pentagon ? 5 : kind == .hexagon ? 6 : 10
            for index in 0..<count {
                let angle = -Double.pi/2 + Double(index) * 2 * .pi / Double(count)
                let scale = kind == .star && index % 2 == 1 ? 0.45 : 1
                let point = CGPoint(x: box.midX + box.width/2 * cos(angle) * scale,
                                    y: box.midY + box.height/2 * sin(angle) * scale)
                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
            }
            path.closeSubpath()
        case .speechBubble:
            let x = box.minX, y = box.minY, w = box.width, h = box.height
            let bottom = y + h * 0.8, r = min(w, h * 0.8) * 0.15
            path.move(to: CGPoint(x: x+r, y: y))
            path.addLine(to: CGPoint(x: x+w-r, y: y))
            path.addQuadCurve(to: CGPoint(x: x+w, y: y+r), control: CGPoint(x: x+w, y: y))
            path.addLine(to: CGPoint(x: x+w, y: bottom-r))
            path.addQuadCurve(to: CGPoint(x: x+w-r, y: bottom), control: CGPoint(x: x+w, y: bottom))
            path.addLine(to: CGPoint(x: x+w*0.4, y: bottom))
            path.addLine(to: CGPoint(x: x+w*0.1, y: y+h))
            path.addLine(to: CGPoint(x: x+w*0.2, y: bottom))
            path.addLine(to: CGPoint(x: x+r, y: bottom))
            path.addQuadCurve(to: CGPoint(x: x, y: bottom-r), control: CGPoint(x: x, y: bottom))
            path.addLine(to: CGPoint(x: x, y: y+r))
            path.addQuadCurve(to: CGPoint(x: x+r, y: y), control: CGPoint(x: x, y: y))
            path.closeSubpath()
        }
        guard rotation != 0 else { return path }
        var transform = CGAffineTransform(translationX: box.midX, y: box.midY)
            .rotated(by: rotation).translatedBy(x: -box.midX, y: -box.midY)
        guard let result = path.copy(using: &transform) else { throw CoreError.invalidGeometry }
        return result
    }

    public struct ArrowPaths {
        public let shaft: CGPath
        public let taperedShaft: CGPath?
        public let startHead: CGPath?
        public let endHead: CGPath?
    }

    public static func arrow(start: CGPoint, end: CGPoint, control: CGPoint, lineWidth: Double,
                             style: ArrowStyle) throws -> ArrowPaths {
        try AnnotationGeometry.arrow(start: start, end: end, control: control).validate()
        guard lineWidth.isFinite, (0.1...256).contains(lineWidth) else { throw CoreError.invalidGeometry }
        func point(_ t: Double) -> CGPoint {
            QuadraticCurve.point(start: start, end: end, control: control, t: t)
        }
        func unit(_ vector: CGPoint, fallback: CGPoint) -> CGPoint {
            let length = hypot(vector.x, vector.y)
            return length > 1e-8 ? CGPoint(x: vector.x/length, y: vector.y/length) : fallback
        }
        let samples = (0...32).map { point(Double($0)/32) }
        var distances: [Double] = [0]
        for index in 1...32 { distances.append(distances[index-1] + hypot(samples[index].x-samples[index-1].x, samples[index].y-samples[index-1].y)) }
        let length = distances[32]
        guard length >= 2 else { throw CoreError.invalidGeometry }
        let headLength = min(12 + 2*lineWidth, length*0.35)
        func parameter(at distance: Double) -> Double {
            for index in 1...32 where distances[index] >= distance {
                let span = distances[index]-distances[index-1]
                return (Double(index-1) + (span > 0 ? (distance-distances[index-1])/span : 0))/32
            }
            return 1
        }
        let a = parameter(at: style.heads == .double ? headLength : 0)
        let b = parameter(at: style.heads == .none ? length : length-headLength)
        let p0 = point(a), p2 = point(b), delta = b-a
        let derivative = CGPoint(x: (1-a)*(control.x-start.x) + a*(end.x-control.x),
                                 y: (1-a)*(control.y-start.y) + a*(end.y-control.y))
        let p1 = CGPoint(x: p0.x+delta*derivative.x, y: p0.y+delta*derivative.y)
        let shaft = CGMutablePath()
        shaft.move(to: p0); shaft.addQuadCurve(to: p2, control: p1)
        let chord = unit(CGPoint(x: end.x-start.x, y: end.y-start.y), fallback: CGPoint(x: 1, y: 0))
        func head(tip: CGPoint, direction: CGPoint) -> CGPath {
            let base = CGPoint(x: tip.x-direction.x*headLength, y: tip.y-direction.y*headLength)
            let normal = CGPoint(x: -direction.y*lineWidth*1.4, y: direction.x*lineWidth*1.4)
            let path = CGMutablePath()
            path.move(to: CGPoint(x: base.x+normal.x, y: base.y+normal.y))
            path.addLine(to: tip)
            path.addLine(to: CGPoint(x: base.x-normal.x, y: base.y-normal.y))
            if style.headShape == .stealth {
                path.addLine(to: CGPoint(x: tip.x-direction.x*headLength*0.65, y: tip.y-direction.y*headLength*0.65))
            }
            if style.headShape != .open { path.closeSubpath() }
            return path
        }
        let startDirection = unit(CGPoint(x: start.x-control.x, y: start.y-control.y), fallback: CGPoint(x: -chord.x, y: -chord.y))
        let endDirection = unit(CGPoint(x: end.x-control.x, y: end.y-control.y), fallback: chord)
        var tapered: CGPath?
        if style.tapered {
            let points = (0...32).map { point(a+(b-a)*Double($0)/32) }
            var left: [CGPoint] = [], right: [CGPoint] = []
            var lastDirection = chord
            for index in 0...32 {
                let previous = points[max(0, index-1)], next = points[min(32, index+1)]
                lastDirection = unit(CGPoint(x: next.x-previous.x, y: next.y-previous.y), fallback: lastDirection)
                let halfWidth = lineWidth/6 + (lineWidth/2-lineWidth/6)*Double(index)/32
                let normal = CGPoint(x: -lastDirection.y*halfWidth, y: lastDirection.x*halfWidth)
                left.append(CGPoint(x: points[index].x+normal.x, y: points[index].y+normal.y))
                right.append(CGPoint(x: points[index].x-normal.x, y: points[index].y-normal.y))
            }
            let path = CGMutablePath()
            path.addLines(between: left + right.reversed())
            path.closeSubpath()
            tapered = path
        }
        return ArrowPaths(shaft: shaft, taperedShaft: tapered,
            startHead: style.heads == .double ? head(tip: start, direction: startDirection) : nil,
            endHead: style.heads == .none ? nil : head(tip: end, direction: endDirection))
    }
}
