#if os(iOS)
import SqueakCore
import SwiftUI

/// One session: what it said, and — for a finished Conductor chat — the
/// decision card (DESIGN.md §8.4) or the reply composer (§8.5).
struct SessionView: View {
    @EnvironmentObject var model: AppModel
    let key: String
    @State private var draft = ""
    @FocusState private var composing: Bool

    private var session: PhoneSnapshot.Session? { model.snapshot?.sessions.first { $0.key == key } }

    var body: some View {
        Group {
            if let session {
                content(session)
            } else {
                Text("This session is no longer active.").foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.bg)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func content(_ session: PhoneSnapshot.Session) -> some View {
        let receipt = model.receipts[session.key].flatMap { $0.turnId == session.turnId ? $0 : nil }
        let delivered: Bool = { if case .sent = receipt?.kind { return true } else { return false } }()

        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text(session.label).font(.title3.bold())
                    HStack(spacing: 8) {
                        StateDot(state: session.state)
                        Text([session.agent, session.stateWord, Age.describe(session.lastActivityAt)].joined(separator: " · "))
                            .foregroundStyle(Theme.muted).font(.subheadline)
                    }
                    if let git = session.git { Text(git).font(.footnote).foregroundStyle(Theme.muted).monospacedDigit() }
                }

                Divider().overlay(Theme.line)

                if session.state == "working", let activity = session.activity, !activity.steps.isEmpty {
                    Text("What it's doing").font(.headline)
                    ActivityFeed(activity: activity)
                } else {
                    Text("What it said").font(.headline)
                    MessageText(text: session.message ?? session.detail ?? "Nothing to show yet.")
                }

                if let receipt { ReceiptView(receipt: receipt) }
            }
            .padding(20)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Theme.bg.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) {
            if !delivered { answer(session, sending: receipt?.kind == .sending) }
        }
    }

    @ViewBuilder
    private func answer(_ session: PhoneSnapshot.Session, sending: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.conductorSessionId == nil {
                Text("Not a Conductor session — answer it where it runs.").foregroundStyle(Theme.muted).font(.footnote)
            } else if session.needsYou {
                Text("This chat is waiting inside Conductor. Answer it on your Mac.").foregroundStyle(Theme.muted).font(.footnote)
            } else {
                if let choices = session.choices, session.state != "working" {
                    DecisionCard(choices: choices, disabled: sending) { letter in
                        Task { await model.send(letter, to: session) }
                    }
                }
                HStack(alignment: .bottom, spacing: 8) {
                    TextField("Message for \(session.label)", text: $draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($composing)
                        .padding(10)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                    Button {
                        let text = draft
                        Task {
                            await model.send(text, to: session)
                            if case .sent = model.receipts[session.key]?.kind { draft = "" }
                        }
                    } label: {
                        Image(systemName: "arrow.up").font(.body.weight(.bold)).frame(width: 44, height: 44)
                            .foregroundStyle(Theme.primaryText)
                            .background(Theme.primaryFill, in: RoundedRectangle(cornerRadius: 8))
                    }
                    .accessibilityLabel("Send")
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(Theme.bg.shadow(.drop(color: .black.opacity(0.3), radius: 8, y: -2)))
    }
}

/// A working session's turn so far, newest last: thinking in italics, tool
/// calls marked in the working colour, the agent's notes as they are.
struct ActivityFeed: View {
    let activity: PhoneSnapshot.Activity

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if activity.total > activity.steps.count {
                Text("The latest \(activity.steps.count) of \(activity.total) steps this turn.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            ForEach(Array(activity.steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    if step.kind == "thinking" {
                        Text("Thinking").font(.caption).foregroundStyle(Theme.subtle)
                    } else if step.kind == "background" {
                        Text("Worker done").font(.caption).foregroundStyle(Theme.subtle)
                    }
                    Text(step.text)
                        .font(.subheadline)
                        .italic(step.kind == "thinking")
                        .foregroundStyle(step.kind == "note" ? Theme.ink : Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10)
                .overlay(alignment: .leading) {
                    Rectangle().fill(step.kind == "tool" ? Theme.working : Theme.line).frame(width: 2)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

struct DecisionCard: View {
    let choices: PhoneSnapshot.Choices
    let disabled: Bool
    let onPick: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let question = choices.question { Text(question).font(.headline) }
            ForEach(choices.options) { option in
                Button { onPick(option.letter) } label: {
                    HStack(spacing: 12) {
                        Text(option.letter).font(.body.bold()).frame(width: 28, height: 28)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6))
                        Text(option.title).multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                        if option.letter == choices.recommended {
                            Text("recommended").font(.caption).foregroundStyle(Theme.muted)
                        }
                    }
                    .padding(10)
                    .frame(minHeight: 44)
                    .background(Theme.surfaceRaised, in: RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.line))
                }
                .buttonStyle(.plain)
                .disabled(disabled)
                .accessibilityLabel("\(option.letter): \(option.title)\(option.letter == choices.recommended ? ", recommended" : "")")
            }
        }
        .padding(12)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.line))
    }
}

struct ReceiptView: View {
    let receipt: AppModel.Receipt

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            switch receipt.kind {
            case .sending:
                ProgressView(); Text("Sending…")
            case let .sent(text):
                Image(systemName: "checkmark").foregroundStyle(Theme.done); Text(text)
            case let .refused(reason):
                Text(reason)
            }
        }
        .font(.subheadline)
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isRefused ? Theme.needsYou : Theme.line))
    }

    private var isRefused: Bool { if case .refused = receipt.kind { return true } else { return false } }
}

/// The agent's markdown, inline formatting only, paragraphs kept. Links and
/// images become their words — a phone should not open agent-written URLs.
struct MessageText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(paragraphs.enumerated()), id: \.offset) { _, paragraph in
                if paragraph.hasPrefix("```") {
                    Text(paragraph.trimmingCharacters(in: CharacterSet(charactersIn: "`\n")))
                        .font(.system(.footnote, design: .monospaced))
                        .padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(attributed(paragraph)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var paragraphs: [String] {
        text.components(separatedBy: "\n\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func attributed(_ paragraph: String) -> AttributedString {
        let plain = paragraph
            .replacingOccurrences(of: #"!\[([^\]]*)\]\([^)]*\)"#, with: "[image: $1]", options: .regularExpression)
            .replacingOccurrences(of: #"\[([^\]]+)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
        var result = (try? AttributedString(markdown: plain, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(plain)
        for run in result.runs where run.link != nil { result[run.range].link = nil }
        return result
    }
}
#endif
