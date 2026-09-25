#if os(iOS)
import SqueakCore
import SwiftUI

/// Squeak's whole iPhone UI as one view: pairing, the session list, answers.
///
/// The Squeak app is nothing but a window around this, and another app can
/// host it as a tab. It owns its model and polls only while it is on screen
/// — the app being in the foreground *and* this view being visible — which is
/// also what tells the Mac to publish and poll faster.
public struct SqueakRootView: View {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false

    public init() {}

    /// Squeak's duck as a tab-bar glyph (a template image, so the tab bar
    /// tints it), for an app that hosts this view as a tab. Generated from
    /// the duck artwork; never an SF Symbol, which draws a generic bird.
    public static var tabIcon: Image { Image("squeak-tab-duck", bundle: .module) }

    public var body: some View {
        RootView()
            .environmentObject(model)
            .tint(Theme.done)
            .onAppear { visible = true; update() }
            .onDisappear { visible = false; update() }
            .onChange(of: scenePhase) { _, _ in update() }
    }

    private func update() {
        if visible && scenePhase == .active { model.resume() } else { model.pause() }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.phase {
        case .unpaired: PairView()
        case let .awaitingApproval(code, mac): AwaitingApprovalView(code: code, mac: mac)
        case .paired: HomeView()
        }
    }
}
#endif
