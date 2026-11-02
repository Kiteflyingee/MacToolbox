import Foundation

/// This boundary exposes selections only, deliberately excluding a field's full value.
protocol SelectionTextAccess {
    associatedtype Element: Equatable
    var isAvailable: Bool { get }
    func belongsToSource(_ element: Element) -> Bool
    func isSecure(_ element: Element) -> Bool
    func parent(of element: Element) -> Element?
    func selectedText(in element: Element) -> String?
    func selectedMarkerText(in element: Element) -> String?
    func selectedRanges(in element: Element) -> [CFRange]
    func string(in element: Element,range: CFRange) -> String?
}

enum SelectionTextSearch {
    static func read<Access: SelectionTextAccess>(roots: [Access.Element],access: Access) -> (text: String?,status: String) {
        var nodes: [Access.Element] = []
        // Check both paths for protected fields before requesting any text.
        for root in roots.prefix(2) {
            var current: Access.Element? = root
            for _ in 0..<8 {
                guard access.isAvailable else { return (nil,"cancelled-or-timeout") }
                guard let node = current,!nodes.contains(node),access.belongsToSource(node) else { break }
                if access.isSecure(node) { return (nil,"secure-field") }
                nodes.append(node); current = access.parent(of: node)
            }
        }
        for node in nodes {
            guard access.isAvailable else { return (nil,"cancelled-or-timeout") }
            if let text = access.selectedText(in: node),valid(text),access.isAvailable { return (text,"selected-text") }
            if let text = access.selectedMarkerText(in: node),valid(text),access.isAvailable { return (text,"selected-marker") }
            let ranges = access.selectedRanges(in: node)
            guard !ranges.isEmpty,ranges.count <= 4,ranges.allSatisfy(validRange) else { continue }
            var parts: [String] = [],bytes = 0
            for range in ranges {
                guard access.isAvailable else { return (nil,"cancelled-or-timeout") }
                guard let part = access.string(in: node,range: range),valid(part) else { parts = []; break }
                bytes += part.utf8.count+(parts.isEmpty ? 0 : 1)
                guard bytes <= AppLimits.textBytes else { parts = []; break }
                parts.append(part)
            }
            if parts.count == ranges.count,access.isAvailable { return (parts.joined(separator: "\n"),"selected-range") }
        }
        return (nil,"no-selected-text")
    }

    private static func valid(_ text: String) -> Bool { !text.isEmpty && text.utf8.count <= AppLimits.textBytes }
    private static func validRange(_ range: CFRange) -> Bool {
        range.location >= 0 && range.length > 0 && range.length <= AppLimits.textBytes &&
            !range.location.addingReportingOverflow(range.length).overflow
    }
}
