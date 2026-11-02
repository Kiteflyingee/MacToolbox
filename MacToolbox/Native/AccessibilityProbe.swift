import ApplicationServices
import Foundation

public struct AccessibilityReport: Equatable, Sendable {
    public let trustedFlag: Bool
    public let apiResult: Int32
    public var canRead: Bool { apiResult == AXError.success.rawValue || (trustedFlag && apiResult != AXError.apiDisabled.rawValue) }
    public init(trustedFlag: Bool, apiResult: Int32) { self.trustedFlag = trustedFlag; self.apiResult = apiResult }
}

public actor AccessibilityProbe {
    public init() {}
    public func check(processID: Int32?) -> AccessibilityReport {
        let trusted = AXIsProcessTrusted()
        // In-process AX calls can synchronously enter AppKit on this actor's thread.
        // Never probe our own UI from a background executor.
        guard let processID, processID != ProcessInfo.processInfo.processIdentifier else {
            return AccessibilityReport(trustedFlag: trusted, apiResult: AXError.noValue.rawValue)
        }
        let application = AXUIElementCreateApplication(processID)
        AXUIElementSetMessagingTimeout(application, 0.15)
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(application, kAXFocusedUIElementAttribute as CFString, &focused)
        return AccessibilityReport(trustedFlag: trusted, apiResult: result.rawValue)
    }
}
