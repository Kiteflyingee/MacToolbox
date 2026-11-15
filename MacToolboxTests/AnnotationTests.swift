import CoreGraphics
import Foundation
import Testing
@testable import MacToolboxCore

private let annotationBox = CGRect(x: 10, y: 20, width: 80, height: 60)

@Test func brushSmoothingPreservesEndpointsAndStaysInsideInputEnvelope() throws {
    let points = [CGPoint(x: 0,y: 0),CGPoint(x: 20,y: 50),CGPoint(x: 40,y: 0),CGPoint(x: 60,y: 20)]
    let path = try GeometryPaths.stroke(points)
    #expect(path.currentPoint == points.last)
    #expect(CGRect(x: 0,y: 0,width: 60,height: 50).contains(path.boundingBoxOfPath))
    var quadCount = 0
    path.applyWithBlock { if $0.pointee.type == .addQuadCurveToPoint { quadCount += 1 } }
    #expect(quadCount == 2)
    #expect(throws: CoreError.invalidGeometry) { try GeometryPaths.stroke([.zero]) }
}

@Test func rotatedTextKeepsEditableContentBoundsAndClipboardAngle() throws {
    let original = Annotation(geometry: .text("Editable text",box: annotationBox))
    let rotated = try original.rotated(to: .pi/2)
    #expect(rotated.geometry == original.geometry)
    #expect(abs(rotated.bounds.width-60) < 0.0001)
    #expect(abs(rotated.bounds.height-80) < 0.0001)
    #expect(abs(rotated.bounds.midX-annotationBox.midX) < 0.0001)
    let copies = try AnnotationClipboard.decodeForPaste(AnnotationClipboard.encode([rotated]))
    #expect(copies[0].rotation == .pi/2)
    #expect(copies[0].geometry == original.geometry.translated(x: 12,y: 12))
    #expect(throws: CoreError.invalidGeometry) { try original.rotated(to: .nan) }
    let legacyStyle = try JSONSerialization.jsonObject(with: JSONEncoder().encode(AnnotationStyle())) as! [String:Any]
    #expect(try JSONDecoder().decode(AnnotationStyle.self,from: JSONSerialization.data(withJSONObject: legacyStyle)).rotation == nil)
}

@Test func cropRebasesUndoAndRedoWithoutErasingAnnotationHistory() throws {
    let first = Annotation(geometry: .shape(.rectangle,box: annotationBox,rotation: 0))
    let second = Annotation(geometry: .text("Hello",box: annotationBox.offsetBy(dx: 100,dy: 50)))
    var document = AnnotationDocument(baseImageID: UUID(),pixels: try PixelSize(width: 800,height: 600))
    try document.replace(with: [first]); try document.replace(with: [first,second])
    #expect(document.undo() == true)
    try document.reframe(pixels: PixelSize(width: 500,height: 400),translation: CGPoint(x: -20,y: -10))
    #expect(document.canRedo)
    #expect(document.annotations.map(\.geometry) == [first.geometry.translated(x: -20,y: -10)])
    #expect(document.redo() == true)
    #expect(document.annotations.map(\.geometry) == [first,second].map { $0.geometry.translated(x: -20,y: -10) })
    #expect(document.undo() == true)
    #expect(document.annotations.count == 1)
    #expect(document.undo() == true)
    #expect(document.annotations.isEmpty)
    #expect(document.pixels == (try PixelSize(width: 500,height: 400)))
}

@Test func objectResizePreservesEditablePointsAndRejectsInvalidBoxes() throws {
    let arrow = AnnotationGeometry.arrow(start: CGPoint(x: 10,y: 20),end: CGPoint(x: 90,y: 80),control: CGPoint(x: 50,y: 20))
    let resized = try arrow.resized(from: annotationBox,to: CGRect(x: 100,y: 200,width: 160,height: 180))
    #expect(resized == .arrow(start: CGPoint(x: 100,y: 200),end: CGPoint(x: 260,y: 380),control: CGPoint(x: 180,y: 200)))
    #expect(throws: CoreError.invalidGeometry) { try arrow.resized(from: .zero,to: annotationBox) }
    let effect = AnnotationGeometry.effect(.pixelate(.coarse),.brush([CGPoint(x: 10,y: 20),CGPoint(x: 90,y: 80)],width: 16))
    let scaled = try effect.resized(from: annotationBox,to: CGRect(x: 0,y: 0,width: 40,height: 30))
    #expect(scaled == .effect(.pixelate(.coarse),.brush([.zero,CGPoint(x: 40,y: 30)],width: 16)))
}

@Test func editingBoundsIncludeCalloutConnectorsAndBrushWidths() {
    let callout = AnnotationGeometry.remark("Label",box: annotationBox,connector: CGPoint(x: -20,y: 100))
    #expect(callout.bounds.minX == -20)
    #expect(callout.bounds.maxY == 100)
    let brush = AnnotationGeometry.effect(.blur(.strong),.brush([CGPoint(x: 20,y: 30),CGPoint(x: 40,y: 50)],width: 10))
    #expect(brush.bounds == CGRect(x: 15,y: 25,width: 30,height: 30))
}
private func annotationFixtures() -> [Annotation] {
    var values = ShapeKind.allCases.map { Annotation(geometry: .shape($0, box: annotationBox, rotation: 0.2)) }
    values += [
        Annotation(geometry: .arrow(start: .zero, end: CGPoint(x: 100, y: 100), control: CGPoint(x: 0, y: 100))),
        Annotation(geometry: .text("中文\nEnglish", box: annotationBox)),
        Annotation(geometry: .numbered(3, center: CGPoint(x: 10, y: 10), label: "步骤", labelBox: annotationBox, connector: .zero)),
        Annotation(geometry: .remark("备注", box: annotationBox, connector: .zero)),
        Annotation(geometry: .highlight(annotationBox)),
        Annotation(geometry: .stroke([.zero, CGPoint(x: 5, y: 9)], highlighter: true)),
        Annotation(geometry: .effect(.pixelate(.coarse), .rectangle(annotationBox))),
        Annotation(geometry: .effect(.blur(.gaussian), .brush([.zero, CGPoint(x: 5, y: 9)], width: 24))),
        Annotation(geometry: .magnifier(source: .zero, lens: annotationBox, scale: .two))
    ]
    return values
}

@Test func allAnnotationKindsRoundTripWithNewIDsAndOnePasteUndo() throws {
    let original = annotationFixtures()
    let data = try AnnotationClipboard.encode(original)
    let copies = try AnnotationClipboard.decodeForPaste(data)
    #expect(copies.count == original.count)
    #expect(Set(copies.map(\.id)).isDisjoint(with: original.map(\.id)))
    #expect(copies.map(\.geometry) == original.map { $0.geometry.translated(x: 12, y: 12) })
    var document = AnnotationDocument(baseImageID: UUID(), pixels: try PixelSize(width: 800, height: 600))
    try document.paste(data)
    #expect(document.annotations.count == original.count)
    #expect(document.undo() == true)
    #expect(document.annotations.isEmpty)
    #expect(document.undo() == false)
    #expect(document.redo() == true)
    #expect(document.annotations.count == original.count)
}

@Test func gestureHasOneUndoAndDraftPreviewsUseIndependentGeneration() throws {
    var document = AnnotationDocument(baseImageID: UUID(), pixels: try PixelSize(width: 800, height: 600))
    let id = UUID()
    try document.beginDraft()
    let initialGeneration = document.previewGeneration
    for index in 0..<100 {
        try document.updateDraft([Annotation(id: id, geometry: .shape(.rectangle,
            box: annotationBox.offsetBy(dx: Double(index), dy: 0), rotation: 0))])
    }
    #expect(document.revision == 0)
    #expect(document.previewGeneration > initialGeneration)
    #expect(document.snapshot().annotations.isEmpty)
    #expect(document.snapshot(includingDraft: true).annotations.count == 1)
    try document.commitDraft()
    #expect(document.revision == 1)
    #expect(document.undo() == true)
    #expect(document.annotations.isEmpty)
    #expect(document.undo() == false)
    #expect(document.redo() == true)
    try document.replace(with: [])
    #expect(document.canRedo == false)
    try document.beginDraft()
    try document.updateDraft(annotationFixtures())
    document.cancelDraft()
    #expect(document.annotations.isEmpty)
}

@Test func undoLimitAndPreviewCoalescingDoNotAccumulateEveryMouseEvent() throws {
    var document = AnnotationDocument(baseImageID: UUID(), pixels: try PixelSize(width: 800, height: 600))
    let id = UUID()
    for index in 0..<110 {
        try document.replace(with: [Annotation(id: id, geometry: .shape(.rectangle,
            box: annotationBox.offsetBy(dx: Double(index), dy: 0), rotation: 0))])
    }
    var undoCount = 0
    while document.undo() { undoCount += 1 }
    #expect(undoCount == 100)
    try document.beginDraft()
    let first = document.snapshot(includingDraft: true)
    try document.updateDraft(annotationFixtures())
    let second = document.snapshot(includingDraft: true)
    try document.updateDraft([])
    let third = document.snapshot(includingDraft: true)
    var scheduler = PreviewScheduler()
    #expect(scheduler.submit(first) == first)
    #expect(scheduler.submit(second) == nil)
    #expect(scheduler.submit(third) == nil)
    let oldCompletion = scheduler.finish(first)
    #expect(!oldCompletion.display)
    #expect(oldCompletion.next == third)
    #expect(scheduler.finish(second).display == false)
    scheduler.cancel()
    #expect(scheduler.finish(third).display == false)
}

@Test func annotationClipboardRejectsUnknownVersionNonFiniteGeometryAndOversizedData() throws {
    let valid = try AnnotationClipboard.encode(annotationFixtures())
    var object = try #require(JSONSerialization.jsonObject(with: valid) as? [String: Any])
    object["version"] = 99
    let unknown = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: CoreError.unsupportedVersion) { try AnnotationClipboard.decodeForPaste(unknown) }
    #expect(throws: CoreError.contentTooLarge) {
        try AnnotationClipboard.decodeForPaste(Data(repeating: 0, count: AppLimits.annotationBytes+1))
    }
    #expect(throws: CoreError.invalidGeometry) {
        try AnnotationClipboard.encode([Annotation(geometry: .arrow(start: .zero, end: CGPoint(x: CGFloat.nan, y: 2), control: .zero))])
    }
}

@Test func shapePathsAndCurveArrowHeadsUseActualGeometry() throws {
    for kind in ShapeKind.allCases {
        let path = try GeometryPaths.shape(kind, box: annotationBox)
        #expect(!path.isEmpty)
        #expect(path.boundingBoxOfPath.width > 0)
    }
    var style = ArrowStyle()
    style.tapered = true
    style.heads = .double
    let arrow = try GeometryPaths.arrow(start: .zero, end: CGPoint(x: 100, y: 100), control: CGPoint(x: 0, y: 100), lineWidth: 4, style: style)
    #expect(arrow.taperedShaft?.isEmpty == false)
    #expect(arrow.startHead != nil)
    let head = try #require(arrow.endHead)
    // The end tangent is horizontal, even though the whole curve's chord is diagonal.
    #expect(abs(head.boundingBoxOfPath.minY - 94.4) < 1e-6)
    #expect(abs(head.boundingBoxOfPath.maxY - 105.6) < 1e-6)
    #expect(throws: CoreError.invalidGeometry) {
        try GeometryPaths.arrow(start: .zero, end: .zero, control: .zero, lineWidth: 4, style: style)
    }
}
