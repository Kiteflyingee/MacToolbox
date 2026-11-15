import AppKit
import CoreGraphics
import ImageIO
import MacToolboxCore
import UniformTypeIdentifiers

@main
struct PreviewBenchmark {
    static func main() async throws {
        let width = 2560, height = 1440
        let context = CGContext(data: nil,width: width,height: height,bitsPerComponent: 8,bytesPerRow: width*4,
            space: CGColorSpaceCreateDeviceRGB(),bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(gray: 0.95,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: width,height: height))
        for x in stride(from: 0,to: width,by: 20) {
            context.setFillColor(CGColor(gray: CGFloat(x%255)/255,alpha: 1))
            context.fill(CGRect(x: x,y: 0,width: 8,height: height))
        }
        let bytes = NSMutableData(), destination = CGImageDestinationCreateWithData(bytes,UTType.png.identifier as CFString,1,nil)!
        CGImageDestinationAddImage(destination,context.makeImage()!,nil)
        guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
        let png = bytes as Data
        var document = AnnotationDocument(baseImageID: UUID(),pixels: try PixelSize(width: width,height: height))
        try document.replace(with: (0..<12).map { index in
            Annotation(geometry: .shape(.roundedRectangle,box: CGRect(x: 80+index*120,y: 100+index*70,width: 300,height: 150),rotation: 0))
        })
        let renderer = AnnotationRenderer(), snapshot = document.snapshot()
        _ = try await renderer.render(basePNG: png,snapshot: snapshot)
        _ = try await renderer.renderImage(basePNG: png,snapshot: snapshot)
        var encoded: [Double] = [], direct: [Double] = []
        for _ in 0..<7 {
            var start = CFAbsoluteTimeGetCurrent()
            let data = try await renderer.render(basePNG: png,snapshot: snapshot)
            _ = NSImage(data: data)
            encoded.append((CFAbsoluteTimeGetCurrent()-start)*1000)
            start = CFAbsoluteTimeGetCurrent()
            let image = try await renderer.renderImage(basePNG: png,snapshot: snapshot)
            _ = NSImage(cgImage: image,size: .zero)
            direct.append((CFAbsoluteTimeGetCurrent()-start)*1000)
        }
        let a = encoded.sorted()[3], b = direct.sorted()[3]
        let report: [String:Any] = ["width":width,"height":height,"annotations":12,"iterations":7,
            "pngDisplayPipelineMedianMS":a,"directImageDisplayMedianMS":b,"ratio":a/b,
            "scope":"Synthetic local compositor benchmark; not an end-to-end interaction FPS measurement."]
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]).write(to: output)
        print(String(format: "PNG display %.1f ms; direct image %.1f ms; %.2f×",a,b,a/b))
    }
}
