import CryptoKit
import Foundation

/// The channel's cryptography, byte-for-byte compatible with the Mac side
/// (src/remote/remote-crypto.ts). See docs/remote-channel.md.
///
/// - Content: AES-256-GCM, `SealedBox.combined` (nonce ‖ ciphertext ‖ tag),
///   base64, under the channel key from the pairing QR code.
/// - Commands: ECDSA P-256 over the exact box string, `rawRepresentation`
///   (r ‖ s), base64. The key lives in the Secure Enclave on a real phone.
public enum ChannelCrypto {
    public enum Failure: Error { case badKey, badBox }

    public static func seal<T: Encodable>(_ value: T, key: String) throws -> String {
        guard let keyData = Data(base64Encoded: key), keyData.count == 32 else { throw Failure.badKey }
        let plain = try JSONEncoder().encode(value)
        let box = try AES.GCM.seal(plain, using: SymmetricKey(data: keyData))
        guard let combined = box.combined else { throw Failure.badBox }
        return combined.base64EncodedString()
    }

    public static func open<T: Decodable>(_ type: T.Type, box: String, key: String) throws -> T {
        guard let keyData = Data(base64Encoded: key), keyData.count == 32 else { throw Failure.badKey }
        guard let raw = Data(base64Encoded: box) else { throw Failure.badBox }
        let sealed = try AES.GCM.SealedBox(combined: raw)
        let plain = try AES.GCM.open(sealed, using: SymmetricKey(data: keyData))
        return try JSONDecoder().decode(type, from: plain)
    }

    /// Mirrors `pairingCode` on the Mac: six digits from SHA-256 of the key.
    public static func pairingCode(publicKeyX963: Data) -> String {
        let digest = Array(SHA256.hash(data: publicKeyX963))
        let value = (UInt32(digest[0]) << 24) | (UInt32(digest[1]) << 16) | (UInt32(digest[2]) << 8) | UInt32(digest[3])
        return String(format: "%06u", value % 1_000_000)
    }
}

/// Something that can sign commands: the Secure Enclave on a phone, a
/// software key in tests and on a Mac without one.
public protocol CommandSigner {
    var publicKeyX963: Data { get }
    func sign(_ message: String) throws -> String
}

public struct SoftwareSigner: CommandSigner {
    public let key: P256.Signing.PrivateKey
    public init(key: P256.Signing.PrivateKey = .init()) { self.key = key }
    public var publicKeyX963: Data { key.publicKey.x963Representation }
    public func sign(_ message: String) throws -> String {
        try key.signature(for: Data(message.utf8)).rawRepresentation.base64EncodedString()
    }
}

public struct EnclaveSigner: CommandSigner {
    public let key: SecureEnclave.P256.Signing.PrivateKey
    public init(key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }
    public var publicKeyX963: Data { key.publicKey.x963Representation }
    public func sign(_ message: String) throws -> String {
        try key.signature(for: Data(message.utf8)).rawRepresentation.base64EncodedString()
    }
}
