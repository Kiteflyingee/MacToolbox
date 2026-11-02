import CoreGraphics
import Foundation

public enum SVGPathError: Error { case invalidPath }

/// Decodes the vector path commands present in the reference toolbar assets.
public enum SVGPath {
    public static func decode(_ source: String) throws -> CGPath {
        guard source.utf8.count <= 100_000 else { throw SVGPathError.invalidPath }
        let expression = try NSRegularExpression(pattern: #"[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?|[A-Za-z]"#)
        let text = source as NSString
        let matches = expression.matches(in: source,range: NSRange(location: 0,length: text.length))
        guard !matches.isEmpty, matches.count <= 20_000 else { throw SVGPathError.invalidPath }
        var last = 0
        for match in matches {
            let gap = text.substring(with: NSRange(location: last,length: match.range.location-last))
            guard gap.allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw SVGPathError.invalidPath }
            last = NSMaxRange(match.range)
        }
        guard text.substring(from: last).allSatisfy({ $0.isWhitespace || $0 == "," }) else { throw SVGPathError.invalidPath }
        let tokens = matches.map { text.substring(with: $0.range) }
        let path = CGMutablePath()
        var index = 0, command = "", previous = ""
        var current = CGPoint.zero, start = CGPoint.zero, control = CGPoint.zero
        var hasMove = false
        func number() throws -> CGFloat {
            guard index < tokens.count, let value = Double(tokens[index]),value.isFinite,abs(value) <= 1_000_000 else {
                throw SVGPathError.invalidPath
            }
            index += 1; return CGFloat(value)
        }
        func point(relative: Bool) throws -> CGPoint {
            let p = try CGPoint(x: number(),y: number())
            return relative ? CGPoint(x: current.x+p.x,y: current.y+p.y) : p
        }
        while index < tokens.count {
            if tokens[index].first?.isLetter == true { command = tokens[index]; index += 1 }
            guard !command.isEmpty else { throw SVGPathError.invalidPath }
            let kind = command.uppercased(), relative = command != kind
            guard hasMove || kind == "M" else { throw SVGPathError.invalidPath }
            switch kind {
            case "M":
                current = try point(relative: relative); start = current; path.move(to: current); hasMove = true
                command = relative ? "l" : "L"
            case "L": current = try point(relative: relative); path.addLine(to: current)
            case "H":
                let x = try number(); current.x = relative ? current.x+x : x; path.addLine(to: current)
            case "V":
                let y = try number(); current.y = relative ? current.y+y : y; path.addLine(to: current)
            case "C":
                let a = try point(relative: relative), b = try point(relative: relative), end = try point(relative: relative)
                path.addCurve(to: end,control1: a,control2: b); current = end; control = b
            case "S":
                let a = ["C","S"].contains(previous) ? CGPoint(x: 2*current.x-control.x,y: 2*current.y-control.y) : current
                let b = try point(relative: relative), end = try point(relative: relative)
                path.addCurve(to: end,control1: a,control2: b); current = end; control = b
            case "Q":
                let a = try point(relative: relative), end = try point(relative: relative)
                path.addQuadCurve(to: end,control: a); current = end; control = a
            case "T":
                let a = ["Q","T"].contains(previous) ? CGPoint(x: 2*current.x-control.x,y: 2*current.y-control.y) : current
                let end = try point(relative: relative)
                path.addQuadCurve(to: end,control: a); current = end; control = a
            case "A":
                let rx = try number(), ry = try number(), rotation = try number(), large = try number(), sweep = try number()
                guard [0,1].contains(large),[0,1].contains(sweep) else { throw SVGPathError.invalidPath }
                let end = try point(relative: relative)
                arc(path,from: current,to: end,rx: rx,ry: ry,rotation: rotation,large: large == 1,sweep: sweep == 1)
                current = end
            case "Z": path.closeSubpath(); current = start; command = ""
            default: throw SVGPathError.invalidPath
            }
            previous = kind
        }
        return path
    }

    private static func arc(_ path: CGMutablePath,from start: CGPoint,to end: CGPoint,rx: CGFloat,ry: CGFloat,
                            rotation: CGFloat,large: Bool,sweep: Bool) {
        guard start != end else { return }
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0,ry > 0 else { path.addLine(to: end); return }
        let phi = rotation.truncatingRemainder(dividingBy: 360)*CGFloat.pi/180
        let c = cos(phi), s = sin(phi), dx = (start.x-end.x)/2, dy = (start.y-end.y)/2
        let x = c*dx+s*dy, y = -s*dx+c*dy
        let size = x*x/(rx*rx)+y*y/(ry*ry)
        if size > 1 { let factor = sqrt(size); rx *= factor; ry *= factor }
        let denominator = rx*rx*y*y+ry*ry*x*x
        guard denominator.isFinite,denominator > 0 else { path.addLine(to: end); return }
        let factor = (large == sweep ? CGFloat(-1) : 1)*sqrt(max(0,(rx*rx*ry*ry-denominator)/denominator))
        let cx = factor*rx*y/ry, cy = -factor*ry*x/rx
        let center = CGPoint(x: c*cx-s*cy+(start.x+end.x)/2,y: s*cx+c*cy+(start.y+end.y)/2)
        let u = CGPoint(x: (x-cx)/rx,y: (y-cy)/ry), v = CGPoint(x: (-x-cx)/rx,y: (-y-cy)/ry)
        let angle = atan2(u.y,u.x)
        var delta = atan2(u.x*v.y-u.y*v.x,u.x*v.x+u.y*v.y)
        if !sweep,delta > 0 { delta -= 2*CGFloat.pi }
        if sweep,delta < 0 { delta += 2*CGFloat.pi }
        let count = max(1,Int(ceil(abs(delta)/(CGFloat.pi/2)))), step = delta/CGFloat(count)
        func position(_ t: CGFloat) -> CGPoint {
            CGPoint(x: center.x+c*rx*cos(t)-s*ry*sin(t),y: center.y+s*rx*cos(t)+c*ry*sin(t))
        }
        func tangent(_ t: CGFloat) -> CGPoint { CGPoint(x: -c*rx*sin(t)-s*ry*cos(t),y: -s*rx*sin(t)+c*ry*cos(t)) }
        for index in 0..<count {
            let a = angle+CGFloat(index)*step, b = a+step, k = 4/3*tan(step/4)
            let pa = position(a), pb = position(b), ta = tangent(a), tb = tangent(b)
            path.addCurve(to: index == count-1 ? end : pb,
                control1: CGPoint(x: pa.x+k*ta.x,y: pa.y+k*ta.y),control2: CGPoint(x: pb.x-k*tb.x,y: pb.y-k*tb.y))
        }
    }
}
