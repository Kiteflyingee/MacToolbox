import Foundation

public struct TranslationSettings: Codable, Equatable, Sendable {
    public let endpointInput: String
    public let model: String
    public let keyReference: UUID?
    public let revision: UInt64

    public init(endpointInput: String, model: String, keyReference: UUID?, revision: UInt64) throws {
        let endpoint = try ChatEndpoint(endpointInput)
        guard revision > 0 else { throw CoreError.invalidContent }
        guard keyReference != nil || endpoint.origin.isLoopback else { throw TranslationError.missingKey }
        self.endpointInput = endpointInput.trimmingCharacters(in: .whitespacesAndNewlines)
        self.model = try ChatRequestBuilder.validateModel(model)
        self.keyReference = keyReference; self.revision = revision
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(endpointInput: values.decode(String.self, forKey: .endpointInput),
                      model: values.decode(String.self, forKey: .model),
                      keyReference: values.decodeIfPresent(UUID.self, forKey: .keyReference),
                      revision: values.decode(UInt64.self, forKey: .revision))
    }
}

public struct ConfiguredTranslationService: Sendable {
    public let endpoint: ChatEndpoint
    public let model: String
    public let key: SecretKey?
    public let settingsRevision: UInt64
}

public enum KeyChoice: Sendable {
    case provided(SecretKey)
    /// Bind consent to the actual destination, so editing the host again cannot reuse a stale checkbox.
    case saved(confirmedOrigin: ServiceOrigin?)
    case none
}

public enum SettingsError: Error, Equatable, Sendable { case notConfigured, busy }

public actor TranslationSettingsStore {
    private let fileURL: URL
    private let secrets: any SecretStore
    public private(set) var current: TranslationSettings?
    private var isMutating = false
    private var startupCleanupAllowed = true

    public init(directory: URL, secrets: any SecretStore) throws {
        guard directory.isFileURL else { throw CoreError.invalidContent }
        fileURL = directory.appendingPathComponent("translation-settings.json")
        self.secrets = secrets
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let values = try fileURL.resourceValues(forKeys: [.fileSizeKey])
            guard (values.fileSize ?? Int.max) <= 32_768 else { throw CoreError.contentTooLarge }
            current = try JSONDecoder().decode(TranslationSettings.self, from: Data(contentsOf: fileURL))
        }
    }

    /// Used for BOTH save and the explicit connection-test button.
    public func resolveDraft(endpointInput: String, model: String, keyChoice: KeyChoice) async throws -> ConfiguredTranslationService {
        let resolved = try await resolve(endpointInput: endpointInput, model: model, keyChoice: keyChoice, previous: current)
        return resolved.service
    }

    @discardableResult
    public func save(endpointInput: String, model: String, keyChoice: KeyChoice) async throws -> TranslationSettings {
        guard !isMutating else { throw SettingsError.busy }
        isMutating = true
        startupCleanupAllowed = false
        defer { isMutating = false }
        let previous = current
        let resolved = try await resolve(endpointInput: endpointInput, model: model, keyChoice: keyChoice, previous: previous)
        guard (previous?.revision ?? 0) < UInt64.max else { throw CoreError.invalidContent }
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        var reference = resolved.savedReference
        if case .provided(let key) = keyChoice {
            let newReference = UUID()
            try await secrets.add(key, reference: newReference)
            reference = newReference
        }
        let settings = try TranslationSettings(endpointInput: endpointInput, model: resolved.service.model,
            keyReference: reference, revision: (previous?.revision ?? 0) + 1)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // No Key deletion here, including on write failure. Startup cleanup is the safe boundary.
        try encoder.encode(settings).write(to: fileURL, options: .atomic)
        current = settings
        startupCleanupAllowed = false
        return settings
    }

    public func configuredService() async throws -> ConfiguredTranslationService {
        guard let current else { throw SettingsError.notConfigured }
        return try await resolve(endpointInput: current.endpointInput, model: current.model,
            keyChoice: current.keyReference == nil ? .none : .saved(confirmedOrigin: nil), previous: current).service
    }

    public func authorizeSavedKey() async throws -> ContentDigest? {
        guard !isMutating else { throw SettingsError.busy }
        guard let previous = current,let reference = previous.keyReference else { throw SettingsError.notConfigured }
        isMutating = true
        defer { isMutating = false }
        let key = try await secrets.authorize(reference)
        // Legacy items may still have partition IDs from early ad-hoc builds.
        // Reuse the existing atomic save transaction to create a current-owner
        // item. The old item is retained until a successful startup validates
        // the replacement; the credential never leaves this process.
        isMutating = false
        _ = try await save(endpointInput: previous.endpointInput,model: previous.model,keyChoice: .provided(key))
        return key.digest
    }

    /// Call at startup, before clipboard monitoring. Returns only an in-memory sensitive digest.
    public func validateStartupAndCollectUnusedKeys() async throws -> ContentDigest? {
        guard !isMutating else { throw SettingsError.busy }
        guard startupCleanupAllowed, let settings = current else { return nil }
        isMutating = true
        defer { isMutating = false }
        let resolved = try await resolve(endpointInput: settings.endpointInput, model: settings.model,
            keyChoice: settings.keyReference == nil ? .none : .saved(confirmedOrigin: nil), previous: settings)
        let references = try await secrets.references()
        for reference in references where reference != settings.keyReference { try await secrets.delete(reference) }
        startupCleanupAllowed = false
        return resolved.service.key?.digest
    }

    private func resolve(endpointInput: String, model: String, keyChoice: KeyChoice,
                         previous: TranslationSettings?) async throws -> (service: ConfiguredTranslationService, savedReference: UUID?) {
        let endpoint = try ChatEndpoint(endpointInput)
        let model = try ChatRequestBuilder.validateModel(model)
        let key: SecretKey?
        let savedReference: UUID?
        switch keyChoice {
        case .provided(let provided): key = provided; savedReference = nil
        case .none: key = nil; savedReference = nil
        case .saved(let confirmedOrigin):
            guard let previous, let reference = previous.keyReference else { throw SettingsError.notConfigured }
            let oldOrigin = try ChatEndpoint(previous.endpointInput).origin
            guard oldOrigin == endpoint.origin || confirmedOrigin == endpoint.origin else { throw TranslationError.newOriginNeedsConfirmation }
            key = try await secrets.load(reference)
            savedReference = reference
        }
        guard key != nil || endpoint.origin.isLoopback else { throw TranslationError.missingKey }
        return (ConfiguredTranslationService(endpoint: endpoint, model: model, key: key,
                                             settingsRevision: previous?.revision ?? 0), savedReference)
    }
}
