#if os(iOS)
import Foundation
import SqueakCore

/// Launch with `-squeak-demo` to see the app without a Mac: screenshots and design review only.
enum DemoData {
    static let snapshot = PhoneSnapshot(
        v: 1, mac: "Sibhi's MacBook", generatedAt: now(-4),
        duck: .init(blockedCount: 1, workingCount: 2),
        sessions: [
            .init(key: "a", conductorSessionId: nil, label: "api-server · retry-queue", agent: "claude", state: "awaiting_approval",
                  lastActivityAt: now(-120), detail: "Claude needs your permission to use Bash", git: nil, contextPercent: nil,
                  turnId: nil, message: "Claude needs your permission to use Bash", choices: nil),
            .init(key: "b", conductorSessionId: "d0000000-0000-4000-8000-000000000001", label: "farm-dashboard · light-control", agent: "claude", state: "finished",
                  lastActivityAt: now(-300), detail: "D1 — Arm device control on the farm?", git: "+212/−48 · 6 files", contextPercent: 62,
                  turnId: "t1",
                  message: "**D1 — Arm device control on the farm?** (reply with a letter)\n\nThe dashboard can't operate anything until `allow_control` is flipped to true on the add-on. That switch is deliberate: it is gate 3 of three, off by default.\n\n**A) Arm it now (recommended).** I set `allow_control: true` and restart the add-on.\n\n**B) Arm it, but only after you are physically near the hardware.** Same change, later.\n\n**C) Leave it off.** The dashboard now says plainly that control is off.",
                  choices: .init(question: "D1 — Arm device control on the farm?",
                                 options: [.init(letter: "A", title: "Arm it now"),
                                           .init(letter: "B", title: "Arm it, but only after you are physically near the hardware"),
                                           .init(letter: "C", title: "Leave it off")],
                                 recommended: "A")),
            .init(key: "c", conductorSessionId: "d0000000-0000-4000-8000-000000000002", label: "squeak · session-hub", agent: "claude", state: "working",
                  lastActivityAt: now(-8), detail: "Running npm run ci", git: "+311/−10 · 20 files", contextPercent: nil,
                  turnId: "t2", message: nil, choices: nil,
                  activity: .init(total: 17, steps: [
                      .init(kind: "note", text: "Checking why the finish card fires twice."),
                      .init(kind: "tool", text: "Read merge.ts"),
                      .init(kind: "thinking", text: "The Stop hook lands after Conductor has already said working, so it overrides a state it should defer to."),
                      .init(kind: "tool", text: "Edit merge.ts"),
                      .init(kind: "tool", text: "Run npm run ci"),
                  ])),
            .init(key: "d", conductorSessionId: "d0000000-0000-4000-8000-000000000003", label: "snof · irrigation-pull-to-refresh", agent: "claude", state: "working",
                  lastActivityAt: now(-40), detail: "Editing HomeView.swift", git: nil, contextPercent: 74,
                  turnId: "t3", message: nil, choices: nil),
        ])

    private static func now(_ offset: Double) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date().addingTimeInterval(offset))
    }
}
#endif
