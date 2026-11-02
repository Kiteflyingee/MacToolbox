import ApplicationServices
import Foundation

/// AX calls stay off the main thread; never synthesize Copy or read an entire field.
public actor SelectionReader {
    public init() {}
    public func selectedText(processID: Int32) -> String? {
        readSelection(processID: processID).text
    }
    public func readSelection(processID: Int32) -> (text: String?, status: String) {
        guard processID != ProcessInfo.processInfo.processIdentifier else { return (nil, "own-process") }
        // Let the real AX call report denial; the process trust flag can lag a grant change.
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        guard result == .success, let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else {
            return (nil, "focused-element:\(result.rawValue)")
        }
        var element = unsafeDowncast(focused, to: AXUIElement.self)
        for _ in 0..<4 {
            guard !Task.isCancelled else { return (nil, "cancelled") }
            AXUIElementSetMessagingTimeout(element, 0.15)
            var subrole: CFTypeRef?
            _ = AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subrole)
            guard subrole as? String != kAXSecureTextFieldSubrole else { return (nil, "secure-field") }
            var selected: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
               let text = selected as? String, !text.isEmpty, text.utf8.count <= AppLimits.textBytes { return (text, "selected-text") }
            // Browsers may expose the selection on the enclosing AXWebArea.
            var parent: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parent) == .success,
                  let parent, CFGetTypeID(parent) == AXUIElementGetTypeID() else { return (nil, "no-selected-text") }
            element = unsafeDowncast(parent, to: AXUIElement.self)
        }
        return (nil, "no-selected-text")
    }
}
