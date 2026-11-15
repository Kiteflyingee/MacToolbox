import Foundation

public struct DocumentSnapshot: Equatable, Sendable {
    public let sessionID: UUID
    public let baseImageID: UUID
    public let revision: UInt64
    public let previewGeneration: UInt64?
    public let pixels: PixelSize
    public let annotations: [Annotation]
}

/// Value-only editor transactions. The base image remains in the future image worker.
public struct AnnotationDocument: Sendable {
    private struct Change: Sendable { let before: [Annotation]; let after: [Annotation] }
    public let sessionID: UUID
    public let baseImageID: UUID
    public private(set) var pixels: PixelSize
    public private(set) var annotations: [Annotation] = []
    public private(set) var revision: UInt64 = 0
    public private(set) var previewGeneration: UInt64 = 0
    private var draft: [Annotation]?
    private var undoStack: [Change] = []
    private var redoStack: [Change] = []
    public var canUndo: Bool { draft == nil && !undoStack.isEmpty }
    public var canRedo: Bool { draft == nil && !redoStack.isEmpty }
    public var hasDraft: Bool { draft != nil }

    public init(sessionID: UUID = UUID(), baseImageID: UUID, pixels: PixelSize) {
        self.sessionID = sessionID; self.baseImageID = baseImageID; self.pixels = pixels
    }

    public mutating func beginDraft() throws {
        guard draft == nil else { throw CoreError.invalidContent }
        draft = annotations
        previewGeneration += 1
    }

    public mutating func updateDraft(_ values: [Annotation]) throws {
        guard draft != nil else { throw CoreError.invalidContent }
        try Self.validate(values)
        draft = values
        previewGeneration += 1
    }

    public mutating func commitDraft() throws {
        guard let values = draft else { return }
        try Self.validate(values)
        draft = nil
        try replace(with: values)
    }

    public mutating func cancelDraft() {
        guard draft != nil else { return }
        draft = nil
        previewGeneration += 1
    }

    public mutating func replace(with values: [Annotation]) throws {
        guard draft == nil else { throw CoreError.invalidContent }
        try Self.validate(values)
        guard values != annotations else { return }
        guard revision < UInt64.max else { throw CoreError.invalidContent }
        undoStack.append(Change(before: annotations, after: values))
        if undoStack.count > AppLimits.undoCount { undoStack.removeFirst(undoStack.count - AppLimits.undoCount) }
        redoStack.removeAll()
        annotations = values
        revision += 1
    }

    /// A crop changes the coordinate origin, not the user's annotation history.
    /// Rebase every undo/redo value together so later undo remains meaningful.
    public mutating func reframe(pixels: PixelSize, translation: CGPoint) throws {
        guard draft == nil,revision < UInt64.max else { throw CoreError.invalidContent }
        guard translation.x.isFinite,translation.y.isFinite else { throw CoreError.invalidGeometry }
        func translated(_ values: [Annotation]) throws -> [Annotation] {
            let result = values.map { annotation in
                var copy = annotation
                copy.geometry = copy.geometry.translated(x: translation.x,y: translation.y)
                return copy
            }
            try Self.validate(result)
            return result
        }
        func rebased(_ changes: [Change]) throws -> [Change] {
            try changes.map { try Change(before: translated($0.before),after: translated($0.after)) }
        }
        let values = try translated(annotations), undo = try rebased(undoStack), redo = try rebased(redoStack)
        annotations = values; undoStack = undo; redoStack = redo; self.pixels = pixels
        revision += 1
    }

    @discardableResult
    public mutating func undo() -> Bool {
        guard draft == nil, let change = undoStack.popLast() else { return false }
        annotations = change.before
        redoStack.append(change)
        revision += 1
        return true
    }

    @discardableResult
    public mutating func redo() -> Bool {
        guard draft == nil, let change = redoStack.popLast() else { return false }
        annotations = change.after
        undoStack.append(change)
        revision += 1
        return true
    }

    public mutating func paste(_ data: Data) throws {
        let copies = try AnnotationClipboard.decodeForPaste(data)
        try replace(with: annotations + copies)
    }

    public func snapshot(includingDraft: Bool = false) -> DocumentSnapshot {
        DocumentSnapshot(sessionID: sessionID, baseImageID: baseImageID, revision: revision,
            previewGeneration: includingDraft && draft != nil ? previewGeneration : nil,
            pixels: pixels, annotations: includingDraft ? (draft ?? annotations) : annotations)
    }

    private static func validate(_ annotations: [Annotation]) throws {
        guard Set(annotations.map(\.id)).count == annotations.count else { throw CoreError.invalidContent }
        for annotation in annotations { try annotation.validate() }
    }
}

/// Keeps one in-flight render and replaces pending drag previews with the newest one.
public struct PreviewScheduler: Sendable {
    public private(set) var inFlight: DocumentSnapshot?
    private var latest: DocumentSnapshot?
    public init() {}

    public mutating func submit(_ snapshot: DocumentSnapshot) -> DocumentSnapshot? {
        if inFlight == nil { inFlight = snapshot; return snapshot }
        latest = snapshot
        return nil
    }

    public mutating func finish(_ snapshot: DocumentSnapshot) -> (display: Bool, next: DocumentSnapshot?) {
        guard inFlight == snapshot else { return (false, nil) }
        let display = latest == nil
        let next = latest
        latest = nil
        inFlight = next
        return (display, next)
    }

    public mutating func cancel() { inFlight = nil; latest = nil }
}
