import Foundation
import LocalAuthentication
import Security
import MacToolboxKeychainCompatibility

/// Two implementations: the system Keychain and an in-memory test store.
/// This is the only credential I/O boundary; no provider registry is involved.
public protocol SecretStore: Sendable {
    func add(_ key: SecretKey, reference: UUID) async throws
    func load(_ reference: UUID) async throws -> SecretKey
    func authorize(_ reference: UUID) async throws -> SecretKey
    func delete(_ reference: UUID) async throws
    func references() async throws -> [UUID]
}

public extension SecretStore {
    func authorize(_ reference: UUID) async throws -> SecretKey { try await load(reference) }
}

public struct KeychainError: Error, Equatable, Sendable {
    public let status: OSStatus
    public init(status: OSStatus) { self.status = status }
}

public actor KeychainStore: SecretStore {
    private let service: String
    private var cache: [UUID: SecretKey] = [:]
    public init(service: String) throws {
        guard !service.isEmpty, service.utf8.count <= 1_024 else { throw CoreError.invalidContent }
        self.service = service
        let status = MacToolboxSetKeychainInteractionAllowed(false)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    private var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrSynchronizable as String: false]
    }

    public func add(_ key: SecretKey, reference: UUID) throws {
        var attributes = base
        attributes[kSecAttrAccount as String] = reference.uuidString
        attributes[kSecValueData as String] = key.data
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        cache[reference] = key
    }

    public func load(_ reference: UUID) throws -> SecretKey {
        if let key = cache[reference] { return key }
        return try read(reference,allowsInteraction: false)
    }

    /// Only called by the explicit settings button. This never changes item ACLs;
    /// the person decides whether to grant access in the system dialog.
    public func authorize(_ reference: UUID) throws -> SecretKey {
        let status = MacToolboxSetKeychainInteractionAllowed(true)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        defer { _ = MacToolboxSetKeychainInteractionAllowed(false) }
        return try read(reference,allowsInteraction: true)
    }

    private func read(_ reference: UUID,allowsInteraction: Bool) throws -> SecretKey {
        var query = base
        query[kSecAttrAccount as String] = reference.uuidString
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        if !allowsInteraction { query[kSecUseAuthenticationContext as String] = noUIContext() }
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else { throw TranslationError.invalidKey }
        let key = try SecretKey(text)
        cache[reference] = key
        return key
    }

    public func delete(_ reference: UUID) throws {
        var query = base
        query[kSecAttrAccount as String] = reference.uuidString
        query[kSecUseAuthenticationContext as String] = noUIContext()
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        cache.removeValue(forKey: reference)
    }

    public func references() throws -> [UUID] {
        var query = base
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        query[kSecUseAuthenticationContext as String] = noUIContext()
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
        guard let attributes = result as? [[String: Any]] else { throw TranslationError.invalidKey }
        return attributes.compactMap { ($0[kSecAttrAccount as String] as? String).flatMap(UUID.init(uuidString:)) }
    }

    private func noUIContext() -> LAContext {
        let context = LAContext()
        context.interactionNotAllowed = true
        return context
    }
}
