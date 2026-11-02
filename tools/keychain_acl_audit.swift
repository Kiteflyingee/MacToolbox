// Read-only metadata audit. Never requests the credential data or changes access.
import Foundation
import Security

@_silgen_name("MacToolboxSetKeychainInteractionAllowed")
func setInteractionAllowed(_ allowed: Bool) -> Int32

do {
    guard setInteractionAllowed(false) == errSecSuccess else { exit(1) }
    let config = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/local.devkite.MacToolbox/translation-settings.json")
    let settings = try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as! [String: Any]
    guard let reference = settings["keyReference"] as? String else { exit(2) }
    let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "local.devkite.MacToolbox.translation",
        kSecAttrAccount as String: reference,kSecReturnRef as String: true,
        kSecMatchLimit as String: kSecMatchLimitOne]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary,&result)
    var report: [String: Any] = ["matchStatus": status,"requestedSecretData": false,"modifiedAccess": false]
    if status == errSecSuccess,let result,CFGetTypeID(result) == SecKeychainItemGetTypeID() {
        let item = unsafeBitCast(result,to: SecKeychainItem.self)
        var access: SecAccess?
        let accessStatus = SecKeychainItemCopyAccess(item,&access)
        report["accessStatus"] = accessStatus
        if accessStatus == errSecSuccess,let access {
            var values: CFArray?
            report["aclStatus"] = SecAccessCopyACLList(access,&values)
            var partitions: [String] = []
            for acl in values as? [SecACL] ?? [] {
                let authorizations = SecACLCopyAuthorizations(acl) as? [String] ?? []
                guard authorizations.contains("ACLAuthorizationPartitionID") else { continue }
                var apps: CFArray?,description: CFString?
                var selector = SecKeychainPromptSelector()
                guard SecACLCopyContents(acl,&apps,&description,&selector) == errSecSuccess,let description else { continue }
                let hex = description as String
                var bytes = Data(); var index = hex.startIndex
                while index < hex.endIndex {
                    let next = hex.index(index,offsetBy: 2,limitedBy: hex.endIndex) ?? hex.endIndex
                    guard let value = UInt8(hex[index..<next],radix: 16) else { break }
                    bytes.append(value); index = next
                }
                if let plist = try? PropertyListSerialization.propertyList(from: bytes,format: nil) as? [String: Any] {
                    partitions += plist["Partitions"] as? [String] ?? []
                }
            }
            report["partitionTypes"] = Array(Set(partitions.map { String($0.split(separator: ":").first ?? "") })).sorted()
            report["partitionCount"] = partitions.count
            if CommandLine.arguments.count == 2 { report["matchesCurrentCDHash"] = partitions.contains("cdhash:"+CommandLine.arguments[1]) }
        }
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report,options: [.prettyPrinted,.sortedKeys]))
} catch { fputs("Metadata audit failed; no secret data requested.\n",stderr); exit(1) }
