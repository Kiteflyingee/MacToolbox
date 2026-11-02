import AppKit

@MainActor
enum StatusIcon {
    static func image() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            NSColor.black.set()
            let back = NSBezierPath(roundedRect: CGRect(x: 2, y: 4, width: 10, height: 11), xRadius: 2, yRadius: 2)
            var tilt = AffineTransform()
            tilt.translate(x: 7, y: 9.5); tilt.rotate(byDegrees: 17); tilt.translate(x: -7, y: -9.5)
            back.transform(using: tilt); back.lineWidth = 1.15; back.stroke()
            let middle = NSBezierPath(roundedRect: CGRect(x: 3, y: 2, width: 10, height: 11), xRadius: 2, yRadius: 2)
            middle.lineWidth = 1.15; middle.stroke()

            var frontTilt = AffineTransform()
            frontTilt.translate(x: 11, y: 8); frontTilt.rotate(byDegrees: -16); frontTilt.translate(x: -11, y: -8)
            let front = NSBezierPath(roundedRect: CGRect(x: 6, y: 2, width: 10, height: 12), xRadius: 2.2, yRadius: 2.2)
            front.transform(using: frontTilt); front.fill()

            let star = NSBezierPath()
            star.move(to: CGPoint(x: 11, y: 11))
            star.curve(to: CGPoint(x: 14, y: 8), controlPoint1: CGPoint(x: 11.5, y: 9), controlPoint2: CGPoint(x: 12, y: 8.5))
            star.curve(to: CGPoint(x: 11, y: 5), controlPoint1: CGPoint(x: 12, y: 7.5), controlPoint2: CGPoint(x: 11.5, y: 7))
            star.curve(to: CGPoint(x: 8, y: 8), controlPoint1: CGPoint(x: 10.5, y: 7), controlPoint2: CGPoint(x: 10, y: 7.5))
            star.curve(to: CGPoint(x: 11, y: 11), controlPoint1: CGPoint(x: 10, y: 8.5), controlPoint2: CGPoint(x: 10.5, y: 9))
            star.close(); star.transform(using: frontTilt)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current?.cgContext.setBlendMode(.clear)
            star.fill()
            NSGraphicsContext.restoreGraphicsState()
            return true
        }
        image.isTemplate = true
        return image
    }
}
