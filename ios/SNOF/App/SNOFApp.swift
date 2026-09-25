import SwiftUI
import GoogleSignIn
import SqueakUI

@main
struct SNOFApp: App {
    @State private var store: FarmStore
    @State private var updates = UpdateCheck()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // The farm when this build carries a Firebase config, bundled demo
        // data otherwise (or when launched with -demo). Never silently both.
        let demo = !FirebaseBackend.isConfigured || ProcessInfo.processInfo.arguments.contains("-demo")
        let backend: FarmBackend = demo ? DemoBackend() : FirebaseBackend()
        _store = State(initialValue: FarmStore(backend: backend))
    }

    /// Every URL the app is opened with. snof://squeak?s=<session> comes from
    /// a Squeak card in Telegram: the owner's Squeak tab, on that session;
    /// nobody else has the tab, so for them it does nothing. Anything else is
    /// Google sign-in's.
    private func open(_ url: URL) {
        if url.scheme == "snof", url.host == "squeak" {
            guard SqueakAccess.shows(for: store.user?.email) else { return }
            store.selectedTab = .squeak
            SqueakRouter.shared.handle(url)
            return
        }
        GIDSignIn.sharedInstance.handle(url)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .environment(updates)
                .onChange(of: scenePhase, initial: true) { _, phase in
                    // Demo data (and the offline review harness) makes no network calls.
                    if phase == .active, !store.backend.isDemo { Task { await updates.check() } }
                }
                .onAppear {
                    if store.phase == .boot { store.start() }
                    #if DEBUG
                    Snapshot.prepare(store)
                    Snapshot.runIfRequested()
                    // The link path without iOS's "Open in SNOF?" prompt, for review.
                    if let link = Snapshot.value("-open-url").flatMap(URL.init(string:)) { open(link) }
                    #endif
                    #if targetEnvironment(macCatalyst)
                    // On a Mac (the no-simulator preview path) default to a
                    // phone-sized window; -wide lifts it for iPad layouts.
                    if !ProcessInfo.processInfo.arguments.contains("-wide") {
                        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
                            scene.sizeRestrictions?.minimumSize = CGSize(width: 402, height: 874)
                            scene.sizeRestrictions?.maximumSize = CGSize(width: 402, height: 874)
                        }
                    }
                    #endif
                }
                .onOpenURL { open($0) }
        }
    }
}
