import AppKit
import Carbon
import Testing
@testable import MacToolboxCore

@Suite(.serialized) @MainActor
struct CaptureShortcutTests {
    private let modifiers: NSEvent.ModifierFlags = [.control, .option, .shift, .command]

    @Test func validatesModifierPolicyAndNormalizesIrrelevantFlags() throws {
        let shortcut = CaptureShortcut(keyCode: 0, modifiers: [.control, .option, .command, .capsLock, .numericPad], key: "A")
        #expect(shortcut.isValid)
        #expect(shortcut.title == "⌃⌥⌘A")
        #expect(shortcut.carbonModifiers == UInt32(controlKey | optionKey | cmdKey))
        for flags: NSEvent.ModifierFlags in [[], .shift, .option, [.option, .shift]] {
            #expect(!CaptureShortcut(keyCode: 0, modifiers: flags, key: "A").isValid)
        }
        for keyCode: UInt16 in [53, 51, 117, 54, 63, 128] {
            #expect(!CaptureShortcut(keyCode: keyCode, modifiers: .command, key: "A").isValid)
        }
        let encoded = try JSONEncoder().encode(shortcut)
        #expect(try JSONDecoder().decode(CaptureShortcut.self, from: encoded) == shortcut)
    }

    @Test func registersPersistsSuspendsRestoresAndClears() throws {
        let suite = "local.devkite.MacToolbox.shortcut-test." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        let shortcut = CaptureShortcut(keyCode: UInt16(kVK_F18), modifiers: modifiers, key: "F18")
        let first = CaptureShortcutController(preferences: preferences, action: {})
        defer { first.stop() }
        #expect(first.shortcut == nil && !first.isRegistered)
        try first.setShortcut(shortcut)
        #expect(first.isRegistered && first.shortcut == shortcut)
        first.suspend()
        #expect(!first.isRegistered && first.shortcut == shortcut)
        first.resume()
        #expect(first.isRegistered && first.registrationError == nil)
        first.stop()
        let restored = CaptureShortcutController(preferences: preferences, action: {})
        defer { restored.stop() }
        #expect(restored.shortcut == shortcut && restored.isRegistered)
        try restored.setShortcut(nil)
        #expect(restored.shortcut == nil && !restored.isRegistered)
        #expect(preferences.object(forKey: "captureShortcut") == nil)
    }

    @Test func conflictingReplacementPreservesOldShortcutIncludingAfterRecording() throws {
        let suite = "local.devkite.MacToolbox.shortcut-test." + UUID().uuidString
        let otherSuite = suite + ".other"
        let preferences = try #require(UserDefaults(suiteName: suite))
        let otherPreferences = try #require(UserDefaults(suiteName: otherSuite))
        defer {
            preferences.removePersistentDomain(forName: suite)
            otherPreferences.removePersistentDomain(forName: otherSuite)
        }
        let first = CaptureShortcutController(preferences: preferences, action: {})
        let other = CaptureShortcutController(preferences: otherPreferences, action: {})
        defer { first.stop(); other.stop() }
        let original = CaptureShortcut(keyCode: UInt16(kVK_F18), modifiers: modifiers, key: "F18")
        let occupied = CaptureShortcut(keyCode: UInt16(kVK_F19), modifiers: modifiers, key: "F19")
        try first.setShortcut(original)
        try other.setShortcut(occupied)
        let saved = preferences.data(forKey: "captureShortcut")
        #expect(throws: CaptureShortcutError.self) { try first.setShortcut(occupied) }
        #expect(first.isRegistered && first.shortcut == original)
        #expect(preferences.data(forKey: "captureShortcut") == saved)
        first.suspend()
        #expect(throws: CaptureShortcutError.self) { try first.setShortcut(occupied) }
        first.resume()
        #expect(first.isRegistered && first.shortcut == original)
    }

    @Test func rejectsCorruptOrUnsafeSavedShortcutWithoutRegistering() throws {
        let suite = "local.devkite.MacToolbox.shortcut-test." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        preferences.set(try JSONEncoder().encode(CaptureShortcut(keyCode: 0, modifiers: [], key: "A")), forKey: "captureShortcut")
        let controller = CaptureShortcutController(preferences: preferences, action: {})
        defer { controller.stop() }
        #expect(controller.shortcut == nil && !controller.isRegistered)
    }

    @Test func dispatchesOnlyMatchingRegisteredHotkeyEvents() throws {
        let suite = "local.devkite.MacToolbox.shortcut-test." + UUID().uuidString
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }
        var triggers = 0
        let controller = CaptureShortcutController(preferences: preferences) { triggers += 1 }
        defer { controller.stop() }
        try controller.setShortcut(CaptureShortcut(keyCode: UInt16(kVK_F18), modifiers: modifiers, key: "F18"))
        var event: EventRef?
        #expect(CreateEvent(nil, OSType(kEventClassKeyboard), UInt32(kEventHotKeyPressed), 0, 0, &event) == noErr)
        let hotkeyEvent = try #require(event)
        defer { ReleaseEvent(hotkeyEvent) }
        var id = controller.hotKeyID
        #expect(SetEventParameter(hotkeyEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &id) == noErr)
        // Delivers an in-process Carbon event; never injects keyboard input into the system.
        #expect(SendEventToEventTarget(hotkeyEvent, GetApplicationEventTarget()) == noErr)
        #expect(triggers == 1)
        controller.suspend()
        _ = SendEventToEventTarget(hotkeyEvent, GetApplicationEventTarget())
        #expect(triggers == 1)
        controller.resume()
        id.id += 1000
        #expect(SetEventParameter(hotkeyEvent, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
            MemoryLayout<EventHotKeyID>.size, &id) == noErr)
        _ = SendEventToEventTarget(hotkeyEvent, GetApplicationEventTarget())
        #expect(triggers == 1)
    }
}
