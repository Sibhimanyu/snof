import SwiftUI
import SNOFCore

struct RootView: View {
    @Environment(FarmStore.self) private var store
    @AppStorage("appearance") private var appearance: Appearance = .dark

    var body: some View {
        Group {
            switch store.phase {
            case .boot: Theme.bg.ignoresSafeArea()
            case .signedOut: GateView(kind: .signIn)
            case .denied(let email): GateView(kind: .denied(email))
            case .misconfigured(let why): GateView(kind: .message(why))
            case .app: MainTabs()
            }
        }
        .preferredColorScheme(appearance.scheme)
        .overlay(alignment: .top) {
            if let t = store.toast {
                ToastView(toast: t)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onTapGesture { store.toast = nil }
            }
        }
        .animation(.snappy, value: store.toast)
    }
}

struct MainTabs: View {
    @Environment(FarmStore.self) private var store
    @State private var account = false
    @State private var overviewPath: [AreaRoute] = []
    @State private var areasPath: [AreaRoute] = []
    @State private var devicesPath: [AreaRoute] = []
    @State private var irrigationPath: [AreaRoute] = []

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            Tab("Overview", systemImage: "house", value: AppTab.overview) {
                stack(path: $overviewPath) { OverviewView() }
            }
            Tab("Areas", systemImage: "square.grid.2x2", value: AppTab.areas) {
                stack(path: $areasPath) { AreasView() }
            }
            Tab("Devices", systemImage: "list.bullet", value: AppTab.devices) {
                stack(path: $devicesPath) { DevicesView() }
            }
            .badge(store.entities.filter(\.isBad).count > 0 ? Text("") : nil)
            Tab("Irrigation", systemImage: "drop", value: AppTab.irrigation) {
                stack(path: $irrigationPath) { IrrigationView() }
            }
        }
        .tint(Theme.text)
        .sheet(isPresented: $account) { AccountSheet() }
        #if DEBUG
        .onAppear {
            if let id = Snapshot.value("-area") { store.selectedTab = .areas; areasPath = [AreaRoute(id: id)] }
            if Snapshot.args.contains("-account") { account = true }
        }
        #endif
    }

    /// Every tab gets the same chrome: the account button here, and the
    /// bridge band at the top of every Page, so liveness is visible anywhere.
    private func stack<V: View>(path: Binding<[AreaRoute]>, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack(path: path) {
            content()
                .navigationDestination(for: AreaRoute.self) { AreaDetailView(areaId: $0.id) }
                // Large title on the same row as the account button, not a
                // second row under it: the page starts a row higher.
                .toolbarTitleDisplayMode(.inlineLarge)
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { account = true } label: {
                            Text(String(store.user?.shortName.first ?? "·").uppercased())
                                .font(.subheadline.weight(.semibold))
                                .frame(width: 32, height: 32)
                                .background(Theme.panel3, in: Circle())
                                .frame(minWidth: Theme.hit, minHeight: Theme.hit)
                        }
                        .accessibilityLabel("Account")
                    }
                }
                .toolbarBackground(Theme.bg, for: .navigationBar)
        }
    }
}

struct AccountSheet: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .dark

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.user?.shortName ?? "").font(.headline)
                        if let e = store.user?.email { Text(e).font(.subheadline).foregroundStyle(Theme.muted) }
                    }
                    LabeledContent("Access", value: store.role.rawValue)
                } footer: {
                    Text(roleNote)
                }
                Section("Bridge") {
                    LabeledContent("Status", value: store.bridgeStatus.label)
                    LabeledContent("Device control", value: store.meta.bridge?.control == false ? "Switched off" : store.meta.bridge?.control == true ? "On" : "Unknown")
                }
                Section("Reports") {
                    LabeledContent("Irrigation reports", value: store.meta.reportsEnabled == false ? "Switched off" : "On")
                }
                Section("Appearance") {
                    Picker("Theme", selection: $appearance) {
                        ForEach(Appearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if store.backend.isDemo {
                    Section {
                        Text("This build has no Firebase configuration, so it shows bundled demo data. Nothing here reaches the farm.")
                            .font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
                Section("App") {
                    LabeledContent("Version", value: "\(UpdateCheck.installedVersion) (\(UpdateCheck.installedBuild))")
                }
                Section {
                    Button("Sign out", role: .destructive) { dismiss(); store.signOut() }
                } footer: {
                    Text("Adding people and granting access stays on the web dashboard's Admin page.")
                }
            }
            .navigationTitle("Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
        .preferredColorScheme(appearance.scheme)
    }

    private var roleNote: String {
        switch store.role {
        case .viewer: return "You can see the farm. Operating devices and running reports needs the controller tier."
        case .controller: return "You can see the farm, operate lights, switches and fans, and run irrigation reports."
        case .admin: return "Controller, plus you can grant access from the web dashboard's Admin page."
        }
    }
}

struct GateView: View {
    enum Kind: Equatable { case signIn, denied(String?), message(String) }
    @Environment(FarmStore.self) private var store
    let kind: Kind
    @State private var busy = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            // The roundel's centre is transparent and its lettering is the
            // brand green, so it always sits on white, in both themes.
            Image("brand-logo").resizable().interpolation(.high).scaledToFit()
                .frame(width: 112, height: 112)
                .padding(6)
                .background(Color.white, in: Circle())
                .accessibilityLabel("Sibhi Natural Orchards and Farms")
            VStack(spacing: 8) {
                Text("SNOF").font(.title.weight(.semibold)).foregroundStyle(Theme.text)
                Text(message).font(.subheadline).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            switch kind {
            case .signIn:
                Button {
                    busy = true
                    Task { await store.signIn(); busy = false }
                } label: {
                    HStack(spacing: 10) {
                        if busy { ProgressView().tint(Theme.bg) } else { Image(systemName: "person.crop.circle") }
                        Text("Sign in with Google").font(.body.weight(.semibold))
                    }
                    .frame(maxWidth: 320, minHeight: 50)
                    .foregroundStyle(Theme.bg)
                    .background(Theme.text, in: RoundedRectangle(cornerRadius: Theme.rMd, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(busy)
                if let err = store.signInError { SignInFailure(detail: err) }
            case .denied:
                Button("Sign out") { store.signOut() }
                    .frame(minHeight: Theme.hit)
                    .foregroundStyle(Theme.text)
            case .message:
                EmptyView()
            }
            if store.backend.isDemo { DemoBadge() }
            // Someone stuck here is exactly who needs to hear about a fix.
            UpdateBanner().frame(maxWidth: 360).padding(.horizontal, 20)
            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg)
    }

    private var message: String {
        switch kind {
        case .signIn: return "Sign in with the Google account on the farm allowlist."
        case .denied(let email):
            // Surfacing the address turns "access denied" into a one-step fix.
            return "\(email ?? "This account") is not on the allowlist.\n\nAsk a farm admin to add you from the web dashboard's Admin page."
        case .message(let why): return why
        }
    }
}

/// A failed sign-in, in words and in full, with a way to send it on.
private struct SignInFailure: View {
    let detail: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Sign-in did not complete", systemImage: "exclamationmark.triangle")
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.bad)
            Text(detail)
                .font(.caption.monospaced()).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy details") {
                UIPasteboard.general.string = detail
                copied = true
            }
            .font(.footnote.weight(.semibold)).foregroundStyle(Theme.text)
            .frame(minHeight: Theme.hit)
        }
        .panel()
        .frame(maxWidth: 360)
        .padding(.horizontal, 20)
    }
}
