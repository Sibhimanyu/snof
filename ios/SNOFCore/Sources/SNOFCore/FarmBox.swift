import Foundation

/* The farm box's add-on version and the admin's Update button. Mirrors
 * farmBoxRow() in dashboard/public/app.js. The bridge publishes version /
 * versionLatest / updateAvailable / remoteUpdate in meta/bridge and, once an
 * update is pressed, meta/bridge/update {state, from, to, reason, at}. */
public struct FarmBoxUpdate: Hashable, Sendable {
    public var state: String?      // updating | done | failed | refused
    public var from: String?
    public var to: String?
    public var reason: String?
    public var at: Double?         // server ms
    public init(state: String? = nil, from: String? = nil, to: String? = nil,
                reason: String? = nil, at: Double? = nil) {
        self.state = state; self.from = from; self.to = to; self.reason = reason; self.at = at
    }
}

public struct FarmBoxRow: Equatable, Sendable {
    public var version: String      // "Add-on 0.10.11"
    public var note: String?        // "Updating…", "Remote updates are off on the farm box", a result
    public var updateTo: String?    // non-nil: show "Update to <x>"

    public static func make(bridge: BridgeMeta?, nowMs: Double, askedAtMs: Double? = nil) -> FarmBoxRow {
        let b = bridge
        let up = b?.update
        let recent = up?.at.map { nowMs - $0 < 3_600_000 } ?? false
        let version = b?.version.map { "Add-on \($0)" } ?? "Add-on version not reported yet"
        if (up?.state == "updating" && recent)
            || (askedAtMs.map { nowMs - $0 < 120_000 } == true && up?.state != "refused") {
            return FarmBoxRow(version: version, note: "Updating…", updateTo: nil)
        }
        if b?.updateAvailable == true {
            if b?.remoteUpdate == true {
                return FarmBoxRow(version: version, note: nil, updateTo: b?.versionLatest ?? "")
            }
            return FarmBoxRow(version: version, note: "Remote updates are off on the farm box", updateTo: nil)
        }
        if recent, let up {
            if up.state == "done" {
                return FarmBoxRow(version: version, note: "Updated to \(up.to ?? b?.version ?? "")", updateTo: nil)
            }
            if up.state == "failed" || up.state == "refused" {
                return FarmBoxRow(version: version,
                                  note: "Update \(up.state ?? ""): \(up.reason ?? "no reason given")", updateTo: nil)
            }
        }
        return FarmBoxRow(version: version, note: nil, updateTo: nil)
    }
}
