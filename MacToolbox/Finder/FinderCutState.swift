import Foundation

public struct FinderFocusSnapshot: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case fileArea, text, unknown }
    public let pid: Int32
    public let kind: Kind
    public let selectedURLs: [URL]
    public let selectedFileDigest: ContentDigest?
    public let generation: UInt64
    public let sampledAt: TimeInterval

    public init(pid: Int32, kind: Kind, selectedURLs: [URL], generation: UInt64, sampledAt: TimeInterval) {
        self.pid = pid; self.kind = kind; self.selectedURLs = selectedURLs
        // Constructed by the AX sampler, never inside the event-tap callback.
        selectedFileDigest = FinderCutState.fileDigest(selectedURLs)
        self.generation = generation; self.sampledAt = sampledAt
    }
}

public struct FinderInputContext: Sendable {
    public var focus: FinderFocusSnapshot?
    public var currentGeneration: UInt64
    public var finderIsFrontmost: Bool
    public var frontmostPID: Int32?
    public var ownInteractionActive: Bool
    public var inputPermissionAvailable: Bool
    public var secureInput: Bool
    public var uptime: TimeInterval

    public init(focus: FinderFocusSnapshot?, generation: UInt64, finderIsFrontmost: Bool, frontmostPID: Int32? = nil,
                ownInteractionActive: Bool, inputPermissionAvailable: Bool,
                secureInput: Bool, uptime: TimeInterval) {
        self.focus = focus; currentGeneration = generation
        self.finderIsFrontmost = finderIsFrontmost; self.frontmostPID = frontmostPID ?? focus?.pid
        self.ownInteractionActive = ownInteractionActive
        self.inputPermissionAvailable = inputPermissionAvailable; self.secureInput = secureInput; self.uptime = uptime
    }

    var safeFileFocus: FinderFocusSnapshot? {
        guard let focus, allowsBridge(for: focus.pid), focus.kind == .fileArea, focus.generation == currentGeneration,
              uptime.isFinite, focus.sampledAt.isFinite,
              uptime >= focus.sampledAt, uptime - focus.sampledAt <= 0.150 else { return nil }
        return focus
    }

    func allowsBridge(for pid: Int32) -> Bool {
        finderIsFrontmost && frontmostPID == pid && !ownInteractionActive &&
        inputPermissionAvailable && !secureInput && uptime.isFinite && uptime >= 0
    }
}

/// Never Codable: a cut intent must not survive persistence or history replay.
public struct FinderCutState: Equatable, Sendable {
    public struct PendingCopy: Equatable, Sendable {
        public let id: UUID
        public let pid: Int32
        public let fileDigest: ContentDigest
        public let oldChangeCount: Int
        public let deadline: TimeInterval
    }
    public struct CutToken: Equatable, Sendable {
        public let id: UUID
        public let pid: Int32
        public let fileDigest: ContentDigest
        public let boundChangeCount: Int
    }
    public enum Phase: Equatable, Sendable {
        case idle, awaitingCopy(PendingCopy), ready(CutToken)
    }
    public private(set) var phase: Phase = .idle

    public init() {}

    public mutating func beginCut(context: FinderInputContext, changeCount: Int) -> Bool {
        phase = .idle
        guard let focus = context.safeFileFocus,
              let digest = focus.selectedFileDigest else { return false }
        phase = .awaitingCopy(PendingCopy(id: UUID(), pid: focus.pid, fileDigest: digest,
                                          oldChangeCount: changeCount, deadline: context.uptime + 1))
        return true
    }

    /// Returns true only when this observation is the expected Finder bridge copy.
    public mutating func observe(changeCount: Int, fileURLs: [URL]?, context: FinderInputContext) -> Bool {
        switch phase {
        case .idle: return false
        case .ready(let token):
            if changeCount != token.boundChangeCount || !context.allowsBridge(for: token.pid) { phase = .idle }
            return false
        case .awaitingCopy(let pending):
            // Source identity was captured before Copy. Window navigation can temporarily
            // invalidate AX focus while Finder is still fulfilling that same copy.
            guard context.allowsBridge(for: pending.pid), context.uptime <= pending.deadline else {
                phase = .idle
                return false
            }
            if changeCount == pending.oldChangeCount { return false }
            guard let fileURLs, Self.fileDigest(fileURLs) == pending.fileDigest else {
                phase = .idle
                return false
            }
            phase = .ready(CutToken(id: pending.id, pid: pending.pid, fileDigest: pending.fileDigest,
                                    boundChangeCount: changeCount))
            return true
        }
    }

    /// Consumes the token before returning the native Finder move decision.
    public mutating func consumeForPaste(context: FinderInputContext, changeCount: Int) -> Bool {
        defer { phase = .idle }
        guard case .ready(let token) = phase, context.safeFileFocus?.pid == token.pid,
              changeCount == token.boundChangeCount else { return false }
        return true
    }

    public mutating func invalidate() { phase = .idle }

    public static func fileDigest(_ urls: [URL]) -> ContentDigest? {
        guard !urls.isEmpty, urls.count <= AppLimits.fileCount, urls.allSatisfy(FileReference.isSupportedURL),
              urls.reduce(0, { $0 + $1.absoluteString.utf8.count }) <= AppLimits.textBytes else { return nil }
        // AX file URLs mark folders with a trailing slash; Finder's pasteboard may omit it.
        return .parts(urls.map { url in
            let host = url.host?.lowercased() ?? ""
            return Data(((host == "localhost" ? "" : host)+"\0"+url.standardizedFileURL.path).utf8)
        }.sorted { $0.lexicographicallyPrecedes($1) })
    }
}

public struct KeyModifiers: OptionSet, Equatable, Sendable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1)
    public static let option = KeyModifiers(rawValue: 2)
    public static let shift = KeyModifiers(rawValue: 4)
    public static let control = KeyModifiers(rawValue: 8)
}

/// Pure decision logic; no event tap is installed by this type.
public struct FinderKeyboardState: Sendable {
    public enum Key: Hashable, Sendable { case x, c, v, other }
    public enum Decision: Equatable, Sendable {
        case pass, drop, rewrite(Key, KeyModifiers)
    }
    private enum Mapping: Sendable { case copy, move }
    private var held: [Key: Mapping] = [:]
    public private(set) var cut = FinderCutState()

    public init() {}

    public mutating func keyDown(_ key: Key, modifiers: KeyModifiers, repeat isRepeat: Bool,
                                 context: FinderInputContext, changeCount: Int) -> Decision {
        if held[key] != nil { return .drop }
        guard !isRepeat else { return .pass }
        guard modifiers == .command else {
            // Native Option-Command-V / copy-path shortcuts keep their meaning,
            // but cannot leave a second pending move behind.
            if modifiers.contains(.command), [.x, .c, .v].contains(key) { cut.invalidate() }
            return .pass
        }
        if key == .c { cut.invalidate(); return .pass }
        if key == .x {
            guard cut.beginCut(context: context, changeCount: changeCount) else { return .pass }
            held[key] = .copy
            return .rewrite(.c, modifiers)
        }
        if key == .v, cut.consumeForPaste(context: context, changeCount: changeCount) {
            held[key] = .move
            return .rewrite(.v, modifiers.union(.option))
        }
        return .pass
    }

    public mutating func keyUp(_ key: Key, modifiers: KeyModifiers) -> Decision {
        guard let mapping = held.removeValue(forKey: key) else { return .pass }
        switch mapping {
        case .copy: return .rewrite(.c, modifiers)
        case .move: return .rewrite(.v, modifiers.union(.option))
        }
    }

    public mutating func observe(changeCount: Int, fileURLs: [URL]?, context: FinderInputContext) -> Bool {
        cut.observe(changeCount: changeCount, fileURLs: fileURLs, context: context)
    }

    public mutating func invalidate() { cut.invalidate() }
    public mutating func tapDisabled() { cut.invalidate(); held.removeAll() }
}
