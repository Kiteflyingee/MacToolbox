import CoreGraphics
import Foundation
import Testing
@testable import MacToolboxCore

private func whitePNG(width: Int, height: Int) throws -> Data {
    let context = try ImageCodec.context(width: width, height: height)
    context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return try ImageCodec.png(#require(context.makeImage()))
}

@Test func imagePreviewKeepsEditsAndInvalidatesCachedBaseImage() async throws {
    let white = try whitePNG(width: 128,height: 128)
    let context = try ImageCodec.context(width: 128,height: 128)
    context.setFillColor(CGColor(gray: 0,alpha: 1)); context.fill(CGRect(x: 0,y: 0,width: 128,height: 128))
    let black = try ImageCodec.png(#require(context.makeImage()))
    var document = AnnotationDocument(baseImageID: UUID(),pixels: try PixelSize(width: 128,height: 128))
    var style = AnnotationStyle(); style.fill = .solid
    try document.replace(with: [Annotation(geometry: .shape(.rectangle,box: CGRect(x: 20,y: 20,width: 88,height: 88),rotation: 0),style: style)])
    let renderer = AnnotationRenderer()
    func channels(_ image: CGImage,at point: CGPoint) throws -> [UInt8] {
        let bitmap = try ImageCodec.context(width: 128,height: 128)
        bitmap.draw(image,in: CGRect(x: 0,y: 0,width: 128,height: 128))
        let bytes = try #require(bitmap.data?.assumingMemoryBound(to: UInt8.self)), offset = Int(point.y)*bitmap.bytesPerRow+Int(point.x)*4
        return (0..<4).map { bytes[offset+$0] }
    }
    let first = try await renderer.renderImage(basePNG: white,snapshot: document.snapshot())
    #expect(try channels(first,at: CGPoint(x: 1,y: 1)) == [255,255,255,255])
    #expect(try channels(first,at: CGPoint(x: 64,y: 64))[0] == 255)
    let replacement = try await renderer.renderImage(basePNG: black,snapshot: document.snapshot())
    #expect(try channels(replacement,at: CGPoint(x: 1,y: 1)) == [0,0,0,255])
    #expect(try channels(replacement,at: CGPoint(x: 64,y: 64))[0] == 255)
    let didUndo = document.undo(); #expect(didUndo)
    let undo = try await renderer.renderImage(basePNG: black,snapshot: document.snapshot())
    #expect(try channels(undo,at: CGPoint(x: 64,y: 64)) == [0,0,0,255])
}

@Test func screenshotExportWritesActualPNGAndHEICWithOriginalDimensions() async throws {
    let png = try whitePNG(width: 120,height: 80)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let codec = ImageCodec()
    for ext in ["png","heic"] {
        let url = directory.appendingPathComponent("screenshot."+ext)
        try await codec.export(png: png,to: url)
        let data = try Data(contentsOf: url), image = try ImageCodec.decode(data)
        #expect(image.width == 120 && image.height == 80)
        if ext == "heic" { #expect(data.prefix(8) != png.prefix(8)) }
    }
}

@Test func selectionOffersWithoutClipboardAndRejectsReplacedRequest() throws {
    var state = TranslationStateMachine()
    let firstCandidate = state.offerSelectionText("First selected sentence.", anchor: CGPoint(x: 20, y: 30), allowsCandidates: true)
    let first = try #require(firstCandidate)
    #expect(state.activeRequest == nil)
    let clicked = state.click(snapshotID: first.id, settingsRevision: 1, target: .simplifiedChinese)
    let ticket = try #require(clicked)
    state.externalVersionChanged(10)
    #expect(state.activeRequest == ticket)
    #expect(state.offerClipboardText("Background copy", changeCount: 10, anchor: .zero, allowsCandidates: true) == nil)
    let secondCandidate = state.offerSelectionText("Second selected sentence.", anchor: .zero, allowsCandidates: true)
    let second = try #require(secondCandidate)
    #expect(second.id != first.id)
    let accepted = state.complete(ticket, response: TranslationResponse(text: "Old response", completion: .complete))
    #expect(!accepted)
    #expect(state.phase == .button(second))
}

@Test func selectionDoesNotInterruptScreenshotOCRAndRequiresRealText() {
    var state = TranslationStateMachine()
    #expect(state.offerSelectionText("1234", anchor: .zero, allowsCandidates: true) == nil)
    #expect(state.offerSelectionText("Selected", anchor: .zero, allowsCandidates: false) == nil)
    let ocr = state.beginScreenshot(captureID: UUID(), revision: 1, anchor: .zero)
    #expect(state.offerSelectionText("Selected", anchor: .zero, allowsCandidates: true) == nil)
    #expect(state.activeOCR == ocr)
}

@Test func rasterUsesTopLeftPixelsAndCropKeepsFlattenedRedaction() async throws {
    let base = try whitePNG(width: 200, height: 100)
    var document = AnnotationDocument(baseImageID: UUID(), pixels: try PixelSize(width: 200, height: 100))
    var style = AnnotationStyle(); style.fill = .solid; style.color = RGBAColor(red: 0, green: 0, blue: 0)
    try document.replace(with: [Annotation(geometry: .shape(.rectangle, box: CGRect(x: 10, y: 15, width: 30, height: 20), rotation: 0), style: style)])
    let renderer = AnnotationRenderer()
    let png = try await renderer.render(basePNG: base, snapshot: document.snapshot())
    #expect(try await renderer.colorHex(png: png, x: 20, y: 20) == "#000000")
    #expect(try await renderer.colorHex(png: png, x: 20, y: 80) == "#FFFFFF")
    let crop = try await renderer.crop(png: png, rect: CGRect(x: 0, y: 0, width: 50, height: 50))
    let image = try ImageCodec.decode(crop)
    #expect(image.width == 50 && image.height == 50)
    #expect(try await renderer.colorHex(png: crop, x: 20, y: 20) == "#000000")
}

@Test func nativeOCRReadsFlattenedImageAndSolidMaskRemovesPrivateWords() async throws {
    let base = try whitePNG(width: 1200, height: 700)
    var document = AnnotationDocument(baseImageID: UUID(), pixels: try PixelSize(width: 1200, height: 700))
    var style = AnnotationStyle(); style.color = RGBAColor(red: 0.1, green: 0.1, blue: 0.1); style.text.fontSize = 46
    let title = Annotation(geometry: .text("PUBLIC SENTENCE FOR TRANSLATION", box: CGRect(x: 60, y: 80, width: 1100, height: 100)), style: style)
    let secret = Annotation(geometry: .text("PRIVATE-42 SECRET WORDS", box: CGRect(x: 60, y: 400, width: 1100, height: 100)), style: style)
    try document.replace(with: [title, secret])
    let renderer = AnnotationRenderer(), ocr = OCRService()
    let original = try await renderer.render(basePNG: base, snapshot: document.snapshot())
    let sourceText = try await ocr.recognize(png: original)
    #expect(sourceText.contains("PUBLIC")); #expect(sourceText.contains("PRIVATE-42"))
    if let path = ProcessInfo.processInfo.environment["MACTOOLBOX_CAPTURE_FIXTURE_PATH"] { try original.write(to: URL(fileURLWithPath: path), options: .atomic) }
    var maskStyle = AnnotationStyle(); maskStyle.fill = .solid; maskStyle.color = RGBAColor(red: 0, green: 0, blue: 0)
    let mask = Annotation(geometry: .shape(.rectangle, box: CGRect(x: 0, y: 350, width: 1200, height: 250), rotation: 0), style: maskStyle)
    try document.replace(with: [title, secret, mask])
    let flattened = try await renderer.render(basePNG: base, snapshot: document.snapshot())
    let translatedInput = try await ocr.recognize(png: flattened)
    #expect(translatedInput.contains("PUBLIC")); #expect(!translatedInput.contains("PRIVATE")); #expect(!translatedInput.contains("SECRET"))
}

@Test func blankScreenshotProducesNoTranslationText() async throws {
    let png = try whitePNG(width: 200, height: 100)
    await #expect(throws: TranslationError.noText) { _ = try await OCRService().recognize(png: png) }
}
