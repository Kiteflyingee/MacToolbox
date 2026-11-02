import AppKit
import MacToolboxCore

@MainActor
enum CaptureIcons {
    private struct Glyph: Decodable { let path: String; let viewBox: CGFloat }
    private struct Library: Decodable { let glyphs: [String: Glyph] }
    private static let glyphs: [String: Glyph] = {
        guard let url = Bundle.main.url(forResource: "CaptureGlyphs",withExtension: "json"),
              let data = try? Data(contentsOf: url),let library = try? JSONDecoder().decode(Library.self,from: data) else { return [:] }
        return library.glyphs
    }()
    private static var images: [String: NSImage] = [:]
    static var loadedGlyphCount: Int { glyphs.count }

    static func image(_ name: String) -> NSImage? {
        if let image = images[name] { return image }
        if name == "square.on.circle" {
            let image = NSImage(size: NSSize(width: 20,height: 20),flipped: false) { _ in
                NSColor.black.setStroke()
                let rectangle = NSBezierPath(roundedRect: CGRect(x: 2,y: 5,width: 12,height: 13),xRadius: 2,yRadius: 2)
                rectangle.lineWidth = 1.6; rectangle.stroke()
                let circle = NSBezierPath(ovalIn: CGRect(x: 9,y: 1,width: 10,height: 10))
                NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current?.cgContext.setBlendMode(.clear); circle.fill(); NSGraphicsContext.restoreGraphicsState()
                NSColor.black.setStroke(); circle.lineWidth = 1.6; circle.stroke(); return true
            }
            image.isTemplate = true; images[name] = image; return image
        }
        guard let glyph = glyphs[name],let path = try? SVGPath.decode(glyph.path) else {
            return NSImage(systemSymbolName: name,accessibilityDescription: nil)
        }
        let image = NSImage(size: NSSize(width: 20,height: 20),flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.saveGState()
            context.translateBy(x: 0,y: rect.height); context.scaleBy(x: rect.width/glyph.viewBox,y: -rect.height/glyph.viewBox)
            context.setFillColor(NSColor.black.cgColor); context.addPath(path); context.drawPath(using: .eoFill)
            context.restoreGState()
            return true
        }
        image.isTemplate = true; images[name] = image; return image
    }
}
