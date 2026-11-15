import AppKit
import MacToolboxCore

private struct GlyphLibrary: Decodable {
    struct Glyph: Decodable { let path: String; let viewBox: CGFloat }
    let glyphs: [String: Glyph]
}

@main
struct CaptureGlyphSheet {
    @MainActor static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        let library = try JSONDecoder().decode(GlyphLibrary.self, from: Data(contentsOf: source))
        let items = try library.glyphs.keys.sorted().map { name in
            let glyph = library.glyphs[name]!
            return (name: name, viewBox: glyph.viewBox, path: try SVGPath.decode(glyph.path))
        }
        let columns = 6, cell = 110
        let width = columns * cell, height = ((items.count + columns - 1) / columns) * cell
        let image = NSImage(size: NSSize(width: width, height: height), flipped: false) { _ in
            NSColor.white.setFill(); CGRect(x: 0, y: 0, width: width, height: height).fill()
            for (offset, value) in items.enumerated() {
                let x = CGFloat(offset % columns) * CGFloat(cell)
                let y = CGFloat(height - (offset / columns + 1) * cell)
                let box = max(24, value.viewBox)
                NSGraphicsContext.saveGraphicsState()
                let context = NSGraphicsContext.current!.cgContext
                context.clip(to: CGRect(x: x, y: y, width: CGFloat(cell), height: CGFloat(cell)))
                context.translateBy(x: x + 29, y: y + 89); context.scaleBy(x: 52 / box, y: -52 / box)
                context.setFillColor(NSColor.black.cgColor); context.addPath(value.path); context.drawPath(using: .eoFill)
                NSGraphicsContext.restoreGraphicsState()
                (value.name as NSString).draw(at: CGPoint(x: x + 6, y: y + 8),
                    withAttributes: [.font: NSFont.monospacedSystemFont(ofSize: 9, weight: .regular), .foregroundColor: NSColor.darkGray])
            }
            return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width * 2, pixelsHigh: height * 2, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero, size: image.size)); NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: output)
        print("Decoded and rendered \(items.count) toolbar glyphs.")
    }
}
