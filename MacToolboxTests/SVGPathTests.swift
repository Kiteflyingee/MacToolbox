import CoreGraphics
import Testing
@testable import MacToolboxCore

@Test func svgPathDecodesRelativeSubpathsAndCloseWithoutJoiningThem() throws {
    let path = try SVGPath.decode("M2 3h10v8H2z m20 0 4 0 0 4-4 0z")
    #expect(path.boundingBoxOfPath == CGRect(x: 2,y: 3,width: 24,height: 8))
    #expect(path.contains(CGPoint(x: 6,y: 6),using: .evenOdd))
    #expect(!path.contains(CGPoint(x: 17,y: 6),using: .evenOdd))
}

@Test func svgPathReflectsSmoothCurveControlsAndHandlesEllipticalArcs() throws {
    let curve = try SVGPath.decode("M0 0C0 10 10 10 10 0S20-10 20 0")
    #expect(abs(curve.boundingBoxOfPath.minY+7.5) < 0.001)
    #expect(abs(curve.boundingBoxOfPath.maxY-7.5) < 0.001)
    let circle = try SVGPath.decode("M10 0A10 10 0 0 1 10 20a10 10 0 0 1 0-20Z")
    #expect(abs(circle.boundingBoxOfPath.width-20) < 0.001)
    #expect(circle.contains(CGPoint(x: 10,y: 10),using: .evenOdd))
}

@Test func svgPathRejectsMalformedOrNonFiniteGeometry() {
    for value in ["L1 2","M0 0C1 2","M0 0X1 2","M0 0LNaN 1","M0 0A1 1 0 4 1 2 3","M0 0@L1 1","M0 0Z1 2"] {
        #expect(throws: SVGPathError.self) { try SVGPath.decode(value) }
    }
}
