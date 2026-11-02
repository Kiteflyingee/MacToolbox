import CoreGraphics
import Foundation

public enum TranslationOrigin: Equatable, Sendable {
    case clipboard(changeCount: Int)
    case selection(id: UUID)
    case screenshot(captureID: UUID, revision: UInt64)
    var isScreenshot: Bool {
        if case .screenshot = self { return true }
        return false
    }
}

public struct TranslationSnapshot: Equatable, Sendable {
    public let id: UUID
    public let origin: TranslationOrigin
    public let text: String
    public let anchor: CGPoint
}

public struct OCRTicket: Equatable, Sendable {
    public let id: UUID
    public let captureID: UUID
    public let revision: UInt64
    public let anchor: CGPoint
    public var origin: TranslationOrigin { .screenshot(captureID: captureID, revision: revision) }
}

public struct TranslationTicket: Equatable, Sendable {
    public let id: UUID
    public let snapshot: TranslationSnapshot
    public let settingsRevision: UInt64
    public let target: TargetLanguage
}

/// Pure identity/state contract. The App coordinator starts work ONLY from returned tickets.
/// After each event it cancels tasks whose IDs no longer equal activeRequest/activeOCR.
public struct TranslationStateMachine: Sendable {
    public enum Failure: Equatable, Sendable {
        case text(TranslationSnapshot, TargetLanguage, TranslationError)
        case ocr(OCRTicket, TranslationError)
    }
    public enum Phase: Equatable, Sendable {
        case hidden
        case button(TranslationSnapshot)
        case extracting(OCRTicket)
        case loading(TranslationTicket)
        case ready(TranslationTicket, TranslationResponse)
        case failure(Failure)
    }
    public private(set) var phase: Phase = .hidden
    private var clipboardVersion: Int?
    private var offeredVersion: Int?
    private var candidateEligible = false
    public init() {}

    public var activeRequest: TranslationTicket? {
        if case .loading(let ticket) = phase { return ticket }
        return nil
    }
    public var activeOCR: OCRTicket? {
        if case .extracting(let ticket) = phase { return ticket }
        return nil
    }
    public var currentOrigin: TranslationOrigin? {
        switch phase {
        case .hidden: nil
        case .button(let snapshot): snapshot.origin
        case .extracting(let ticket): ticket.origin
        case .loading(let ticket), .ready(let ticket, _): ticket.snapshot.origin
        case .failure(.text(let snapshot, _, _)): snapshot.origin
        case .failure(.ocr(let ticket, _)): ticket.origin
        }
    }

    public mutating func externalVersionChanged(_ changeCount: Int, allowsCandidates: Bool = true) {
        guard clipboardVersion != changeCount else { return }
        clipboardVersion = changeCount
        offeredVersion = nil
        if case .selection? = currentOrigin { candidateEligible = false; return }
        candidateEligible = allowsCandidates && currentOrigin?.isScreenshot != true
        if case .clipboard? = currentOrigin { phase = .hidden }
        // Screenshot OCR/network is independent of later external copies.
    }

    @discardableResult
    public mutating func offerClipboardText(_ text: String, changeCount: Int, anchor: CGPoint,
                                            allowsCandidates: Bool) -> TranslationSnapshot? {
        guard candidateEligible, allowsCandidates, currentOrigin?.isScreenshot != true,
              clipboardVersion == changeCount, offeredVersion != changeCount,
              anchor.x.isFinite, anchor.y.isFinite,
              text.utf8.count <= AppLimits.textBytes,
              text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        let snapshot = TranslationSnapshot(id: UUID(), origin: .clipboard(changeCount: changeCount), text: text, anchor: anchor)
        offeredVersion = changeCount
        phase = .button(snapshot) // Deliberately no network ticket here.
        return snapshot
    }

    public mutating func click(snapshotID: UUID, settingsRevision: UInt64, target: TargetLanguage) -> TranslationTicket? {
        guard case .button(let snapshot) = phase, snapshot.id == snapshotID else { return nil }
        return start(snapshot: snapshot, settingsRevision: settingsRevision, target: target)
    }

    @discardableResult
    public mutating func offerSelectionText(_ text: String, anchor: CGPoint, allowsCandidates: Bool) -> TranslationSnapshot? {
        guard allowsCandidates, currentOrigin?.isScreenshot != true,
              anchor.x.isFinite, anchor.y.isFinite,
              text.utf8.count <= AppLimits.textBytes,
              text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { return nil }
        candidateEligible = false
        let id = UUID()
        let snapshot = TranslationSnapshot(id: id, origin: .selection(id: id), text: text, anchor: anchor)
        phase = .button(snapshot)
        return snapshot
    }

    public mutating func beginScreenshot(captureID: UUID, revision: UInt64, anchor: CGPoint) -> OCRTicket {
        candidateEligible = false
        let ticket = OCRTicket(id: UUID(), captureID: captureID, revision: revision, anchor: anchor)
        phase = .extracting(ticket)
        return ticket
    }

    public mutating func completeOCR(_ ticket: OCRTicket, text: String, settingsRevision: UInt64,
                                    target: TargetLanguage) -> TranslationTicket? {
        guard activeOCR == ticket else { return nil }
        let snapshot = TranslationSnapshot(id: UUID(), origin: ticket.origin, text: text, anchor: ticket.anchor)
        return start(snapshot: snapshot, settingsRevision: settingsRevision, target: target)
    }

    @discardableResult
    public mutating func failOCR(_ ticket: OCRTicket, error: TranslationError) -> Bool {
        guard activeOCR == ticket else { return false }
        phase = .failure(.ocr(ticket, error))
        return true
    }

    public mutating func retryOCR(id: UUID) -> OCRTicket? {
        guard case .failure(.ocr(let old, _)) = phase, old.id == id else { return nil }
        return beginScreenshot(captureID: old.captureID, revision: old.revision, anchor: old.anchor)
    }

    @discardableResult
    public mutating func complete(_ ticket: TranslationTicket, response: TranslationResponse) -> Bool {
        guard activeRequest == ticket else { return false }
        phase = .ready(ticket, response)
        return true
    }

    @discardableResult
    public mutating func fail(_ ticket: TranslationTicket, error: TranslationError) -> Bool {
        guard activeRequest == ticket else { return false }
        phase = .failure(.text(ticket.snapshot, ticket.target, error))
        return true
    }

    public mutating func retry(snapshotID: UUID, settingsRevision: UInt64) -> TranslationTicket? {
        guard case .failure(.text(let snapshot, let target, _)) = phase, snapshot.id == snapshotID else { return nil }
        return start(snapshot: snapshot, settingsRevision: settingsRevision, target: target)
    }

    /// Changing the destination reuses the immutable source and invalidates the
    /// previous request, including a response that races with cancellation.
    public mutating func changeTarget(snapshotID: UUID, settingsRevision: UInt64,
                                      target: TargetLanguage) -> TranslationTicket? {
        let snapshot: TranslationSnapshot
        switch phase {
        case .button(let value): snapshot = value
        case .loading(let ticket), .ready(let ticket, _): snapshot = ticket.snapshot
        case .failure(.text(let value, _, _)): snapshot = value
        default: return nil
        }
        guard snapshot.id == snapshotID else { return nil }
        return start(snapshot: snapshot, settingsRevision: settingsRevision, target: target)
    }

    public mutating func expireButton(snapshotID: UUID) {
        if case .button(let snapshot) = phase, snapshot.id == snapshotID { close() }
    }

    public mutating func close() { phase = .hidden; candidateEligible = false }
    public mutating func settingsChanged() { close() }

    private mutating func start(snapshot: TranslationSnapshot, settingsRevision: UInt64,
                                target: TargetLanguage) -> TranslationTicket? {
        do { try ChatRequestBuilder.validateText(snapshot.text) }
        catch let error as TranslationError { phase = .failure(.text(snapshot, target, error)); return nil }
        catch { phase = .failure(.text(snapshot, target, .invalidResponse)); return nil }
        let ticket = TranslationTicket(id: UUID(), snapshot: snapshot, settingsRevision: settingsRevision, target: target)
        phase = .loading(ticket)
        return ticket
    }
}
