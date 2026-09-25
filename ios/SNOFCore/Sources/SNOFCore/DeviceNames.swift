import Foundation

/* Some integrations name a device by its serial number: the 3D printer is
 * "P1S_01P09C510500118", its AMS "P1S_01P09C510500118_AMS_1", a camera
 * station "T8400P202040124D". They read as what they are; renaming the device
 * in Home Assistant fixes it at the source. Mirrors tidyDeviceName() and
 * tidyNames() in app.js. */
public enum DeviceNames {
    private static let bambu = try! NSRegularExpression(
        pattern: #"^(P1S|P1P|X1C|X1E|X1|A1M|A1|H2D|H2S)_(?=(?:[A-Z]*\d){6})[0-9A-Z]{12,}(?:_(.+))?$"#)
    private static let serial = try! NSRegularExpression(pattern: #"^(?=(?:[A-Z]*\d){6})[A-Z0-9]{10,}$"#)

    /// "P1S printer", "P1S AMS 1", "P1S external spool"; a serial-named device
    /// whose entity ids all start alike takes that ("goats_…" -> "Goats").
    /// Anything else is returned as it is.
    public static func tidy(_ raw: String, objectIds: [String]) -> String {
        let ns = raw as NSString
        let all = NSRange(location: 0, length: ns.length)
        if let m = bambu.firstMatch(in: raw, range: all) {
            let model = ns.substring(with: m.range(at: 1))
            guard m.range(at: 2).location != NSNotFound else { return "\(model) printer" }
            let rest = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "_", with: " ")
                .replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
            let keepCase = rest.range(of: "^[A-Z]{2}", options: .regularExpression) != nil
            return "\(model) \(keepCase ? rest : rest.lowercased())"
        }
        // Two ids at least: one id's "prefix" is the whole id ("goats_motion_detected").
        if serial.firstMatch(in: raw, range: all) != nil, objectIds.count >= 2 {
            // Home Assistant keeps the name a device had when its entities were
            // made in their ids: "goats_motion_detected", under a station now
            // called by its serial number.
            let parts = objectIds.map { $0.split(separator: "_", omittingEmptySubsequences: false).map(String.init) }
            var n = 0
            while parts.allSatisfy({ $0.count > n && $0[n] == parts[0][n] }) { n += 1 }
            let slug = parts[0].prefix(n).joined(separator: " ")
            if slug.count >= 3, let head = parts[0].first, !raw.lowercased().hasPrefix(head) {
                return slug.prefix(1).uppercased() + slug.dropFirst()
            }
        }
        return raw
    }

    /// Device names as the farm reads them, and entity names re-based on
    /// them. The raw names stay with the caller for anything that matches on
    /// them (a printer's add-ons, in Systems.build).
    public static func apply(_ entities: [Entity], names raw: [String: String]) -> (entities: [Entity], names: [String: String]) {
        var ids: [String: [String]] = [:]
        for e in entities { if let d = e.device { ids[d, default: []].append(e.objectId) } }
        var names = raw
        var renamed: [String: (raw: String, tidy: String)] = [:]
        for (id, objectIds) in ids {
            guard let r = raw[id] else { continue }
            let t = tidy(r, objectIds: objectIds)
            if t != r { names[id] = t; renamed[id] = (r, t) }
        }
        let out = entities.map { e0 -> Entity in
            var e = e0
            // "Solar Solar Power": a device named "Solar" with the integration's
            // own "Solar Power" sensor. Say the device once.
            if let d = e.device, let own = raw[d], e.name.hasPrefix("\(own) \(own)") {
                let after = e.name.dropFirst(own.count * 2 + 1)
                if after.isEmpty || after.hasPrefix(" ") { e = e.renamed(String(e.name.dropFirst(own.count + 1))) }
            }
            guard let d = e.device, let r = renamed[d], e.name.hasPrefix(r.raw) else { return e }
            let after = e.name.dropFirst(r.raw.count)
            guard after.isEmpty || after.hasPrefix(" ") else { return e }
            // "T8400P202040124D Goats" is the station's own entity: "Goats", not "Goats Goats".
            let rest = after.trimmingCharacters(in: .whitespaces)
            let repeats = rest.lowercased().hasPrefix(r.tidy.lowercased())
                && (rest.count == r.tidy.count || rest.dropFirst(r.tidy.count).hasPrefix(" "))
            return e.renamed(repeats ? rest : rest.isEmpty ? r.tidy : "\(r.tidy) \(rest)")
        }
        return (out, names)
    }
}

extension Entity {
    /// The same entity under another display name.
    public func renamed(_ name: String) -> Entity {
        Entity(domain: domain, objectId: objectId, entityId: entityId, name: name, state: state,
               area: area, device: device, attrs: attrs, lastChanged: lastChanged)
    }
}
