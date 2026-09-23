import SwiftUI
import SNOFCore

/* ---- headings ---- */

struct SectionHead: View {
    let symbol: String
    let title: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).font(.footnote).foregroundStyle(Theme.muted)
            Text(title.uppercased())
                .font(.caption.weight(.semibold)).tracking(0.8)
                .foregroundStyle(Theme.muted)
            Rectangle().fill(Theme.line).frame(height: 1)
            if let action {
                Button(action: action.run) {
                    HStack(spacing: 2) {
                        Text(action.label)
                        Image(systemName: "chevron.right").font(.caption2.weight(.semibold))
                    }
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.text)
                    .frame(minHeight: Theme.hit)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 18)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/* ---- state ---- */

/// Colour plus a word: state never relies on colour alone.
struct StatePill: View {
    let text: String
    let tone: StateTone

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .foregroundStyle(tone == .off || tone == .neutral ? Theme.muted : Theme.tone(tone))
            .background(background, in: Capsule())
            .overlay(Capsule().strokeBorder(border, lineWidth: 1))
            .fixedSize()
    }

    private var background: Color {
        switch tone {
        case .on: return Theme.on.opacity(0.13)
        case .unavailable: return Theme.bad.opacity(0.12)
        default: return Theme.panel2
        }
    }
    private var border: Color {
        switch tone {
        case .on: return Theme.on.opacity(0.34)
        case .unavailable: return Theme.bad.opacity(0.32)
        default: return Theme.line
        }
    }
}

struct Tag: View {
    enum Kind { case plain, on, warn, bad }
    let text: String
    var kind: Kind = .plain

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(fg)
            .background(fg.opacity(kind == .plain ? 0 : 0.12), in: Capsule())
            .overlay(Capsule().strokeBorder(kind == .plain ? Theme.line2 : fg.opacity(0.32), lineWidth: 1))
    }
    private var fg: Color {
        switch kind {
        case .plain: return Theme.muted
        case .on: return Theme.on
        case .warn: return Theme.warn
        case .bad: return Theme.bad
        }
    }
}

/* ---- bridge ---- */

struct BridgePill: View {
    let status: BridgeStatus
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
                // Liveness, not decoration: the one animation that stays
                // unless the user asked for less motion.
                .opacity(status == .live && pulse ? 0.35 : 1)
                .animation(status == .live && !reduceMotion
                           ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: pulse)
            Text(status.label).font(.caption.weight(.semibold))
        }
        .foregroundStyle(status == .unknown ? Theme.muted : color)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Theme.panel, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.line2, lineWidth: 1))
        .onAppear { pulse = true }
        .accessibilityLabel("Bridge: \(status.label)")
    }

    private var color: Color {
        switch status {
        case .live: return Theme.on
        case .stale: return Theme.warn
        case .offline: return Theme.bad
        case .unknown: return Theme.muted
        }
    }
}

/// One line explaining why controls are disabled, when they are.
struct ControlNote: View {
    @Environment(FarmStore.self) private var store

    var body: some View {
        let gate = store.gate(.control)
        if !store.canControl {
            Note(text: "Your account can view, but not control. Ask a farm admin for the controller tier.")
        } else if !gate.ok {
            Note(text: gate.why, tone: .warn)
        } else if !store.connected {
            Note(text: "Reconnecting to the farm — controls are paused until then.", tone: .warn)
        }
    }
}

struct Note: View {
    let text: String
    var tone: Tag.Kind = .plain

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            if tone != .plain {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(tone == .bad ? Theme.bad : Theme.warn)
            }
            Text(text).foregroundStyle(Theme.muted)
        }
        .font(.footnote)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct EmptyBlock: View {
    let title: String
    let message: String
    var symbol = "magnifyingglass"

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.title3).foregroundStyle(Theme.muted)
                .frame(width: 44, height: 44)
                .background(Theme.panel2, in: RoundedRectangle(cornerRadius: Theme.rMd))
            Text(title).font(.headline).foregroundStyle(Theme.text)
            Text(message).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 16)
        .panel()
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO DATA")
            .font(.caption2.weight(.bold)).tracking(0.8)
            .foregroundStyle(Theme.warn)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().strokeBorder(Theme.warn.opacity(0.5), lineWidth: 1))
            .accessibilityLabel("Showing demo data, not the farm")
    }
}

/* ---- devices ---- */

struct DeviceIcon: View {
    let domain: String
    var tone: StateTone = .neutral
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: Theme.symbol(domain))
            .font(.system(size: size * 0.44))
            .foregroundStyle(tone == .on ? Theme.on : tone == .unavailable ? Theme.bad : Theme.muted)
            .frame(width: size, height: size)
            .background(tone == .on ? Theme.on.opacity(0.13) : Theme.panel2,
                        in: RoundedRectangle(cornerRadius: Theme.rSm, style: .continuous))
    }
}

/// A controllable device: toggle, optional level slider, area and state.
struct DeviceCard: View {
    @Environment(FarmStore.self) private var store
    let entity: Entity
    var showArea = true

    /// Held while dragging and until the farm catches up, so a live update
    /// never yanks the slider out from under a finger.
    @State private var draft: Double?
    @State private var draftExpiry: Task<Void, Never>?

    var body: some View {
        let on = store.displayOn(entity)
        let busy = store.pending[entity.key] != nil
        let operable = store.canOperate(entity)
        let tone: StateTone = entity.isBad ? .unavailable : on ? .on : .off

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                DeviceIcon(domain: entity.domain, tone: tone)
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(2)
                    Text(meta).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if store.canControl {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small).accessibilityLabel("Waiting for the farm") }
                        Toggle(entity.name, isOn: Binding(get: { on }, set: { _ in store.toggle(entity) }))
                            .labelsHidden()
                            .tint(Theme.on)
                            .disabled(!operable)
                            .sensoryFeedback(.selection, trigger: on)
                    }
                    .frame(minHeight: Theme.hit)
                } else {
                    StatePill(text: entity.formattedState, tone: entity.tone)
                }
            }

            if store.canControl, let level = entity.level {
                HStack(spacing: 10) {
                    Text(entity.domain == "fan" ? "Speed" : "Bright")
                        .font(.caption).foregroundStyle(Theme.muted).frame(width: 44, alignment: .leading)
                    Slider(value: Binding(get: { draft ?? Double(level) }, set: { draft = $0 }),
                           in: 0...100, step: 1) { editing in
                        if !editing, let d = draft { commit(Int(d)) }
                        if editing { draftExpiry?.cancel() }
                    }
                    .tint(Theme.on)
                    .disabled(!operable)
                    .accessibilityLabel("\(entity.name) \(entity.domain == "fan" ? "speed" : "brightness")")
                    Text("\(Int(draft ?? Double(level)))%")
                        .font(.caption.monospacedDigit()).foregroundStyle(Theme.muted)
                        .frame(width: 40, alignment: .trailing)
                }
                .frame(minHeight: Theme.hit)
                .onChange(of: entity.level) { _, _ in draft = nil }
            }

            HStack {
                if showArea { Text(store.areaName(entity.area)) }
                Spacer()
                if store.canControl { Text(entity.formattedState).monospacedDigit() }
            }
            .font(.caption).foregroundStyle(Theme.muted)
        }
        .panel()
        .opacity(entity.isBad ? 0.75 : 1)
        .accessibilityElement(children: .contain)
    }

    private var meta: String {
        [entity.humanDomain, entity.subtitle].filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private func commit(_ pct: Int) {
        store.setLevel(entity, percent: pct)
        draftExpiry?.cancel()
        draftExpiry = Task {
            try? await Task.sleep(for: Farm.commandTimeout)
            if !Task.isCancelled { draft = nil }
        }
    }
}

/// A read-only row: icon, name, context, state. Controllers get the toggle
/// inline for operable domains, so the device list is usable one-handed.
struct DeviceRow: View {
    @Environment(FarmStore.self) private var store
    let entity: Entity
    var withArea = false

    var body: some View {
        HStack(spacing: 12) {
            DeviceIcon(domain: entity.domain, tone: entity.tone, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(.subheadline.weight(.medium)).foregroundStyle(Theme.text).lineLimit(1)
                Text(meta).font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.canControl && entity.isControllable && !entity.isBad {
                if store.pending[entity.key] != nil { ProgressView().controlSize(.small) }
                Toggle(entity.name, isOn: Binding(get: { store.displayOn(entity) }, set: { _ in store.toggle(entity) }))
                    .labelsHidden().tint(Theme.on)
                    .disabled(!store.canOperate(entity))
            } else {
                StatePill(text: entity.formattedState, tone: entity.tone)
            }
        }
        .frame(minHeight: Theme.hit)
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    private var meta: String {
        [withArea ? store.areaName(entity.area) : entity.humanDomain, entity.subtitle]
            .filter { !$0.isEmpty }.joined(separator: " · ")
    }
}

/// Rows grouped in one bordered panel with hairline separators.
struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                row(item)
            }
        }
        .padding(.horizontal, 12)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).strokeBorder(Theme.line, lineWidth: 1))
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind == .ok ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(toast.kind == .ok ? Theme.on : Theme.bad)
            Text(toast.message).font(.subheadline).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(Theme.panel3, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous).strokeBorder(Theme.line2, lineWidth: 1))
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

/// Page scaffolding shared by every tab: canvas colour, padding, width cap.
struct Page<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                BridgeBand()
                UpdateBanner()
                content
            }
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.immediately)
    }
}

/// One line, only when SideStore's source has a newer build than this one.
struct UpdateBanner: View {
    @Environment(UpdateCheck.self) private var updates

    var body: some View {
        if let version = updates.available {
            Button { updates.openSideStore() } label: {
                HStack(spacing: 10) {
                    Image(systemName: "arrow.down.circle").foregroundStyle(Theme.text)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Version \(version) is available").font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.text)
                        Text("Open SideStore → My Apps → Update").font(.caption).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                }
                .frame(minHeight: Theme.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .panel(padding: 10)
        }
    }
}
