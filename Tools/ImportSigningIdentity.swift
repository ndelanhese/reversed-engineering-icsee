// Imports an in-memory identity into Keychain. No private key file is written.
import Foundation
import Security
import CryptoKit
func check(_ status: OSStatus) {
    guard status == errSecSuccess else {
        fputs("Keychain error: \(status)\n", stderr)
        exit(1)
    }
}
var keychain: SecKeychain?
check(SecKeychainCopyDefault(&keychain))
var trusted: SecTrustedApplication?
check(SecTrustedApplicationCreateFromPath("/usr/bin/codesign", &trusted))
var access: SecAccess?
check(SecAccessCreate("Reversed engineering Icsee local signing" as CFString, [trusted!] as CFArray, &access))
var parameters = SecItemImportExportKeyParameters()
parameters.version = UInt32(SEC_KEY_IMPORT_EXPORT_PARAMS_VERSION)
parameters.accessRef = .passUnretained(access!)
let usage = [kSecAttrCanSign] as CFArray
parameters.keyUsage = .passUnretained(usage)
let attributes = [kSecAttrIsPermanent, kSecAttrIsSensitive] as CFArray
parameters.keyAttributes = .passUnretained(attributes)
var format = SecExternalFormat.formatPEMSequence
var type = SecExternalItemType.itemTypeAggregate
var items: CFArray?
let data = FileHandle.standardInput.readDataToEndOfFile()
withExtendedLifetime((access, usage, attributes)) {
    check(SecItemImport(data as CFData, nil, &format, &type, [], &parameters, keychain, &items))
}
for item in items! as [AnyObject] {
    if CFGetTypeID(item) == SecCertificateGetTypeID() {
        let certificate = item as! SecCertificate
        let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(certificate) as Data).map { String(format: "%02X", $0) }.joined()
        print(fingerprint)
    }
}
