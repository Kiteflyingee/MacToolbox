import ApplicationServices
import Foundation

/// AX calls stay off the main thread; never synthesize Copy or read an entire field.
public actor SelectionReader {
    public init() {}
    public func selectedText(processID: Int32) -> String? {
        readSelection(processID: processID).text
    }
    /// `point` uses Accessibility's global top-left screen coordinates.
    public func readSelection(processID: Int32,at point: CGPoint? = nil) -> (text: String?, status: String) {
        guard processID != ProcessInfo.processInfo.processIdentifier else { return (nil, "own-process") }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.075)
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(450))
        var roots: [SelectionElement] = []
        // Scope hit-testing to the source app, never another app's popup.
        if let point,point.x.isFinite,point.y.isFinite {
            var hit: AXUIElement?
            if AXUIElementCopyElementAtPosition(application,Float(point.x),Float(point.y),&hit) == .success,let hit {
                roots.append(SelectionElement(value: hit))
            }
        }
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        if result == .success,let focused,CFGetTypeID(focused) == AXUIElementGetTypeID() {
            roots.append(SelectionElement(value: unsafeDowncast(focused,to: AXUIElement.self)))
        }
        guard !roots.isEmpty else { return (nil,"focused-element:\(result.rawValue)") }
        // Scoped AX queries may return embedded content hosted by another PID.
        // Approve only those roots' PIDs and the source app, never a global hit-test.
        var sourcePIDs: Set<Int32> = [processID]
        for root in roots {
            var pid: pid_t = 0
            if AXUIElementGetPid(root.value,&pid) == .success,pid > 0,pid != ProcessInfo.processInfo.processIdentifier { sourcePIDs.insert(pid) }
        }
        let access = NativeSelectionAccess(sourcePIDs: sourcePIDs,deadline: deadline)
        let outcome = SelectionTextSearch.read(roots: roots,access: access)
        #if DEBUG
        if outcome.status == "no-selected-text",access.isAvailable {
            let roles = roots.compactMap { access.role(of: $0) }
            return (nil,"no-selected-text[\(roles.joined(separator: ","))]")
        }
        #endif
        return outcome
    }
}

private struct SelectionElement: Equatable {
    let value: AXUIElement
    static func == (lhs: Self,rhs: Self) -> Bool { CFEqual(lhs.value,rhs.value) }
}

private struct NativeSelectionAccess: SelectionTextAccess {
    let sourcePIDs: Set<Int32>
    let deadline: ContinuousClock.Instant
    var isAvailable: Bool { !Task.isCancelled && ContinuousClock.now < deadline }
    func belongsToSource(_ element: SelectionElement) -> Bool {
        var pid: pid_t = 0
        return isAvailable && AXUIElementGetPid(element.value,&pid) == .success && sourcePIDs.contains(pid)
    }
    func isSecure(_ element: SelectionElement) -> Bool {
        value(kAXSubroleAttribute,in: element) as? String == kAXSecureTextFieldSubrole
    }
    func parent(of element: SelectionElement) -> SelectionElement? {
        guard let parent = value(kAXParentAttribute,in: element),CFGetTypeID(parent) == AXUIElementGetTypeID() else { return nil }
        return SelectionElement(value: unsafeDowncast(parent,to: AXUIElement.self))
    }
    func selectedText(in element: SelectionElement) -> String? { value(kAXSelectedTextAttribute,in: element) as? String }
    func selectedMarkerText(in element: SelectionElement) -> String? {
        // Chromium/WebKit publish document selections as opaque text markers.
        // Pass only the current selected range back; never construct a document-wide range.
        guard let range = value("AXSelectedTextMarkerRange",in: element),isAvailable else { return nil }
        var text: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element.value,"AXStringForTextMarkerRange" as CFString,range,&text)
        return status == .success ? text as? String : nil
    }
    func role(of element: SelectionElement) -> String? { value(kAXRoleAttribute,in: element) as? String }
    func selectedRanges(in element: SelectionElement) -> [CFRange] {
        if let values = value(kAXSelectedTextRangesAttribute,in: element) as? [AnyObject],!values.isEmpty {
            let decoded = values.compactMap { decodeRange($0) }
            return values.count <= 4 && decoded.count == values.count ? decoded : []
        }
        if let range = value(kAXSelectedTextRangeAttribute,in: element),let decoded = decodeRange(range),decoded.length > 0 { return [decoded] }
        return []
    }
    func string(in element: SelectionElement,range: CFRange) -> String? {
        guard isAvailable else { return nil }
        var range = range
        guard let parameter = AXValueCreate(.cfRange,&range) else { return nil }
        var text: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(element.value,kAXStringForRangeParameterizedAttribute as CFString,parameter,&text)
        return status == .success ? text as? String : nil
    }
    private func value(_ attribute: String,in element: SelectionElement) -> CFTypeRef? {
        guard isAvailable else { return nil }
        AXUIElementSetMessagingTimeout(element.value,0.075)
        var result: CFTypeRef?
        return AXUIElementCopyAttributeValue(element.value,attribute as CFString,&result) == .success ? result : nil
    }
    private func decodeRange(_ value: CFTypeRef) -> CFRange? {
        guard CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        let value = unsafeDowncast(value,to: AXValue.self)
        guard AXValueGetType(value) == .cfRange else { return nil }
        var range = CFRange()
        return AXValueGetValue(value,.cfRange,&range) ? range : nil
    }
}
