import Foundation

/* The RTDB mirror, as Swift values. Shapes follow what the bridge actually
 * writes (addon/snof_bridge/bridge/mapper.py, irrigation.py), not what would be
 * convenient: an entity lives at /farms/<farm>/entities/<domain>/<object_id>,
 * area is absent rather than null when Home Assistant has none, and every
 * attribute is optional because ALLOWED_ATTRS is an allow-list. */

public struct Attrs: Hashable, Sendable {
    public var unit: String?
    public var deviceClass: String?
    public var batteryLevel: Double?
    /// Home Assistant's 0–255 scale, as published.
    public var brightness: Double?
    /// Fans, 0–100.
    public var percentage: Double?

    public init(unit: String? = nil, deviceClass: String? = nil, batteryLevel: Double? = nil,
                brightness: Double? = nil, percentage: Double? = nil) {
        self.unit = unit
        self.deviceClass = deviceClass
        self.batteryLevel = batteryLevel
        self.brightness = brightness
        self.percentage = percentage
    }
}

public struct Entity: Identifiable, Hashable, Sendable {
    /// `<domain>.<object_id>` — the RTDB path, which is also the HA entity id.
    public let key: String
    public let domain: String
    public let objectId: String
    public let entityId: String
    public let name: String
    public let state: String?
    /// An area id, or `unassigned`.
    public let area: String
    /// Home Assistant device id; nil only from a bridge older than 0.9.3.
    public let device: String?
    public let attrs: Attrs
    public let lastChanged: String?

    public var id: String { key }

    public init(domain: String, objectId: String, entityId: String? = nil, name: String? = nil,
                state: String?, area: String? = nil, device: String? = nil,
                attrs: Attrs = Attrs(), lastChanged: String? = nil) {
        self.domain = domain
        self.objectId = objectId
        self.key = "\(domain).\(objectId)"
        self.entityId = entityId ?? "\(domain).\(objectId)"
        self.name = (name?.isEmpty == false ? name : nil) ?? self.entityId
        self.state = state
        self.area = (area?.isEmpty == false ? area : nil) ?? Area.unassigned
        self.device = device?.isEmpty == false ? device : nil
        self.attrs = attrs
        self.lastChanged = lastChanged
    }
}

public struct Area: Identifiable, Hashable, Sendable {
    public static let unassigned = "unassigned"
    public let id: String
    public let name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

/// `meta/bridge`, rewritten by the add-on every `heartbeatSeconds`.
public struct BridgeMeta: Hashable, Sendable {
    public var status: String?
    /// Server milliseconds.
    public var lastSeen: Double?
    public var heartbeatSeconds: Double?
    /// `allow_control`. nil means a bridge too old to publish it — not the same as off.
    public var control: Bool?
    public var commandsRun: Int?
    public var commandsRefused: Int?
    /// `allow_irrigation_control` with every setting it needs. Unlike
    /// `control`, nil is off: an older bridge cannot send irrigation commands.
    public var irrigationControl: Bool?
    /// The bridge's own cap on a manual run.
    public var irrigationMaxMinutes: Int?

    public init(status: String? = nil, lastSeen: Double? = nil, heartbeatSeconds: Double? = nil,
                control: Bool? = nil,
                commandsRun: Int? = nil, commandsRefused: Int? = nil) {
        self.status = status
        self.lastSeen = lastSeen
        self.heartbeatSeconds = heartbeatSeconds
        self.control = control
        self.commandsRun = commandsRun
        self.commandsRefused = commandsRefused
    }
}

public struct FarmMeta: Hashable, Sendable {
    public var name: String?
    public var bridge: BridgeMeta?
    /// `meta/reports.enabled`: the kill switch the report Cloud Function reads.
    /// nil (never set) is on; only an explicit false blocks.
    public var reportsEnabled: Bool?
    /// `meta/irrigationControl`: valve control run by the Cloud Function
    /// (dashboard/functions/irrigation_control.py), which is where it moves
    /// off the NUC. Only an explicit true opens it; nil or false leaves the
    /// decision to the bridge's heartbeat as before.
    public var cloudIrrigationControl: Bool?
    public var cloudIrrigationMaxMinutes: Int?
    /// `meta/reports.transport`: "relay" while controller reads go through the
    /// NUC, "direct" once the function reaches Mobitech itself. nil = relay.
    public var reportsTransport: String? = nil
    public init(name: String? = nil, bridge: BridgeMeta? = nil, reportsEnabled: Bool? = nil,
                cloudIrrigationControl: Bool? = nil, cloudIrrigationMaxMinutes: Int? = nil) {
        self.name = name; self.bridge = bridge; self.reportsEnabled = reportsEnabled
        self.cloudIrrigationControl = cloudIrrigationControl
        self.cloudIrrigationMaxMinutes = cloudIrrigationMaxMinutes
    }
}

/* ---- irrigation ---- */

/// One row of a report section. Values are kept as display strings; the bridge
/// has already normalised them, and the app parses nothing it does not have to.
public typealias ReportRow = [String: String]

public struct ReportSection: Hashable, Sendable {
    /// metrics | status | series | bars | timeline | facts | lines | stack |
    /// grid | matrix. An unknown kind is skipped, never guessed at — see
    /// docs/irrigation.md.
    public var kind: String
    public var title: String
    public var note: String
    public var source: String
    public var status: String
    public var error: String
    public var unit: String
    public var rows: [ReportRow]
    /// `[{key, label}]`: which keys of a row to draw, and what to call them —
    /// the lines of a `lines` chart, the two parts of a `stack`, the columns
    /// of a `matrix`.
    public var legend: [ReportRow]

    public init(kind: String, title: String = "", note: String = "", source: String = "",
                status: String = "ok", error: String = "", unit: String = "", rows: [ReportRow] = [],
                legend: [ReportRow] = []) {
        self.legend = legend
        self.kind = kind
        self.title = title
        self.note = note
        self.source = source
        self.status = status
        self.error = error
        self.unit = unit
        self.rows = rows
    }
}

public struct Report: Identifiable, Hashable, Sendable {
    public let key: String
    public var type: String
    public var label: String
    public var from: String?
    public var to: String?
    /// ok | partial | error | anything else = still working.
    public var status: String
    public var summary: String
    public var error: String
    /// Milliseconds.
    public var at: Double
    public var sections: [ReportSection]
    /// Reports written before sections existed carry only these.
    public var legacyRows: [ReportRow]

    public var id: String { key }

    public init(key: String, type: String, label: String, from: String? = nil, to: String? = nil,
                status: String, summary: String = "", error: String = "", at: Double,
                sections: [ReportSection] = [], legacyRows: [ReportRow] = []) {
        self.key = key
        self.type = type
        self.label = label
        self.from = from
        self.to = to
        self.status = status
        self.summary = summary
        self.error = error
        self.at = at
        self.sections = sections
        self.legacyRows = legacyRows
    }
}

/// `/farms/<farm>/irrigation` — whatever the last reports left behind.
public struct IrrigationCache: Hashable, Sendable {
    public var device: String?
    public var serial: String?
    public var lastPacket: String?
    public var serverTime: String?
    public var valveNames: [ReportRow] = []
    public var valves: [ReportRow] = []
    public var electricity: [ReportRow] = []
    public var pressure: [ReportRow] = []
    /// Program runs, newest first — from the last session or timer log.
    public var timerLog: [ReportRow] = []
    /// When that log was read (server ms); nil from a function before 2026-09-25.
    public var timerLogAt: Double?
    /// One row per pump day, newest first — from the last session or motor log.
    public var motorLog: [ReportRow] = []
    /// What the controller was doing at the last controller pull.
    public var program: CurrentProgram?
    /// The controller's offset, "+05:30". Every timestamp above is in it.
    public var timeZone: String?
    public var lastUpdated: Double?
    public var lastType: String?
    public var lastError: String?

    public init() {}

    public var isEmpty: Bool {
        device == nil && valveNames.isEmpty && valves.isEmpty && electricity.isEmpty && pressure.isEmpty
            && timerLog.isEmpty && motorLog.isEmpty && program == nil
    }
}

public struct NextProgram: Hashable, Sendable {
    public var name: String
    public var valves: String
    public var plannedMin: Int?
    public init(name: String, valves: String = "", plannedMin: Int? = nil) {
        self.name = name; self.valves = valves; self.plannedMin = plannedMin
    }
}

/// `irrigation/program`: the controller dashboard's current timer, as the
/// report function caches it (`program_cache` in dashboard/functions).
public struct CurrentProgram: Hashable, Sendable {
    public var name: String
    public var kind: String
    public var running: Bool
    public var valves: String
    /// Farm time, "2026-09-23 20:41:05".
    public var start: String
    public var plannedMin: Int?
    public var remainingMin: Int?
    /// Farm time the controller last reported the timer — what remainingMin is as of.
    public var lastSeen: String = ""
    /// Valves of the running program that did not answer: "6 Kulam no signal".
    public var faults: [String] = []
    /// What the controller starts next.
    public var next: NextProgram?
    /// Server milliseconds of the pull.
    public var at: Double?

    public init(name: String = "", kind: String = "", running: Bool = false, valves: String = "",
                start: String = "", plannedMin: Int? = nil, remainingMin: Int? = nil, at: Double? = nil) {
        self.name = name; self.kind = kind; self.running = running; self.valves = valves
        self.start = start; self.plannedMin = plannedMin; self.remainingMin = remainingMin; self.at = at
    }
}
