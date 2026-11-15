import CoreGraphics
import Foundation
import Testing
@testable import MacToolboxCore

private let translationResult = TranslationResponse(text: "结果", completion: .complete)

@Test func targetSwitchKeepsSourceAndRejectsPreviousResponse() throws {
    var state = TranslationStateMachine()
    let offered = state.offerSelectionText("中文 source", anchor: .zero, allowsCandidates: true)
    let snapshot = try #require(offered)
    let originalValue = state.click(snapshotID: snapshot.id, settingsRevision: 1, target: .automatic)
    let original = try #require(originalValue)
    let switchedValue = state.changeTarget(snapshotID: snapshot.id, settingsRevision: 1, target: .english)
    let switched = try #require(switchedValue)
    #expect(switched.snapshot == original.snapshot)
    #expect(switched.target == .english)
    #expect(state.complete(original, response: translationResult) == false)
    #expect(state.complete(switched, response: translationResult) == true)
    let chineseValue = state.changeTarget(snapshotID: snapshot.id, settingsRevision: 1, target: .simplifiedChinese)
    let chinese = try #require(chineseValue)
    #expect(chinese.snapshot.text == "中文 source")
    state.close()
    #expect(state.changeTarget(snapshotID: snapshot.id, settingsRevision: 1, target: .automatic) == nil)
}

@Test func copyingOnlyOffersButtonAndStaleButtonTimerAndResponsesCannotChangeNewWork() throws {
    var state = TranslationStateMachine()
    state.externalVersionChanged(1)
    let offeredA = state.offerClipboardText("Alpha", changeCount: 1, anchor: .zero, allowsCandidates: true)
    let a = try #require(offeredA)
    #expect(state.activeRequest == nil)
    let requestA = state.click(snapshotID: a.id, settingsRevision: 1, target: .simplifiedChinese)
    let first = try #require(requestA)
    state.externalVersionChanged(2)
    let offeredB = state.offerClipboardText("Beta", changeCount: 2, anchor: .zero, allowsCandidates: true)
    let b = try #require(offeredB)
    state.expireButton(snapshotID: a.id)
    #expect(state.phase == .button(b))
    #expect(state.complete(first, response: translationResult) == false)
    #expect(state.click(snapshotID: a.id, settingsRevision: 1, target: .english) == nil)
    let requestB = state.click(snapshotID: b.id, settingsRevision: 1, target: .simplifiedChinese)
    let second = try #require(requestB)
    #expect(state.complete(second, response: translationResult) == true)
    state.close()
    #expect(state.complete(second, response: translationResult) == false)
    #expect(state.phase == .hidden)
}

@Test func settingsAndRetriesUseImmutableSnapshotAndRejectOldClosures() throws {
    var state = TranslationStateMachine()
    state.externalVersionChanged(1)
    let offer = state.offerClipboardText("Original", changeCount: 1, anchor: .zero, allowsCandidates: true)
    let snapshot = try #require(offer)
    let firstValue = state.click(snapshotID: snapshot.id, settingsRevision: 1, target: .simplifiedChinese)
    let first = try #require(firstValue)
    #expect(state.fail(first, error: .transport) == true)
    let retryValue = state.retry(snapshotID: snapshot.id, settingsRevision: 2)
    let retry = try #require(retryValue)
    #expect(retry.id != first.id)
    #expect(retry.snapshot.text == "Original")
    #expect(retry.target == first.target)
    #expect(retry.settingsRevision == 2)
    state.settingsChanged()
    #expect(state.complete(retry, response: translationResult) == false)
    #expect(state.retry(snapshotID: snapshot.id, settingsRevision: 3) == nil)
}

@Test func sameRevisionOCRGetsNewIdentityAndExternalCopiesDoNotCancelScreenshotWork() throws {
    var state = TranslationStateMachine()
    let capture = UUID()
    let old = state.beginScreenshot(captureID: capture, revision: 7, anchor: .zero)
    state.close()
    let current = state.beginScreenshot(captureID: capture, revision: 7, anchor: .zero)
    #expect(old.id != current.id)
    state.externalVersionChanged(10) // Can be text, image, or files.
    #expect(state.offerClipboardText("Background", changeCount: 10, anchor: .zero, allowsCandidates: true) == nil)
    #expect(state.activeOCR == current)
    #expect(state.completeOCR(old, text: "stale", settingsRevision: 1, target: .english) == nil)
    let request = state.completeOCR(current, text: "当前截图", settingsRevision: 1, target: .english)
    let ticket = try #require(request)
    state.externalVersionChanged(11)
    #expect(state.activeRequest == ticket)
    #expect(state.complete(ticket, response: translationResult) == true)
}

@Test func delayedClassificationAndBlockedCandidatesCannotReopenOldCopy() {
    var state = TranslationStateMachine()
    state.externalVersionChanged(1)
    state.externalVersionChanged(2)
    #expect(state.offerClipboardText("old", changeCount: 1, anchor: .zero, allowsCandidates: true) == nil)
    #expect(state.offerClipboardText("new", changeCount: 2, anchor: .zero, allowsCandidates: false) == nil)
    #expect(state.offerClipboardText("1234", changeCount: 2, anchor: .zero, allowsCandidates: true) == nil)
    #expect(state.activeRequest == nil)
    state.close()
    #expect(state.offerClipboardText("late after close", changeCount: 2, anchor: .zero, allowsCandidates: true) == nil)
    state.externalVersionChanged(3, allowsCandidates: false)
    #expect(state.offerClipboardText("copied while settings open", changeCount: 3, anchor: .zero, allowsCandidates: true) == nil)
}
