import SwiftUI
import Charts
import SNOFCore

/* Nothing here is polled. Each report answers a press of Generate: the app
 * appends a request to /farms/<farm>/irrigation_requests, the bridge on the
 * NUC makes the controller call with its own credentials, and writes the
 * sanitized result to irrigation_reports. This screen never sees a vendor
 * credential and cannot operate a pump or a valve. */
struct IrrigationView: View {
    @Environment(FarmStore.self) private var store
    @State private var type = "live_readings"
    @State private var from = Calendar.current.date(byAdding: .day, value: -2, to: .now) ?? .now
    @State private var to = Date.now
    @State private var sending = false

    var body: some View {
        Page {
            SectionHead(symbol: "drop", title: "Generate report")
            if store.canControl { builder } else {
                Note(text: "Report generation is limited to controllers — your account can view results below, but not run new pulls.")
            }

            SectionHead(symbol: "doc.text", title: "Reports")
            if store.reports.isEmpty {
                let gate = store.gate(.irrigation)
                EmptyBlock(title: "No reports yet",
                           message: !store.canControl ? "No reports have been run yet."
                               : !gate.ok ? gate.why : "Pick a report above and press Generate.",
                           symbol: "doc.text")
            } else {
                ForEach(store.reports) { ReportCard(report: $0) }
            }

            if !store.irrigation.isEmpty { LastResults(cache: store.irrigation) }

            Note(text: "Read-only pulls — this screen cannot operate pumps or valves.")
                .padding(.top, 8)
        }
        .navigationTitle("Irrigation")
    }

    @ViewBuilder private var builder: some View {
        let gate = store.gate(.irrigation)
        let needsRange = IrrigationTypes.find(type)?.needsRange ?? false
        let waiting = !store.waitingReports.isEmpty
        VStack(alignment: .leading, spacing: 0) {
            Picker("Report", selection: $type) {
                Section("Combined") {
                    ForEach(IrrigationTypes.all.filter(\.combined)) { Text($0.label).tag($0.type) }
                }
                Section("Single endpoint") {
                    ForEach(IrrigationTypes.all.filter { !$0.combined }) { Text($0.label).tag($0.type) }
                }
            }
            .pickerStyle(.menu)
            .tint(Theme.text)
            .frame(minHeight: Theme.hit)

            if needsRange {
                Divider().overlay(Theme.line)
                DatePicker("From", selection: $from, in: ...to, displayedComponents: .date)
                    .frame(minHeight: Theme.hit)
                Divider().overlay(Theme.line)
                DatePicker("To", selection: $to, in: from...Date.now, displayedComponents: .date)
                    .frame(minHeight: Theme.hit)
            }

            Button {
                sending = true
                Task {
                    await store.requestReport(type: type, from: from, to: to)
                    sending = false
                }
            } label: {
                HStack {
                    if waiting || sending { ProgressView().controlSize(.small).tint(.white) }
                    Text(waiting ? "Working…" : "Generate report").font(.body.weight(.semibold))
                }
                .frame(maxWidth: .infinity, minHeight: Theme.hit)
                .foregroundStyle(.white)
                .background(Theme.brand, in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(waiting || sending || !gate.ok)
            .opacity(waiting || sending || !gate.ok ? 0.5 : 1)
            .padding(.top, 10)
        }
        .font(.subheadline)
        .foregroundStyle(Theme.text)
        .panel()

        if !gate.ok { Note(text: gate.why, tone: .warn) }
        if waiting {
            Note(text: "Pulling from the controller — the result lands below, usually within a minute.")
        }
    }
}

/* ---- one report ---- */

struct ReportCard: View {
    let report: Report

    var body: some View {
        let drawable = report.sections.filter { ReportSectionView.kinds.contains($0.kind) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(report.label).font(.headline).foregroundStyle(Theme.text)
                statusTag
                Spacer(minLength: 0)
            }
            Text(when).font(.caption).foregroundStyle(Theme.muted)
            if !report.summary.isEmpty {
                Text(report.summary).font(.subheadline).foregroundStyle(Theme.text)
            }
            if report.status == "error", !report.error.isEmpty {
                Text(report.error).font(.subheadline).foregroundStyle(Theme.bad)
            }
            if report.sections.isEmpty {
                LegacyBody(report: report)
            } else {
                ForEach(Array(drawable.enumerated()), id: \.offset) { _, sec in
                    ReportSectionView(section: sec, withTitle: drawable.count > 1)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }

    /// Three outcomes, three tags: a report where one call answered and one
    /// did not is not "Ready", and must not read as if it were.
    @ViewBuilder private var statusTag: some View {
        switch report.status {
        case "ok": Tag(text: "Ready", kind: .on)
        case "partial": Tag(text: "Partly ready", kind: .warn)
        case "error": Tag(text: "Failed", kind: .bad)
        default: Tag(text: "Working…")
        }
    }

    private var when: String {
        var bits: [String] = []
        if let f = report.from, let t = report.to { bits.append("\(f) → \(t)") }
        if report.at > 0 {
            bits.append(Date(timeIntervalSince1970: report.at / 1000).formatted(date: .abbreviated, time: .shortened))
        }
        return bits.joined(separator: " · ")
    }
}

/// Draws by kind, never by sniffing shapes. An unknown kind is skipped, so the
/// bridge can add one without breaking an old build of this app.
struct ReportSectionView: View {
    static let kinds: Set<String> = ["metrics", "status", "series", "bars", "timeline", "facts"]
    static let rowCap = 8

    let section: ReportSection
    let withTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if withTitle, !section.title.isEmpty {
                HStack(spacing: 6) {
                    Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.text)
                    if !section.source.isEmpty { Tag(text: section.source) }
                }
            }
            if section.status == "error" {
                Text(section.error.isEmpty ? "This part of the report did not come back." : section.error)
                    .font(.footnote).foregroundStyle(Theme.bad)
            } else {
                content
                if !section.note.isEmpty { Text(section.note).font(.footnote).foregroundStyle(Theme.muted) }
            }
        }
        .padding(.top, 4)
    }

    @ViewBuilder private var content: some View {
        let rows = section.rows
        switch section.kind {
        case "metrics": Metrics(rows: rows)
        case "facts": Facts(rows: rows)
        case "status":
            SimpleRows(rows: Array(rows.prefix(Self.rowCap)), art: valveArt) { r in
                (r["name"] ?? "Valve", r["meta"] ?? "", r["status"])
            }
            more(rows.count, "rows")
        case "series": Series(rows: rows, unit: section.unit)
        case "bars":
            Bars(items: rows.map { ($0["name"] ?? "Valve", Int(Double($0["value"] ?? "") ?? 0), $0["status"] == "on", valveArt($0)) })
        case "timeline":
            Timeline(rows: Array(rows.prefix(Self.rowCap)))
            more(rows.count, "entries")
        default: EmptyView()
        }
    }

    @ViewBuilder private func more(_ total: Int, _ what: String) -> some View {
        if total > Self.rowCap {
            Text("\(total - Self.rowCap) more \(what) in this report.").font(.footnote).foregroundStyle(Theme.muted)
        }
    }
}

private struct Metrics: View {
    let rows: [ReportRow]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            ForEach(Array(rows.filter { !($0["value"] ?? "").isEmpty }.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 3) {
                    Text(r["label"] ?? "").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(r["value"] ?? "").font(.title3.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.text)
                        if let u = r["unit"], !u.isEmpty { Text(u).font(.caption).foregroundStyle(Theme.muted) }
                    }
                    if let n = r["note"], !n.isEmpty {
                        Text(n).font(.caption2).foregroundStyle(Theme.muted).lineLimit(2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
            }
        }
    }
}

private struct Facts: View {
    let rows: [ReportRow]
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.filter { !($0["value"] ?? "").isEmpty }.enumerated()), id: \.offset) { i, r in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack {
                    Text(r["label"] ?? "").foregroundStyle(Theme.muted)
                    Spacer()
                    Text(r["value"] ?? "").foregroundStyle(Theme.text).multilineTextAlignment(.trailing)
                }
                .font(.subheadline).padding(.vertical, 8)
            }
        }
    }
}

private struct SimpleRows: View {
    let rows: [ReportRow]
    var art: (ReportRow) -> String? = { _ in nil }
    let map: (ReportRow) -> (String, String, String?)
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                let (name, meta, status) = map(r)
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                HStack(spacing: 10) {
                    ValveGlyph(art: art(r))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(name).font(.subheadline).foregroundStyle(Theme.text)
                        if !meta.isEmpty { Text(meta).font(.caption).foregroundStyle(Theme.muted) }
                    }
                    Spacer()
                    if let status { ValveTag(status: status) }
                }
                .padding(.vertical, 8)
            }
        }
    }
}

/// The farm's own picture for what a valve waters (DCON design assets), or
/// the plain tap icon when the name is not one it recognises.
struct ValveGlyph: View {
    let art: String?
    var size: CGFloat = 28
    var body: some View {
        if let art {
            Image("art-\(art)").resizable().interpolation(.high).scaledToFit()
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        } else {
            Image(systemName: "spigot").foregroundStyle(Theme.muted).frame(width: size, height: size)
        }
    }
}

let valveArt: (ReportRow) -> String? = { ValveArt.key(name: $0["name"], type: $0["type"] ?? $0["meta"], status: $0["status"]) }

struct ValveTag: View {
    let status: String
    var body: some View {
        switch status {
        case "on": Tag(text: "Running", kind: .on)
        case "off": Tag(text: "Off")
        default: Tag(text: "Unknown")
        }
    }
}

private struct Series: View {
    let rows: [ReportRow]
    let unit: String

    var body: some View {
        let pts = rows.enumerated().compactMap { i, r -> (Int, String, Double)? in
            guard let v = Double(r["value"] ?? "") else { return nil }
            return (i, r["at"] ?? "", v)
        }
        let u = unit.isEmpty ? (rows.first { !($0["unit"] ?? "").isEmpty }?["unit"] ?? "") : unit
        if pts.count >= 2, let lo = pts.map(\.2).min(), let hi = pts.map(\.2).max(), let last = pts.last {
            VStack(alignment: .leading, spacing: 6) {
                Chart(pts, id: \.0) { p in
                    LineMark(x: .value("Reading", p.0), y: .value("Value", p.2))
                        .foregroundStyle(Theme.brand)
                        .interpolationMethod(.monotone)
                }
                .chartPlotStyle { $0.clipped() }   // the area mark's baseline is 0, far below the domain
                .chartXAxis(.hidden)
                .chartYScale(domain: (lo - (hi - lo) * 0.1)...(hi + (hi - lo) * 0.1 + 0.001))
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 90)
                .accessibilityLabel("\(pts.count) readings from \(fmt(lo, u)) to \(fmt(hi, u)), latest \(fmt(last.2, u))")
                HStack {
                    Text("\(fmt(lo, u)) min")
                    Spacer()
                    Text("\(fmt(last.2, u)) latest").foregroundStyle(Theme.text).fontWeight(.semibold)
                    Spacer()
                    Text("\(fmt(hi, u)) max")
                }
                .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
            }
        } else {
            // One reading is not a curve. Show it as a reading.
            SimpleRows(rows: Array(rows.prefix(8))) { r in
                ([r["value"], r["unit"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "), r["at"] ?? "", nil)
            }
        }
    }

    private func fmt(_ v: Double, _ u: String) -> String {
        let s = v.formatted(.number.precision(.fractionLength(0...2)))
        return u.isEmpty ? s : "\(s) \(u)"
    }
}

private struct Bars: View {
    let items: [(name: String, minutes: Int, on: Bool, art: String?)]
    var body: some View {
        let rows = items.filter { $0.minutes > 0 }
        let top = max(rows.map(\.minutes).max() ?? 1, 1)
        VStack(spacing: 8) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                HStack(spacing: 8) {
                    ValveGlyph(art: r.art, size: 22)
                    Text(r.name).font(.caption).foregroundStyle(Theme.text).lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(r.on ? Theme.brand : Theme.muted)
                                .frame(width: max(6, g.size.width * CGFloat(r.minutes) / CGFloat(top)))
                        }
                    }
                    .frame(height: 8)
                    Text(Format.minutes(r.minutes)).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                        .frame(width: 56, alignment: .trailing)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct Timeline: View {
    let rows: [ReportRow]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { i, r in
                let (day, time) = split(r["at"] ?? "")
                let prevDay = i > 0 ? split(rows[i - 1]["at"] ?? "").0 : ""
                if !day.isEmpty && day != prevDay {
                    Text(day).font(.caption.weight(.semibold)).foregroundStyle(Theme.muted).padding(.top, i > 0 ? 8 : 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(time.isEmpty ? "—" : time).font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                        .frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r["detail"] ?? r["event"] ?? "entry").font(.subheadline).foregroundStyle(Theme.text)
                        if r["detail"] != nil, let ev = r["event"] {
                            Text(ev).font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    if let art = ValveArt.key(timelineSource: r["source"]) {
                        ValveGlyph(art: art, size: 22)
                    }
                    if let s = r["source"], !s.isEmpty { Tag(text: s) }
                }
                .padding(.vertical, 5)
            }
        }
    }

    private func split(_ at: String) -> (String, String) {
        guard at.range(of: #"^\d{4}-\d{2}-\d{2}"#, options: .regularExpression) != nil else { return ("", at) }
        let t = at.dropFirst(11).prefix(5)
        return (String(at.prefix(10)), String(t))
    }
}

/// Reports written before sections existed: kept readable, never guessed at.
private struct LegacyBody: View {
    let report: Report
    var body: some View {
        let rows = report.legacyRows
        if report.status == "ok", report.type == "valves" {
            Bars(items: rows.map { ($0["name"] ?? "Valve", Format.runtimeMinutes($0["runtime"]), $0["status"] == "on", valveArt($0)) })
        }
        SimpleRows(rows: Array(rows.prefix(6))) { r in
            let name = r["name"] ?? r["event"] ?? r["id"] ?? report.label
            let meta = [r["status"], r["detail"], r["runtime"],
                        [r["value"], r["unit"]].compactMap { $0 }.joined(separator: " "), r["at"]]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return (name, meta, nil)
        }
        if rows.count > 6 {
            Text("\(rows.count - 6) more rows in this report.").font(.footnote).foregroundStyle(Theme.muted)
        }
    }
}

/* ---- the cache the last reports left behind ---- */

private struct LastResults: View {
    let cache: IrrigationCache

    var body: some View {
        SectionHead(symbol: "spigot", title: "Last results")
        if let at = cache.lastUpdated {
            Note(text: "From \(cache.lastType ?? "a report") · \(Date(timeIntervalSince1970: at / 1000).formatted(date: .abbreviated, time: .shortened))."
                 + (cache.lastError.map { " Last error: \($0)." } ?? ""))
        }
        let open = cache.valves.filter { $0["status"] == "on" }.count
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ReadingTile(label: "Valves open", value: "\(open)", note: "of \(cache.valves.count) last seen", on: open > 0)
            ReadingTile(label: "Pressure", value: latest(cache.pressure), note: cache.pressure.isEmpty ? "no pull yet" : "last reading")
            ReadingTile(label: "Electricity", value: latest(cache.electricity), note: cache.electricity.isEmpty ? "no pull yet" : "last reading")
        }
        let facts: [ReportRow] = [("Device", cache.device), ("Serial", cache.serial),
                                  ("Last packet", cache.lastPacket), ("Controller clock", cache.serverTime)]
            .compactMap { k, v in v.map { ["label": k, "value": $0] } }
        if !facts.isEmpty { Facts(rows: facts).panel(padding: 12) }
        if !cache.valves.isEmpty {
            SimpleRows(rows: cache.valves, art: valveArt) { v in
                (v["name"] ?? "Valve \(v["id"] ?? "")", [v["runtime"], v["id"]].compactMap { $0 }.joined(separator: " · "), v["status"] ?? "unknown")
            }
            .panel(padding: 12)
        } else if !cache.valveNames.isEmpty {
            SimpleRows(rows: cache.valveNames, art: valveArt) { v in (v["name"] ?? "Valve", v["type"] ?? "valve \(v["id"] ?? "")", nil) }
                .panel(padding: 12)
        }
    }

    private func latest(_ rows: [ReportRow]) -> String {
        guard let last = rows.last else { return "—" }
        return [last["value"], last["unit"]].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
    }
}

private struct ReadingTile: View {
    let label: String
    let value: String
    let note: String
    var on = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
            Text(value).font(.title2.weight(.semibold).monospacedDigit()).foregroundStyle(on ? Theme.on : Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}
