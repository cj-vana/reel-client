import SwiftUI

struct ServersView: View {
    @Environment(Session.self) private var session
    @Environment(Downloads.self) private var downloads
    @Environment(ServerPreferences.self) private var preferences
    @Environment(MediaHub.self) private var mediaHub
    @Environment(\.dismiss) private var dismiss
    private struct ConnectionDraft: Identifiable { let id = UUID(); let account: Account? }
    @State private var connection: ConnectionDraft?
    @State private var removing: Account?
    @State private var error: String?
    @State private var busy = false

    var body: some View {
        List {
            Section {
                ForEach(session.accounts) { account in
                    HStack(spacing: 14) {
                        Button {
                            Task {
                                busy = true
                                defer { busy = false }
                                do { try await session.select(account); dismiss() }
                                catch { self.error = error.localizedDescription }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Image(systemName: "server.rack").font(.title2).foregroundStyle(Color.reelText)
                                    .frame(width: 48, height: 48).background(Color.reelFill, in: RoundedRectangle(cornerRadius: ReelRadius.control))
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(account.serverName).font(.headline).foregroundStyle(Color.reelText)
                                    Text(account.name + " · " + (account.server.host ?? "")).font(.subheadline).foregroundStyle(Color.reelMuted).lineLimit(2)
                                }
                                Spacer()
                                if account.id == session.account?.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.reelBlue).accessibilityLabel("Current server") }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain).accessibilityIdentifier("server-\(account.userID)")
                        Menu {
                            Button("Sign in again", systemImage: "person.badge.key") { connection = ConnectionDraft(account: account) }
                            Button("Remove from device", systemImage: "trash", role: .destructive) { removing = account }
                        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
                            .accessibilityLabel("Options for \(account.serverName), \(account.name)")
                            .accessibilityIdentifier("serverOptions-\(account.userID)")
                    }.padding(.vertical, 5).listRowBackground(Color.reelSurface)
                }
                Button { connection = ConnectionDraft(account: nil) } label: { Label("Add server", systemImage: "plus.circle.fill").font(.headline).padding(.vertical, 8) }
                    .accessibilityIdentifier("addServer").listRowBackground(Color.reelSurface)
            } header: { Text("Saved connections") } footer: { Text("Each server keeps its own account and library. Switching reconnects with your saved sign-in; it works without signing out of the others.").foregroundStyle(Color.reelMuted) }
            if let error { Section { Text(error).font(.footnote).foregroundStyle(.orange) } }
            if session.api?.isSimulatorPreview == true {
                Section { Label("Library changes are off for this server in this build.", systemImage: "eye.slash").font(.subheadline) }
            }
        }
        .disabled(busy)
        .scrollContentBackground(.hidden).background(Color.reelBackground)
        .navigationTitle("Servers").navigationBarTitleDisplayMode(.large)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        .toolbarMinimizationBehavior(.never, for: .navigationBar)
        .sheet(item: $connection) { draft in NavigationStack { ConnectView(addingServer: true, account: draft.account).id(draft.id) } }
        .confirmationDialog("Remove this saved connection?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible, presenting: removing) { account in
            Button("Remove from device", role: .destructive) {
                removing = nil
                Task { do { try await session.remove(account) { preferences.clear(accountID: account.id); downloads.removeAccount(account.id); do { try mediaHub.removeAccount(account.id) } catch { session.notice = error.localizedDescription } } } catch { self.error = error.localizedDescription } }
            }.accessibilityIdentifier("confirmRemoveServer")
        } message: { _ in Text("This signs out on this device. Your Jellyfin account, library and watch history stay on the server.") }
    }
}

struct ServerSwitcher: View {
    var compact = false
    @Environment(Session.self) private var session
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: {
            HStack(spacing: 7) {
                Image(systemName: "server.rack").foregroundStyle(Color.reelBlue)
                if !compact, horizontalSizeClass != .regular {
                    Text(session.account?.serverName ?? "Servers").lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                }
            }.font(.subheadline.weight(.semibold))
                .frame(minWidth: compact || horizontalSizeClass == .regular ? 44 : nil, minHeight: 44)
                .contentShape(Rectangle())
        }.accessibilityIdentifier("servers")
        .accessibilityLabel("Servers")
        .accessibilityValue(session.account?.serverName ?? "No server selected")
        .sheet(isPresented: $showing) { NavigationStack { ServersView() } }
    }
}
