import Foundation

public struct TextPayload: Codable, Equatable, Sendable {
    public var plain: String
    public var rtf: Data?
    public var html: Data?

    public init(plain: String, rtf: Data? = nil, html: Data? = nil) {
        self.plain = plain
        self.rtf = rtf
        self.html = html
    }

    public var byteCount: Int { plain.utf8.count + (rtf?.count ?? 0) + (html?.count ?? 0) }
    public var plainDigest: ContentDigest { ContentDigest(data: Data(plain.utf8)) }
}

public struct FileReference: Codable, Equatable, Sendable {
    public let originalURL: URL
    public var bookmark: Data?
    public let displayName: String

    public init(url: URL, bookmark: Data? = nil) throws {
        guard Self.isSupportedURL(url) else { throw CoreError.invalidContent }
        originalURL = url.standardizedFileURL // Does not resolve symbolic links.
        self.bookmark = bookmark
        displayName = url.lastPathComponent
    }

    static func isSupportedURL(_ url: URL) -> Bool {
        url.isFileURL && url.baseURL == nil && url.path.hasPrefix("/") &&
        url.query == nil && url.fragment == nil && url.user == nil && url.password == nil
    }
}

public struct ImagePayload: Codable, Equatable, Sendable {
    public let png: Data
    public let width: Int
    public let height: Int
    public let pixelDigest: ContentDigest
    public let thumbnail: Data?

    /// The image normalizer supplies the digest of canonical sRGB RGBA pixels.
    public init(png: Data, width: Int, height: Int, pixelDigest: ContentDigest, thumbnail: Data? = nil) throws {
        guard width > 0, height > 0, width <= AppLimits.imagePixels / height,
              !png.isEmpty, png.count <= AppLimits.imageBytes,
              (thumbnail?.count ?? 0) <= AppLimits.textBytes else { throw CoreError.contentTooLarge }
        self.png = png
        self.width = width
        self.height = height
        self.pixelDigest = pixelDigest
        self.thumbnail = thumbnail
    }
}

public enum UnavailableReason: String, Codable, Sendable {
    case tooLarge, unsupported, providerFailed
}

public enum ClipboardContent: Codable, Equatable, Sendable {
    case text(TextPayload)
    case image(ImagePayload)
    case files([FileReference])
    case unavailable(UnavailableReason, summary: String)

    public var kind: String {
        switch self {
        case .text: "text"
        case .image: "image"
        case .files: "files"
        case .unavailable: "unavailable"
        }
    }

    public var summary: String {
        switch self {
        case .text(let value): String(value.plain.prefix(160))
        case .image(let value): "图片 \(value.width)×\(value.height)"
        case .files(let values): values.count == 1 ? (values.first?.displayName ?? "文件") : "\(values.count) 个文件或文件夹"
        case .unavailable(_, let summary): String(summary.prefix(160))
        }
    }

    public var byteCount: Int {
        switch self {
        case .text(let value): value.byteCount
        case .image(let value): value.png.count + (value.thumbnail?.count ?? 0)
        case .files(let values): values.reduce(0) { $0 + $1.originalURL.absoluteString.utf8.count + ($1.bookmark?.count ?? 0) }
        case .unavailable(_, let summary): summary.utf8.count
        }
    }

    public var externalOrigin: ClipboardOrigin {
        switch self {
        case .text: .externalText
        case .image: .externalImage
        case .files: .externalFiles
        case .unavailable: .externalUnsupported
        }
    }

    public var fingerprint: ContentDigest {
        let tag = Data(kind.utf8)
        switch self {
        case .text(let value):
            return .parts([tag, Data(value.plain.utf8), value.rtf ?? Data(), value.html ?? Data()])
        case .image(let value):
            return .parts([tag, Data("\(value.width)x\(value.height)".utf8), Data(value.pixelDigest.hex.utf8)])
        case .files(let values):
            return .parts([tag] + values.map(\.originalURL.absoluteString).sorted().map { Data($0.utf8) })
        case .unavailable(let reason, let summary):
            return .parts([tag, Data(reason.rawValue.utf8), Data(summary.utf8)])
        }
    }

    public func validate() throws {
        switch self {
        case .text(let value):
            guard value.byteCount <= AppLimits.textBytes else { throw CoreError.contentTooLarge }
        case .image(let value):
            _ = try ImagePayload(png: value.png, width: value.width, height: value.height,
                                 pixelDigest: value.pixelDigest, thumbnail: value.thumbnail)
        case .files(let values):
            guard !values.isEmpty, values.count <= AppLimits.fileCount,
                  byteCount <= AppLimits.textBytes else { throw CoreError.contentTooLarge }
            guard values.allSatisfy({ FileReference.isSupportedURL($0.originalURL) }) else {
                throw CoreError.invalidContent
            }
        case .unavailable(_, let summary):
            guard summary.utf8.count <= 1_024 else { throw CoreError.contentTooLarge }
        }
    }
}

public struct ClipboardSnapshot: Codable, Equatable, Sendable {
    public let id: UUID
    public let observedSequence: Int64
    public let observedChangeCount: Int
    public let observedAt: Date
    public let frontmostAppHint: String?
    public let content: ClipboardContent
    public var fingerprint: ContentDigest { content.fingerprint }

    public init(id: UUID = UUID(), sequence: Int64, changeCount: Int, observedAt: Date = Date(),
                frontmostAppHint: String? = nil, content: ClipboardContent) throws {
        guard sequence > 0, observedAt.timeIntervalSince1970.isFinite else { throw CoreError.invalidContent }
        guard (frontmostAppHint?.utf8.count ?? 0) <= 1_024 else { throw CoreError.contentTooLarge }
        try content.validate()
        self.id = id
        observedSequence = sequence
        observedChangeCount = changeCount
        self.observedAt = observedAt
        self.frontmostAppHint = frontmostAppHint
        self.content = content
    }
}

/// Intentionally has no cut/move field. Every replay is ordinary copying.
public struct HistoryEntry: Equatable, Sendable {
    public let snapshot: ClipboardSnapshot
    public var canReplay: Bool {
        if case .unavailable = snapshot.content { return false }
        return true
    }
}

public struct HistorySummary: Equatable, Sendable {
    public let id: UUID
    public let sequence: Int64
    public let kind: String
    public let observedAt: Date
    public let summary: String
    public let thumbnail: Data?
    public let payloadBytes: Int
    public let status: String
}
