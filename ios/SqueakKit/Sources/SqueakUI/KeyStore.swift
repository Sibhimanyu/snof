#if os(iOS)
import CryptoKit
import Foundation
import Security
import SqueakCore

/// The phone's secrets: the pairing (it carries the channel key) and the
/// signing key. Keychain, this-device-only, never in backups. The signing
/// key is made in the Secure Enclave, so what is stored is only an encrypted
/// handle the Enclave will accept back — the key itself never leaves it.
enum KeyStore {
    private static let service = "com.squeak.phone"

    static func save(_ data: Data, account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(account: String) -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess ? item as? Data : nil
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }

    /// The Secure Enclave key, made once. A simulator has no Enclave, so it
    /// falls back to a software key there; a real phone always has one.
    static func signer() -> CommandSigner {
        if SecureEnclave.isAvailable {
            if let blob = load(account: "enclave-key"),
               let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob) {
                return EnclaveSigner(key: key)
            }
            if let key = try? SecureEnclave.P256.Signing.PrivateKey() {
                save(key.dataRepresentation, account: "enclave-key")
                return EnclaveSigner(key: key)
            }
        }
        if let raw = load(account: "software-key"), let key = try? P256.Signing.PrivateKey(rawRepresentation: raw) {
            return SoftwareSigner(key: key)
        }
        let key = P256.Signing.PrivateKey()
        save(key.rawRepresentation, account: "software-key")
        return SoftwareSigner(key: key)
    }

    /// Forget the pairing and the key: the Mac's approval of this key is worthless afterwards.
    static func wipe() {
        for account in ["pairing", "device-id", "enclave-key", "software-key"] {
            delete(account: account)
        }
    }
}
#endif
