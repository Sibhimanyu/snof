import Foundation

/* People and access, as an admin sees them (owner, 2026-09-25: "as an admin
 * I should be able to give permission to other people either from the iOS
 * or web"). Mirrors adminView() in dashboard/public/app.js: the same tiers,
 * the same order, the same writes. The RTDB rules are what actually decide;
 * admin is never a tier an app can hand out. */

public enum AccessTier: String, Sendable, CaseIterable {
    case admin, control, view, none

    public var label: String {
        switch self {
        case .admin: return "Admin"
        case .control: return "Controller"
        case .view: return "Viewer"
        case .none: return "No access"
        }
    }
    var rank: Int { [.admin: 0, .control: 1, .view: 2, .none: 3][self] ?? 3 }
}

public struct Person: Identifiable, Hashable, Sendable {
    public let uid: String
    public let email: String?
    public let name: String?
    public let tier: AccessTier
    public var id: String { uid }
}

public struct PendingInvite: Identifiable, Hashable, Sendable {
    public let key: String
    /// view or control only; admin cannot be invited.
    public let tier: AccessTier
    public var id: String { key }
    public var email: String { Invites.email(forKey: key) }
}

public struct AccessList: Equatable, Sendable {
    public var people: [Person] = []
    public var invites: [PendingInvite] = []
    public init(people: [Person] = [], invites: [PendingInvite] = []) { self.people = people; self.invites = invites }
}

extension Invites {
    public static func email(forKey key: String) -> String { key.replacingOccurrences(of: ",", with: ".") }

    /// The same test as sendInvite() in app.js.
    public static func isEmail(_ s: String) -> Bool {
        s.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil
    }
}

extension Parse {
    /// The whole acl subtree (admins can read it in one shot).
    public static func access(_ v: Any?) -> AccessList {
        let acl = v as? [String: Any] ?? [:]
        func trues(_ k: String) -> Set<String> {
            Set((acl[k] as? [String: Any] ?? [:]).filter { bool($0.value) == true }.map(\.key))
        }
        let admins = trues("admins"), controllers = trues("controllers"), viewers = trues("viewers")
        let directory = acl["directory"] as? [String: Any] ?? [:]
        let uids = admins.union(controllers).union(viewers).union(directory.keys)
        func tier(_ uid: String) -> AccessTier {
            if admins.contains(uid) { return .admin }
            if controllers.contains(uid) { return .control }
            if viewers.contains(uid) { return .view }
            return .none
        }
        var people: [Person] = []
        for uid in uids {
            let d = directory[uid] as? [String: Any]
            let email: String? = string(d?["email"])
            let name: String? = string(d?["name"])
            people.append(Person(uid: uid, email: email, name: name, tier: tier(uid)))
        }
        people.sort { a, b in
            if a.tier.rank != b.tier.rank { return a.tier.rank < b.tier.rank }
            return (a.email ?? a.uid).localizedStandardCompare(b.email ?? b.uid) == .orderedAscending
        }
        // Once claimed, the claim deletes the invite; this covers the gap
        // between a claim landing and that delete confirming.
        let known = Set(people.compactMap { $0.email?.lowercased() })
        let invites = (acl["invites"] as? [String: Any] ?? [:]).compactMap { key, node -> PendingInvite? in
            guard !known.contains(Invites.email(forKey: key).lowercased()) else { return nil }
            let t = string((node as? [String: Any])?["tier"])
            return PendingInvite(key: key, tier: t == "control" ? .control : .view)
        }
        .sorted { $0.key.localizedStandardCompare($1.key) == .orderedAscending }
        return AccessList(people: people, invites: invites)
    }
}
