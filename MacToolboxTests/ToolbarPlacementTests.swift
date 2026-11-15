import CoreGraphics
import Testing
@testable import MacToolboxCore

@Test func fullScreenCaptureKeepsControlsBelowMenuBarAndAwayFromDock() {
    // A secondary screen above/left of the primary, with a left Dock and 38pt menu/notch area.
    let screen = CGRect(x: -1440,y: 900,width: 1440,height: 900)
    let visible = CGRect(x: -1360,y: 900,width: 1360,height: 862)
    let safe = ToolbarPlacement.chromeBounds(captureFrame: screen,visibleScreenFrame: visible)
    #expect(safe == CGRect(x: 80,y: 38,width: 1360,height: 862))
    let bar = ToolbarPlacement.toolbar(size: CGSize(width: 754,height: 42),selection: CGRect(origin: .zero,size: screen.size),bounds: safe)
    #expect(safe.contains(bar))
    #expect(bar.maxY == safe.maxY-8)
    let panel = ToolbarPlacement.panel(size: CGSize(width: 340,height: 48),anchor: bar,toolbar: bar,bounds: safe)
    #expect(!panel.below)
    #expect(safe.contains(panel.frame))
    #expect(panel.frame.maxY < bar.minY)
    // Manual dragging uses the same safe rectangle as automatic placement.
    let dragged = ToolbarPlacement.clamped(CGRect(x: -500,y: -500,width: 754,height: 42),to: safe)
    #expect(dragged.minY == 46)
    #expect(dragged.minX == 88)
}

@Test func windowedCaptureDoesNotLoseCanvasSpaceToDesktopInsets() {
    let window = CGRect(x: 300,y: 200,width: 1000,height: 600)
    #expect(ToolbarPlacement.chromeBounds(captureFrame: window,visibleScreenFrame: CGRect(x: 80,y: 0,width: 1360,height: 862)) == CGRect(origin: .zero,size: window.size))
}

@Test func captureChromeStaysInsideCanvasAndFlipsAtBottomEdge() {
    let bounds = CGRect(x: 0,y: 0,width: 1000,height: 600)
    let bar = ToolbarPlacement.toolbar(size: CGSize(width: 650,height: 42),selection: CGRect(x: 10,y: 400,width: 300,height: 180),bounds: bounds)
    #expect(bounds.contains(bar))
    #expect(bar.maxY < 400)
    let panel = ToolbarPlacement.panel(size: CGSize(width: 280,height: 250),anchor: CGRect(x: 12,y: bar.minY,width: 32,height: 32),toolbar: bar,bounds: bounds)
    #expect(bounds.contains(panel.frame))
    #expect(!panel.below)
    #expect(panel.frame.maxY < bar.minY)
}

@Test func stylePanelCanOpenBelowToolbarNearTopEdge() {
    let bounds = CGRect(x: 0,y: 0,width: 1000,height: 700)
    let bar = CGRect(x: 350,y: 80,width: 600,height: 42)
    let result = ToolbarPlacement.panel(size: CGSize(width: 280,height: 300),anchor: CGRect(x: 900,y: 80,width: 32,height: 32),toolbar: bar,bounds: bounds)
    #expect(result.below)
    #expect(bounds.contains(result.frame))
    #expect(result.frame.minY > bar.maxY)
}
