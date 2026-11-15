import Foundation

public enum AppLimits {
    public static let historyCount = 20
    public static let textBytes = 1_048_576
    public static let imageBytes = 16 * 1_048_576
    public static let imagePixels = 64_000_000
    public static let fileCount = 200
    public static let historyQueueCount = 4
    public static let historyQueueBytes = 64 * 1_048_576
    public static let translationCharacters = 20_000
    public static let translationRequestBytes = 128 * 1_024
    public static let translationResponseBytes = 2 * 1_048_576
    public static let annotationBytes = 1_048_576
    public static let annotationCount = 200
    public static let undoCount = 100
}

public enum CoreError: Error, Equatable, Sendable {
    case invalidContent
    case contentTooLarge
    case invalidGeometry
    case unsupportedVersion
    case sequenceOutOfOrder
    case queueFull
    case historySuspended
}
