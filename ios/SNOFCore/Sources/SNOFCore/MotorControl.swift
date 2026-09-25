import Foundation

/* Motor control: on and off for the water-chain motors, confirmed by the
 * motor itself (docs/motor-control.md). The rules that decide are in the
 * motor_command Cloud Function and the RTDB rules; these only say, before a
 * press, what the function would refuse, so a button is never offered that
 * the farm would turn down. Mirrors motorRefusal() in app.js. */
public struct MotorControl: Hashable, Sendable {
    /// meta/motorControl/enabled (service account only; off by default).
    public var enabled = false
    /// meta/motorControl/motors/<key>: each motor armed on its own.
    public var motors: [String: Bool] = [:]
    /// meta/motorControl/zones/<key>: zone changes armed on their own.
    public var zones: [String: Bool] = [:]
    /// meta/motorControl/lastByMotor/<key>: when it last changed (server ms).
    public var lastByMotor: [String: Double] = [:]
    /// meta/motorControl/lastZoneByMotor/<key>: zone changes keep their own cooldown.
    public var lastZoneByMotor: [String: Double] = [:]
    /// meta/motorControl/lock/until: no motor may change before (server ms).
    public var lockUntil: Double?
    public init() {}

    /// The function's per-motor wait between changes.
    public static let cooldownMs: Double = 120_000

    public func armed(_ key: String) -> Bool { enabled && motors[key] == true }
    public func zonesArmed(_ key: String) -> Bool { armed(key) && zones[key] == true }

    /// Why a zone change cannot be pressed now, or nil: the motor rules plus a
    /// program running (so it can never start a motor) and another zone.
    public func zoneRefusal(_ key: String, motor: WaterMotor?, zone: Int, current: Bool, isAdmin: Bool,
                            pending: Bool, confirming: Bool, online: Bool = true, nowMs: Double) -> String? {
        if !zonesArmed(key) { return "Zone changes are turned off for this motor." }
        if let why = refusal(key, motor: motor, current: current, isAdmin: isAdmin, pending: pending,
                             confirming: confirming, online: online, nowMs: nowMs, action: "zone") { return why }
        guard let m = motor, m.running == true, m.program != nil, let now = m.zone else {
            return "No program is running, so there is no zone to change."
        }
        // As the function: heard from in the last 90 s, and 5+ minutes left on
        // the current zone, or a natural advance could read as success.
        guard let live = m.liveAt, nowMs - live.timeIntervalSince1970 * 1000 <= 90_000 else {
            return "The controller has not reported in the last 90 s. Refresh first."
        }
        let parts = (m.zoneLeft ?? "").split(separator: ":").compactMap { Int($0) }
        let left = parts.count == 3 ? parts[0] * 3600 + parts[1] * 60 + parts[2] : nil
        if left == nil || left! < 300 { return "The current zone ends in under 5 minutes. Change it after the program moves on." }
        if !(1...8).contains(zone) { return "Zones are 1 to 8." }
        if now == zone { return "It is already on zone \(zone)." }
        return nil
    }

    /// Seconds left of this motor's cooldown, or nil.
    public func cooldownLeft(_ key: String, nowMs: Double, action: String = "on") -> Int? {
        // Stopping is never held back by the cooldown; zones keep their own.
        if action == "off" { return nil }
        guard let last = (action == "zone" ? lastZoneByMotor : lastByMotor)[key], nowMs - last < Self.cooldownMs else { return nil }
        return Int(((Self.cooldownMs - (nowMs - last)) / 1000).rounded(.up))
    }

    /// Why a switch cannot be pressed now, or nil. `current`: the motor's
    /// reading says what it is doing now (WaterState.isCurrent).
    public func refusal(_ key: String, motor: WaterMotor?, current: Bool, isAdmin: Bool,
                        pending: Bool, confirming: Bool, online: Bool = true, nowMs: Double,
                        action: String = "on") -> String? {
        if !isAdmin { return "Only farm admins can switch motors." }
        if !armed(key) { return "Switching this motor is turned off at the farm." }
        if pending { return confirming ? "Sent once. Waiting for the motor to confirm…" : "Sending…" }
        if (lockUntil ?? 0) > nowMs { return "The last motor change is still being confirmed." }
        // A write queued offline would reach the farm late (the rules and the
        // function refuse it by its press time too).
        if !online { return "Offline. Motors are switched only over a live connection." }
        if let s = cooldownLeft(key, nowMs: nowMs, action: action) { return "This motor changed moments ago. Wait \(s)s." }
        guard let motor else { return "No reading from this motor." }
        if !current { return "The reading is not current. Refresh before switching." }
        if motor.running == nil { return "The motor's state is unknown." }
        return nil
    }

    /// What the confirmation asks, in the motor's own terms.
    public static func question(_ m: WaterMotor, action: String) -> String {
        if action == "off" {
            return "Stop \(m.name)?" + (m.vendor == "livesky" && m.autoStart == true
                ? " Auto-start is on: the starter may start it again when power returns." : "")
        }
        let why = m.role == "drip" || m.program != nil ? " Its drip program starts with it; the controller picks the zones."
            : m.role == "main-farm" ? " It sends water to Farm."
            : m.vendor == "livesky" ? " It pumps river water to Thoppu." : ""
        return "Start \(m.name)?" + why
    }
}
