import Foundation
import Security
import Testing
import MacToolboxKeychainCompatibility
@testable import MacToolboxCore

@Test func legacyKeychainBackgroundReadsCannotPresentAuthorizationUI() async throws {
    let store = try KeychainStore(service: "local.mactoolbox.smoke.missing.\(UUID())")
    #expect(MacToolboxKeychainInteractionAllowed() == 0)
    // A fresh service/account pair cannot match any real saved credential.
    do {
        _ = try await store.load(UUID())
        Issue.record("An absent test credential unexpectedly existed")
    } catch let error as KeychainError {
        #expect(error.status == errSecItemNotFound)
    }
    #expect(MacToolboxKeychainInteractionAllowed() == 0)
}
