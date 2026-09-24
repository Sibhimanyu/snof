import SwiftUI
import SNOFCore

/* ---- page scaffolding ---- */

/// Every tab opens the same way as the web dashboard: an uppercase eyebrow
/// that says where you are, a large title, one line of context. The
/// navigation bar carries only the wordmark, the bridge and the account.
struct Page<Content: View>: View {
    var eyebrow: String? = nil
    var title: String? = nil
    var subtitle: String? = nil
    @ViewBuilder let content: Content
    @State private var position = ScrollPosition(edge: .top)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                UpdateBanner()
                if eyebrow != nil || title != nil {
                    VStack(alignment: .leading, spacing: 6) {
                        if let eyebrow { Text(eyebrow).eyebrowStyle() }
                        if let title {
                            Text(title).font(Theme.display).tracking(-1.4).foregroundStyle(Theme.text)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityAddTraits(.isHeader)
                        }
                        if let subtitle {
                            Text(subtitle).font(Theme.meta).foregroundStyle(Theme.muted).padding(.top, 2)
                        }
                    }
                    .padding(.top, 8).padding(.bottom, 4)
                }
                content
            }
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 28)
        }
        .background(Theme.bg)
        .scrollDismissesKeyboard(.immediately)
        .scrollPosition($position)
        #if DEBUG
        // Review hook: -scroll <points> scrolls every page before a snapshot.
        .task {
            if let y = Snapshot.value("-scroll").flatMap(Double.init) {
                try? await Task.sleep(for: .seconds(1))
                position.scrollTo(y: y)
            }
        }
        #endif
    }
}

/* ---- headings ---- */

/// A quiet divider heading inside a page: eyebrow text and a hairline.
struct SectionHead: View {
    let symbol: String
    let title: String
    var action: (label: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 10) {
            Text(title).eyebrowStyle()
            Rectangle().fill(Theme.line).frame(height: 1)
            if let action { LinkButton(label: action.label, run: action.run) }
        }
        .padding(.top, 12)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// "View all areas →" — green text, never a filled button.
struct LinkButton: View {
    let label: String
    let run: () -> Void
    var body: some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Text(label)
                Image(systemName: "arrow.right").font(.system(size: 12, weight: .semibold))
            }
            .font(Theme.font(14, .bold, relativeTo: .subheadline))
            .foregroundStyle(Theme.on)
            .frame(minHeight: Theme.hit)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A white panel with a title row and hairline-separated content.
struct TitledPanel<Content: View>: View {
    let title: String
    var count: Int? = nil
    var action: (label: String, run: () -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(Theme.panelTitle).tracking(-0.4).foregroundStyle(Theme.text)
                if let count { Text("\(count)").font(Theme.small).foregroundStyle(Theme.faint) }
                Spacer(minLength: 8)
                if let action { LinkButton(label: action.label, run: action.run) }
            }
            .padding(.horizontal, 18)
            .frame(minHeight: 56)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Rectangle().fill(Theme.line.opacity(0.6)).frame(height: 1)
            content
        }
        .card()
    }
}

/* ---- state ---- */

/// Colour plus a word: state never relies on colour alone.
struct StatePill: View {
    let text: String
    let tone: StateTone

    var body: some View {
        Text(text)
            .font(Theme.font(12.5, .bold, relativeTo: .caption).monospacedDigit())
            .italic(tone == .unavailable)
            .lineLimit(1)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .foregroundStyle(tone == .on ? Theme.on : tone == .unavailable ? Theme.faint : Theme.muted)
            .background(tone == .unavailable ? Color.clear : Theme.panel2, in: Capsule())
            .overlay(Capsule().strokeBorder(tone == .unavailable ? Theme.line2 : .clear,
                                            style: StrokeStyle(lineWidth: 1, dash: tone == .unavailable ? [3, 2] : [])))
            .fixedSize()
    }
}

/// A status word in running text: a dot and coloured text, no capsule wash.
struct Tag: View {
    enum Kind { case plain, on, warn, bad }
    let text: String
    var kind: Kind = .plain
    var dot = true

    var body: some View {
        HStack(spacing: 6) {
            if dot { Circle().fill(kind == .on ? Theme.brand : fg).frame(width: 6, height: 6) }
            Text(text)
        }
        .font(Theme.font(12.5, .bold, relativeTo: .caption).monospacedDigit())
        .foregroundStyle(fg)
        .lineLimit(1)
        .fixedSize()
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
    var text: String? = nil
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Circle().fill(status == .live ? Theme.brand : color).frame(width: 7, height: 7)
                // Liveness, not decoration: the one animation that stays
                // unless the user asked for less motion.
                .opacity(status == .live && pulse ? 0.35 : 1)
                .animation(status == .live && !reduceMotion
                           ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: pulse)
            Text(text ?? status.label).font(Theme.font(compact ? 12.5 : 13, .bold, relativeTo: .caption))
                .lineLimit(1)
        }
        .foregroundStyle(status == .unknown ? Theme.muted : color)
        .padding(.horizontal, compact ? 11 : 14).padding(.vertical, compact ? 6 : 8)
        .background(Theme.fill, in: Capsule())
        .overlay(Capsule().strokeBorder(border, lineWidth: 1))
        .fixedSize()
        .onAppear { pulse = true }
        .accessibilityLabel("Bridge: \(text ?? status.label)")
    }

    private var border: Color {
        switch status {
        case .stale: return Theme.warn.opacity(0.4)
        case .offline: return Theme.bad.opacity(0.4)
        default: return .clear
        }
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
            Text(text).foregroundStyle(tone == .plain ? Theme.muted : tone == .bad ? Theme.bad : Theme.warn)
        }
        .font(Theme.meta)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
    }
}

struct EmptyBlock: View {
    let title: String
    let message: String
    var symbol = "magnifyingglass"
    var framed = true

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.faint)
                .frame(width: 44, height: 44)
                .background(Theme.panel2, in: Circle())
            Text(title).font(Theme.font(16, .bold, relativeTo: .headline)).foregroundStyle(Theme.text)
            Text(message).font(Theme.meta).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 28).padding(.horizontal, 16)
        .modifier(Panel(padding: 0, fill: framed ? Theme.panel : .clear, lifted: framed))
    }
}

struct DemoBadge: View {
    var body: some View {
        Text("DEMO DATA")
            .font(Theme.font(11, .bold, relativeTo: .caption2)).tracking(0.8)
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
    var size: CGFloat = 32

    var body: some View {
        Image(systemName: Theme.symbol(domain))
            .font(.system(size: size * 0.42))
            .foregroundStyle(tone == .on ? Theme.on : tone == .unavailable ? Theme.bad : Theme.muted)
            .frame(width: size, height: size)
            // A filled squircle, like a Settings icon, but neutral: the
            // glyph's colour carries state, never the tile's.
            .background(tone == .unavailable ? Theme.bad.opacity(0.09) : Theme.panel2,
                        in: RoundedRectangle(cornerRadius: Theme.rIcon, style: .continuous))
    }
}

/// One operable device as a row: name, context, and the toggle on the right,
/// with a level slider beneath when the device has one. `quick` (Overview)
/// says which room it is in; inside a room it says for how long it has been
/// in its state instead, which the toggle cannot show.
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

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entity.name)
                        .font(Theme.rowTitle).tracking(-0.2)
                        .foregroundStyle(entity.isBad ? Theme.muted : Theme.text)
                        .lineLimit(2)
                    Text(meta(on: on)).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if store.canControl {
                    HStack(spacing: 6) {
                        if busy { ProgressView().controlSize(.small).accessibilityLabel("Waiting for the farm") }
                        Toggle(entity.name, isOn: Binding(get: { on }, set: { want in
                            Haptics.toggle(on: want); store.toggle(entity)
                        }))
                            .labelsHidden()
                            .tint(Theme.brand)
                            .disabled(!operable)
                    }
                    .frame(minHeight: Theme.hit)
                } else {
                    StatePill(text: entity.formattedState, tone: entity.tone)
                }
            }

            if store.canControl, !showArea, let level = entity.level {
                HStack(spacing: 10) {
                    Text(entity.domain == "fan" ? "Speed" : "Bright")
                        .font(Theme.small).foregroundStyle(Theme.faint).frame(width: 48, alignment: .leading)
                    Slider(value: Binding(get: { draft ?? Double(level) }, set: { draft = $0 }),
                           in: 0...100, step: 1) { editing in
                        if !editing, let d = draft { Haptics.tap(); commit(Int(d)) }
                        if editing { draftExpiry?.cancel() }
                    }
                    // A detent every 10%, only while a finger is on it.
                    .onChange(of: draft.map { Int($0) / 10 }) { old, new in
                        if old != nil, new != nil { Haptics.tick() }
                    }
                    .tint(Theme.brand)
                    .disabled(!operable)
                    .accessibilityLabel("\(entity.name) \(entity.domain == "fan" ? "speed" : "brightness")")
                    Text("\(Int(draft ?? Double(level)))%")
                        .font(Theme.small.monospacedDigit()).foregroundStyle(Theme.muted)
                        .frame(width: 40, alignment: .trailing)
                }
                .frame(minHeight: Theme.hit)
                .onChange(of: entity.level) { _, _ in draft = nil }
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    private func meta(on: Bool) -> String {
        let level = entity.level.map { on && !entity.isBad ? " · \($0)%" : "" } ?? ""
        if showArea { return store.areaName(entity.area) + level }
        let since = Format.since(entity.lastChanged).map { " for \($0)" } ?? ""
        if entity.isBad { return "Not reporting" + since }
        return (on ? "On" : "Off") + since + level
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
            DeviceIcon(domain: entity.domain, tone: entity.tone, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(entity.name).font(Theme.font(14.5, .semibold, relativeTo: .subheadline))
                    .foregroundStyle(Theme.text).lineLimit(1)
                Text(meta).font(Theme.meta).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.canControl && entity.isControllable && !entity.isBad {
                if store.pending[entity.key] != nil { ProgressView().controlSize(.small) }
                Toggle(entity.name, isOn: Binding(get: { store.displayOn(entity) }, set: { want in
                    Haptics.toggle(on: want); store.toggle(entity)
                }))
                    .labelsHidden().tint(Theme.brand)
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

/// Rows with hairline separators. Framed as its own panel by default; set
/// `framed: false` inside a TitledPanel, which already draws one.
struct RowList<Item: Identifiable, Row: View>: View {
    let items: [Item]
    var framed = true
    var inset: CGFloat = 16
    @ViewBuilder let row: (Item) -> Row

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { i, item in
                if i > 0 { Rectangle().fill(Theme.line).frame(height: 1) }
                row(item).padding(.horizontal, inset)
            }
        }
        .modifier(Panel(padding: 0, fill: framed ? Theme.panel : .clear, lifted: framed))
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.kind == .ok ? "checkmark.circle" : "exclamationmark.circle")
                .foregroundStyle(toast.kind == .ok ? Theme.on : Theme.bad)
            Text(toast.message).font(Theme.font(14, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        // An iOS banner: frosted, fully rounded, floating on a soft shadow.
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.rLg, style: .continuous)
            .strokeBorder(toast.kind == .ok ? Theme.edge : Theme.bad.opacity(0.4), lineWidth: 1))
        .shadow(color: .black.opacity(0.14), radius: 24, y: 10)
        .padding(.horizontal, 16)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.updatesFrequently)
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
                        Text("Version \(version) is available").font(Theme.rowTitle)
                            .foregroundStyle(Theme.text)
                        Text("Open SideStore → My Apps → Update").font(Theme.meta).foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(Theme.muted)
                }
                .frame(minHeight: Theme.hit)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .panel(padding: 12)
        }
    }
}
