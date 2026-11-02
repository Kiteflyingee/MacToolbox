import AppKit
import Testing
@testable import MacToolboxCore

@MainActor private func cocoaKey(_ type: NSEvent.EventType, code: UInt16, character: String, windowNumber: Int = 0) throws -> CGEvent {
    try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: .command, timestamp: 42,
        windowNumber: windowNumber, context: nil, characters: character, charactersIgnoringModifiers: character,
        isARepeat: false, keyCode: code)?.cgEvent)
}

@Test @MainActor func finderConversionPreservesWindowAndProcessRouting() throws {
    // Construction only: this test never posts an event to any process.
    let original = try cocoaKey(.keyDown, code: 7, character: "x", windowNumber: 321)
    #expect(NSEvent(cgEvent: original)?.windowNumber == 321)
    original.setIntegerValueField(.eventTargetUnixProcessID, value: 12345)
    original.setIntegerValueField(.eventSourceUserData, value: 8765)
    let converted = try #require(FinderKeyEvent.replacement(for: original, key: .c, modifiers: .command))
    let parsed = try #require(NSEvent(cgEvent: converted))
    #expect(parsed.windowNumber == 321)
    #expect(converted.getIntegerValueField(.eventTargetUnixProcessID) == 12345)
    #expect(converted.getIntegerValueField(.eventSourceUserData) == 8765)
}

@Test @MainActor func finderCopyConvertsPhysicalKeyboardEventWithoutMutatingOriginal() throws {
    // The process tap supplies physical keyboard events, not Cocoa-created text
    // events with an already cached characters string.
    let original = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 7, keyDown: true))
    original.flags = .maskCommand
    let replacement = try #require(FinderKeyEvent.replacement(for: original, key: .c, modifiers: .command))
    let parsed = try #require(NSEvent(cgEvent: replacement))
    #expect(parsed.keyCode == 8)
    #expect(parsed.characters == "c")
    #expect(parsed.charactersIgnoringModifiers == "c")
    #expect(parsed.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command)
    #expect(replacement.timestamp == original.timestamp)
    #expect(NSEvent(cgEvent: original)?.charactersIgnoringModifiers == "x")
    #expect(original.getIntegerValueField(.keyboardEventKeycode) == 7)
}

@Test @MainActor func finderMoveReturnsMatchingDownAndUpWithOptionCommandV() throws {
    for type: NSEvent.EventType in [.keyDown, .keyUp] {
        let original = try cocoaKey(type, code: 9, character: "v")
        let replacement = try #require(FinderKeyEvent.replacement(for: original, key: .v, modifiers: [.command, .option]))
        let parsed = try #require(NSEvent(cgEvent: replacement))
        #expect(parsed.type == type)
        #expect(parsed.keyCode == 9 && parsed.charactersIgnoringModifiers == "v")
        #expect(parsed.modifierFlags.intersection(.deviceIndependentFlagsMask) == [.command, .option])
    }
}

@Test @MainActor func finderEventReplacementRejectsUnmappedKeysAndMouseEvents() throws {
    let original = try cocoaKey(.keyDown, code: 7, character: "x")
    #expect(FinderKeyEvent.replacement(for: original, key: .other, modifiers: .command) == nil)
    let mouse = try #require(CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: .zero, mouseButton: .left))
    #expect(FinderKeyEvent.replacement(for: mouse, key: .c, modifiers: .command) == nil)
}
