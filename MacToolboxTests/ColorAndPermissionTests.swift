import ApplicationServices
import CoreGraphics
import Foundation
import Testing
@testable import MacToolboxCore

@Test func explicitScreenAuthorizationIsNotSuppressedByEarlierRequests() {
    #expect(ScreenCaptureAuthorization.shouldRequest(isGranted: false,explicit: true,hasRequestedBefore: true))
    #expect(ScreenCaptureAuthorization.shouldRequest(isGranted: false,explicit: false,hasRequestedBefore: false))
    #expect(!ScreenCaptureAuthorization.shouldRequest(isGranted: false,explicit: false,hasRequestedBefore: true))
    #expect(!ScreenCaptureAuthorization.shouldRequest(isGranted: true,explicit: true,hasRequestedBefore: true))
}

@Test func permissionUsesRealAXResultInsteadOfOnlyCachedTrustFlag() {
    #expect(AccessibilityReport(trustedFlag: false, apiResult: AXError.success.rawValue).canRead)
    #expect(!AccessibilityReport(trustedFlag: true, apiResult: AXError.apiDisabled.rawValue).canRead)
    #expect(!AccessibilityReport(trustedFlag: false, apiResult: AXError.cannotComplete.rawValue).canRead)
    #expect(AccessibilityReport(trustedFlag: true, apiResult: AXError.noValue.rawValue).canRead)
}

@Test func permissionProbeNeverReentersOwnAppKitFromBackgroundActor() async {
    let report = await AccessibilityProbe().check(processID: ProcessInfo.processInfo.processIdentifier)
    #expect(report.apiResult == AXError.noValue.rawValue)
}

@Test func selectionReaderRejectsOwnProcessBeforeCallingAppKit() async {
    let result = await SelectionReader().readSelection(processID: ProcessInfo.processInfo.processIdentifier)
    #expect(result.text == nil)
    #expect(result.status == "own-process")
}

@Test func colorSamplerUsesTopLeftOriginalPixelsAndHandlesEdgesAndTransparency() async throws {
    let context = try ImageCodec.context(width: 2, height: 2)
    let pixels = try #require(context.data?.assumingMemoryBound(to: UInt8.self))
    let rgba: [UInt8] = [255,0,0,255, 0,255,0,255, 0,0,128,128, 0,0,0,0]
    for (index, value) in rgba.enumerated() { pixels[index] = value }
    let png = try ImageCodec.png(#require(context.makeImage()))
    let sampler = ColorSampler()
    _ = try await sampler.load(png: png, id: 1)
    let red = try await sampler.sample(id: 1, point: CGPoint(x: 0.9,y: 0.9))
    #expect(red?.hex == "#FF0000" && red?.x == 0 && red?.y == 0)
    #expect(red?.focusInNeighborhood == .zero)
    #expect(try ImageCodec.decode(#require(red?.neighborhoodPNG)).width == 2)
    #expect(try await sampler.sample(id: 1,point: CGPoint(x: 1,y: 0))?.hex == "#00FF00")
    #expect(try await sampler.sample(id: 1,point: CGPoint(x: 0,y: 1))?.hex == "#0000FF")
    #expect(try await sampler.sample(id: 1,point: CGPoint(x: 1,y: 1)) == nil)
    #expect(try await sampler.sample(id: 1,point: CGPoint(x: -0.1,y: 0)) == nil)
    #expect(try await sampler.sample(id: 1,point: CGPoint(x: 2,y: 0)) == nil)
    #expect(try await sampler.sample(id: 1,point: CGPoint(x: Double.nan,y: 0)) == nil)
    await sampler.clear()
    #expect(try await sampler.sample(id: 1,point: .zero) == nil)
}
