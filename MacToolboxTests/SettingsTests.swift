import Darwin
import Foundation
import Testing
@testable import MacToolboxCore

private actor MemorySecrets: SecretStore {
    private var keys: [UUID: SecretKey] = [:]
    private var readsFail = false
    func add(_ key: SecretKey, reference: UUID) { keys[reference] = key }
    func load(_ reference: UUID) throws -> SecretKey {
        guard !readsFail, let key = keys[reference] else { throw KeychainError(status: -25293) }
        return key
    }
    func delete(_ reference: UUID) { keys[reference] = nil }
    func references() -> [UUID] { Array(keys.keys) }
    func failReads(_ value: Bool) { readsFail = value }
}

private func settingsDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-settings-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test func authorizationRecreatesLegacyReferenceWithoutChangingProviderOrSecret() async throws {
    let directory = try settingsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets(), key = try SecretKey("fake-migration-key")
    let store = try TranslationSettingsStore(directory: directory,secrets: secrets)
    let before = try await store.save(endpointInput: "https://example.com/v1",model: "existing-model",keyChoice: .provided(key))
    #expect(try await store.authorizeSavedKey() == key.digest)
    let value = await store.current
    let after = try #require(value)
    #expect(after.keyReference != before.keyReference)
    #expect(after.endpointInput == before.endpointInput && after.model == before.model)
    #expect(after.revision == before.revision+1)
    let reopened = try TranslationSettingsStore(directory: directory,secrets: secrets)
    #expect(try await reopened.configuredService().key?.digest == key.digest)
    #expect(try await reopened.validateStartupAndCollectUnusedKeys() == key.digest)
    #expect(await secrets.references() == [after.keyReference!])
    let data = try Data(contentsOf: directory.appendingPathComponent("translation-settings.json"))
    #expect(!String(decoding: data,as: UTF8.self).contains("fake-migration-key"))
}

@Test(.enabled(if: geteuid() != 0,"Requires normal-user filesystem permissions"))
func authorizationMigrationWriteFailurePreservesWorkingReferenceAndCredential() async throws {
    let directory = try settingsDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions:0o755],ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let secrets = MemorySecrets(), key = try SecretKey("fake-retained-key")
    let store = try TranslationSettingsStore(directory: directory,secrets: secrets)
    let before = try await store.save(endpointInput: "https://example.com/v1",model: "model",keyChoice: .provided(key))
    let file = directory.appendingPathComponent("translation-settings.json"), original = try Data(contentsOf: directory.appendingPathComponent("translation-settings.json"))
    try FileManager.default.setAttributes([.posixPermissions:0o555],ofItemAtPath: directory.path)
    await #expect(throws: (any Error).self) { try await store.authorizeSavedKey() }
    #expect(await store.current == before)
    #expect(try Data(contentsOf: file) == original)
    #expect(try await store.configuredService().key?.digest == key.digest)
    #expect(await secrets.references().count == 2)
}

@Test func settingsNeverPersistKeyAndNewOriginNeedsConfirmationIncludingDraftTest() async throws {
    let directory = try settingsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    let store = try TranslationSettingsStore(directory: directory, secrets: secrets)
    let first = try await store.save(endpointInput: "https://example.com/v1", model: "model", keyChoice: .provided(SecretKey("fake-first-key")))
    let data = try Data(contentsOf: directory.appendingPathComponent("translation-settings.json"))
    #expect(!String(decoding: data, as: UTF8.self).contains("fake-first-key"))
    #expect(first.revision == 1)
    await #expect(throws: TranslationError.newOriginNeedsConfirmation) {
        try await store.resolveDraft(endpointInput: "https://other.example/v1", model: "model", keyChoice: .saved(confirmedOrigin: nil))
    }
    await #expect(throws: TranslationError.newOriginNeedsConfirmation) {
        try await store.save(endpointInput: "https://other.example/v1", model: "model", keyChoice: .saved(confirmedOrigin: nil))
    }
    let consent = try ChatEndpoint("https://other.example/v1").origin
    await #expect(throws: TranslationError.newOriginNeedsConfirmation) {
        try await store.resolveDraft(endpointInput: "https://third.example/v1", model: "model", keyChoice: .saved(confirmedOrigin: consent))
    }
    let confirmed = try await store.save(endpointInput: "https://other.example/v1", model: "model", keyChoice: .saved(confirmedOrigin: consent))
    #expect(confirmed.keyReference == first.keyReference)
    #expect(confirmed.revision == 2)
    #expect(try await store.configuredService().key?.digest == SecretKey("fake-first-key").digest)
}

@Test(.enabled(if: geteuid() != 0, "Filesystem permission failure requires a normal user"))
func atomicWriteFailureKeepsDiskAndMemoryOldConfigAndOldKey() async throws {
    let directory = try settingsDirectory()
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let secrets = MemorySecrets()
    let store = try TranslationSettingsStore(directory: directory, secrets: secrets)
    let first = try await store.save(endpointInput: "https://example.com/v1", model: "old-model", keyChoice: .provided(SecretKey("old-fake-key")))
    let file = directory.appendingPathComponent("translation-settings.json")
    let before = try Data(contentsOf: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)
    await #expect(throws: (any Error).self) {
        try await store.save(endpointInput: "https://example.com/v1", model: "new-model", keyChoice: .provided(SecretKey("new-fake-key")))
    }
    #expect(await store.current == first)
    #expect(try Data(contentsOf: file) == before)
    #expect(await secrets.references().count == 2) // Failed new item is retained safely until restart.
    #expect(try await store.validateStartupAndCollectUnusedKeys() == nil) // No same-process GC.
    let reopened = try TranslationSettingsStore(directory: directory, secrets: secrets)
    #expect(try await reopened.validateStartupAndCollectUnusedKeys() == SecretKey("old-fake-key").digest)
    #expect(await secrets.references() == [first.keyReference!])
}

@Test func lockedKeychainAndCorruptConfigNeverGarbageCollectSecrets() async throws {
    let directory = try settingsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let secrets = MemorySecrets()
    let store = try TranslationSettingsStore(directory: directory, secrets: secrets)
    _ = try await store.save(endpointInput: "https://example.com/v1", model: "model", keyChoice: .provided(SecretKey("fake-key")))
    await secrets.add(try SecretKey("orphan"), reference: UUID())
    let reopened = try TranslationSettingsStore(directory: directory, secrets: secrets)
    await secrets.failReads(true)
    await #expect(throws: KeychainError.self) { try await reopened.validateStartupAndCollectUnusedKeys() }
    #expect(await secrets.references().count == 2)
    try Data("invalid-json".utf8).write(to: directory.appendingPathComponent("translation-settings.json"))
    #expect(throws: (any Error).self) { try TranslationSettingsStore(directory: directory, secrets: secrets) }
    #expect(await secrets.references().count == 2)
}

@Test func localModelCanOmitKeyButRemoteCannot() async throws {
    let directory = try settingsDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try TranslationSettingsStore(directory: directory, secrets: MemorySecrets())
    let local = try await store.save(endpointInput: "http://localhost:11434/v1", model: "local", keyChoice: .none)
    #expect(local.keyReference == nil)
    #expect(try await store.configuredService().key == nil)
    await #expect(throws: TranslationError.missingKey) {
        try await store.save(endpointInput: "https://remote.example/v1", model: "remote", keyChoice: .none)
    }
    #expect(await store.current == local)
}
