import CoreGraphics
import Foundation
import ScreenCaptureKit

public enum CaptureError: Error, Sendable { case permission, displayUnavailable }

public enum ScreenCaptureAuthorization {
    public static func shouldRequest(isGranted: Bool,explicit: Bool,hasRequestedBefore: Bool) -> Bool {
        !isGranted && (explicit || !hasRequestedBefore)
    }
}

public struct CapturedScreen: Sendable {
    public let png: Data
    /// Global display coordinates, with the origin at the primary display's top left.
    public let windows: [CGRect]
}

public actor ScreenCaptureService {
    public init() {}
    public func capture(displayID: UInt32, pixels: PixelSize) async throws -> Data {
        try await captureScene(displayID: displayID, pixels: pixels).png
    }
    public func captureScene(displayID: UInt32, pixels: PixelSize) async throws -> CapturedScreen {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw CaptureError.displayUnavailable }
        let own = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
        let config = SCStreamConfiguration()
        config.width = pixels.width; config.height = pixels.height; config.showsCursor = false
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        try Task.checkCancellation()
        let windows = content.windows.filter {
            $0.isOnScreen && $0.windowLayer == 0 && $0.frame.width >= 48 && $0.frame.height >= 48
                && $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier
        }.map(\.frame)
        return CapturedScreen(png: try ImageCodec.png(image), windows: windows)
    }
}
