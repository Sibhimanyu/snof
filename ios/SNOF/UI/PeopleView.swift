import SwiftUI
import SNOFCore

/* People and access, for admins (owner, 2026-09-25: "as an admin I should be
 * able to give permission to other people either from the iOS or web").
 * Mirrors adminView() in dashboard/public/app.js: add someone by email
 * before they have ever signed in, then grant or revoke view and control.
 * The RTDB rules decide every write; admin is never offered here, because no
 * app can make one (acl/admins refuses every client write). */
struct PeopleView: View {
    @Environment(FarmStore.self) private var store
    @State private var email = ""
    @State private var tier: AccessTier = .view
    @FocusState private var typing: Bool

    var body: some View {
        List {
            Section {
                TextField("someone@example.com", text: $email)
                    .keyboardType(.emailAddress).textContentType(.emailAddress)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($typing).submitLabel(.done)
                Picker("Access", selection: $tier) {
                    Text("View").tag(AccessTier.view)
                    Text("View + control").tag(AccessTier.control)
                }
                Button {
                    typing = false
                    Task { if await store.invite(email: email, tier: tier) { email = ""; tier = .view } }
                } label: {
                    HStack {
                        Text("Add person").bold()
                        if let key = Invites.key(for: email), store.accessBusy.contains(key) { Spacer(); ProgressView() }
                    }
                }
                .disabled(email.trimmingCharacters(in: .whitespaces).isEmpty)
            } header: {
                Text("Add a person")
            } footer: {
                Text("Access starts when they sign in with that Google account.")
            }

            if let list = store.access {
                if !list.invites.isEmpty {
                    Section("Invited") {
                        ForEach(list.invites) { inv in
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(inv.email).font(Theme.rowTitle).foregroundStyle(Theme.text)
                                    Text("\(inv.tier == .control ? "View + control" : "View") · waiting for their first sign-in")
                                        .font(Theme.meta).foregroundStyle(Theme.muted)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                Tag(text: "Pending")
                            }
                            .swipeActions {
                                Button("Cancel invite", role: .destructive) { Task { await store.cancelInvite(inv) } }
                            }
                            .contextMenu {
                                Button("Cancel invite", role: .destructive) { Task { await store.cancelInvite(inv) } }
                            }
                        }
                    }
                }
                Section {
                    if list.people.isEmpty {
                        Text("No one yet. Add someone above: they do not need to have signed in first.")
                            .font(Theme.meta).foregroundStyle(Theme.muted)
                    }
                    ForEach(list.people) { PersonRow(person: $0) }
                } header: {
                    Text("People")
                } footer: {
                    Text("Only the farm owner can make someone an admin.")
                }
            } else {
                Section { HStack { Spacer(); ProgressView(); Spacer() } }
            }
        }
        .navigationTitle("People and access")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.watchAccess(true) }
        .onDisappear { store.watchAccess(false) }
    }
}

private struct PersonRow: View {
    @Environment(FarmStore.self) private var store
    let person: Person

    var body: some View {
        let me = person.uid == store.user?.uid
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name ?? person.email ?? "No name on record").font(Theme.rowTitle).foregroundStyle(Theme.text)
                // The email once: as the title when there is no name.
                let sub = me ? "This is you" : person.tier == .admin ? "Admin: change from the command line"
                    : person.name == nil ? (person.email == nil ? "Signed in, no email on record" : "")
                    : person.email ?? ""
                if !sub.isEmpty { Text(sub).font(Theme.meta).foregroundStyle(Theme.muted) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.accessBusy.contains(person.uid) { ProgressView() }
            if me || person.tier == .admin {
                tag
            } else {
                // The tier is the button: what they have, and what it can become.
                Menu {
                    if person.tier == .none { action("Grant view", .view) }
                    if person.tier == .view { action("Grant control", .control) }
                    if person.tier == .control { action("Revoke control", .view) }
                    if person.tier == .view || person.tier == .control {
                        Button("Revoke all access", role: .destructive) { Task { await store.setAccess(person, to: .none) } }
                    }
                } label: {
                    HStack(spacing: 4) { tag; Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint) }
                        .contentShape(Rectangle())
                }
                .disabled(store.accessBusy.contains(person.uid))
                .accessibilityLabel("\(person.tier.label). Change access")
            }
        }
        .frame(minHeight: Theme.hit)
    }

    private var tag: some View {
        Tag(text: person.tier.label, kind: person.tier == .admin || person.tier == .control ? .on : person.tier == .none ? .bad : .plain)
    }

    private func action(_ label: String, _ tier: AccessTier) -> some View {
        Button(label) { Task { await store.setAccess(person, to: tier) } }
    }
}
