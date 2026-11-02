// A local development identity stays in the login keychain across builds. No root trust changes.
import CryptoKit
import Foundation
import Security

let identityName = "MacToolbox Local Development"
func check(_ status: OSStatus) throws {
    guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
}
func existingIdentity() throws -> String? {
    var value: CFTypeRef?
    let status = SecItemCopyMatching([kSecClass: kSecClassIdentity, kSecReturnRef: true,
        kSecMatchLimit: kSecMatchLimitAll] as CFDictionary, &value)
    if status == errSecItemNotFound { return nil }
    try check(status)
    for identity in value as? [SecIdentity] ?? [] {
        var certificate: SecCertificate?
        try check(SecIdentityCopyCertificate(identity, &certificate))
        guard let certificate, SecCertificateCopySubjectSummary(certificate) as String? == identityName else { continue }
        return Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
    }
    return nil
}
func openssl(_ arguments: [String], directory: URL, input: Data? = nil) throws {
    let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
    process.arguments = arguments; process.currentDirectoryURL = directory
    process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
    let pipe = Pipe(); process.standardInput = pipe
    try process.run()
    if let input { pipe.fileHandleForWriting.write(input) }
    try pipe.fileHandleForWriting.close(); process.waitUntilExit()
    guard process.terminationStatus == 0 else { throw NSError(domain: "LocalSigning", code: Int(process.terminationStatus)) }
}
do {
    if let identity = try existingIdentity() { print(identity); exit(0) }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MacToolbox-signing-"+UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let config = """
    [req]
    distinguished_name=subject
    x509_extensions=extensions
    prompt=no
    [subject]
    CN=MacToolbox Local Development
    OU=local.devkite.MacToolbox
    [extensions]
    basicConstraints=critical,CA:FALSE
    keyUsage=critical,digitalSignature
    extendedKeyUsage=critical,codeSigning
    """
    try config.write(to: directory.appendingPathComponent("certificate.cnf"), atomically: true, encoding: .utf8)
    try openssl(["req", "-new", "-x509", "-newkey", "rsa:3072", "-nodes", "-days", "3650", "-sha256",
        "-config", "certificate.cnf", "-keyout", "private.pem", "-out", "certificate.pem"], directory: directory)
    let temporaryPassphrase = UUID().uuidString + UUID().uuidString
    try openssl(["pkcs12", "-export", "-inkey", "private.pem", "-in", "certificate.pem", "-out", "identity.p12",
        "-passout", "stdin"], directory: directory, input: Data((temporaryPassphrase+"\n").utf8))
    var trustedApplication: SecTrustedApplication?
    try check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trustedApplication))
    var access: SecAccess?
    try check(SecAccessCreate(identityName as CFString, [trustedApplication!] as CFArray, &access))
    var parameters = SecItemImportExportKeyParameters()
    parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
    let passphrase = temporaryPassphrase as CFString
    let usage = [kSecAttrCanSign] as CFArray
    let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
    parameters.passphrase = .passUnretained(passphrase); parameters.accessRef = access.map(Unmanaged.passUnretained)
    parameters.keyUsage = .passUnretained(usage)
    parameters.keyAttributes = .passUnretained(attributes)
    var keychain: SecKeychain?
    try check(SecKeychainCopyDefault(&keychain))
    var format = SecExternalFormat.formatPKCS12, itemType = SecExternalItemType.itemTypeAggregate
    let data = try Data(contentsOf: directory.appendingPathComponent("identity.p12"))
    try withExtendedLifetime((passphrase, usage, attributes, access)) {
        try check(SecItemImport(data as CFData, "p12" as CFString, &format, &itemType, [], &parameters, keychain, nil))
    }
    guard let identity = try existingIdentity() else { throw NSError(domain: "LocalSigning", code: 1) }
    print(identity)
} catch {
    FileHandle.standardError.write(Data("Local signing identity unavailable: \(error)\n".utf8)); exit(1)
}
