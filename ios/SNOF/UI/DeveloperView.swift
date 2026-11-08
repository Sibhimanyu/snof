import SwiftUI
import SNOFCore

/* Developer console, owner only (contract: .context/dev-console-contract.md).
 * Raw, read-only Mobitech requests sent through the farm box. The phone never
 * holds the token: requests carry {{token}} placeholders the box fills in, and
 * anything token-shaped is replaced before it leaves the device. */

private final class Once { var done = false }

@MainActor
@Observable
final class DeveloperModel {
    struct Row: Identifiable, Equatable { var id = UUID(); var key = ""; var value = "" }
    enum Target: Hashable { case path, query(UUID), form(UUID), json }

    var method = "GET"
    var path = "/v1/http/"
    var query: [Row] = []
    var form: [Row] = []
    var bodyMode = "none"          // none | form | json
    var json = ""
    var auth = false
    var target: Target = .path

    var sending = false
    var message: String?
    var result: DevResult?
    var sent: DevRequest?
    var history: [DevConsole.HistoryEntry] = []
    private static let key = "devHistory"

    init() {
        if let d = UserDefaults.standard.data(forKey: Self.key),
           let h = try? JSONDecoder().decode([DevConsole.HistoryEntry].self, from: d) { history = h }
    }

    var request: DevRequest {
        let body: String
        switch bodyMode {
        case "form": body = DevConsole.joinRows(form.map { ($0.key, $0.value) })
        case "json": body = json.trimmingCharacters(in: .whitespacesAndNewlines)
        default: body = ""
        }
        return DevRequest(method: method, path: path.trimmingCharacters(in: .whitespaces),
                          query: DevConsole.joinRows(query.map { ($0.key, $0.value) }),
                          body: body, bodyType: body.isEmpty ? "none" : bodyMode, auth: auth)
    }

    func load(_ r: DevRequest) {
        method = r.method; path = r.path; auth = r.auth
        query = DevConsole.queryRows(r.query).map { Row(key: $0.key, value: $0.value) }
        form = []; json = ""
        if r.body.isEmpty { bodyMode = "none" }
        else if r.bodyType == "json" { bodyMode = "json"; json = r.body }
        else { bodyMode = "form"; form = DevConsole.queryRows(r.body).map { Row(key: $0.key, value: $0.value) } }
        message = nil
    }

    func pasteCurl() {
        guard let text = UIPasteboard.general.string, !text.isEmpty else { message = "The clipboard is empty."; return }
        do { load(try DevConsole.parseCurl(text)); message = "Curl loaded. The token, if any, was replaced by {{token}}." }
        catch { message = error.localizedDescription }
    }

    func insert(_ placeholder: String) {
        switch target {
        case .path: path += placeholder
        case .query(let id): if let i = query.firstIndex(where: { $0.id == id }) { query[i].value += placeholder }
        case .form(let id): if let i = form.firstIndex(where: { $0.id == id }) { form[i].value += placeholder }
        case .json: json += placeholder
        }
    }

    func copyCurl() {
        UIPasteboard.general.string = DevConsole.curl(request)
        message = "Copied as curl (placeholders, no token)."
    }

    func clearHistory() { history = []; UserDefaults.standard.removeObject(forKey: Self.key) }

    func send(_ store: FarmStore) async {
        let req = DevConsole.scrubbed(request)
        if let why = DevConsole.refusal(req) { message = why; return }
        guard let uid = store.user?.uid, store.isOwner else { message = "Only the farm owner can use the console."; return }
        sending = true; message = nil; result = nil; sent = req
        defer { sending = false }
        let backend = store.backend
        do {
            let id = try await backend.sendDev(req, uid: uid)
            let once = Once()
            var stop: (() -> Void)?
            let r: DevResult? = await withCheckedContinuation { cont in
                let finish: (DevResult?) -> Void = { r in
                    guard !once.done else { return }
                    once.done = true; stop?(); cont.resume(returning: r)
                }
                stop = backend.observeDevResult(id: id) { v in if let r = DevResult.parse(v) { finish(r) } }
                Task { @MainActor in try? await Task.sleep(for: .seconds(DevConsole.timeoutSeconds)); finish(nil) }
            }
            guard let r else { message = "The farm did not answer."; return }
            result = r
            history = DevConsole.pushHistory(history, .init(at: Date().timeIntervalSince1970 * 1000, request: req, result: r))
            if let d = try? JSONEncoder().encode(history) { UserDefaults.standard.set(d, forKey: Self.key) }
            await backend.deleteDevResult(id: id)
        } catch {
            message = (error as? BackendError)?.errorDescription ?? error.localizedDescription
        }
    }
}

struct DeveloperView: View {
    @Environment(FarmStore.self) private var store
    @State private var m = DeveloperModel()
    @State private var pretty = true
    @State private var open: Set<String> = []
    @State private var tree: JSONTree.Node?
    @State private var treeFor = ""
    @FocusState private var focus: DeveloperModel.Target?
    private static let mono = Font.system(size: 12.5, design: .monospaced)

    var body: some View {
        let gate = store.gate(.devConsole)
        List {
            if !gate.ok {
                Section { Note(text: gate.why, tone: .warn) }
            }
            #if DEBUG
            // -dev-demo puts the response on top so a window-sized snapshot shows it.
            if Snapshot.args.contains("-dev-demo"), let r = m.result { responseSection(r) }
            #endif
            requestSection
            actionSection(gate)
            if let msg = m.message { Section { Note(text: msg, tone: m.result == nil ? .warn : .plain) } }
            if m.sending { Section { HStack { ProgressView(); Text("Waiting for the farm box…").font(Theme.meta).foregroundStyle(Theme.muted) } } }
            #if DEBUG
            if let r = m.result, !Snapshot.args.contains("-dev-demo") { responseSection(r) }
            #else
            if let r = m.result { responseSection(r) }
            #endif
            historySection
        }
        .tint(Theme.on)
        .navigationTitle("Developer")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: focus) { _, f in if let f { m.target = f } }
        .onChange(of: m.result) { _, r in refreshTree(r) }
        #if DEBUG
        .task {
            // -dev-demo: send the dashboard preset once, for a screenshot.
            if Snapshot.args.contains("-dev-demo"), m.result == nil {
                m.load(DevConsole.presets[0].request)
                try? await Task.sleep(for: .seconds(1))
                await m.send(store)
            }
        }
        #endif
    }

    // MARK: builder

    private var requestSection: some View {
        Group {
            Section {
                Picker("Method", selection: $m.method) { Text("GET").tag("GET"); Text("POST").tag("POST") }
                    .pickerStyle(.segmented)
                TextField("/v1/http/", text: $m.path)
                    .font(Self.mono).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($focus, equals: .path)
                Toggle("Send authorization header", isOn: $m.auth).tint(Theme.brand)
            } header: { Text("Request") } footer: {
                Text("Reads only. Commands, sign-in and sign-out are refused here before anything is sent.")
            }
            Section("Query") {
                ForEach($m.query) { $row in rowEditor($row, .query(row.id)) }
                    .onDelete { m.query.remove(atOffsets: $0) }
                Button("Add query row") { m.query.append(.init()) }
            }
            Section {
                Picker("Body", selection: $m.bodyMode) {
                    Text("None").tag("none"); Text("Form").tag("form"); Text("JSON").tag("json")
                }.pickerStyle(.segmented)
                if m.bodyMode == "form" {
                    ForEach($m.form) { $row in rowEditor($row, .form(row.id)) }
                        .onDelete { m.form.remove(atOffsets: $0) }
                    Button("Add body row") { m.form.append(.init()) }
                } else if m.bodyMode == "json" {
                    TextEditor(text: $m.json).font(Self.mono).frame(minHeight: 110)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($focus, equals: .json)
                }
            } header: { Text("Body") }
            Section {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack {
                        ForEach(DevConsole.placeholders, id: \.self) { p in
                            Button(p) { m.insert(p) }
                                .font(Self.mono).buttonStyle(.bordered).tint(Theme.muted)
                        }
                    }
                }
            } header: { Text("Placeholders") } footer: {
                Text("The farm box fills these in. Inserted into the field you last edited.")
            }
        }
    }

    private func rowEditor(_ row: Binding<DeveloperModel.Row>, _ t: DeveloperModel.Target) -> some View {
        HStack(spacing: 8) {
            TextField("key", text: row.key).frame(maxWidth: 130)
            Text("=").foregroundStyle(Theme.faint)
            TextField("value", text: row.value)
        }
        .font(Self.mono).textInputAutocapitalization(.never).autocorrectionDisabled()
        .focused($focus, equals: t)
    }

    private func actionSection(_ gate: Gate) -> some View {
        Section {
            Menu {
                ForEach(DevConsole.presets) { p in Button(p.id) { m.load(p.request) } }
            } label: { Label("Presets", systemImage: "list.bullet") }
            Button { m.pasteCurl() } label: { Label("Paste curl", systemImage: "doc.on.clipboard") }
            Button { m.copyCurl() } label: { Label("Copy as curl", systemImage: "terminal") }
            Button {
                focus = nil
                Task { await m.send(store) }
            } label: {
                HStack { Text("Send").bold(); Spacer(); if m.sending { ProgressView() } }
            }
            .disabled(!gate.ok || m.sending || !store.isOwner)
        }
    }

    // MARK: response

    private func refreshTree(_ r: DevResult?) {
        guard let r, r.json, r.size < 400_000, let t = JSONTree.parse(r.body) else { tree = nil; return }
        tree = t; open = JSONTree.defaultOpen(t)
    }

    private func responseSection(_ r: DevResult) -> some View {
        Section {
            HStack(spacing: 10) {
                Tag(text: r.status == 0 ? "No answer" : "\(r.status)", kind: r.status >= 200 && r.status < 300 ? .on : .bad)
                Text("\(r.ms) ms").font(Theme.meta).foregroundStyle(Theme.muted)
                Text(ByteCountFormatter.string(fromByteCount: Int64(r.size), countStyle: .file)).font(Theme.meta).foregroundStyle(Theme.muted)
                if r.truncated { Tag(text: "Truncated", kind: .warn) }
                Spacer()
                Button { UIPasteboard.general.string = shown(r) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless).accessibilityLabel("Copy response")
            }
            if let e = r.error { Note(text: e, tone: .bad) }
            if r.json {
                Picker("View", selection: $pretty) { Text("Pretty").tag(true); Text("Raw").tag(false) }.pickerStyle(.segmented)
            }
            if r.json, pretty, let t = tree {
                HStack {
                    Button("Expand all") { open = JSONTree.containerIDs(t) }
                    Spacer()
                    Button("Collapse all") { open = [] }
                }.buttonStyle(.borderless).font(Theme.meta)
                let rows = JSONTree.rows(t, open: open)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(rows.prefix(2000)) { row in treeRow(row) }
                        if rows.count > 2000 { Text("… \(rows.count - 2000) more rows").font(Theme.meta).foregroundStyle(Theme.faint) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 420)
            } else {
                let text = shown(r)
                ScrollView(.vertical) {
                    Text(text.count > 60_000 ? String(text.prefix(60_000)) + "\n… (Copy copies everything)" : text)
                        .font(Self.mono).foregroundStyle(Theme.text).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 420)
            }
        } header: { Text("Response") }
    }

    private func shown(_ r: DevResult) -> String {
        r.json && pretty ? (JSONTree.pretty(r.body) ?? r.body) : r.body
    }

    private func treeRow(_ row: JSONTree.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            if row.isContainer {
                Image(systemName: row.isOpen ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold)).frame(width: 12)
            } else { Spacer().frame(width: 12) }
            if let k = row.key { Text(k + ":").foregroundStyle(Theme.on) }
            Text(row.text).foregroundStyle(color(row.kind)).lineLimit(row.isContainer ? 1 : 4)
        }
        .font(Self.mono)
        .padding(.leading, CGFloat(row.depth) * 14)
        .contentShape(Rectangle())
        .onTapGesture { if row.isContainer { if open.contains(row.id) { open.remove(row.id) } else { open.insert(row.id) } } }
    }

    private func color(_ k: JSONTree.Kind) -> Color {
        switch k {
        case .string: return Theme.text
        case .number: return Theme.warn
        case .bool, .null: return Theme.bad
        default: return Theme.muted
        }
    }

    // MARK: history

    @ViewBuilder private var historySection: some View {
        if !m.history.isEmpty {
            Section {
                ForEach(m.history) { h in
                    Button {
                        m.load(h.request); m.result = h.result; m.sent = h.request
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(h.request.query.isEmpty ? h.request.path : h.request.query)
                                .font(Self.mono).foregroundStyle(Theme.text).lineLimit(1)
                            Text("\(h.request.method) · \(h.status == 0 ? "no answer" : String(h.status)) · \(h.ms) ms · \(Date(timeIntervalSince1970: h.at / 1000).formatted(date: .omitted, time: .shortened))")
                                .font(Theme.meta).foregroundStyle(Theme.muted)
                        }
                    }
                }
                Button("Clear history", role: .destructive) { m.clearHistory() }
            } header: { Text("History") } footer: { Text("The last 20, kept on this device only.") }
        }
    }
}
