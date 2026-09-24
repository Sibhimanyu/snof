import SwiftUI
import SNOFCore

struct RootView: View {
    @Environment(FarmStore.self) private var store
    @AppStorage("appearance") private var appearance: Appearance = .system

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
    @State private var overviewPath = NavigationPath()
    @State private var areasPath = NavigationPath()
    @State private var irrigationPath = NavigationPath()
    @State private var waterPath = NavigationPath()

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.overview) {
                stack(path: $overviewPath) { OverviewView() }
            }
            Tab("Irrigation", systemImage: "drop", value: AppTab.irrigation) {
                stack(path: $irrigationPath) { IrrigationView() }
            }
            Tab("Water", systemImage: "water.waves", value: AppTab.water) {
                stack(path: $waterPath) { WaterView() }
            }
            Tab("Rooms", systemImage: "square.grid.2x2", value: AppTab.areas) {
                stack(path: $areasPath) {
                    if store.roomsMode == .rooms { AreasView() } else { DevicesView() }
                }
            }
            // Faults only: ACs, TVs and the printer off at the wall are not.
            .badge(store.faultyDevices.isEmpty ? nil : Text(""))
        }
        .tint(Theme.text)
        .toolbarBackground(.bar, for: .tabBar)
        .sensoryFeedback(.selection, trigger: store.selectedTab)
        // The store is handed to every sheet explicitly: a sheet on this
        // TabView was built without it on Catalyst (fatal "No Observable
        // object of type FarmStore found", snapshot review 2026-09-25).
        .sheet(isPresented: $account) { AccountSheet().environment(store) }
        #if DEBUG
        .onAppear {
            if let id = Snapshot.value("-area") { store.selectedTab = .areas; areasPath.append(AreaRoute(id: id)) }
            if let raw = Snapshot.value("-system"), let id = FarmSystemID(rawValue: raw) { store.selectedTab = .overview; overviewPath.append(SystemRoute(id: id)) }
            if Snapshot.args.contains("-account") { account = true }
        }
        #endif
    }

    /// Every tab gets the same bar as the web dashboard on a phone: the
    /// wordmark on the left, the bridge and the account on the right. The
    /// page's own eyebrow and large title sit in the content, so the bar
    /// never repeats them.
    /// Type-erased paths: a stack carries both room pages (AreaRoute) and
    /// system pages (SystemRoute). A typed [AreaRoute] path could not push
    /// a system page at all.
    private func stack<V: View>(path: Binding<NavigationPath>, @ViewBuilder _ content: () -> V) -> some View {
        NavigationStack(path: path) {
            content()
                .navigationDestination(for: AreaRoute.self) { AreaDetailView(areaId: $0.id) }
                .navigationDestination(for: SystemRoute.self) { SystemView(id: $0.id) }
                .toolbarTitleDisplayMode(.inline)
                .toolbar(removing: .title)
                .toolbar { barItems }
                // The system's frosted bar, as in every iOS app.
                .toolbarBackground(.bar, for: .navigationBar)
        }
    }

    /// iOS 26 wraps each bar item in a glass capsule; the wordmark and the
    /// pill carry their own shape, so they opt out where that exists.
    @ToolbarContentBuilder private var barItems: some ToolbarContent {
        if #available(iOS 26.0, *) {
            ToolbarItem(placement: .topBarLeading) { wordmark }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { bridgePill }.sharedBackgroundVisibility(.hidden)
            ToolbarItem(placement: .topBarTrailing) { accountButton }.sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .topBarLeading) { wordmark }
            ToolbarItem(placement: .topBarTrailing) { HStack(spacing: 4) { bridgePill; accountButton } }
        }
    }

    private var wordmark: some View {
        Text("SNOF").font(Theme.font(20, .heavy, relativeTo: .title3)).tracking(-1.2)
            .foregroundStyle(Theme.text)
            .fixedSize()
            .accessibilityAddTraits(.isHeader)
    }

    private var bridgePill: some View {
        BridgePill(status: store.bridgeStatus, text: store.bridgeText(), compact: true)
    }

    private var accountButton: some View {
        Button { account = true } label: {
            Text(String(store.user?.shortName.first ?? "·").uppercased())
                .font(Theme.font(12, .heavy, relativeTo: .caption))
                .foregroundStyle(Theme.muted)
                .frame(width: 30, height: 30)
                .background(Theme.panel3, in: Circle())
                .frame(minWidth: Theme.hit, minHeight: Theme.hit)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Account")
    }
}

struct AccountSheet: View {
    @Environment(FarmStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appearance") private var appearance: Appearance = .system

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(store.user?.shortName ?? "").font(Theme.font(16.5, .bold, relativeTo: .headline))
                        if let e = store.user?.email { Text(e).font(Theme.font(14.5, .regular, relativeTo: .subheadline)).foregroundStyle(Theme.muted) }
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
                    .sensoryFeedback(.selection, trigger: appearance)
                }
                if store.backend.isDemo {
                    Section {
                        Text("This build has no Firebase configuration, so it shows bundled demo data. Nothing here reaches the farm.")
                            .font(Theme.font(13, .regular, relativeTo: .footnote)).foregroundStyle(Theme.muted)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    // The roundel's centre is transparent and its lettering is
                    // the brand green, so it always sits on white.
                    Image("brand-logo").resizable().interpolation(.high).scaledToFit()
                        .frame(width: 28, height: 28).padding(2)
                        .background(Color.white, in: Circle())
                        .overlay(Circle().strokeBorder(Theme.line, lineWidth: 1))
                        .accessibilityLabel("Sibhi Natural Orchards and Farms")
                    Text("SNOF").font(Theme.font(22, .heavy, relativeTo: .title2)).tracking(-1.3)
                        .foregroundStyle(Theme.text)
                    Text("Natural Orchards").font(Theme.font(13.5, .semibold, relativeTo: .subheadline))
                        .foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 32)

                Text("Sibhi Natural Orchards & Farms").eyebrowStyle()
                Text("Your farm, right now.").font(Theme.font(36, .bold, relativeTo: .largeTitle))
                    .tracking(-1.8).foregroundStyle(Theme.text)
                    .padding(.top, 10).padding(.bottom, 12)
                Text("Every room, sensor and switch on the farm — live, and operable from here.")
                    .font(Theme.font(15, .regular, relativeTo: .body)).foregroundStyle(Theme.muted)

                Text(message).font(Theme.meta).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tintPanel(padding: 14)
                    .padding(.top, 24).padding(.bottom, 12)

                switch kind {
                case .signIn:
                    Button {
                        busy = true
                        Task { await store.signIn(); busy = false }
                    } label: {
                        HStack(spacing: 10) {
                            if busy { ProgressView().tint(Theme.text) } else { Image(systemName: "person.crop.circle") }
                            Text("Continue with Google").font(Theme.font(15.5, .bold, relativeTo: .body))
                        }
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(Theme.text)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.rSm + 2, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(busy)
                    if let err = store.signInError { SignInFailure(detail: err).padding(.top, 12) }
                case .denied:
                    Button("Use a different account") { store.signOut() }
                        .font(Theme.font(15, .bold, relativeTo: .body))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .foregroundStyle(Theme.text)
                        .background(Theme.fill, in: RoundedRectangle(cornerRadius: Theme.rSm + 2, style: .continuous))
                case .message:
                    EmptyView()
                }

                Text("Control is limited to lights, switches and fans on the allowlist.")
                    .font(Theme.meta).foregroundStyle(Theme.faint).padding(.top, 16)
                if store.backend.isDemo { DemoBadge().padding(.top, 12) }
                // Someone stuck here is exactly who needs to hear about a fix.
                UpdateBanner().padding(.top, 12)
            }
            .padding(24)
            .modifier(Panel(padding: 0))
            .frame(maxWidth: 440)
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        // Centred when it fits, scrollable from the top when it does not.
        .defaultScrollAnchor(.center)
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
                .font(Theme.font(14.5, .semibold, relativeTo: .subheadline)).foregroundStyle(Theme.bad)
            Text(detail)
                .font(.caption.monospaced()).foregroundStyle(Theme.text)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(copied ? "Copied" : "Copy details") {
                UIPasteboard.general.string = detail
                copied = true
            }
            .font(Theme.font(13, .semibold, relativeTo: .footnote)).foregroundStyle(Theme.text)
            .frame(minHeight: Theme.hit)
        }
        .panel()
    }
}


/// SNOF's own Mobitech session: sign in with an SMS code the way Mobitech's
/// app does (docs/mobitech-app.md), proved with a dashboard read, or sign out.
/// Admins only.
struct MobitechSignIn: View {
    enum Step { case idle, mobile, code }
    @Environment(FarmStore.self) private var store
    @State private var step = Step.idle
    @State private var mobile = ""
    @State private var code = ""
    @State private var busy = false
    @State private var confirmSignOut = false

    var body: some View {
        Text("SNOF signs in to Mobitech with its own session, so a sign-out on the phone does not stop valve control.")
            .font(Theme.meta).foregroundStyle(Theme.muted)
        if let st = store.mobitechStatus {
            LabeledContent("Signed in as", value: [st.name, st.user.isEmpty || st.name.isEmpty ? nil : "(\(st.user))"]
                .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " "))
            LabeledContent("Number", value: "ending \(st.mobileLast4)")
            LabeledContent("Since", value: FarmTime.when(ms: st.at, now: Date()))
            LabeledContent("Last command", value: st.lastOk.map { "accepted " + FarmTime.when(ms: $0, now: Date()) } ?? "none yet")
        }
        if let problem = store.mobitechProblem { Text(problem).foregroundStyle(Theme.warn) }

        switch step {
        case .idle:
            Button(store.mobitechStatus == nil ? "Sign in to Mobitech" : "Sign in again") { step = .mobile }
            if store.mobitechStatus != nil {
                Button("Sign SNOF out", role: .destructive) { confirmSignOut = true }
                    .disabled(busy)
                    .confirmationDialog("Sign SNOF out of Mobitech?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                        Button("Sign out", role: .destructive) {
                            busy = true
                            Task { await store.mobitechSignOut(); busy = false }
                        }
                    } message: { Text("Valve commands stop until someone signs in again.") }
            }
        case .mobile:
            TextField("Mobitech mobile number", text: $mobile)
                .keyboardType(.numberPad).textContentType(.telephoneNumber)
            Text("Signing SNOF in may sign the Mobitech app on the phone out, if Mobitech allows one session per account.")
                .font(Theme.meta).foregroundStyle(Theme.muted)
            Button(busy ? "Sending…" : "Send code") {
                busy = true
                Task { if await store.mobitechSendCode(mobile) { step = .code }; busy = false }
            }
            .disabled(busy || Mobitech.mobile(mobile) == nil)
            Button("Cancel", role: .cancel) { step = .idle; mobile = "" }.disabled(busy)
        case .code:
            TextField("Code from the SMS", text: $code)
                .keyboardType(.numberPad).textContentType(.oneTimeCode)
            Button(busy ? "Signing in…" : "Sign in") {
                busy = true
                Task {
                    if await store.mobitechSignIn(mobile, code: code) { step = .idle; code = ""; mobile = "" }
                    busy = false
                }
            }
            .disabled(busy || code.filter(\.isNumber).count < 4)
            Button("Use another number", role: .cancel) { step = .mobile; code = "" }.disabled(busy)
        }
    }
}
