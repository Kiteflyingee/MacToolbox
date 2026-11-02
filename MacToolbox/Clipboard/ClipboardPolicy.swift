import Foundation

public enum ClipboardOrigin: String, Codable, CaseIterable, Sendable {
    case externalText, externalImage, externalFiles, externalUnsupported
    case finderBridge, historyReplay, screenshotExport, colorCopy
    case translationResultCopy, ownTextCopy, annotationCopy

    public var isOwnWrite: Bool {
        switch self {
        case .externalText, .externalImage, .externalFiles, .externalUnsupported, .finderBridge: false
        default: true
        }
    }

    public var recordsHistory: Bool {
        self != .historyReplay && self != .annotationCopy
    }

    public var offersTranslation: Bool { self == .externalText }
}

public struct WriteReceipt: Equatable, Sendable {
    public let id: UUID
    public let origin: ClipboardOrigin
    public let finalChangeCount: Int
    public let fingerprint: ContentDigest

    public init(id: UUID = UUID(), origin: ClipboardOrigin, finalChangeCount: Int, fingerprint: ContentDigest) throws {
        guard origin.isOwnWrite else { throw CoreError.invalidContent }
        self.id = id
        self.origin = origin
        self.finalChangeCount = finalChangeCount
        self.fingerprint = fingerprint
    }
}

/// Bookkeeping only. The future MainActor broker owns the actual pasteboard.
public struct ClipboardLedger: Sendable {
    private var receipts: [WriteReceipt] = []
    private var sequence: Int64

    public init(lastSequence: Int64 = 0) { sequence = lastSequence }

    public mutating func nextSequence() throws -> Int64 {
        guard sequence < Int64.max else { throw CoreError.sequenceOutOfOrder }
        sequence += 1
        return sequence
    }

    public mutating func register(_ receipt: WriteReceipt) {
        receipts.removeAll { $0.id == receipt.id }
        receipts.append(receipt)
        if receipts.count > 8 { receipts.removeFirst(receipts.count - 8) }
    }

    public func ownOrigin(changeCount: Int, fingerprint: ContentDigest, markerID: UUID?) -> ClipboardOrigin? {
        receipts.last {
            $0.id == markerID && $0.finalChangeCount == changeCount && $0.fingerprint == fingerprint
        }?.origin
    }
}
