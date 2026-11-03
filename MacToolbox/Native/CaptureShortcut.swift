import AppKit
import Carbon

public struct CaptureShortcut: Codable, Equatable, Sendable {
    public let keyCode: UInt16
    public let modifiers: UInt
    public let key: String

    public init(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, key: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.command, .control, .option, .shift]).rawValue
        self.key = key
    }

    public init(event: NSEvent) throws {
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: "空格", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        let characters = event.characters(byApplyingModifiers: []) ?? event.charactersIgnoringModifiers ?? ""
        let key: String
        if let name = special[event.keyCode] { key = name }
        else if let scalar = characters.unicodeScalars.first, (0xF704...0xF717).contains(scalar.value) {
            key = "F\(scalar.value - 0xF704 + 1)"
        } else {
            guard characters.count == 1, !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw CaptureShortcutError.invalid
            }
            key = characters.uppercased()
        }
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags, key: key)
        guard event.type == .keyDown, !event.isARepeat, isValid else { throw CaptureShortcutError.invalid }
    }

    public var flags: NSEvent.ModifierFlags { .init(rawValue: modifiers) }
    public var isValid: Bool {
        keyCode < 128 && ![53, 51, 117].contains(keyCode) && !(54...63).contains(keyCode)
            && !flags.intersection([.command, .control]).isEmpty && !key.isEmpty && key.count <= 8
            && flags.intersection([.command, .control, .option, .shift]).rawValue == modifiers
    }
    public var title: String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined() + key
    }
    var carbonModifiers: UInt32 {
        [(NSEvent.ModifierFlags.command, cmdKey), (.control, controlKey), (.option, optionKey), (.shift, shiftKey)]
            .filter { flags.contains($0.0) }.reduce(UInt32(0)) { $0 | UInt32($1.1) }
    }
}

public enum CaptureShortcutError: LocalizedError {
    case invalid, occupied, registration(OSStatus)
    public var errorDescription: String? {
        switch self {
        case .invalid: return "请使用包含 ⌘ 或 ⌃ 的组合键；Esc 取消，Delete 清除。"
        case .occupied: return "此快捷键已被系统或其他应用占用，请换一个组合键。"
        case .registration(let code): return "无法注册快捷键（错误 \(code)），请尝试其他组合键。"
        }
    }
}

@MainActor
public final class CaptureShortcutController {
    private static var nextID: UInt32 = 0
    private let preferences: UserDefaults
    private let action: () -> Void
    let hotKeyID: EventHotKeyID
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    public private(set) var shortcut: CaptureShortcut?
    public private(set) var registrationError: String?
    public var isRegistered: Bool { hotKey != nil }

    public init(preferences: UserDefaults, action: @escaping () -> Void) {
        self.preferences = preferences; self.action = action
        Self.nextID += 1
        hotKeyID = EventHotKeyID(signature: 0x4D544253, id: Self.nextID)
        if let data = preferences.data(forKey: "captureShortcut"),
           let saved = try? JSONDecoder().decode(CaptureShortcut.self, from: data), saved.isValid { shortcut = saved }
        resume()
    }

    public func setShortcut(_ value: CaptureShortcut?) throws {
        if let value, !value.isValid { throw CaptureShortcutError.invalid }
        let data = try value.map { try JSONEncoder().encode($0) }
        if value == shortcut, isRegistered { return }
        // Register the replacement first: a conflict must leave the current binding intact.
        let replacement = try value.map { try register($0) }
        suspend()
        hotKey = replacement; shortcut = value; registrationError = nil
        if let data { preferences.set(data, forKey: "captureShortcut") }
        else { preferences.removeObject(forKey: "captureShortcut") }
    }

    public func suspend() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        hotKey = nil
    }

    public func resume() {
        guard hotKey == nil, let shortcut else { return }
        do { hotKey = try register(shortcut); registrationError = nil }
        catch { registrationError = error.localizedDescription }
    }

    public func stop() {
        suspend()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    private func register(_ value: CaptureShortcut) throws -> EventHotKeyRef {
        var symbolic: Unmanaged<CFArray>?
        if CopySymbolicHotKeys(&symbolic) == noErr, let keys = symbolic?.takeRetainedValue() as? [[String: Any]],
           keys.contains(where: {
               ($0[kHISymbolicHotKeyEnabled as String] as? Bool) == true
                   && ($0[kHISymbolicHotKeyCode as String] as? NSNumber)?.uint16Value == value.keyCode
                   && ($0[kHISymbolicHotKeyModifiers as String] as? NSNumber)?.uint32Value == value.carbonModifiers
           }) { throw CaptureShortcutError.occupied }
        if handler == nil {
            var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                return MainActor.assumeIsolated {
                    let owner = Unmanaged<CaptureShortcutController>.fromOpaque(context).takeUnretainedValue()
                    var id = EventHotKeyID()
                    guard GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                        id.signature == owner.hotKeyID.signature, id.id == owner.hotKeyID.id, owner.isRegistered else {
                        return OSStatus(eventNotHandledErr)
                    }
                    owner.action()
                    return noErr
                }
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
            guard status == noErr else { throw CaptureShortcutError.registration(status) }
        }
        var reference: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(value.keyCode), value.carbonModifiers, hotKeyID,
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &reference)
        guard status == noErr, let reference else {
            if status == eventHotKeyExistsErr { throw CaptureShortcutError.occupied }
            throw CaptureShortcutError.registration(status)
        }
        return reference
    }

    isolated deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
