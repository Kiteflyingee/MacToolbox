import CoreGraphics
import Foundation
import ImageIO

public actor ImageCodec {
    public init() {}

    public func export(png: Data, to url: URL) throws {
        if url.pathExtension.lowercased() != "heic" { try png.write(to: url, options: .atomic); return }
        let image = try Self.decode(png), output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, "public.heic" as CFString, 1, nil) else { throw CoreError.invalidContent }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw CoreError.invalidContent }
        try (output as Data).write(to: url, options: .atomic)
    }

    public func normalize(_ data: Data) throws -> ImagePayload {
        guard data.count <= AppLimits.imageBytes else { throw CoreError.contentTooLarge }
        let image = try Self.decode(data)
        let context = try Self.context(width: image.width, height: image.height)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard let canonical = context.makeImage(), let pixels = context.data else { throw CoreError.invalidContent }
        let png = try Self.png(canonical)
        let bytes = Data(bytes: pixels, count: context.bytesPerRow * context.height)
        let scale = min(1, 256 / Double(max(image.width, image.height)))
        let thumbnailContext = try Self.context(width: max(1, Int(Double(image.width)*scale)), height: max(1, Int(Double(image.height)*scale)))
        thumbnailContext.interpolationQuality = .high
        thumbnailContext.draw(canonical, in: CGRect(x: 0, y: 0, width: thumbnailContext.width, height: thumbnailContext.height))
        let thumbnail = try thumbnailContext.makeImage().map(Self.png)
        return try ImagePayload(png: png, width: image.width, height: image.height,
                                pixelDigest: ContentDigest(data: bytes), thumbnail: thumbnail)
    }

    static func decode(_ data: Data) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { throw CoreError.invalidContent }
        _ = try PixelSize(width: width, height: height)
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else {
            throw CoreError.invalidContent
        }
        return image
    }

    static func context(width: Int, height: Int) throws -> CGContext {
        _ = try PixelSize(width: width, height: height)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                 bytesPerRow: width*4, space: space,
                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw CoreError.invalidContent
        }
        return context
    }

    static func png(_ image: CGImage) throws -> Data {
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil) else { throw CoreError.invalidContent }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw CoreError.invalidContent }
        return buffer as Data
    }
}
