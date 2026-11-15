import Foundation
import Testing
@testable import MacToolboxCore

private final class SelectionFixture: SelectionTextAccess {
    struct Node {
        var parent: Int?
        var secure = false
        var sourceOwned = true
        var selected: String?
        var markerText: String?
        var ranges: [CFRange] = []
        var document = ""
    }
    var nodes: [Int: Node] = [:]
    var isAvailable = true
    var textReads: [Int] = []
    var rangeReads: [CFRange] = []
    var parentReads = 0
    var markerReads: [Int] = []
    var failRangeAt: Int?
    func belongsToSource(_ element: Int) -> Bool { nodes[element]?.sourceOwned == true }
    func isSecure(_ element: Int) -> Bool { nodes[element]?.secure == true }
    func parent(of element: Int) -> Int? { parentReads += 1; return nodes[element]?.parent }
    func selectedText(in element: Int) -> String? { textReads.append(element); return nodes[element]?.selected }
    func selectedMarkerText(in element: Int) -> String? { markerReads.append(element); return nodes[element]?.markerText }
    func selectedRanges(in element: Int) -> [CFRange] { nodes[element]?.ranges ?? [] }
    func string(in element: Int,range: CFRange) -> String? {
        rangeReads.append(range)
        guard rangeReads.count != failRangeAt,let node = nodes[element] else { return nil }
        let text = node.document as NSString
        guard range.location+range.length <= text.length else { return nil }
        return text.substring(with: NSRange(location: range.location,length: range.length))
    }
}

@Test func pointerSelectionWinsOverAnUnrelatedFocusedEditor() {
    let access = SelectionFixture()
    access.nodes = [1: .init(selected: "Selected webpage sentence"),2: .init(selected: "Old editor selection")]
    #expect(SelectionTextSearch.read(roots: [1,2],access: access).text == "Selected webpage sentence")
    #expect(access.textReads == [1])
}

@Test func selectionCanLiveBeyondTheFormerFourAncestorLimit() {
    let access = SelectionFixture()
    for id in 0..<6 { access.nodes[id] = .init(parent: id+1) }
    access.nodes[6] = .init(selected: "Selection on enclosing web area")
    #expect(SelectionTextSearch.read(roots: [0],access: access).text == "Selection on enclosing web area")
    #expect(access.parentReads == 7)
}

@Test func selectedRangesReturnOnlyTheSelectedUnicodeFragments() {
    let access = SelectionFixture(),document = "Unselected 🧭 Hello gap 中文 unselected tail" as NSString
    let first = document.range(of: "Hello"),second = document.range(of: "中文")
    access.nodes[1] = .init(ranges: [CFRange(location: first.location,length: first.length),CFRange(location: second.location,length: second.length)],document: document as String)
    let result = SelectionTextSearch.read(roots: [1],access: access)
    #expect(result.text == "Hello\n中文")
    #expect(result.status == "selected-range")
    #expect(access.rangeReads.count == 2)
    #expect(access.rangeReads[0].location == first.location)
    #expect(access.rangeReads[1].length == second.length)
}

@Test func protectedFocusOrAncestorBlocksAllTextReads() {
    for protectFocus in [true,false] {
        let access = SelectionFixture()
        access.nodes = [1: .init(parent: 3,selected: "must not read"),2: .init(secure: protectFocus),3: .init(secure: !protectFocus)]
        let result = SelectionTextSearch.read(roots: [1,2],access: access)
        #expect(result.text == nil)
        #expect(result.status == "secure-field")
        #expect(access.textReads.isEmpty)
        #expect(access.markerReads.isEmpty)
        #expect(access.rangeReads.isEmpty)
    }
}

@Test func selectionSearchRejectsOtherProcessesAndBoundsParentCycles() {
    let access = SelectionFixture()
    access.nodes = [1: .init(sourceOwned: false,selected: "other app"),2: .init(parent: 2,selected: "same app")]
    #expect(SelectionTextSearch.read(roots: [1,2],access: access).text == "same app")
    #expect(access.textReads == [2])
    #expect(access.parentReads == 1)
}

@Test func malformedSelectionRangesNeverRequestDocumentText() {
    for range in [CFRange(location: -1,length: 3),CFRange(location: 0,length: 0),CFRange(location: Int.max,length: 2),CFRange(location: 0,length: AppLimits.textBytes+1)] {
        let access = SelectionFixture()
        access.nodes[1] = .init(ranges: [range],document: "some private full document")
        #expect(SelectionTextSearch.read(roots: [1],access: access).text == nil)
        #expect(access.rangeReads.isEmpty)
    }
}

@Test func failedMultipleSelectionIsNotDeliveredAsAPartialResult() {
    let access = SelectionFixture()
    access.nodes[1] = .init(ranges: [CFRange(location: 0,length: 3),CFRange(location: 4,length: 3)],document: "one two")
    access.failRangeAt = 2
    #expect(SelectionTextSearch.read(roots: [1],access: access).text == nil)
}

@Test func unavailableSelectionSearchMakesNoAccessibilityQueries() {
    let access = SelectionFixture()
    access.nodes[1] = .init(selected: "obsolete selection")
    access.isAvailable = false
    #expect(SelectionTextSearch.read(roots: [1],access: access).text == nil)
    #expect(access.parentReads == 0)
    #expect(access.textReads.isEmpty)
}

@Test func browserTextMarkerSelectionWorksWithoutAnEditableTextRange() {
    let access = SelectionFixture()
    access.nodes[1] = .init(markerText: "Browser response selection")
    let result = SelectionTextSearch.read(roots: [1],access: access)
    #expect(result.text == "Browser response selection")
    #expect(result.status == "selected-marker")
    #expect(access.rangeReads.isEmpty)
}

@Test func emptyMarkerAtCaretDoesNotProduceATranslationCandidate() {
    let access = SelectionFixture()
    access.nodes[1] = .init(markerText: "")
    #expect(SelectionTextSearch.read(roots: [1],access: access).text == nil)
}
