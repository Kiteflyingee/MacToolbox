import ApplicationServices
import Foundation

/// Finder IPC runs away from the keyboard callback. Unknown/editable focus never arms a move.
public actor FinderSelectionReader {
    public init() {}

    public func snapshot(pid: Int32, generation: UInt64) -> FinderFocusSnapshot {
        let sampledAt = ProcessInfo.processInfo.systemUptime
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        func result(_ kind: FinderFocusSnapshot.Kind, _ urls: [URL] = []) -> FinderFocusSnapshot {
            FinderFocusSnapshot(pid: pid, kind: kind, selectedURLs: urls, generation: generation, sampledAt: sampledAt)
        }
        guard let focus = element(attribute(app, kAXFocusedUIElementAttribute)) else { return result(.unknown) }
        let role = attribute(focus, kAXRoleAttribute) as? String ?? ""
        let subrole = attribute(focus, kAXSubroleAttribute) as? String ?? ""
        if role == kAXTextFieldRole, attribute(focus, kAXURLAttribute) != nil, !subrole.contains("Text") {
            // Finder file-name cells expose AXTextField even outside rename mode.
            // A real editor supports a selected-text range; ordinary file cells don't.
            var range: CFTypeRef?
            if AXUIElementCopyAttributeValue(focus, kAXSelectedTextRangeAttribute as CFString, &range) != .attributeUnsupported {
                return result(.text)
            }
        } else if [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole].contains(role) || subrole.contains("Text") {
            return result(.text)
        }
        // Finder's sidebar is also an outline. Only its actual file view is accepted.
        let identifiers = ["ListView", "IconView", "ColumnView", "GalleryView", "DesktopView"]
        var current: AXUIElement? = focus
        for _ in 0..<5 {
            guard let node = current, !Task.isCancelled else { break }
            if let identifier = attribute(node, kAXIdentifierAttribute) as? String, identifiers.contains(identifier) {
                var selected = elements(attribute(node, kAXSelectedChildrenAttribute))
                if selected == nil { selected = elements(attribute(node, kAXSelectedRowsAttribute)) }
                var urls: [URL] = []
                var budget = 600
                for child in selected ?? [] {
                    guard let url = selectedURL(child, depth: 0, budget: &budget) else { return result(.unknown) }
                    urls.append(url)
                }
                return result(.fileArea, urls)
            }
            current = element(attribute(node, kAXParentAttribute))
        }
        return result(.unknown)
    }

    private func selectedURL(_ node: AXUIElement, depth: Int, budget: inout Int) -> URL? {
        guard budget > 0, depth <= 4, !Task.isCancelled else { return nil }
        budget -= 1
        if let value = attribute(node, kAXURLAttribute) {
            let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
            if let url, FileReference.isSupportedURL(url) { return url }
        }
        for child in elements(attribute(node, kAXChildrenAttribute)) ?? [] {
            if let url = selectedURL(child, depth: depth+1, budget: &budget) { return url }
        }
        return nil
    }
    private func attribute(_ node: AXUIElement, _ name: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(node, 0.04)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(node, name as CFString, &value) == .success else { return nil }
        return value
    }
    private func element(_ value: CFTypeRef?) -> AXUIElement? {
        guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }
    private func elements(_ value: CFTypeRef?) -> [AXUIElement]? { value as? [AXUIElement] }
}
