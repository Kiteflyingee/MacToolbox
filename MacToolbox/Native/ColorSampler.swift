import CoreGraphics
import Foundation

public struct ColorSample: Sendable, Equatable {
    public let x: Int
    public let y: Int
    public let hex: String
    public let neighborhoodPNG: Data
    public let focusInNeighborhood: CGPoint
}

/// Immutable normalized bitmap per frozen display/document; sampling does not re-decode the screen.
public actor ColorSampler {
    private struct Bitmap {
        let context: CGContext
        let image: CGImage
    }
    private var bitmaps: [UInt32: Bitmap] = [:]
    public init() {}

    public func load(png: Data, id: UInt32) throws -> PixelSize {
        guard png.count <= AppLimits.historyQueueBytes else { throw CoreError.contentTooLarge }
        let image = try ImageCodec.decode(png)
        let size = try PixelSize(width: image.width, height: image.height)
        let otherPixels = bitmaps.filter { $0.key != id }.values.reduce(0) { $0 + $1.image.width*$1.image.height }
        guard otherPixels <= AppLimits.imagePixels-size.count else { throw CoreError.contentTooLarge }
        try Task.checkCancellation()
        let context = try ImageCodec.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let normalized = context.makeImage() else { throw CoreError.invalidContent }
        bitmaps[id] = Bitmap(context: context, image: normalized)
        return size
    }

    public func sample(id: UInt32, point: CGPoint) throws -> ColorSample? {
        guard let bitmap = bitmaps[id], point.x.isFinite, point.y.isFinite,
              point.x >= 0, point.y >= 0, point.x < CGFloat(bitmap.image.width), point.y < CGFloat(bitmap.image.height) else { return nil }
        let x = Int(point.x), y = Int(point.y)
        guard let bytes = bitmap.context.data?.assumingMemoryBound(to: UInt8.self) else { throw CoreError.invalidContent }
        let offset = y*bitmap.context.bytesPerRow+x*4, alpha = Int(bytes[offset+3])
        guard alpha > 0 else { return nil }
        func channel(_ index: Int) -> Int { min(255, (Int(bytes[offset+index])*255+alpha/2)/alpha) }
        let hex = String(format: "#%02X%02X%02X", channel(0), channel(1), channel(2))
        let cropRect = CGRect(x: max(0,x-7), y: max(0,y-7), width: min(bitmap.image.width,x+8)-max(0,x-7), height: min(bitmap.image.height,y+8)-max(0,y-7))
        guard let crop = bitmap.image.cropping(to: cropRect) else { throw CoreError.invalidContent }
        return try ColorSample(x: x, y: y, hex: hex, neighborhoodPNG: ImageCodec.png(crop),
            focusInNeighborhood: CGPoint(x: CGFloat(x)-cropRect.minX, y: CGFloat(y)-cropRect.minY))
    }
    public func clear() { bitmaps.removeAll() }
}
