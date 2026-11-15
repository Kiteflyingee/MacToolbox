import CoreGraphics
import Foundation
import Testing
@testable import MacToolboxCore

private func screens() throws -> [ScreenGeometry] {
    [try ScreenGeometry(displayID: 1, desktopFrame: DesktopRect(CGRect(x: -1000, y: -100, width: 1000, height: 600)),
        appKitFrame: CGRect(x: -1000, y: 400, width: 1000, height: 600), pixels: PixelSize(width: 1000, height: 600)),
     try ScreenGeometry(displayID: 2, desktopFrame: DesktopRect(CGRect(x: 0, y: 0, width: 1440, height: 900)),
        appKitFrame: CGRect(x: 0, y: 0, width: 1440, height: 900), pixels: PixelSize(width: 2880, height: 1800))]
}

@Test func fixedOddPixelDimensionsPreserveFractionalCropMarginsAcrossMixedScreens() throws {
    let screens = try screens()
    let pixels = try PixelSize(width: 801, height: 603)
    let selection = try CompositeLayout.fixedSelection(origin: CGPoint(x: -100.25, y: 20.5), pixels: pixels, startingScreen: screens[1])
    let layout = try CompositeLayout(selection: selection, screens: screens, fixedPixels: pixels)
    #expect(layout.pixels == pixels)
    #expect(layout.density == 2)
    #expect(layout.tiles.count == 2)
    let left = try #require(layout.tiles.first { $0.displayID == 1 })
    #expect(left.sourceCrop.minX == 899)
    #expect(left.destinationDraw.minX == -1.5)
    #expect(left.destinationDraw.width == 202)
    #expect(left.destinationClip.minX == 0)
    #expect(left.destinationClip.width == 200.5)
}

@Test func appKitConversionUsesEachDisplayFrameAndGapsHaveNoColorPixel() throws {
    let screens = try screens()
    let point = CGPoint(x: -999, y: -99)
    let mapped = screens[0].appKitPoint(fromDesktop: point)
    #expect(mapped == CGPoint(x: -999, y: 999))
    #expect(screens[0].desktopPoint(fromAppKit: mapped) == point)
    let selection = try DesktopRect(CGRect(x: -100, y: 450, width: 200, height: 200))
    let layout = try CompositeLayout(selection: selection, screens: screens)
    #expect(layout.imagePixel(atDesktop: CGPoint(x: -50, y: 600)) == nil)
    #expect(layout.imagePixel(atDesktop: CGPoint(x: 50, y: 600)) != nil)
    #expect(throws: CoreError.contentTooLarge) { try PixelSize(width: Int.max, height: 2) }
    #expect(throws: CoreError.invalidGeometry) { try DesktopRect(CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 1)) }
}

@Test func recentSelectionsKeepFiveAndRejectOldTopologyAfterRoundTrip() throws {
    var recent = RecentSelections()
    let topology = try ScreenGeometry.topology(screens())
    for index in 0..<6 {
        recent.record(try DesktopRect(CGRect(x: index, y: 0, width: 10, height: 10)), topology: topology)
    }
    let restored = try JSONDecoder().decode(RecentSelections.self, from: JSONEncoder().encode(recent))
    #expect(restored.available(topology: topology).count == 5)
    #expect(restored.available(topology: ContentDigest(data: Data())).isEmpty)
}

@Test func freezeBudgetIsCheckedBeforeAllocatingAllScreens() throws {
    let screens = try (0..<5).map { id in
        try ScreenGeometry(displayID: UInt32(id), desktopFrame: DesktopRect(CGRect(x: id*4000, y: 0, width: 4000, height: 4000)),
            appKitFrame: CGRect(x: id*4000, y: 0, width: 4000, height: 4000), pixels: PixelSize(width: 4000, height: 4000))
    }
    #expect(ScreenGeometry.fitsFreezeBudget(Array(screens.prefix(4))))
    #expect(!ScreenGeometry.fitsFreezeBudget(screens))
    #expect(!ScreenGeometry.fitsFreezeBudget([]))
}
