import Foundation
import Testing
@testable import MacToolboxCore

@Test func ownWritesCannotStartTranslationOrReplayHistory() throws {
    #expect(ClipboardOrigin.externalText.offersTranslation)
    for origin in ClipboardOrigin.allCases where origin.isOwnWrite {
        #expect(!origin.offersTranslation)
    }
    #expect(!ClipboardOrigin.historyReplay.recordsHistory)
    #expect(!ClipboardOrigin.annotationCopy.recordsHistory)
    let digest = ContentDigest(data: Data("hello".utf8))
    let receipt = try WriteReceipt(origin: .translationResultCopy, finalChangeCount: 8, fingerprint: digest)
    var ledger = ClipboardLedger()
    ledger.register(receipt)
    #expect(ledger.ownOrigin(changeCount: 8, fingerprint: digest, markerID: receipt.id) == .translationResultCopy)
    // An external app can copy the same text and even preserve the marker.
    #expect(ledger.ownOrigin(changeCount: 9, fingerprint: digest, markerID: receipt.id) == nil)
    #expect(ledger.ownOrigin(changeCount: 8, fingerprint: digest, markerID: nil) == nil)
    #expect(ledger.ownOrigin(changeCount: 8, fingerprint: ContentDigest(data: Data()), markerID: receipt.id) == nil)
}

@Test func fileReferencesRejectNonFileAndAmbiguousURLsWithoutResolvingLinks() throws {
    #expect(throws: CoreError.invalidContent) { try FileReference(url: URL(string: "https://example.com/file")!) }
    #expect(throws: CoreError.invalidContent) { try FileReference(url: URL(string: "file:///tmp/a?other=path")!) }
    let reference = try FileReference(url: URL(fileURLWithPath: "/tmp/example-link"))
    #expect(reference.originalURL.path == "/tmp/example-link")
    #expect(FinderCutState.fileDigest([reference.originalURL]) != nil)
}
