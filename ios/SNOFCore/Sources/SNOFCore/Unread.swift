import Foundation

/* When a source cannot be read, the apps say so where its reading would be,
 * and never show the last reading as if it were now (owner, 2026-09-26:
 * "when the api fails or you dont have auth you should say that explicitly
 * … the app just says that the motor is not running"). Mirrors unread*() in
 * dashboard/public/app.js. */
public enum Unread {
    /// Why the controller cannot be read now, or nil. Only a failure after
    /// the last good read counts: a later success means it was read.
    public static func controller(_ c: IrrigationCache) -> String? {
        guard let err = c.controllerError else { return nil }
        let good = c.program?.at ?? 0
        if let at = c.controllerErrorAt, at < good { return nil }
        return words(err)
    }

    /// A vendor error in a person's words.
    public static func words(_ raw: String) -> String {
        let t = raw.lowercased()
        if t.contains("signed this session out") || t.contains("other mobile") || t.contains("re-sign") {
            return "Mobitech signed SNOF out"
        }
        if t.contains("bridge did not answer") || t.contains("nuc online") { return "The farm box did not answer" }
        if t.contains("not configured") { return "Mobitech is not set up" }
        if t.contains("http") || t.contains("timeout") || t.contains("connectionerror") || t.contains("not json") {
            return "Mobitech did not answer"
        }
        let short = raw.replacingOccurrences(of: #"^DCON [a-z_]+: "#, with: "", options: .regularExpression)
        return String(short.prefix(60))
    }

    /// Why a water motor cannot be read now, or nil.
    public static func motor(_ m: WaterMotor, _ w: WaterState, nowMs: Double) -> String? {
        if m.vendor == "livesky" {
            switch w.livesky.kind(nowMs: nowMs) {
            case .ok: return nil
            case .none: return "Not signed in to Livesky"
            case .expired: return "Livesky sign-in expired"
            case .error: return w.livesky.status.error.isEmpty ? "Livesky did not answer" : String(w.livesky.status.error.prefix(60))
            }
        }
        if w.niagara.ok == false { return "Niagara did not answer" }
        return nil
    }
}
