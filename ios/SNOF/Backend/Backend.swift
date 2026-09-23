import Foundation
import SNOFCore

struct AppUser: Equatable {
    let uid: String
    let email: String?
    let displayName: String?

    var shortName: String {
        if let n = displayName, !n.isEmpty { return n }
        if let e = email, let local = e.split(separator: "@").first { return String(local) }
        return "Signed in"
    }
}

/// Everything the store hears from the farm. Values are raw RTDB trees; the
/// store runs them through SNOFCore.Parse, so demo and live share one parser.
enum FarmEvent {
    case meta(Any?)
    case areas(Any?)
    case entities(Any?)
    case irrigation(Any?)
    case reports(Any?)
    case controller(Bool)
    case admin(Bool)
    case serverTimeOffset(Double)
    case connected(Bool)
    /// A farm read was refused: this account is not on the allowlist.
    case denied
}

enum BackendError: LocalizedError {
    case refused
    case notConnected
    case cancelled
    case notConfigured(String)
    case other(String)

    var errorDescription: String? {
        switch self {
        case .refused: return "The database refused that."
        case .notConnected: return "The phone is not connected to the farm right now."
        case .cancelled: return "Cancelled."
        case .notConfigured(let why): return why
        case .other(let s): return s
        }
    }
}

/* Two implementations: FirebaseBackend (the farm) and DemoBackend (bundled
 * fixtures, no network). Every write path the app has is on this protocol,
 * and each one maps to exactly one RTDB rule. */
@MainActor
protocol FarmBackend: AnyObject {
    var isDemo: Bool { get }
    /// nil when the backend can run; otherwise why it cannot (shown on the gate).
    var configurationProblem: String? { get }

    func observeAuth(_ handler: @escaping (AppUser?) -> Void)
    func signIn() async throws
    func signOut()

    /// Attach every farm listener for this user. Also self-registers
    /// acl/directory and claims a pending invite, as app.js `enter()` does.
    func attach(user: AppUser, _ handler: @escaping (FarmEvent) -> Void)
    func detach()

    /// Append one node to /farms/<farm>/commands. Resolves when the server acks.
    func send(_ command: Command, uid: String) async throws
    /// Append one node to /farms/<farm>/irrigation_requests; returns its key,
    /// which the bridge reuses as the irrigation_reports key.
    func requestReport(type: String, from: String?, to: String?, uid: String) async throws -> String
    /// Drop writes the server has not acknowledged yet. Called when a control
    /// times out, so a toggle queued while offline cannot fire minutes later.
    func cancelUnsentWrites()
}
