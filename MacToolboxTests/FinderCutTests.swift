import Foundation
import Testing
@testable import MacToolboxCore

private let sampleFiles = [URL(fileURLWithPath: "/tmp/MacToolbox-example-a"), URL(fileURLWithPath: "/tmp/MacToolbox-example-b")]

private func context(_ kind: FinderFocusSnapshot.Kind = .fileArea, time: Double = 1, selected: [URL] = sampleFiles) -> FinderInputContext {
    FinderInputContext(focus: FinderFocusSnapshot(pid: 42, kind: kind, selectedURLs: selected, generation: 1, sampledAt: time),
                       generation: 1, finderIsFrontmost: true, ownInteractionActive: false,
                       inputPermissionAvailable: true, secureInput: false, uptime: time)
}

@Test func cutNeedsMatchingCopyAndMoveTokenIsConsumedOnce() {
    var state = FinderCutState()
    #expect(state.beginCut(context: context(), changeCount: 1) == true)
    #expect(state.observe(changeCount: 2, fileURLs: Array(sampleFiles.reversed()), context: context(time: 1.1)) == true)
    // Target folder can have no selection; source URLs need not remain selected.
    #expect(state.consumeForPaste(context: context(time: 1.2, selected: []), changeCount: 2) == true)
    #expect(state.consumeForPaste(context: context(time: 1.2), changeCount: 2) == false)
    #expect(state.phase == .idle)
}

@Test func cutConfirmationSignalsFeedbackOnlyOnceForMatchingFiles() {
    var keys = FinderKeyboardState()
    #expect(keys.keyDown(.x, modifiers: .command, repeat: false, context: context(), changeCount: 1) == .rewrite(.c, .command))
    #expect(keys.keyDown(.x, modifiers: .command, repeat: true, context: context(), changeCount: 1) == .drop)
    #expect(keys.observe(changeCount: 1, fileURLs: nil, context: context(time: 1.05)) == false)
    #expect(keys.observe(changeCount: 2, fileURLs: sampleFiles, context: context(time: 1.1)) == true)
    #expect(keys.observe(changeCount: 2, fileURLs: sampleFiles, context: context(time: 1.2)) == false)
    #expect(keys.observe(changeCount: 3, fileURLs: sampleFiles, context: context(time: 1.3)) == false)
    #expect(keys.cut.phase == .idle)
    _ = keys.keyUp(.x, modifiers: .command)
    _ = keys.keyDown(.x, modifiers: .command, repeat: false, context: context(time: 1.4), changeCount: 3)
    #expect(keys.observe(changeCount: 4, fileURLs: [sampleFiles[0]], context: context(time: 1.5)) == false)
}

@Test func directoryURLSlashesDoNotBreakFinderBridgeIdentity() {
    let selected = [URL(fileURLWithPath: "/private/tmp/source/file.txt"), URL(fileURLWithPath: "/private/tmp/source/folder", isDirectory: true)]
    let copied = [URL(fileURLWithPath: "/private/tmp/source/folder", isDirectory: false), URL(fileURLWithPath: "/private/tmp/source/file.txt")]
    #expect(FinderCutState.fileDigest(selected) == FinderCutState.fileDigest(copied))
    #expect(FinderCutState.fileDigest([URL(string: "file://remote-host/private/tmp/source/file.txt")!]) != FinderCutState.fileDigest([selected[0]]))
    var cut = FinderCutState()
    #expect(cut.beginCut(context: context(selected: selected), changeCount: 1) == true)
    #expect(cut.observe(changeCount: 2, fileURLs: copied, context: context(time: 1.1, selected: selected)) == true)
    #expect(cut.consumeForPaste(context: context(time: 1.2, selected: []), changeCount: 2) == true)
}

@Test func pendingCopySurvivesWindowFocusResamplingUntilMatchingClipboardArrives() {
    var cut = FinderCutState()
    #expect(cut.beginCut(context: context(), changeCount: 1) == true)
    let navigating = FinderInputContext(focus: nil, generation: 2, finderIsFrontmost: true, frontmostPID: 42,
        ownInteractionActive: false, inputPermissionAvailable: true, secureInput: false, uptime: 1.05)
    #expect(cut.observe(changeCount: 1, fileURLs: nil, context: navigating) == false)
    if case .awaitingCopy = cut.phase { } else { Issue.record("Focus resampling cancelled a pending copy") }
    #expect(cut.observe(changeCount: 2, fileURLs: sampleFiles, context: navigating) == true)
    #expect(cut.consumeForPaste(context: context(time: 1.2, selected: []), changeCount: 2) == true)
}

@Test func navigationToleranceStillRequiresSameFinderAndSafePasteFocus() {
    var unsafe = [FinderInputContext]()
    var input = context(); input.frontmostPID = 99; unsafe.append(input)
    input = context(); input.finderIsFrontmost = false; unsafe.append(input)
    input = context(); input.secureInput = true; unsafe.append(input)
    input = context(); input.inputPermissionAvailable = false; unsafe.append(input)
    input = context(); input.ownInteractionActive = true; unsafe.append(input)
    input = context(); input.uptime = 2.1; unsafe.append(input)
    for input in unsafe {
        var cut = FinderCutState()
        #expect(cut.beginCut(context: context(), changeCount: 1) == true)
        #expect(cut.observe(changeCount: 1, fileURLs: nil, context: input) == false)
        #expect(cut.phase == .idle)
    }
    var cut = FinderCutState()
    #expect(cut.beginCut(context: context(), changeCount: 1) == true)
    #expect(cut.observe(changeCount: 2, fileURLs: sampleFiles, context: context(.text, time: 1.1)) == true)
    #expect(cut.consumeForPaste(context: context(.text, time: 1.2), changeCount: 2) == false)
    #expect(cut.phase == .idle)
}

@Test func wrongSourceTextFocusStaleFocusAndExternalWriteFailClosed() {
    var state = FinderCutState()
    #expect(state.beginCut(context: context(.text), changeCount: 1) == false)
    #expect(state.beginCut(context: context(.unknown), changeCount: 1) == false)
    var stale = context()
    stale.uptime = 1.2
    #expect(state.beginCut(context: stale, changeCount: 1) == false)
    #expect(state.beginCut(context: context(), changeCount: 1) == true)
    #expect(state.observe(changeCount: 2, fileURLs: [URL(fileURLWithPath: "/tmp/other")], context: context(time: 1.1)) == false)
    #expect(state.phase == .idle)
    #expect(state.beginCut(context: context(), changeCount: 1) == true)
    #expect(state.observe(changeCount: 2, fileURLs: sampleFiles, context: context(time: 1.1)) == true)
    #expect(state.consumeForPaste(context: context(time: 1.2), changeCount: 3) == false)
    #expect(state.phase == .idle)
    #expect(state.beginCut(context: context(), changeCount: 1) == true)
    state.invalidate() // history replay, own write, app switch, sleep, or revoked permission
    #expect(state.consumeForPaste(context: context(), changeCount: 1) == false)
}

@Test func rewrittenKeysHavePairedUpsAndHeldPasteNeverFallsBackToCopy() {
    var keys = FinderKeyboardState()
    #expect(keys.keyDown(.x, modifiers: .command, repeat: false, context: context(), changeCount: 1) == .rewrite(.c, .command))
    #expect(keys.keyDown(.x, modifiers: .command, repeat: true, context: context(), changeCount: 1) == .drop)
    #expect(keys.keyUp(.x, modifiers: .command) == .rewrite(.c, .command))
    #expect(keys.observe(changeCount: 2, fileURLs: sampleFiles, context: context(time: 1.1)) == true)
    #expect(keys.keyDown(.v, modifiers: .command, repeat: false, context: context(time: 1.2), changeCount: 2) == .rewrite(.v, [.command, .option]))
    #expect(keys.keyDown(.v, modifiers: .command, repeat: true, context: context(time: 1.2), changeCount: 2) == .drop)
    #expect(keys.keyUp(.v, modifiers: .command) == .rewrite(.v, [.command, .option]))
    #expect(keys.keyDown(.v, modifiers: [.command, .option], repeat: false, context: context(), changeCount: 2) == .pass)
}

@Test func privacyFocusAndTimeoutGatesNeverArmCutAndNativeMoveClearsToken() {
    var blocked = [FinderInputContext]()
    var value = context(); value.secureInput = true; blocked.append(value)
    value = context(); value.ownInteractionActive = true; blocked.append(value)
    value = context(); value.finderIsFrontmost = false; blocked.append(value)
    value = context(); value.inputPermissionAvailable = false; blocked.append(value)
    value = context(); value.currentGeneration = 2; blocked.append(value)
    for value in blocked {
        var cut = FinderCutState()
        #expect(cut.beginCut(context: value, changeCount: 1) == false)
    }
    var cut = FinderCutState()
    #expect(cut.beginCut(context: context(), changeCount: 1) == true)
    #expect(cut.observe(changeCount: 2, fileURLs: sampleFiles, context: context(time: 2.1)) == false)
    var keys = FinderKeyboardState()
    _ = keys.keyDown(.x, modifiers: .command, repeat: false, context: context(), changeCount: 1)
    _ = keys.keyUp(.x, modifiers: .command)
    #expect(keys.observe(changeCount: 2, fileURLs: sampleFiles, context: context(time: 1.1)) == true)
    #expect(keys.keyDown(.v, modifiers: [.command, .option], repeat: false, context: context(time: 1.2), changeCount: 2) == .pass)
    #expect(keys.cut.phase == .idle)
}
