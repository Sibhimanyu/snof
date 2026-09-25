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
    case devices(Any?)
    case entities(Any?)
    case irrigation(Any?)
    case reports(Any?)
    /// irrigation_command_results: what the NUC did with each Run/Stop.
    case irrigationResults(Any?)
    /// irrigation_lock: held from before a Run/Stop is sent until the
    /// controller confirms it (or 3 min pass). While live, nothing may change.
    case irrigationLock(Any?)
    /// motor_command_results: what the motor_command function did with each press.
    case motorResults(Any?)
    /// farms/<farm>/mobitech_status: who is signed in to Mobitech (never the token).
    case mobitechStatus(Any?)
    /// farms/<farm>/water: the river motor and the other farm's motors, as
    /// the water functions last read them. Read-only.
    case water(Any?)
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
    /// Append one node to /farms/<farm>/irrigation_commands (admins only);
    /// returns its key, which the NUC reuses for the result.
    func sendIrrigation(_ command: IrrigationCommand, uid: String) async throws -> String
    /// Append one node to /farms/<farm>/motor_commands (admins only, armed
    /// motors only): {motor, action, uid, at, clientAt}. clientAt is the press
    /// on the server's clock; the rules refuse it 30 s late. Returns its key,
    /// which the motor_command function reuses for the result.
    func sendMotor(motor: String, action: String, zone: Int?, uid: String, clientAt: Double) async throws -> String
    /// Store a Mobitech session: the token where no client can read it
    /// (/private/mobitech) and a non-secret status line. Admins only.
    func saveMobitechSession(_ session: Mobitech.Session, mobileLast4: String, uid: String) async throws
    /// Stop SNOF using its session: remove the token and the status line.
    /// (Mobitech's own logout needs the token, which no client can read.)
    func clearMobitechSession() async throws
    /// Append to /farms/<farm>/water_requests: "pull the water chain now".
    /// Any viewer; the function pulls at most once per 15 s whoever asks.
    func requestWaterRefresh(uid: String) async throws
    /// POST to the water_session function (Livesky sign-in, admins only)
    /// with this user's Firebase ID token. Returns its JSON answer; throws
    /// with the function's own error text when it refuses.
    func waterSession(_ body: [String: Any]) async throws -> [String: Any]
    /// Drop writes the server has not acknowledged yet. Called when a control
    /// times out, so a toggle queued while offline cannot fire minutes later.
    func cancelUnsentWrites()
}
