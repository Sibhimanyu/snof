import Foundation
import UIKit
import FirebaseCore
import FirebaseAuth
@preconcurrency import FirebaseDatabase
import GoogleSignIn
import SNOFCore

/* The farm. Same paths, same writes, same rules as dashboard/public/app.js —
 * this app is a second client of the one database, not a new trust boundary.
 *
 * Disk persistence is deliberately left OFF (the SDK default). With it on, a
 * command written while the phone had no signal would be kept on disk and
 * replayed on the next launch, and the rules' `at === now` check would
 * happily accept it, because `now` is evaluated when the write reaches the
 * server, not when the button was pressed. */
@MainActor
final class FirebaseBackend: FarmBackend {

    static var isConfigured: Bool {
        Bundle.main.path(forResource: "GoogleService-Info", ofType: "plist") != nil
    }

    let isDemo = false
    private var observers: [(query: DatabaseQuery, handle: DatabaseHandle)] = []
    private var authHandle: AuthStateDidChangeListenerHandle?
    private var db: Database { Database.database() }

    init() {
        if FirebaseApp.app() == nil { FirebaseApp.configure() }
    }

    var configurationProblem: String? {
        guard let opts = FirebaseApp.app()?.options else {
            return "Firebase is not configured in this build."
        }
        if opts.databaseURL == nil {
            return "This build's GoogleService-Info.plist has no DATABASE_URL. Re-run scripts/fetch-firebase-config.sh now that the database exists."
        }
        if opts.clientID == nil {
            return "This build's GoogleService-Info.plist has no CLIENT_ID. Enable Google sign-in for the project, then re-run scripts/fetch-firebase-config.sh."
        }
        return nil
    }

    /* ---- auth ---- */

    func observeAuth(_ handler: @escaping (AppUser?) -> Void) {
        if let authHandle { Auth.auth().removeStateDidChangeListener(authHandle) }
        authHandle = Auth.auth().addStateDidChangeListener { _, user in
            handler(user.map { AppUser(uid: $0.uid, email: $0.email, displayName: $0.displayName) })
        }
    }

    func signIn() async throws {
        guard let clientID = FirebaseApp.app()?.options.clientID else {
            throw BackendError.notConfigured("Google sign-in is not configured in this build.")
        }
        guard let presenter = Self.topViewController() else {
            throw BackendError.other("Could not find a window to sign in from.")
        }
        GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
        let result: GIDSignInResult
        do {
            result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
        } catch let err as NSError where err.domain == kGIDSignInErrorDomain
                                      && err.code == GIDSignInError.canceled.rawValue {
            throw BackendError.cancelled
        }
        guard let idToken = result.user.idToken?.tokenString else {
            throw BackendError.other("Google did not return an ID token.")
        }
        let credential = GoogleAuthProvider.credential(withIDToken: idToken,
                                                       accessToken: result.user.accessToken.tokenString)
        _ = try await Auth.auth().signIn(with: credential)
    }

    func signOut() {
        GIDSignIn.sharedInstance.signOut()
        try? Auth.auth().signOut()
    }

    /* ---- listeners ---- */

    private var attachTask: Task<Void, Never>?

    func attach(user: AppUser, _ handler: @escaping (FarmEvent) -> Void) {
        detach()

        // Self-registered so an admin can resolve this uid to an email from
        // the dashboard. Fire-and-forget, as on the web.
        db.reference(withPath: "acl/directory/\(user.uid)").setValue([
            "email": String((user.email ?? "").prefix(254)),
            "name": String((user.displayName ?? "").prefix(128)),
            "at": ServerValue.timestamp(),
        ])

        // Claim first, then listen: attaching the farm listeners while an
        // invite is still being claimed gets them refused, and a first-time
        // invitee would be told they have no access until they relaunched.
        attachTask = Task { [weak self] in
            await self?.claimInvite(user)
            guard let self, !Task.isCancelled else { return }
            self.listen(user, handler)
        }
    }

    private func listen(_ user: AppUser, _ handler: @escaping (FarmEvent) -> Void) {
        observe(".info/serverTimeOffset") { handler(.serverTimeOffset(Parse.double($0) ?? 0)) }
        observe(".info/connected") { handler(.connected(Parse.bool($0) ?? false)) }
        observe("acl/controllers/\(user.uid)", onDenied: { handler(.controller(false)) }) {
            handler(.controller(Parse.bool($0) == true))
        }
        observe("acl/admins/\(user.uid)", onDenied: { handler(.admin(false)) }) {
            handler(.admin(Parse.bool($0) == true))
        }

        let farm = "farms/\(Farm.slug)"
        let denied = { handler(.denied) }
        observe("\(farm)/meta", onDenied: denied) { handler(.meta($0)) }
        observe("\(farm)/areas", onDenied: denied) { handler(.areas($0)) }
        observe("\(farm)/devices", onDenied: denied) { handler(.devices($0)) }
        observe("\(farm)/entities", onDenied: denied) { handler(.entities($0)) }
        observe("\(farm)/irrigation", onDenied: denied) { handler(.irrigation($0)) }
        // The last 20 results, as on the web; a new report always lands in them.
        observe(db.reference(withPath: "\(farm)/irrigation_reports").queryLimited(toLast: 20),
                onDenied: denied) { handler(.reports($0)) }
        observe(db.reference(withPath: "\(farm)/irrigation_command_results").queryLimited(toLast: 10),
                onDenied: nil) { handler(.irrigationResults($0)) }
        observe("\(farm)/irrigation_lock", onDenied: nil) { handler(.irrigationLock($0)) }
        observe(db.reference(withPath: "\(farm)/motor_command_results").queryLimited(toLast: 10),
                onDenied: nil) { handler(.motorResults($0)) }
        observe("\(farm)/motor_lock", onDenied: nil) { handler(.motorLock($0)) }
        observe("\(farm)/mobitech_status", onDenied: nil) { handler(.mobitechStatus($0)) }
        observe("\(farm)/water", onDenied: nil) { handler(.water($0)) }
    }

    func detach() {
        attachTask?.cancel()
        attachTask = nil
        for o in observers { o.query.removeObserver(withHandle: o.handle) }
        observers.removeAll()
    }

    private func observe(_ path: String, onDenied: (() -> Void)? = nil, _ cb: @escaping (Any?) -> Void) {
        observe(db.reference(withPath: path), onDenied: onDenied, cb)
    }

    private func observe(_ query: DatabaseQuery, onDenied: (() -> Void)?, _ cb: @escaping (Any?) -> Void) {
        let handle = query.observe(.value, with: { snap in
            cb(snap.value is NSNull ? nil : snap.value)
        }, withCancel: { err in
            // The SDK cancels a listener only when the rules refuse the read.
            NSLog("SNOF: listener cancelled at %@: %@", query.ref.url, err.localizedDescription)
            onDenied?()
        })
        observers.append((query, handle))
    }

    /* If an admin pre-authorized this email (acl/invites), claim it: view, then
     * control if the invite asks for it, then delete the invite. The rules
     * enforce every step from the server side; this only means a first-time
     * sign-in from the phone works without a detour through the web. */
    private func claimInvite(_ user: AppUser) async {
        guard let key = Invites.key(for: user.email) else { return }
        let invite = db.reference(withPath: "acl/invites/\(key)")
        do {
            guard let node = try await invite.getData().value as? [String: Any] else { return }
            try await db.reference(withPath: "acl/viewers/\(user.uid)").setValue(true)
            if Parse.string(node["tier"]) == "control" {
                try await db.reference(withPath: "acl/controllers/\(user.uid)").setValue(true)
            }
            try await invite.removeValue()
        } catch {
            NSLog("SNOF: invite claim failed: %@", error.localizedDescription)
        }
    }

    /* ---- writes ---- */

    func send(_ command: Command, uid: String) async throws {
        var node: [String: Any] = [
            "entity_id": command.entityId,
            "domain": command.domain,
            "service": command.service,
            "uid": uid,
            "at": ServerValue.timestamp(),
        ]
        if !command.dataPayload.isEmpty { node["data"] = command.dataPayload }
        try await push("farms/\(Farm.slug)/commands", node)
    }

    func requestReport(type: String, from: String?, to: String?, uid: String) async throws -> String {
        var node: [String: Any] = ["type": type, "uid": uid, "at": ServerValue.timestamp()]
        if let from { node["from"] = from }
        if let to { node["to"] = to }
        return try await push("farms/\(Farm.slug)/irrigation_requests", node)
    }

    func sendIrrigation(_ command: IrrigationCommand, uid: String) async throws -> String {
        var node = command.payload
        node["uid"] = uid
        node["at"] = ServerValue.timestamp()
        return try await push("farms/\(Farm.slug)/irrigation_commands", node)
    }

    func sendMotor(motor: String, action: String, uid: String) async throws -> String {
        try await push("farms/\(Farm.slug)/motor_commands",
                       ["motor": motor, "action": action, "uid": uid, "at": ServerValue.timestamp()])
    }

    func saveMobitechSession(_ session: Mobitech.Session, mobileLast4: String, uid: String) async throws {
        try await set("private/mobitech", ["token": session.token, "at": ServerValue.timestamp(), "uid": uid])
        try await set("farms/\(Farm.slug)/mobitech_status",
                      ["at": ServerValue.timestamp(), "uid": uid, "name": session.name,
                       "user": session.user, "mobileLast4": mobileLast4])
    }

    func clearMobitechSession() async throws {
        try await set("private/mobitech", nil)
        try await set("farms/\(Farm.slug)/mobitech_status", nil)
    }

    func requestWaterRefresh(uid: String) async throws {
        try await push("farms/\(Farm.slug)/water_requests", ["uid": uid, "at": ServerValue.timestamp()])
    }

    /// The function lives beside the database (asia-southeast1). The project
    /// id comes from GoogleService-Info.plist; nothing here is hardcoded.
    func waterSession(_ body: [String: Any]) async throws -> [String: Any] {
        guard let project = FirebaseApp.app()?.options.projectID,
              let url = URL(string: "https://asia-southeast1-\(project).cloudfunctions.net/water_session") else {
            throw BackendError.notConfigured("Firebase is not configured in this build.")
        }
        guard let user = Auth.auth().currentUser else { throw BackendError.other("Sign in to SNOF first.") }
        let idToken = try await user.getIDToken()
        var req = URLRequest(url: url, timeoutInterval: 45)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(idToken)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        guard (resp as? HTTPURLResponse)?.statusCode == 200, Parse.bool(json["ok"]) == true else {
            throw BackendError.other(Parse.string(json["error"]) ?? "The function answered \((resp as? HTTPURLResponse)?.statusCode ?? 0).")
        }
        return json
    }

    private func set(_ path: String, _ node: [String: Any]?) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            db.reference(withPath: path).setValue(node) { err, _ in
                if let err = err as NSError? {
                    cont.resume(throwing: err.localizedDescription.lowercased().contains("permission")
                                ? BackendError.refused : BackendError.other(err.localizedDescription))
                } else {
                    cont.resume()
                }
            }
        }
    }

    func cancelUnsentWrites() {
        db.purgeOutstandingWrites()
    }

    @discardableResult
    private func push(_ path: String, _ node: [String: Any]) async throws -> String {
        let ref = db.reference(withPath: path).childByAutoId()
        let key = ref.key ?? ""
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            ref.setValue(node) { err, _ in
                if let err = err as NSError? {
                    let msg = err.localizedDescription.lowercased()
                    if msg.contains("permission") { cont.resume(throwing: BackendError.refused) }
                    else if msg.contains("cancel") || msg.contains("purge") { cont.resume(throwing: BackendError.cancelled) }
                    else { cont.resume(throwing: BackendError.other(err.localizedDescription)) }
                } else {
                    cont.resume()
                }
            }
        }
        return key
    }

    /* ---- helpers ---- */

    static func topViewController() -> UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive } ??
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first
        var vc = scene?.keyWindow?.rootViewController ?? scene?.windows.first?.rootViewController
        while let next = vc?.presentedViewController { vc = next }
        return vc
    }
}
