import CryptoKit
import Foundation

public struct ContentDigest: Codable, Hashable, Sendable {
    public let hex: String

    public init(data: Data) {
        hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        guard value.count == 64, value.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw CoreError.invalidContent
        }
        hex = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(hex)
    }

    /// Length prefixes distinguish ["ab", "c"] from ["a", "bc"].
    static func parts(_ parts: [Data]) -> ContentDigest {
        var hash = SHA256()
        for part in parts {
            var length = UInt64(part.count).bigEndian
            withUnsafeBytes(of: &length) { hash.update(data: Data($0)) }
            hash.update(data: part)
        }
        return ContentDigest(bytes: hash.finalize())
    }

    private init(bytes: SHA256.Digest) {
        hex = bytes.map { String(format: "%02x", $0) }.joined()
    }
}
