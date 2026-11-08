import SwiftUI
import SNOFCore

/* The controller page's saved programs, rain and controller facts. Mirrors
 * the web's Programs, Rain and Controller cards (contract:
 * .context/mobitech-more-contract.md). Every card carries its data's age, and
 * a read that failed says so instead of showing old figures. */

struct ProgramsCard: View {
    @Environment(FarmStore.self) private var store
    @State private var confirming: SavedProgram?

    var body: some View {
        let c = store.irrigation
        let refusal = store.programRefusal()
        let known = store.metaLoaded
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Programs").font(Theme.panelTitle).foregroundStyle(Theme.text)
                Spacer()
                if Unread.read(c, "programs") != nil { Text("can't read").font(Theme.small).foregroundStyle(Theme.warn) }
                else if let ag = ago(c.programs?.at, now: store.now) {
                    Text("read \(ag)").font(Theme.small).foregroundStyle(Theme.faint)
                }
            }
            if let why = Unread.read(c, "programs") {
                Note(text: "Can't read the saved programs: \(why).", tone: .warn)
            } else if let cache = c.programs {
                if cache.items.isEmpty {
                    Note(text: "The controller has no saved programs.")
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(cache.items.enumerated()), id: \.element.id) { i, p in
                            if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                            row(p, mark: Programs.mark(p, in: c), refusal: refusal)
                        }
                    }
                    if store.isAdmin, known, let refusal, !refusal.isEmpty, store.irrigationPending == nil {
                        Note(text: refusal, tone: .warn)
                    }
                }
            } else {
                Note(text: store.canControl ? "Not read yet. Press Refresh to ask the controller." : "Nothing has been read yet.")
            }
        }
        .modifier(Panel(padding: 16))
        .confirmationDialog(confirming.map { Programs.confirm($0) } ?? "", isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }), titleVisibility: .visible) {
            Button("Start program") {
                if let p = confirming { Haptics.commit(); Task { await store.startProgram(p) } }
                confirming = nil
            }
        }
    }

    private func row(_ p: SavedProgram, mark: ProgramMark?, refusal: String?) -> some View {
        let valves = p.valves.map(String.init).joined(separator: ", ")
        let detail = [p.start, Programs.durationText(p), p.days].filter { !$0.isEmpty }.joined(separator: " · ")
        return HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("#\(p.number) \(p.name)").font(Theme.font(15, .semibold, relativeTo: .body)).foregroundStyle(Theme.text)
                    if !p.enabled { Text("Off").font(Theme.small).foregroundStyle(Theme.faint) }
                    switch mark {
                    case .running: Tag(text: "Running", kind: .on)
                    case .next: Tag(text: p.start.isEmpty ? "Next" : "Next · \(p.start)", kind: .plain)
                    case nil: EmptyView()
                    }
                }
                if !detail.isEmpty { Text(detail).font(Theme.meta).foregroundStyle(Theme.muted) }
                if !valves.isEmpty { Text("Valves \(valves)").font(Theme.small).foregroundStyle(Theme.faint) }
            }
            Spacer(minLength: 4)
            if store.isAdmin, p.enabled {
                let ok = refusal == nil && mark != .running
                Button { confirming = p } label: {
                    Text("Start")
                        .font(Theme.font(14, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(ok ? .white : Theme.muted)
                        .padding(.horizontal, 16).frame(minHeight: 34)
                        .background(ok ? Theme.brand : Theme.panel3, in: Capsule())
                        .frame(minHeight: Theme.hit)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!ok)
                .accessibilityLabel("Start \(p.label)")
            }
        }
        .padding(.vertical, 8)
        .opacity(p.enabled ? 1 : 0.45)
    }
}

/// "Rain today 0 mm · week 3.2 mm", with its age.
struct RainLine: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        if let why = Unread.read(c, "rain") {
            Note(text: "Can't read the rain gauge: \(why).", tone: .warn)
        } else if let r = c.rain, let line = Programs.rainLine(r) {
            HStack(spacing: 8) {
                Image(systemName: "cloud.rain").foregroundStyle(Theme.faint)
                Text(line).font(Theme.font(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                Spacer(minLength: 4)
                if let ag = ago(r.at, now: store.now) { Text("read \(ag)").font(Theme.small).foregroundStyle(Theme.faint) }
            }
            .modifier(Panel(padding: 14))
        }
    }
}

/// Firmware, SIM and emergency shutdown, from the last controller read.
struct ControllerCard: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let c = store.irrigation
        let info = c.controllerInfo
        if !info.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Controller").font(Theme.panelTitle).foregroundStyle(Theme.text)
                    Spacer()
                    if let ag = ago(c.program?.at ?? c.lastUpdated, now: store.now) {
                        Text("read \(ag)").font(Theme.small).foregroundStyle(Theme.faint)
                    }
                }
                if let f = info.firmware { fact("Firmware", f) }
                if let s = info.simExpiry { fact("SIM valid until", Programs.simText(s)) }
                if let on = info.shutdown {
                    fact("Emergency shutdown", on ? "On" : "Off", warn: on)
                }
            }
            .modifier(Panel(padding: 16))
        }
    }

    private func fact(_ label: String, _ value: String, warn: Bool = false) -> some View {
        HStack {
            Text(label).font(Theme.meta).foregroundStyle(Theme.muted)
            Spacer()
            Text(value).font(Theme.font(14, .semibold, relativeTo: .subheadline))
                .foregroundStyle(warn ? Theme.warn : Theme.text)
        }
    }
}
