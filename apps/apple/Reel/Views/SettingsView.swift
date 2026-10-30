import SwiftUI

struct SettingsView: View {
    @State private var showingServers = false
    @Environment(Session.self) private var session
    @Environment(Downloads.self) private var downloads
    @Environment(ServerPreferences.self) private var preferences
    @Environment(MediaHub.self) private var mediaHub
    @AppStorage("streamQuality") private var quality = StreamQuality.original.rawValue
    @AppStorage("findMarkers") private var findMarkers = true
    @State private var confirmSignOut = false
    @State private var signingOut = false
    @State private var error: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Text(String(session.account?.name.prefix(1) ?? "R").uppercased())
                        .font(.system(size: 21, weight: .semibold)).foregroundStyle(Color.reelText)
                        .frame(width: 48, height: 48).background(Color.reelSurfaceRaised, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(session.account?.name ?? "Your account").font(.headline).foregroundStyle(Color.reelText)
                        Text([session.account?.serverName, session.account?.server.host].compactMap { $0 }.joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color.reelMuted).lineLimit(2)
                    }
                }.padding(.vertical, 6).accessibilityElement(children: .combine)
                Button { showingServers = true } label: {
                    SettingsRow(title: "Manage servers", systemImage: "server.rack", chevron: true)
                }.accessibilityIdentifier("manageServers")
            } header: { Text("Account") }.listRowBackground(Color.reelSurface)
            Section {
                @Bindable var session = session
                Toggle(isOn: $session.privateViewing) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Private viewing")
                        Text("With private viewing on, watch progress stays on this device.")
                            .font(.footnote).foregroundStyle(Color.reelMuted)
                    }
                }.accessibilityIdentifier("privateViewing")
                Toggle(isOn: $findMarkers) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Find intros and credits")
                        Text("When your server has not marked them, Reel compares the opening and closing minutes of neighboring episodes. Your server streams a low-quality copy of that audio to do it.")
                            .font(.footnote).foregroundStyle(Color.reelMuted)
                    }
                }.accessibilityIdentifier("findMarkers")
                if session.api?.isSimulatorPreview == true { Text("This build doesn’t change the library or watch history on this server, even after relaunching.").font(.footnote).foregroundStyle(Color.reelMuted) }
                Picker("Streaming quality", selection: $quality) { ForEach(StreamQuality.allCases) { Text($0.label).tag($0.rawValue) } }
                    // The chosen value reads as muted text, like every other value in Settings, not in the accent.
                    .tint(Color.reelMuted).disabled(preferences.bitrateLocked).accessibilityIdentifier("qualityPicker")
            } header: { Text("Playback") } footer: { Text("Reel plays compatible files directly and asks Jellyfin to convert the rest. A lower quality uses less mobile data.").foregroundStyle(Color.reelMuted) }.listRowBackground(Color.reelSurface)
            ServerPreferencesSection()
            Section {
                SettingsRow(title: "Sign-in kept in the Keychain", systemImage: "key.horizontal")
                SettingsRow(title: "No Reel analytics", systemImage: "hand.raised")
                SettingsRow(title: "Artwork cached in memory only", systemImage: "photo.stack")
            } header: { Text("Privacy") }.listRowBackground(Color.reelSurface)
            Section {
                Button(role: .destructive) { confirmSignOut = true } label: {
                    HStack { Text(signingOut ? "Signing out…" : "Sign out of this account"); Spacer(); Image(systemName: "rectangle.portrait.and.arrow.right") }
                }.disabled(signingOut).accessibilityIdentifier("signOut")
                if let error { Text(error).foregroundStyle(.orange).font(.footnote) }
            } footer: {
                HStack(spacing: 12) {
                    ReelMark(markOnly: true)
                    Text("Reel \(Self.version). An independent Jellyfin client.").font(.footnote).foregroundStyle(Color.reelTertiary)
                }.padding(.top, 24).frame(maxWidth: .infinity)
            }.listRowBackground(Color.reelSurface)
        }
        .modifier(ReadableColumn())
        .scrollContentBackground(.hidden).reelCanvas()
        .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingServers) { NavigationStack { ServersView() } }
        .confirmationDialog("Sign out of Reel?", isPresented: $confirmSignOut, titleVisibility: .visible) {
            Button("Sign out", role: .destructive) {
                signingOut = true
                Task { defer { signingOut = false }; do { let id = session.account?.id; try await session.signOut { if let id { preferences.clear(accountID: id); downloads.removeAccount(id); do { try mediaHub.removeAccount(id) } catch { session.notice = error.localizedDescription } } } } catch { self.error = error.localizedDescription } }
            }
        } message: { Text("Your library stays on your server. You can sign in again at any time.") }
    }

    /// The marketing version from the app bundle, so the footer never states a stale number.
    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
}

/// A settings row: a muted icon in a fixed column, so every title starts on the same edge.
private struct SettingsRow: View {
    let title: String
    let systemImage: String
    var chevron = false
    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: systemImage).font(.body).foregroundStyle(Color.reelMuted).frame(width: 24).accessibilityHidden(true)
            Text(title).foregroundStyle(Color.reelText)
            if chevron {
                Spacer(minLength: 8)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.reelTertiary).accessibilityHidden(true)
            }
        }.frame(minHeight: 32).contentShape(Rectangle())
    }
}
