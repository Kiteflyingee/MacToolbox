import CoreGraphics
import Foundation

public struct PixelSize: Codable, Equatable, Sendable {
    public let width: Int
    public let height: Int
    public var count: Int { width * height }

    public init(width: Int, height: Int) throws {
        guard width > 0, height > 0, width <= AppLimits.imagePixels / height else { throw CoreError.contentTooLarge }
        self.width = width; self.height = height
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(width: values.decode(Int.self, forKey: .width), height: values.decode(Int.self, forKey: .height))
    }
}

public struct DesktopRect: Codable, Equatable, Sendable {
    public let rect: CGRect
    public init(_ rect: CGRect) throws {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite, rect.width.isFinite, rect.height.isFinite,
              rect.width > 0, rect.height > 0, rect.maxX.isFinite, rect.maxY.isFinite else { throw CoreError.invalidGeometry }
        self.rect = rect
    }

    public init(from decoder: any Decoder) throws {
        try self.init(decoder.singleValueContainer().decode(CGRect.self))
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rect)
    }
}

public struct ScreenGeometry: Codable, Equatable, Sendable {
    public let displayID: UInt32
    public let desktopFrame: DesktopRect
    public let appKitFrame: CGRect
    public let pixels: PixelSize
    public var scaleX: Double { Double(pixels.width) / desktopFrame.rect.width }
    public var scaleY: Double { Double(pixels.height) / desktopFrame.rect.height }
    public var density: Double { max(scaleX, scaleY) }

    public init(displayID: UInt32, desktopFrame: DesktopRect, appKitFrame: CGRect, pixels: PixelSize) throws {
        _ = try DesktopRect(appKitFrame)
        guard (Double(pixels.width) / desktopFrame.rect.width).isFinite,
              (Double(pixels.height) / desktopFrame.rect.height).isFinite else { throw CoreError.invalidGeometry }
        self.displayID = displayID; self.desktopFrame = desktopFrame
        self.appKitFrame = appKitFrame; self.pixels = pixels
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(displayID: values.decode(UInt32.self, forKey: .displayID),
                      desktopFrame: values.decode(DesktopRect.self, forKey: .desktopFrame),
                      appKitFrame: values.decode(CGRect.self, forKey: .appKitFrame),
                      pixels: values.decode(PixelSize.self, forKey: .pixels))
    }

    public static func fitsFreezeBudget(_ screens: [ScreenGeometry]) -> Bool {
        guard !screens.isEmpty else { return false }
        var total = 0
        for screen in screens {
            guard screen.pixels.count <= AppLimits.imagePixels - total else { return false }
            total += screen.pixels.count
        }
        return true
    }

    public func appKitPoint(fromDesktop point: CGPoint) -> CGPoint {
        let frame = desktopFrame.rect
        return CGPoint(x: appKitFrame.minX + (point.x - frame.minX) / frame.width * appKitFrame.width,
                       y: appKitFrame.maxY - (point.y - frame.minY) / frame.height * appKitFrame.height)
    }

    public func desktopPoint(fromAppKit point: CGPoint) -> CGPoint {
        let frame = desktopFrame.rect
        return CGPoint(x: frame.minX + (point.x - appKitFrame.minX) / appKitFrame.width * frame.width,
                       y: frame.minY + (appKitFrame.maxY - point.y) / appKitFrame.height * frame.height)
    }

    public static func topology(_ screens: [ScreenGeometry]) throws -> ContentDigest {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ContentDigest(data: try encoder.encode(screens.sorted { $0.displayID < $1.displayID }))
    }
}

public struct CaptureTile: Equatable, Sendable {
    public let displayID: UInt32
    public let sourceCrop: CGRect // Integer pixel bounds in the original full-screen image.
    public let destinationDraw: CGRect // Includes outward-rounding compensation.
    public let destinationClip: CGRect // Ideal intersection, never stretched to the crop.
}

public struct CompositeLayout: Equatable, Sendable {
    public let selection: DesktopRect
    public let pixels: PixelSize
    public let density: Double
    public let tiles: [CaptureTile]

    public static func fixedSelection(origin: CGPoint, pixels: PixelSize, startingScreen: ScreenGeometry) throws -> DesktopRect {
        try DesktopRect(CGRect(x: origin.x, y: origin.y, width: Double(pixels.width) / startingScreen.density,
                               height: Double(pixels.height) / startingScreen.density))
    }

    public init(selection: DesktopRect, screens: [ScreenGeometry], fixedPixels: PixelSize? = nil) throws {
        let region = selection.rect
        let participating = screens.filter { $0.desktopFrame.rect.intersects(region) }
        guard !participating.isEmpty, Set(screens.map(\.displayID)).count == screens.count else { throw CoreError.invalidGeometry }
        let density: Double
        let pixels: PixelSize
        if let fixedPixels {
            density = Double(fixedPixels.width) / region.width
            let vertical = Double(fixedPixels.height) / region.height
            guard density.isFinite, abs(density - vertical) <= max(1, density) * 1e-9 else { throw CoreError.invalidGeometry }
            pixels = fixedPixels
        } else {
            density = participating.map(\.density).max()!
            let width = ceil(region.width * density), height = ceil(region.height * density)
            guard width.isFinite, height.isFinite, width >= 1, height >= 1,
                  width <= Double(AppLimits.imagePixels), height <= Double(AppLimits.imagePixels) else { throw CoreError.contentTooLarge }
            pixels = try PixelSize(width: Int(width), height: Int(height))
        }
        self.selection = selection; self.pixels = pixels; self.density = density
        tiles = participating.map { screen in
            let display = screen.desktopFrame.rect
            let intersection = region.intersection(display)
            let x0 = max(0, floor((intersection.minX - display.minX) * screen.scaleX))
            let x1 = min(Double(screen.pixels.width), ceil((intersection.maxX - display.minX) * screen.scaleX))
            let y0 = max(0, floor((intersection.minY - display.minY) * screen.scaleY))
            let y1 = min(Double(screen.pixels.height), ceil((intersection.maxY - display.minY) * screen.scaleY))
            let draw = CGRect(x: (display.minX + x0 / screen.scaleX - region.minX) * density,
                              y: (display.minY + y0 / screen.scaleY - region.minY) * density,
                              width: (x1 - x0) / screen.scaleX * density,
                              height: (y1 - y0) / screen.scaleY * density)
            let clip = CGRect(x: (intersection.minX - region.minX) * density,
                              y: (intersection.minY - region.minY) * density,
                              width: intersection.width * density, height: intersection.height * density)
            return CaptureTile(displayID: screen.displayID, sourceCrop: CGRect(x: x0, y: y0, width: x1-x0, height: y1-y0),
                               destinationDraw: draw, destinationClip: clip)
        }
    }

    public func imagePixel(atDesktop point: CGPoint) -> CGPoint? {
        guard point.x.isFinite, point.y.isFinite else { return nil }
        let imagePoint = CGPoint(x: (point.x - selection.rect.minX) * density, y: (point.y - selection.rect.minY) * density)
        guard tiles.contains(where: { $0.destinationClip.contains(imagePoint) }),
              imagePoint.x >= 0, imagePoint.y >= 0,
              imagePoint.x < Double(pixels.width), imagePoint.y < Double(pixels.height) else { return nil }
        return CGPoint(x: floor(imagePoint.x), y: floor(imagePoint.y))
    }
}

public struct RecentSelections: Codable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public let selection: DesktopRect
        public let topology: ContentDigest
    }
    public private(set) var entries: [Entry] = []
    public init() {}
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let entries = try values.decode([Entry].self, forKey: .entries)
        guard entries.count <= 5 else { throw CoreError.contentTooLarge }
        self.entries = entries
    }
    public mutating func record(_ selection: DesktopRect, topology: ContentDigest) {
        let entry = Entry(selection: selection, topology: topology)
        entries.removeAll { $0 == entry }
        entries.insert(entry, at: 0)
        if entries.count > 5 { entries.removeLast(entries.count - 5) }
    }
    public func available(topology: ContentDigest) -> [DesktopRect] {
        entries.filter { $0.topology == topology }.map(\.selection)
    }
}
