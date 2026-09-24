import Foundation

/* Which farm illustration (from the DCON design assets) goes with a valve.
 *
 * The controller names valves "<number> <word>": "4 Veg", "6 Kulam",
 * "13 Gova 1". The word is what the valve waters, so it picks the picture.
 * Anything unrecognised gets nil and the caller keeps its plain icon — a
 * wrong crop on a valve is worse than no crop.
 *
 * Mirrored by valveArt() in dashboard/public/app.js; keep the two tables in
 * step. Keys are file names: art-<key> in the iOS asset catalog,
 * /art/<key>.png on the web. */
public enum ValveArt {

    static let words: [String: String] = [
        "veg": "veg", "vegetable": "veg", "vegetables": "veg",
        "onion": "onion", "kulam": "kulam", "grass": "grass", "house": "house",
        "mulberry": "mulberry",
        "coco": "coconut", "coconut": "coconut",
        "gova": "guava", "guava": "guava",        // the controller spells it "Gova"
        "mango": "mango", "amla": "amla", "jamun": "jamun",
        "pomegranate": "pomegranate", "backwash": "backwash",
    ]

    /// - Parameters:
    ///   - name: the controller's valve name, e.g. "13 Gova 1".
    ///   - type: the valve type, e.g. "Irrigation", "Booster Pump", "Backwash".
    ///   - status: "on" / "off" / other, for the motor picture.
    public static func key(name: String?, type: String? = nil, status: String? = nil) -> String? {
        let t = (type ?? "").lowercased()
        let tokens = (name ?? "").lowercased()
            .split(whereSeparator: { !$0.isLetter })
            .map(String.init)
        // A pump is a motor whatever it is called; its picture shows on/off.
        if t.contains("pump") || tokens.contains(where: { $0 == "bpump" || $0 == "pump" || $0 == "motor" }) {
            return status == "on" ? "motor-on" : "motor-off"
        }
        if t.contains("backwash") { return "backwash" }
        for tok in tokens { if let k = words[tok] { return k } }
        return nil
    }

    /// Timeline rows carry a source, not a valve: motor or timer.
    public static func key(timelineSource source: String?) -> String? {
        switch source?.lowercased() {
        case "motor": return "motor-on"
        case "timer": return "timer"
        default: return nil
        }
    }
}
