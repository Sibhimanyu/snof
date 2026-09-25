import Foundation

/// What the Mac's pairing QR code carries: `squeak://pair?d=<base64url JSON>`.
/// The channel key in here is the secret that lets a phone read; it goes
/// straight to the Keychain and is never shown again.
public struct PairingPayload: Codable, Equatable, Sendable {
    public let v: Int
    /// Firebase project id.
    public let p: String
    /// Channel id: the Firestore path.
    public let c: String
    /// Channel key, base64: AES-256-GCM.
    public let k: String
    /// The Mac's name, for the screen.
    public let n: String

    public init(v: Int, p: String, c: String, k: String, n: String) {
        self.v = v; self.p = p; self.c = c; self.k = k; self.n = n
    }

    public enum Failure: Error, Equatable { case notAPairingCode, unsupportedVersion }

    public static func parse(_ text: String) throws -> PairingPayload {
        guard let components = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              components.scheme == "squeak", components.host == "pair",
              let encoded = components.queryItems?.first(where: { $0.name == "d" })?.value,
              let data = Data(base64URLEncoded: encoded)
        else { throw Failure.notAPairingCode }
        let payload = try JSONDecoder().decode(PairingPayload.self, from: data)
        guard payload.v == 1 else { throw Failure.unsupportedVersion }
        guard Data(base64Encoded: payload.k)?.count == 32, payload.c.count >= 22 else { throw Failure.notAPairingCode }
        return payload
    }
}

extension Data {
    init?(base64URLEncoded text: String) {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while base64.count % 4 != 0 { base64 += "=" }
        self.init(base64Encoded: base64)
    }
}
