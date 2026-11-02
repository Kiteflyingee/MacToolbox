import AppKit

@main
struct StatusIconPreview {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let icon = StatusIcon.image()
        precondition(icon.isTemplate && icon.size == NSSize(width: 18, height: 18))
        for scale in [1, 2] {
            let side = 18*scale
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            bitmap.size = NSSize(width: 18, height: 18)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
            icon.draw(in: CGRect(x: 0,y: 0,width: 18,height: 18))
            NSGraphicsContext.restoreGraphicsState()
            precondition(bitmap.colorAt(x: 0,y: 0)!.alphaComponent == 0)
            let coverage = (0..<side).reduce(0) { count,y in
                count+(0..<side).filter { bitmap.colorAt(x: $0,y: y)!.alphaComponent > 0.5 }.count
            }
            precondition(coverage > 60*scale*scale && coverage < 240*scale*scale)
            try bitmap.representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("status-icon-\(scale)x.png"))
        }
        let preview = NSImage(size: NSSize(width: 320,height: 120),flipped: false) { _ in
            for (index,background) in [NSColor(white: 0.94,alpha: 1),NSColor(white: 0.12,alpha: 1)].enumerated() {
                let x = CGFloat(index*160)
                background.setFill(); CGRect(x: x,y: 0,width: 160,height: 120).fill()
                let tinted = NSImage(size: icon.size,flipped: false) { _ in
                    icon.draw(at: .zero,from: .zero,operation: .sourceOver,fraction: 1)
                    NSGraphicsContext.current?.compositingOperation = .sourceIn
                    (index == 0 ? NSColor.black : NSColor.white).setFill()
                    CGRect(x: 0,y: 0,width: 18,height: 18).fill()
                    return true
                }
                tinted.draw(in: CGRect(x: x+20,y: 18,width: 84,height: 84))
                tinted.draw(in: CGRect(x: x+125,y: 50,width: 18,height: 18))
            }
            return true
        }
        let previewBitmap = NSBitmapImageRep(bitmapDataPlanes: nil,pixelsWide: 640,pixelsHigh: 240,bitsPerSample: 8,
            samplesPerPixel: 4,hasAlpha: true,isPlanar: false,colorSpaceName: .deviceRGB,bytesPerRow: 0,bitsPerPixel: 0)!
        previewBitmap.size = preview.size
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: previewBitmap)
        preview.draw(in: CGRect(origin: .zero,size: preview.size)); NSGraphicsContext.restoreGraphicsState()
        try previewBitmap.representation(using: .png,properties: [:])!.write(to: directory.appendingPathComponent("appearance.png"))
        print("18pt template icon rendered at 1× and 2×; transparency and coverage checks passed.")
    }
}
