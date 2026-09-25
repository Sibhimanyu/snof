import Foundation

/// A paired phone's side of the channel: read the Mac's view, say it is
/// open, ask to pair, and send signed replies. Paths and formats mirror
/// src/remote/remote-bridge.ts.
public struct Channel: Sendable {
    public let pairing: PairingPayload
    public let deviceId: String
    let firestore: FirestoreClient

    /// Commands live a few minutes: long enough for a slow network, short
    /// enough that a stale one is refused (the Mac caps it at ten).
    public static let commandLifetime: TimeInterval = 5 * 60

    public init(pairing: PairingPayload, deviceId: String, transport: HTTPTransport = URLSession.shared) {
        self.pairing = pairing
        self.deviceId = deviceId
        firestore = FirestoreClient(projectId: pairing.p, transport: transport)
    }

    func path(_ kind: String, _ id: String) -> String { "channels/\(pairing.c)/\(kind)/\(id)" }

    public func snapshot() async throws -> PhoneSnapshot? {
        guard let document = try await firestore.get(path("state", "snapshot")) else { return nil }
        return try ChannelCrypto.open(PhoneSnapshot.self, box: document.box, key: pairing.k)
    }

    /// Tells the Mac a phone is looking, so it polls and publishes faster.
    public func touchPresence(now: Date = Date()) async throws {
        struct Presence: Codable { let at: Int64 }
        let box = try ChannelCrypto.seal(Presence(at: Int64(now.timeIntervalSince1970 * 1000)), key: pairing.k)
        try await firestore.set(path("state", "presence"), ChannelDocument(box: box))
    }

    public func requestPairing(name: String, signer: CommandSigner) async throws {
        struct Request: Codable { let name: String; let publicKey: String }
        let box = try ChannelCrypto.seal(Request(name: name, publicKey: signer.publicKeyX963.base64EncodedString()), key: pairing.k)
        try await firestore.set(path("pairing", deviceId), ChannelDocument(box: box))
    }

    public func pairingAnswer() async throws -> PairingAnswer? {
        guard let document = try await firestore.get(path("results", "pair-\(deviceId)")) else { return nil }
        return try ChannelCrypto.open(PairingAnswer.self, box: document.box, key: pairing.k)
    }

    /// The signed document for a reply. Separate from sending so it can be
    /// checked against the Mac's verifier in tests.
    public func replyDocument(
        to session: PhoneSnapshot.Session,
        text: String,
        signer: CommandSigner,
        now: Date = Date()
    ) throws -> (id: String, document: ChannelDocument) {
        guard let sessionId = session.conductorSessionId else { throw ChannelCrypto.Failure.badBox }
        var nonce = Data(count: 16)
        _ = nonce.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!) }
        let command = ReplyCommand(
            v: 1,
            sessionId: sessionId,
            answersTurn: session.turnId,
            text: text,
            nonce: nonce.map { String(format: "%02x", $0) }.joined(),
            expiresAt: Int64((now.timeIntervalSince1970 + Self.commandLifetime) * 1000)
        )
        let box = try ChannelCrypto.seal(command, key: pairing.k)
        let id = UUID().uuidString.lowercased()
        return (id, ChannelDocument(box: box, sig: try signer.sign(box), device: deviceId))
    }

    public func send(_ document: ChannelDocument, id: String) async throws {
        try await firestore.set(path("commands", id), document)
    }

    public func result(for id: String) async throws -> CommandResult? {
        guard let document = try await firestore.get(path("results", id)) else { return nil }
        return try ChannelCrypto.open(CommandResult.self, box: document.box, key: pairing.k)
    }
}
