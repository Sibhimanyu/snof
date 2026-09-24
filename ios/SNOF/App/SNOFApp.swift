import SwiftUI
import GoogleSignIn

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
                .onOpenURL { GIDSignIn.sharedInstance.handle($0) }
        }
    }
}
