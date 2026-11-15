import CoreGraphics
import Foundation
import ImageIO
import SQLite3
import Testing
@testable import MacToolboxCore

private func temporaryDatabase() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-tests-\(UUID())", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory.appendingPathComponent("history.sqlite")
}

private func textSnapshot(_ text: String, sequence: Int64) throws -> ClipboardSnapshot {
    try ClipboardSnapshot(sequence: sequence, changeCount: Int(sequence), content: .text(TextPayload(plain: text)))
}

func redPixelPNG() throws -> (Data, ContentDigest) {
    let pixels = Data([255, 0, 0, 255])
    let provider = try #require(CGDataProvider(data: pixels as CFData))
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    let image = try #require(CGImage(width: 1, height: 1, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 4,
        space: colorSpace, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue).union(.byteOrder32Big),
        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    let bytes = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(bytes, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    try #require(CGImageDestinationFinalize(destination))
    return (bytes as Data, ContentDigest(data: pixels))
}

@Test func historyKeepsTwentyAcrossReopenAndOnlyDeduplicatesConsecutiveContent() async throws {
    let url = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try HistoryStore(url: url)
    for index in 1...21 { try await store.append(textSnapshot("\(index)", sequence: Int64(index))) }
    var entries = try await store.entries()
    #expect(entries.count == 20)
    #expect(entries.first?.snapshot.content.summary == "21")
    #expect(entries.last?.snapshot.content.summary == "2")
    try await store.append(textSnapshot("21", sequence: 22))
    #expect(try await store.entries().count == 20)
    try await store.append(textSnapshot("B", sequence: 23))
    try await store.append(textSnapshot("21", sequence: 24))
    entries = try await store.entries()
    #expect(entries.prefix(3).map(\.snapshot.content.summary) == ["21", "B", "21"])
    try await store.close()
    let reopened = try HistoryStore(url: url)
    #expect(try await reopened.entries() == entries)
    #expect(await reopened.maximumSequence() == 24)
    try await reopened.close()
}

@Test func failedPruneRollsBackTheInsertAndKeepsOldTwenty() async throws {
    let url = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try HistoryStore(url: url)
    for index in 1...20 { try await store.append(textSnapshot("\(index)", sequence: Int64(index))) }
    let before = try await store.entries()
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    defer { sqlite3_close(db) }
    #expect(sqlite3_exec(db, "CREATE TRIGGER deny_prune BEFORE DELETE ON entries BEGIN SELECT RAISE(ABORT,'test'); END", nil, nil, nil) == SQLITE_OK)
    await #expect(throws: HistoryStorageError.self) {
        try await store.append(textSnapshot("new", sequence: 21))
    }
    #expect(try await store.entries() == before)
    #expect(await store.maximumSequence() == 20)
    try await store.close()
}

@Test func unknownDatabaseVersionIsPreserved() throws {
    let url = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    var db: OpaquePointer?
    #expect(sqlite3_open(url.path, &db) == SQLITE_OK)
    #expect(sqlite3_exec(db, "PRAGMA user_version=99", nil, nil, nil) == SQLITE_OK)
    sqlite3_close(db)
    let before = try Data(contentsOf: url)
    #expect(throws: CoreError.unsupportedVersion) { try HistoryStore(url: url) }
    #expect(try Data(contentsOf: url) == before)
}

@Test func historyQueuePreservesSlowExternalThenFastOwnWriteAndPurgesPendingSecrets() async throws {
    let url = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try HistoryStore(url: url)
    let ingestor = HistoryIngestor(store: store)
    let a = try textSnapshot("A", sequence: 1)
    let b = try textSnapshot("B", sequence: 2)
    let gate = AsyncGate()
    try await ingestor.enqueue(sequence: 1, byteCount: 1) {
        await gate.wait()
        return a
    }
    try await ingestor.enqueue(b)
    #expect(try await store.summaries().isEmpty)
    await gate.open()
    await ingestor.waitUntilIdle()
    #expect(try await store.entries().map(\.snapshot.content.summary) == ["B", "A"])
    let secret = try ClipboardSnapshot(sequence: 3, changeCount: 3,
        content: .text(TextPayload(plain: "test-secret", rtf: Data("format".utf8))))
    try await ingestor.enqueue(sequence: 3, byteCount: secret.content.byteCount) {
        try await Task.sleep(for: .milliseconds(20))
        return secret
    }
    try await ingestor.registerSensitiveText("test-secret")
    try await ingestor.enqueue(textSnapshot("test-secret", sequence: 4))
    await ingestor.waitUntilIdle()
    #expect(try await store.entries().map(\.snapshot.content.summary) == ["B", "A"])
    #expect(await ingestor.takeEvents().contains(.skippedSensitive(4)))
    try await store.close()
}

@Test func queueCountsTheInFlightJobAndRejectsFifthWithoutUnboundedAllocation() async throws {
    let url = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try HistoryStore(url: url)
    let ingestor = HistoryIngestor(store: store)
    let first = try textSnapshot("1", sequence: 1)
    let gate = AsyncGate()
    try await ingestor.enqueue(sequence: 1, byteCount: 1) {
        await gate.wait()
        return first
    }
    for index in 2...4 { try await ingestor.enqueue(textSnapshot("\(index)", sequence: Int64(index))) }
    await #expect(throws: CoreError.queueFull) { try await ingestor.enqueue(textSnapshot("5", sequence: 5)) }
    #expect(await ingestor.overloadCount == 1)
    await gate.open()
    await ingestor.waitUntilIdle()
    #expect(try await store.entries().count == 4)
    try await store.close()
}

@Test func fileReferencesUnavailableItemsAndLazySummarySurviveReopen() async throws {
    let url = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try HistoryStore(url: url)
    let files = try ["/tmp/a", "/tmp/folder", "/tmp/link"].map { try FileReference(url: URL(fileURLWithPath: $0)) }
    let snapshot = try ClipboardSnapshot(sequence: 1, changeCount: 8, content: .files(files))
    try await store.append(snapshot)
    let unavailable = try ClipboardSnapshot(sequence: 2, changeCount: 9, content: .unavailable(.tooLarge, summary: "内容过大"))
    try await store.append(unavailable)
    let (png, pixelDigest) = try redPixelPNG()
    let image = try ImagePayload(png: png, width: 1, height: 1, pixelDigest: pixelDigest, thumbnail: png)
    let imageSnapshot = try ClipboardSnapshot(sequence: 3, changeCount: 10, content: .image(image))
    try await store.append(imageSnapshot)
    let summaries = try await store.summaries()
    #expect(summaries.count == 3)
    #expect(summaries[0].kind == "image")
    #expect(summaries[0].thumbnail == png)
    #expect(summaries[1].status == "unavailable")
    #expect(summaries[2].kind == "files")
    #expect(summaries[2].summary == "3 个文件或文件夹")
    #expect(try await store.entry(id: snapshot.id)?.snapshot.content == .files(files))
    #expect(try await store.entry(id: unavailable.id)?.canReplay == false)
    try await store.close()
    let reopened = try HistoryStore(url: url)
    #expect(try await reopened.summaries() == summaries)
    #expect(try await reopened.entry(id: imageSnapshot.id)?.snapshot.content == .image(image))
    try await reopened.close()
}

@Test func storageFailureSuspendsHistoryWithoutPretendingToSave() async throws {
    let url = try temporaryDatabase()
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let store = try HistoryStore(url: url)
    let ingestor = HistoryIngestor(store: store)
    try await store.close()
    try await ingestor.enqueue(textSnapshot("not saved", sequence: 1))
    await ingestor.waitUntilIdle()
    #expect(await ingestor.isSuspended)
    #expect(await ingestor.takeEvents() == [.failed(1)])
    await #expect(throws: CoreError.historySuspended) { try await ingestor.enqueue(textSnapshot("next", sequence: 2)) }
}
