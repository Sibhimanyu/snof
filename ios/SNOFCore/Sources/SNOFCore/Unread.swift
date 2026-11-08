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

    /// Mobitech has signed SNOF out when a read failed that way after the
    /// session was last signed in (mobitech_status.at). Returns when (ms) the
    /// newest such failure happened; nil when the session is as signed in.
    /// A failure with no stamp counts only when there is no sign-in time.
    public static func mobitechSignedOut(_ c: IrrigationCache, signedInAt: Double?) -> Double? {
        var newest: Double?
        for (type, err) in c.readErrors where words(err) == "Mobitech signed SNOF out" {
            let at = c.readErrorAts[type]
            if let at { newest = max(newest ?? 0, at) } else if newest == nil { newest = 0 }
        }
        if let ce = c.controllerError, words(ce) == "Mobitech signed SNOF out" {
            newest = max(newest ?? 0, c.controllerErrorAt ?? 0)
        }
        guard let n = newest else { return nil }
        if let s = signedInAt { return n > s ? n : nil }
        return n > 0 ? n : nil
    }

    /// Why Home Assistant — every device, the power lines, the cameras —
    /// cannot be read now, or nil: the farm box has gone quiet or offline.
    public static func homeAssistant(_ s: BridgeStatus) -> String? {
        switch s {
        case .offline: return "the farm box is offline"
        case .stale(let age): return "the farm box has not reported for \(Format.age(age))"
        case .live, .unknown: return nil
        }
    }

    /// Why the last Mobitech read of this type failed ("live_readings",
    /// "session_log", …), or nil. The function clears it on the next success.
    public static func read(_ c: IrrigationCache, _ type: String) -> String? {
        c.readErrors[type].map(words)
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
