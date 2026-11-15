import CoreGraphics

public enum FinderKeyEvent {
    /// Copy before editing: preserve the original event's routing/window payload
    /// and avoid mutating an event that AppKit may already have cached.
    public static func replacement(for original: CGEvent, key: FinderKeyboardState.Key,
                                   modifiers: KeyModifiers) -> CGEvent? {
        guard original.type == .keyDown || original.type == .keyUp, key == .c || key == .v else { return nil }
        let code: CGKeyCode = key == .c ? 8 : 9
        guard let event = original.copy() else { return nil }
        event.setIntegerValueField(.keyboardEventKeycode, value: Int64(code))
        var flags: CGEventFlags = []
        if modifiers.contains(.command) { flags.insert(.maskCommand) }
        if modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if modifiers.contains(.shift) { flags.insert(.maskShift) }
        if modifiers.contains(.control) { flags.insert(.maskControl) }
        event.flags = flags
        return event
    }
}
