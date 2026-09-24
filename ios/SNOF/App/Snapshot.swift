#if DEBUG
import SwiftUI
import UIKit

/* Debug-only: render the window to a PNG and quit, so screens can be reviewed
 * on a machine with no simulator and no screen-recording permission.
 *
 *   SNOF.app -demo -snapshot /tmp/out.png [-tab devices] [-area pump_house]
 *            [-account] [-snapshot-delay 3]
 *
 * Used by scripts/shoot.sh. Compiled out of Release builds. */
@MainActor
enum Snapshot {
    static var args: [String] { ProcessInfo.processInfo.arguments }

    static func value(_ flag: String) -> String? {
        guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
        return args[i + 1]
    }

    private static var store: FarmStore?

    static func prepare(_ store: FarmStore) {
        Self.store = store
        switch value("-tab") {
        case "areas": store.selectedTab = .areas
        case "devices": store.selectedTab = .areas; store.roomsMode = .devices
        case "irrigation": store.selectedTab = .irrigation
        case "water": store.selectedTab = .water
        default: break
        }
        if value("-status") == "offline" { store.deviceStatus = .offline }
        if args.contains("-press-signin") { Task { try? await Task.sleep(for: .seconds(1)); await store.signIn() } }
    }

    static func runIfRequested() {
        guard let out = value("-snapshot") else { return }
        let delay = Double(value("-snapshot-delay") ?? "") ?? 3
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            // -reports renders every report card at full length, which a
            // window-sized capture cannot show.
            // -report-sheet renders the first report the way its sheet shows
            // it; a Catalyst sheet is its own window, out of reach of the
            // window capture below.
            if args.contains("-report-sheet"), let store, let first = store.reports.first {
                let dark = UserDefaults.standard.string(forKey: "appearance") == "dark"
                let content = ReportSheetContent(report: store.reports.first(where: { !$0.sections.isEmpty }) ?? first)
                    .frame(width: 402).background(Theme.bg)
                    .environment(\.colorScheme, dark ? .dark : .light)
                let r = ImageRenderer(content: content)
                r.scale = 3
                try? r.uiImage?.pngData()?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
            if args.contains("-reports"), let store {
                let content = VStack(spacing: 10) { ForEach(store.reports) { ReportCard(report: $0) } }
                    .padding(16).frame(width: 402).background(Theme.bg)
                    .environment(\.colorScheme, .dark)
                let r = ImageRenderer(content: content)
                r.scale = 3
                try? r.uiImage?.pngData()?.write(to: URL(fileURLWithPath: out))
                exit(0)
            }
            guard let window = UIApplication.shared.connectedScenes
                .compactMap({ ($0 as? UIWindowScene)?.keyWindow ?? ($0 as? UIWindowScene)?.windows.first }).first
            else { exit(2) }
            let format = UIGraphicsImageRendererFormat()
            format.scale = 3
            let img = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            try? img.pngData()?.write(to: URL(fileURLWithPath: out))
            exit(0)
        }
    }
}
#endif
