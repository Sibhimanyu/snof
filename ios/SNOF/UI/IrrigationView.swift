import SwiftUI
import Charts
import SNOFCore

/* Nothing here is polled. Each report answers a press of Generate: the app
 * appends a request to /farms/<farm>/irrigation_requests, a Cloud Function
 * (dashboard/functions) makes the controller calls with credentials held in
 * Secret Manager, and writes the finished report to irrigation_reports. This screen never sees a vendor
 * credential and cannot operate a pump or a valve. */
struct IrrigationView: View {
    @Environment(FarmStore.self) private var store
    @State private var type = "live_readings"
    @State private var from = Calendar.current.date(byAdding: .day, value: -2, to: .now) ?? .now
    @State private var to = Date.now
    @State private var sending = false
    /// The report open in the sheet, by key, so it keeps updating while open.
    @State private var opened: OpenReport?
    /// Set by Generate: the next report to land opens by itself.
    @State private var awaitingNew = false

    @State private var building = false
    @State private var account = false

    /// Everything irrigation, as modules (owner, 2026-09-25): what the
    /// controller is doing with Run / Stop, the valves, the last day, the
    /// supply, and the reports. Mirrors irrigationView() in app.js.
    var body: some View {
        Page(title: "Irrigation", refresh: store.irrigationPull) {
            IrrigationNowCard()
            PumpPowerCard()
            WateredCard()

            HStack(alignment: .firstTextBaseline) {
                Text("Reports").font(Theme.panelTitle).foregroundStyle(Theme.text)
                if !store.latestReports.isEmpty { Text("\(store.latestReports.count)").font(Theme.small).foregroundStyle(Theme.faint) }
                Spacer()
                if store.canControl { LinkButton(label: "New report", run: { building = true }) }
            }
            .padding(.top, 14)
            if store.latestReports.isEmpty {
                Note(text: "No reports yet.")
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(store.latestReports.enumerated()), id: \.element.id) { i, r in
                        if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                        Button { opened = OpenReport(id: r.key) } label: { ReportListRow(report: r, now: store.now) }
                            .buttonStyle(.plain)
                    }
                }
                .modifier(Panel(padding: 0))
            }
            if store.isAdmin {
                AccountRow(title: "Mobitech account", problem: store.mobitechProblem) { account = true }
                    .padding(.top, 10)
            }
        }
        .navigationTitle("Irrigation")
        .task { await store.autoRefreshIrrigationIfStale() }
        .sheet(item: $opened) { open in
            ReportSheet(reportKey: open.id).environment(store)
        }
        .sheet(isPresented: $building) {
            NavigationStack {
                ScrollView { builder.padding(16) }
                    .background(Theme.bg)
                    .navigationTitle("New report").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { building = false } } }
            }
            .environment(store)
            .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $account) {
            NavigationStack {
                Form { Section { MobitechSignIn() } footer: {
                    Text("The number and the SMS code are never stored; the session is kept where no app can read it.")
                } }
                .navigationTitle("Mobitech account").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { account = false } } }
            }
            .environment(store)
        }
        #if DEBUG
        .task {
            if Snapshot.args.contains("-open-report") {
                try? await Task.sleep(for: .seconds(1))
                if let k = store.reports.first?.key { opened = OpenReport(id: k) }
            }
        }
        #endif
        // The report you just asked for opens by itself when it lands.
        .onChange(of: store.reports.first?.key) { old, new in
            guard awaitingNew, let new, new != old else { return }
            awaitingNew = false
            opened = OpenReport(id: new)
        }
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
                Haptics.tap()
                sending = true
                awaitingNew = true
                building = false
                Task {
                    await store.requestReport(type: type, from: from, to: to)
                    sending = false
                }
            } label: {
                HStack {
                    if waiting || sending { ProgressView().controlSize(.small).tint(.white) }
                    Text(waiting ? "Working…" : "Generate report").font(Theme.font(16, .semibold, relativeTo: .body))
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
        .font(Theme.font(14.5, .regular, relativeTo: .subheadline))
        .foregroundStyle(Theme.text)
        .panel()

        if !gate.ok { Note(text: gate.why, tone: .warn) }
        if waiting {
            Note(text: "Pulling from the controller — the result lands below, usually within a minute.")
        }
    }
}

/* ---- the report list and the report sheet ---- */

struct OpenReport: Identifiable, Hashable { let id: String }

/// One report as a list row: what it is, whether it worked, when, and the
/// one-line summary. The full report is a tap away.
struct ReportListRow: View {
    let report: Report
    let now: Date

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(report.label).font(Theme.font(15, .bold, relativeTo: .subheadline)).tracking(-0.2)
                        .foregroundStyle(Theme.text).lineLimit(1)
                    Spacer(minLength: 4)
                    ReportStatusTag(status: report.status)
                }
                Text(meta).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1)
                if report.status == "error", !report.error.isEmpty {
                    Text(report.error).font(Theme.meta).foregroundStyle(Theme.bad).lineLimit(2)
                } else if !summary.isEmpty {
                    Text(summary).font(Theme.font(13.5, .regular, relativeTo: .footnote))
                        .foregroundStyle(Theme.text.opacity(0.85)).lineLimit(2)
                }
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
        .frame(minHeight: 64)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the report")
    }

    private var summary: String { report.summaryWithoutRange }

    /// "2026-02-20 → 2026-02-22 · 2h ago".
    private var meta: String {
        var bits: [String] = []
        if let f = report.from, let t = report.to { bits.append(f == t ? f : "\(f) → \(t)") }
        if report.at > 0 {
            let age = now.timeIntervalSince1970 - report.at / 1000
            bits.append(age < 60 ? "just now" : "\(Format.age(age)) ago")
        }
        return bits.isEmpty ? "Waiting for the controller" : bits.joined(separator: " · ")
    }
}

/// The whole report, on its own, looked up by key so a report still being
/// written fills in while it is open.
struct ReportSheet: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .system
    let reportKey: String

    var body: some View {
        NavigationStack {
            ScrollView {
                if let report = store.reports.first(where: { $0.key == reportKey }) {
                    ReportSheetContent(report: report)
                } else {
                    EmptyBlock(title: "Report no longer here",
                               message: "Only the latest reports are kept. Generate it again for fresh numbers.",
                               symbol: "doc.text")
                        .padding(16)
                }
            }
            .background(Theme.bg)
            .navigationTitle("Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.font(Theme.font(16, .bold, relativeTo: .body))
                }
            }
            .toolbarBackground(.bar, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(appearance.scheme)
    }
}

/// What the sheet shows for one report: eyebrow, title, then the report.
struct ReportSheetContent: View {
    let report: Report
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Irrigation report").eyebrowStyle()
            Text(report.label).font(Theme.font(28, .bold, relativeTo: .title)).tracking(-1)
                .foregroundStyle(Theme.text).fixedSize(horizontal: false, vertical: true)
            ReportBody(report: report, showTitle: false)
        }
        .padding(16)
        .frame(maxWidth: 820, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

extension Report {
    /// The summary without the date range, which the line above it already
    /// shows (the function appends it; the sheet showed it twice).
    var summaryWithoutRange: String {
        var s = summary
        if let f = from, let t = to {
            for range in ["\(f) → \(t)", f == t ? f : nil].compactMap({ $0 }) {
                if s.hasSuffix(" · " + range) { s.removeLast(range.count + 3) }
                else if s == range { s = "" }
            }
        }
        return s
    }
}

/// Three outcomes, three tags: a report where one call answered and one
/// did not is not "Ready", and must not read as if it were.
struct ReportStatusTag: View {
    let status: String
    var body: some View {
        switch status {
        case "ok": Tag(text: "Ready", kind: .on)
        case "partial": Tag(text: "Partly ready", kind: .warn)
        case "error": Tag(text: "Failed", kind: .bad)
        default: Tag(text: "Working…")
        }
    }
}

/* ---- one report ---- */

/// A full report in a panel. The list uses rows and the sheet uses
/// ReportBody; this stays for the -reports review snapshot.
struct ReportCard: View {
    let report: Report

    var body: some View {
        ReportBody(report: report, showTitle: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .panel()
    }
}

/// Everything a report says, without a frame: status and when, summary or
/// error, then its sections drawn by kind.
struct ReportBody: View {
    let report: Report
    var showTitle = true

    var body: some View {
        let drawable = report.sections.filter { ReportSectionView.kinds.contains($0.kind) }
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if showTitle {
                    Text(report.label).font(Theme.font(16.5, .bold, relativeTo: .headline)).foregroundStyle(Theme.text)
                }
                ReportStatusTag(status: report.status)
                Spacer(minLength: 0)
            }
            Text(when).font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted)
            if !report.summaryWithoutRange.isEmpty {
                Text(report.summaryWithoutRange).font(Theme.font(14.5, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.text)
            }
            if report.status == "error", !report.error.isEmpty {
                Text(report.error).font(Theme.font(14.5, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.bad)
            }
            if report.sections.isEmpty {
                LegacyBody(report: report)
            } else {
                ForEach(Array(drawable.enumerated()), id: \.offset) { _, sec in
                    ReportSectionView(section: sec, withTitle: drawable.count > 1)
                }
            }
        }
    }

    private var when: String {
        var bits: [String] = []
        if let f = report.from, let t = report.to { bits.append("\(f) → \(t)") }
        if report.at > 0 {
            bits.append(FarmTime.when(ms: report.at, now: Date()))
        }
        return bits.joined(separator: " · ")
    }
}

/// Draws by kind, never by sniffing shapes. An unknown kind is skipped, so the
/// bridge can add one without breaking an old build of this app.
struct ReportSectionView: View {
    static let kinds: Set<String> = ["metrics", "status", "series", "bars", "timeline", "facts",
                                     "lines", "stack", "grid", "matrix"]
    static let rowCap = 8

    let section: ReportSection
    let withTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if withTitle, !section.title.isEmpty {
                HStack(spacing: 6) {
                    Text(section.title).font(Theme.font(14.5, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                    if !section.source.isEmpty { Tag(text: section.source, dot: false) }
                }
            }
            if section.status == "error" {
                Text(section.error.isEmpty ? "This part of the report did not come back." : section.error)
                    .font(Theme.font(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.bad)
            } else {
                content
                if !section.note.isEmpty { Text(section.note).font(Theme.font(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.muted) }
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
        case "lines": Lines(section: section)
        case "stack": Stack(section: section)
        case "grid": ValveGrid(rows: rows)
        case "matrix": Matrix(section: section)
        default: EmptyView()
        }
    }

    @ViewBuilder private func more(_ total: Int, _ what: String) -> some View {
        if total > Self.rowCap {
            Text("\(total - Self.rowCap) more \(what) in this report.").font(Theme.font(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.muted)
        }
    }
}

private struct Metrics: View {
    let rows: [ReportRow]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 8)], spacing: 8) {
            ForEach(Array(rows.filter { !($0["value"] ?? "").isEmpty }.enumerated()), id: \.offset) { _, r in
                VStack(alignment: .leading, spacing: 3) {
                    Text(r["label"] ?? "").font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted).lineLimit(1)
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(r["value"] ?? "").font(Theme.font(20, .semibold, relativeTo: .title3).monospacedDigit()).foregroundStyle(Theme.text)
                        if let u = r["unit"], !u.isEmpty { Text(u).font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted) }
                    }
                    if let n = r["note"], !n.isEmpty {
                        Text(n).font(Theme.font(11, .regular, relativeTo: .caption2)).foregroundStyle(Theme.muted).lineLimit(2)
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
                .font(Theme.font(14.5, .regular, relativeTo: .subheadline)).padding(.vertical, 8)
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
                        Text(name).font(Theme.font(14.5, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                        if !meta.isEmpty { Text(meta).font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted) }
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
                // A flat series gets room around it, not a 0.001 span that
                // labels its axis "2.4010 / 2.4005".
                .chartYScale(domain: (lo - max((hi - lo) * 0.1, max(abs(hi) * 0.05, 0.05)))...(hi + max((hi - lo) * 0.1, max(abs(hi) * 0.05, 0.05))))
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
                .font(Theme.font(12.5, .regular, relativeTo: .caption).monospacedDigit()).foregroundStyle(Theme.muted)
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
                    Text(r.name).font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.text).lineLimit(1)
                        .frame(width: 84, alignment: .leading)
                    GeometryReader { g in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Theme.track)
                            Capsule().fill(r.on ? Theme.brand : Theme.muted)
                                .frame(width: max(6, g.size.width * CGFloat(r.minutes) / CGFloat(top)))
                        }
                    }
                    .frame(height: 8)
                    Text(Format.minutes(r.minutes)).font(Theme.font(12.5, .regular, relativeTo: .caption).monospacedDigit()).foregroundStyle(Theme.muted)
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
                    Text(day).font(Theme.font(12.5, .semibold, relativeTo: .caption)).foregroundStyle(Theme.muted).padding(.top, i > 0 ? 8 : 0)
                }
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(time.isEmpty ? "—" : time).font(Theme.font(12.5, .regular, relativeTo: .caption).monospacedDigit()).foregroundStyle(Theme.muted)
                        .frame(width: 44, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r["detail"] ?? r["event"] ?? "entry").font(Theme.font(14.5, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                        if r["detail"] != nil, let ev = r["event"] {
                            Text(ev).font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted)
                        }
                    }
                    Spacer()
                    if let art = ValveArt.key(timelineSource: r["source"]) {
                        ValveGlyph(art: art, size: 22)
                    }
                    if let s = r["source"], !s.isEmpty { Tag(text: s, dot: false) }
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

/* ---- multi-value kinds ----
 * Same contract as the web: flat rows, and the section's legend names the
 * keys. A key missing from a row is a gap (a supply cut), so each line is
 * drawn as separate runs rather than joined across it. Lines are told apart
 * by weight and dash, not hue: the brand green first, then the page's greys. */

private let lineStyles: [(Color, StrokeStyle)] = [
    (Theme.brand, StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round)),
    (Theme.text.opacity(0.62), StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)),
    (Theme.muted, StrokeStyle(lineWidth: 1.8, lineCap: .round, dash: [5, 4])),
    (Theme.muted.opacity(0.7), StrokeStyle(lineWidth: 1.6, lineCap: .round, dash: [2, 3])),
]

private struct Legend: View {
    let items: [(String, Int)]
    var trailing: String = ""
    var body: some View {
        HStack(spacing: 14) {
            ForEach(items, id: \.1) { label, i in
                HStack(spacing: 6) {
                    Path { p in p.move(to: .init(x: 0, y: 1)); p.addLine(to: .init(x: 16, y: 1)) }
                        .stroke(lineStyles[i % lineStyles.count].0, style: lineStyles[i % lineStyles.count].1)
                        .frame(width: 16, height: 2)
                    Text(label)
                }
            }
            if !trailing.isEmpty { Text(trailing).foregroundStyle(Theme.muted.opacity(0.8)) }
        }
        .font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted)
    }
}

private struct Lines: View {
    let section: ReportSection

    private struct Pt: Identifiable { let id: String; let i: Int; let v: Double; let run: String; let k: Int }

    var body: some View {
        let legend = Array(section.legend.prefix(4))
        let rows = section.rows
        let pts: [Pt] = legend.enumerated().flatMap { k, l -> [Pt] in
            var run = 0, open = false, out: [Pt] = []
            for (i, r) in rows.enumerated() {
                guard let v = Double(r[l["key"] ?? ""] ?? "") else { if open { run += 1 }; open = false; continue }
                open = true
                out.append(Pt(id: "\(k)-\(i)", i: i, v: v, run: "\(k)-\(run)", k: k))
            }
            return out
        }
        let on = rows.enumerated().filter { $0.element["on"] == "1" }.map(\.offset)
        if rows.count >= 2, let lo = pts.map(\.v).min(), let hi = pts.map(\.v).max() {
            let pad = max((hi - lo) * 0.08, 0.5)
            VStack(alignment: .leading, spacing: 6) {
                Chart {
                    ForEach(on, id: \.self) { i in
                        RectangleMark(xStart: .value("t", Double(i) - 0.5), xEnd: .value("t", Double(i) + 0.5))
                            .foregroundStyle(Theme.brand.opacity(0.14))
                    }
                    ForEach(pts) { p in
                        LineMark(x: .value("t", Double(p.i)), y: .value("v", p.v), series: .value("run", p.run))
                            .foregroundStyle(lineStyles[p.k % lineStyles.count].0)
                            .lineStyle(lineStyles[p.k % lineStyles.count].1)
                    }
                }
                .chartXScale(domain: -0.5...(Double(rows.count) - 0.5))
                .chartYScale(domain: max(0, lo - pad)...(hi + pad))
                .chartXAxis {
                    AxisMarks(values: [0, Double(rows.count / 2), Double(rows.count - 1)]) { v in
                        AxisValueLabel {
                            if let d = v.as(Double.self) { Text(clock(rows[min(rows.count - 1, max(0, Int(d)))]["at"] ?? "", rows)) }
                        }
                    }
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 150)
                .accessibilityLabel("\(section.title), \(legend.count) lines over \(rows.count) windows")
                Legend(items: legend.enumerated().map { ($0.element["label"] ?? "", $0.offset) },
                       trailing: section.unit.isEmpty ? "" : "in \(section.unit)")
            }
        }
    }

    private func clock(_ at: String, _ rows: [ReportRow]) -> String {
        let oneDay = (rows.first?["at"] ?? "").prefix(10) == (rows.last?["at"] ?? "").prefix(10)
        return String(at.dropFirst(oneDay ? 11 : 5).prefix(oneDay ? 5 : 11))
    }
}

/// The whole is power available that day; the part inside it is the pump's share.
private struct Stack: View {
    let section: ReportSection
    private struct Day: Identifiable { let id: String; let whole: Double; let part: Double }

    var body: some View {
        if section.legend.count >= 2, let wk = section.legend[0]["key"], let pk = section.legend[1]["key"] {
            let days = section.rows.map {
                Day(id: $0["at"] ?? "", whole: Double($0[wk] ?? "") ?? 0, part: Double($0[pk] ?? "") ?? 0)
            }
            VStack(alignment: .leading, spacing: 6) {
                Chart(days) { d in
                    BarMark(x: .value("Day", String(d.id.suffix(2))), yStart: .value("h", 0), yEnd: .value("h", d.whole))
                        .foregroundStyle(Theme.track)
                    BarMark(x: .value("Day", String(d.id.suffix(2))), yStart: .value("h", 0), yEnd: .value("h", min(d.part, d.whole)))
                        .foregroundStyle(Theme.brand)
                }
                .chartYAxis { AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) }
                .frame(height: 130)
                HStack(spacing: 14) {
                    swatch(Theme.track, section.legend[0]["label"] ?? "")
                    swatch(Theme.brand, section.legend[1]["label"] ?? "")
                    if !section.unit.isEmpty { Text("in \(section.unit)").foregroundStyle(Theme.muted.opacity(0.8)) }
                }
                .font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted)
            }
        }
    }

    private func swatch(_ c: Color, _ label: String) -> some View {
        HStack(spacing: 6) { RoundedRectangle(cornerRadius: 2).fill(c).frame(width: 10, height: 10); Text(label) }
    }
}

/// Every valve at a glance; one that got nothing stays in, dimmed, reading "none".
private struct ValveGrid: View {
    let rows: [ReportRow]
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 7)], spacing: 7) {
            ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                let m = Int(Double(r["value"] ?? "") ?? 0)
                HStack(spacing: 8) {
                    ValveGlyph(art: ValveArt.key(name: r["name"], type: r["type"], status: m > 0 ? "on" : "off"), size: 24)
                        .opacity(m > 0 ? 1 : 0.45).saturation(m > 0 ? 1 : 0)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r["name"] ?? "Valve").font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.text).lineLimit(1)
                        Text(m > 0 ? Format.minutes(m) : "none")
                            .font(Theme.font(14.5, m > 0 ? .bold : .semibold, relativeTo: .subheadline).monospacedDigit())
                            .foregroundStyle(m > 0 ? Theme.on : Theme.muted)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                .background(m > 0 ? Theme.panel2 : Color.clear, in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous)
                    .strokeBorder(m > 0 ? Color.clear : Theme.line2, lineWidth: 1))
                .accessibilityElement(children: .combine)
            }
        }
    }
}

/// Valve × day. Heat is the brand green at an opacity proportional to minutes.
private struct Matrix: View {
    let section: ReportSection
    var body: some View {
        let cols = section.legend
        let top = max(1, section.rows.flatMap { r in cols.map { Int(Double(r[$0["key"] ?? ""] ?? "") ?? 0) } }.max() ?? 1)
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    Text("Valve").frame(width: 92, alignment: .leading)
                    ForEach(Array(cols.enumerated()), id: \.offset) { _, c in Text(c["label"] ?? "").frame(width: 52) }
                    Text("Total").frame(width: 60)
                }
                .font(Theme.font(11, .semibold, relativeTo: .caption2)).foregroundStyle(Theme.muted).padding(.vertical, 5)
                ForEach(Array(section.rows.enumerated()), id: \.offset) { _, r in
                    Divider().overlay(Theme.line)
                    GridRow {
                        Text(r["name"] ?? "").font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.text).lineLimit(1)
                            .frame(width: 92, alignment: .leading)
                        ForEach(Array(cols.enumerated()), id: \.offset) { _, c in
                            let m = Int(Double(r[c["key"] ?? ""] ?? "") ?? 0)
                            Text(m > 0 ? Format.minutes(m) : "–")
                                .font(Theme.font(11, .regular, relativeTo: .caption2).monospacedDigit())
                                .foregroundStyle(m > 0 ? Theme.text : Theme.muted)
                                .frame(width: 52, height: 26)
                                .background(Theme.brand.opacity(m > 0 ? 0.10 + 0.55 * Double(m) / Double(top) : 0))
                        }
                        Text(Format.minutes(Int(Double(r["total"] ?? "") ?? 0)))
                            .font(Theme.font(11, .bold, relativeTo: .caption2).monospacedDigit()).foregroundStyle(Theme.text).frame(width: 60)
                    }
                }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous).strokeBorder(Theme.line.opacity(0.6), lineWidth: 1))
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
            Text("\(rows.count - 6) more rows in this report.").font(Theme.font(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.muted)
        }
    }
}

/* ---- the cache the last reports left behind ---- */


private struct ReadingTile: View {
    let label: String
    let value: String
    let note: String
    var on = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(Theme.font(12.5, .medium, relativeTo: .caption)).foregroundStyle(Theme.muted)
            Text(value).font(Theme.font(22, .semibold, relativeTo: .title2).monospacedDigit()).foregroundStyle(on ? Theme.on : Theme.text)
                .lineLimit(1).minimumScaleFactor(0.6)
            Text(note).font(Theme.font(12.5, .regular, relativeTo: .caption)).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panel()
    }
}

/// One tappable line that opens an account sheet; says so when it needs you.
struct AccountRow: View {
    let title: String
    let problem: String?
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 12) {
                Image(systemName: problem == nil ? "person.crop.circle.badge.checkmark" : "exclamationmark.triangle")
                    .foregroundStyle(problem == nil ? Theme.faint : Theme.warn).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(Theme.font(14.5, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                    if let problem { Text(problem).font(Theme.meta).foregroundStyle(Theme.warn).lineLimit(2) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(Panel(padding: 0))
    }
}
