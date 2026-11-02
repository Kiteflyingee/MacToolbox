import AppKit
import Testing
@testable import MacToolboxCore

@Test @MainActor func nativeStartupMonitoringSkipsOldContentsAndRecordsNewCopies() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-startup-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let ingestor = HistoryIngestor(store: store)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents(); board.setString("Before launch", forType: .string)
    let broker = ClipboardBroker(pasteboard: board, ingestor: ingestor, lastSequence: 0)
    defer { broker.disable() }
    try broker.resumeMonitoringIfAllowed()
    #expect(broker.isEnabled)
    await broker.poll(); await ingestor.waitUntilIdle()
    #expect(try await store.summaries().isEmpty)
    board.clearContents(); board.setString("After launch", forType: .string)
    // A scheduled poll may already be suspended in the ingestor. Wait for the
    // observable record, rather than assuming our overlapping poll owns it.
    for _ in 0..<100 {
        await broker.poll(); await ingestor.waitUntilIdle()
        if try await store.summaries().map(\.summary) == ["After launch"] { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(try await store.summaries().map(\.summary) == ["After launch"])
    broker.disable()
    board.clearContents(); board.setString("While paused", forType: .string)
    await broker.poll(); await ingestor.waitUntilIdle()
    #expect(try await store.summaries().count == 1)
    try broker.resumeMonitoringIfAllowed()
    await broker.poll(); await ingestor.waitUntilIdle()
    #expect(try await store.summaries().count == 1)
    try await store.close()
}

@Test @MainActor func nativePrivatePasteboardClassifiesExternalWritesAndOwnReplayWithoutLoop() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-native-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let ingestor = HistoryIngestor(store: store)
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    let broker = ClipboardBroker(pasteboard: board, ingestor: ingestor, lastSequence: 0)
    defer { broker.disable() }
    var offers: [String] = []
    broker.onExternalChange = { _, text in if let text { offers.append(text) } }
    try broker.enableFromUserAction()
    try await broker.write(.text(TextPayload(plain: "Own translation")), origin: .translationResultCopy)
    await ingestor.waitUntilIdle()
    await broker.poll()
    #expect(offers.isEmpty)
    #expect(try await store.summaries().count == 1)
    try await broker.write(.text(TextPayload(plain: "Own translation")), origin: .historyReplay)
    await ingestor.waitUntilIdle()
    #expect(try await store.summaries().count == 1)
    board.clearContents(); board.setString("External sample", forType: .string)
    await broker.poll(); await ingestor.waitUntilIdle()
    #expect(offers == ["External sample"])
    #expect(try await store.summaries().count == 2)
    #expect(board.string(forType: .string) == "External sample")
    try await store.close()
}

@Test @MainActor func nativeFileURLPriorityAndMissingReferenceNeverPartiallyReplays() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-files-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let ingestor = HistoryIngestor(store: store)
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let broker = ClipboardBroker(pasteboard: board, ingestor: ingestor, lastSequence: 0)
    defer { broker.disable() }
    try broker.enableFromUserAction()
    let file = directory.appendingPathComponent("sample.txt")
    try Data("sample".utf8).write(to: file)
    let item = NSPasteboardItem(); item.setString(file.absoluteString, forType: .fileURL); item.setString("not translation", forType: .string)
    board.clearContents(); board.writeObjects([item])
    let observation = broker.fileObservation()
    #expect(observation.changeCount == board.changeCount)
    #expect(observation.urls == [file])
    #expect(try await store.summaries().isEmpty)
    var offered = false
    broker.onExternalChange = { _, text in if text != nil { offered = true } }
    await broker.poll(); await ingestor.waitUntilIdle()
    #expect(!offered)
    #expect(try await store.summaries().first?.kind == "files")
    let good = try FileReference(url: file)
    let missing = try FileReference(url: directory.appendingPathComponent("missing"))
    let count = board.changeCount
    await #expect(throws: ClipboardAccessError.missingFiles(1)) {
        try await broker.write(.files([good, missing]), origin: .historyReplay)
    }
    #expect(board.changeCount == count)
    #expect(FileManager.default.fileExists(atPath: file.path))
    try await store.close()
}

@Test @MainActor func nativeImagePriorityNormalizesPixelsAndReplayDoesNotAppend() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-images-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let ingestor = HistoryIngestor(store: store)
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let broker = ClipboardBroker(pasteboard: board, ingestor: ingestor, lastSequence: 0)
    defer { broker.disable() }
    try broker.enableFromUserAction()
    let (png, digest) = try redPixelPNG()
    let item = NSPasteboardItem(); item.setData(png, forType: .png); item.setString("image alternate", forType: .string)
    board.clearContents(); board.writeObjects([item])
    var offered = false
    broker.onExternalChange = { _, text in if text != nil { offered = true } }
    await broker.poll(); await ingestor.waitUntilIdle()
    #expect(!offered)
    let summaries = try await store.summaries()
    #expect(summaries.count == 1)
    let entry = try await store.entry(id: #require(summaries.first).id)
    guard case .image(let image) = entry?.snapshot.content else { Issue.record("Expected normalized image"); return }
    #expect(image.pixelDigest == digest)
    #expect(image.thumbnail != nil)
    try await broker.write(.image(image), origin: .historyReplay)
    await ingestor.waitUntilIdle()
    #expect(try await store.summaries().count == 1)
    try await store.close()
}

@Test @MainActor func nativeCopyStillSucceedsWhenHistoryIsSuspended() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-storage-failure-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try HistoryStore(url: directory.appendingPathComponent("history.sqlite"))
    let ingestor = HistoryIngestor(store: store)
    let board = NSPasteboard.withUniqueName(); defer { board.releaseGlobally() }
    let broker = ClipboardBroker(pasteboard: board, ingestor: ingestor, lastSequence: 0)
    try await store.close()
    try await ingestor.enqueue(ClipboardSnapshot(sequence: 1, changeCount: 0, content: .text(TextPayload(plain: "unsaved"))))
    await ingestor.waitUntilIdle()
    var warned = false
    broker.onIssue = { _ in warned = true }
    try await broker.write(.text(TextPayload(plain: "copied despite history error")), origin: .ownTextCopy)
    #expect(board.string(forType: .string) == "copied despite history error")
    #expect(warned)
}
