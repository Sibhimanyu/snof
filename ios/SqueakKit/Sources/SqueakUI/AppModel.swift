#if os(iOS)
import Foundation
import LocalAuthentication
import SqueakCore
import SwiftUI
import UIKit

/// The whole app's state. It decides nothing about agents — the Mac does
/// (DESIGN.md §1, "every surface agrees") — it only fetches, shows and sends.
@MainActor
final class AppModel: ObservableObject {
    enum Phase: Equatable {
        case unpaired
        /// Waiting for the Mac to approve; both screens show `code`.
        case awaitingApproval(code: String, mac: String)
        case paired
    }

    struct Receipt: Equatable {
        enum Kind: Equatable { case sending, sent(String), refused(String) }
        let kind: Kind
        let turnId: String?
    }

    @Published private(set) var phase: Phase = .unpaired
    @Published private(set) var snapshot: PhoneSnapshot?
    @Published private(set) var lastFetch: Date?
    @Published private(set) var problem: String?
    @Published var receipts: [String: Receipt] = [:]

    private var channel: Channel?
    private var loop: Task<Void, Never>?
    private var lastPresence = Date.distantPast
    private let signer: CommandSigner
    let demo: Bool

    init() {
        demo = ProcessInfo.processInfo.arguments.contains("-squeak-demo")
        signer = demo ? SoftwareSigner() : KeyStore.signer()
        if demo {
            snapshot = DemoData.snapshot
            lastFetch = Date()
            phase = .paired
            return
        }
        if let data = KeyStore.load(account: "pairing"),
           let pairing = try? JSONDecoder().decode(PairingPayload.self, from: data),
           let deviceId = KeyStore.load(account: "device-id").flatMap({ String(data: $0, encoding: .utf8) }) {
            channel = Channel(pairing: pairing, deviceId: deviceId)
            phase = KeyStore.load(account: "approved") != nil ? .paired : .awaitingApproval(
                code: ChannelCrypto.pairingCode(publicKeyX963: signer.publicKeyX963), mac: pairing.n)
        }
    }

    /* ---------- pairing ---------- */

    func pair(with text: String) async {
        do {
            let pairing = try PairingPayload.parse(text)
            let deviceId = UUID().uuidString.lowercased()
            let channel = Channel(pairing: pairing, deviceId: deviceId)
            try await channel.requestPairing(name: UIDevice.current.name, signer: signer)
            KeyStore.save(try JSONEncoder().encode(pairing), account: "pairing")
            KeyStore.save(Data(deviceId.utf8), account: "device-id")
            self.channel = channel
            problem = nil
            phase = .awaitingApproval(code: ChannelCrypto.pairingCode(publicKeyX963: signer.publicKeyX963), mac: pairing.n)
            resume()
        } catch is PairingPayload.Failure {
            problem = "That isn't a Squeak pairing code. Open Squeak on your Mac, choose iPhone, then Pair an iPhone."
        } catch {
            problem = "Couldn't reach Squeak's server. Check the connection and scan again."
        }
    }

    func unpair() {
        KeyStore.wipe()
        KeyStore.delete(account: "approved")
        channel = nil
        snapshot = nil
        phase = .unpaired
        loop?.cancel()
    }

    /* ---------- the loop: only while the app is on screen ---------- */

    func resume() {
        guard !demo, loop == nil, channel != nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    func pause() {
        loop?.cancel()
        loop = nil
    }

    func refresh() async {
        await tick()
    }

    private func tick() async {
        guard let channel else { return }
        do {
            if case .awaitingApproval = phase {
                if let answer = try await channel.pairingAnswer() {
                    if answer.approved {
                        KeyStore.save(Data("1".utf8), account: "approved")
                        phase = .paired
                    } else {
                        unpair()
                        problem = "Your Mac said no. Pair again if that was a mistake."
                    }
                }
                return
            }
            // Tell the Mac someone is looking, so it publishes and polls faster.
            if Date().timeIntervalSince(lastPresence) > 20 {
                try await channel.touchPresence()
                lastPresence = Date()
            }
            if let next = try await channel.snapshot() {
                snapshot = next
            }
            lastFetch = Date()
            problem = nil
        } catch ChannelCrypto.Failure.badBox, ChannelCrypto.Failure.badKey {
            problem = "This phone's pairing no longer matches your Mac. Pair again."
        } catch {
            problem = "Can't reach Squeak's server right now."
        }
    }

    /* ---------- replying ---------- */

    func send(_ text: String, to session: PhoneSnapshot.Session) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard await confirmWithBiometrics(reason: "Send to \(session.label)") else { return }
        receipts[session.key] = Receipt(kind: .sending, turnId: session.turnId)
        if demo {
            try? await Task.sleep(for: .seconds(1))
            receipts[session.key] = Receipt(kind: .sent(Self.sentText(trimmed, session.label, via: "conductor")), turnId: session.turnId)
            return
        }
        guard let channel else { return }
        do {
            let (id, document) = try channel.replyDocument(to: session, text: trimmed, signer: signer)
            try await channel.send(document, id: id)
            // The Mac answers within a few seconds while this app is open.
            for _ in 0..<40 {
                try await Task.sleep(for: .milliseconds(750))
                if let result = try await channel.result(for: id) {
                    let kind: Receipt.Kind = result.sent
                        ? .sent(Self.sentText(trimmed, session.label, via: result.via))
                        : .refused(result.reason ?? "Your Mac refused that reply.")
                    receipts[session.key] = Receipt(kind: kind, turnId: session.turnId)
                    return
                }
            }
            receipts[session.key] = Receipt(kind: .refused("Your Mac didn't answer. It may be asleep; the reply expires in five minutes."), turnId: session.turnId)
        } catch {
            receipts[session.key] = Receipt(kind: .refused("Couldn't send: \(error.localizedDescription)"), turnId: session.turnId)
        }
    }

    /// DESIGN.md §9: "Sent B to snof · irrigation in Conductor."
    static func sentText(_ text: String, _ label: String, via: String?) -> String {
        let what = text.count <= 3 ? text : "your reply"
        return via == "background"
            ? "Sent \(what) to \(label) in the background. Conductor shows it next time it loads the chat."
            : "Sent \(what) to \(label) in Conductor."
    }

    private func confirmWithBiometrics(reason: String) async -> Bool {
        if demo { return true }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else { return true }
        return (try? await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
#endif
