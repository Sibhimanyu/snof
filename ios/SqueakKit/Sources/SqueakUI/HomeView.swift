#if os(iOS)
import SqueakCore
import SwiftUI

/// DESIGN.md §8.2: every active session, in attention order.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmingUnpair = false
    /// `-squeak-open <key>` starts inside a session: screenshots of the demo only.
    @State private var path: [String] = {
        let args = ProcessInfo.processInfo.arguments
        guard let index = args.firstIndex(of: "-squeak-open"), index + 1 < args.count else { return [] }
        return [args[index + 1]]
    }()

    var body: some View {
        NavigationStack(path: $path) {
            List {
                if let snapshot = model.snapshot {
                    if snapshot.sessions.isEmpty {
                        empty
                    }
                    ForEach(PhoneSnapshot.groups, id: \.title) { group in
                        let members = snapshot.sessions.filter { group.states.contains($0.state) }
                        if !members.isEmpty {
                            Section {
                                ForEach(members) { session in
                                    NavigationLink(value: session.key) { SessionRow(session: session) }
                                        .listRowBackground(Theme.surface)
                                }
                            } header: {
                                Text("\(group.title) \(members.count)").font(.footnote.weight(.semibold)).foregroundStyle(Theme.muted)
                            }
                        }
                    }
                } else {
                    waiting
                }
                footer
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg.ignoresSafeArea())
            .navigationTitle("Squeak")
            .navigationDestination(for: String.self) { key in SessionView(key: key) }
            .refreshable { await model.refresh() }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Unpair this iPhone", role: .destructive) { confirmingUnpair = true }
                    } label: {
                        Image(systemName: "ellipsis.circle").accessibilityLabel("More")
                    }
                }
            }
            .confirmationDialog("Unpair this iPhone?", isPresented: $confirmingUnpair, titleVisibility: .visible) {
                Button("Unpair", role: .destructive) { model.unpair() }
            } message: {
                Text("It will stop seeing and answering your agents until you pair again.")
            }
        }
        .foregroundStyle(Theme.ink)
    }

    private var summary: String {
        guard let snapshot = model.snapshot else { return "" }
        var bits: [String] = []
        if snapshot.duck.blockedCount > 0 { bits.append("\(snapshot.duck.blockedCount) need\(snapshot.duck.blockedCount == 1 ? "s" : "") you") }
        if snapshot.duck.workingCount > 0 { bits.append("\(snapshot.duck.workingCount) working") }
        return bits.isEmpty ? "All quiet" : bits.joined(separator: " · ")
    }

    private var empty: some View {
        VStack(spacing: 12) {
            Image("duck-asleep", bundle: .module).resizable().scaledToFit().frame(width: 88, height: 88).accessibilityHidden(true)
            Text("Nothing's running. The duck is resting.").foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private var waiting: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(model.problem ?? "Waiting for your Mac…").foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.vertical, 40)
        .listRowBackground(Color.clear)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let snapshot = model.snapshot {
                Text("\(summary) · \(snapshot.mac)")
                Text("Updated \(Age.describe(snapshot.generatedAt))")
            }
            if let problem = model.problem, model.snapshot != nil {
                Text(problem).foregroundStyle(Theme.needsYou)
            }
        }
        .font(.footnote)
        .foregroundStyle(Theme.muted)
        .listRowBackground(Color.clear)
    }
}

struct SessionRow: View {
    let session: PhoneSnapshot.Session

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            StateDot(state: session.state).alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
            VStack(alignment: .leading, spacing: 2) {
                Text(session.label).font(.body.weight(.medium)).lineLimit(1)
                Text(meta).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1).monospacedDigit()
                if let git = session.git {
                    Text(git).font(.footnote).foregroundStyle(Theme.muted).lineLimit(1).monospacedDigit()
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    var meta: String {
        var parts = [session.agent, session.stateWord, Age.describe(session.lastActivityAt)]
        if let context = session.contextPercent, context >= 60 { parts.append("ctx \(Int(context))%") }
        return parts.joined(separator: " · ")
    }
}

enum Age {
    static func describe(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return "" }
        let minutes = Int(Date().timeIntervalSince(date) / 60)
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        return hours < 24 ? "\(hours)h" : "\(hours / 24)d"
    }
}
#endif
