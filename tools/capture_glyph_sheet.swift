import AppKit

private struct Inventory: Decodable {
    struct Item: Decodable { let index: Int; let path: String; let vm_address: String }
    let paths: [Item]
}

@main
struct CaptureGlyphSheet {
    @MainActor static func main() throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        let inventory = try JSONDecoder().decode(Inventory.self,from: Data(contentsOf: source))
        let paths = try inventory.paths.map { (item: $0,path: try SVGPath.decode($0.path)) }
        let width = 12*90, height = ((paths.count+11)/12)*90
        let image = NSImage(size: NSSize(width: width,height: height),flipped: false) { _ in
            NSColor.white.setFill(); CGRect(x: 0,y: 0,width: width,height: height).fill()
            for (offset,value) in paths.enumerated() {
                let x = CGFloat(offset%12)*90, y = CGFloat(height-(offset/12+1)*90)
                let bounds = value.path.boundingBoxOfPath, box = max(24,max(bounds.maxX,bounds.maxY))
                NSGraphicsContext.saveGraphicsState()
                let context = NSGraphicsContext.current!.cgContext
                context.clip(to: CGRect(x: x,y: y,width: 90,height: 90))
                context.translateBy(x: x+19,y: y+79); context.scaleBy(x: 52/box,y: -52/box)
                context.setFillColor(NSColor.black.cgColor); context.addPath(value.path); context.drawPath(using: .eoFill)
                NSGraphicsContext.restoreGraphicsState()
                let text = "\(value.item.index) · \(value.item.vm_address.suffix(5))"
                (text as NSString).draw(at: CGPoint(x: x+4,y: y+6),withAttributes: [.font:NSFont.monospacedSystemFont(ofSize: 9,weight: .regular),.foregroundColor:NSColor.darkGray])
            }
            return true
        }
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: width*2,pixelsHigh: height*2,bitsPerSample: 8,
            samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
        bitmap.size = image.size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        image.draw(in: CGRect(origin: .zero,size: image.size)); NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png,properties: [:])!.write(to: output)
        print("Decoded and rendered \(paths.count) source vector paths.")
    }
}
