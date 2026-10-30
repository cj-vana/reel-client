import SwiftUI

struct TVSettingsView: View {
    @Environment(TVCoordinator.self) private var coordinator
    @State private var addingServer = false
    @State private var removing: Account?
    private var version: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 56) {
                Text("Settings").font(.system(size: 52, weight: .bold)).tracking(-0.6)
                section("Servers") {
                    ForEach(coordinator.session.accounts) { account in accountRow(account) }
                    Button { addingServer = true } label: { Label("Add server", systemImage: "plus") }
                        .accessibilityIdentifier("addServer")
                }
                .disabled(coordinator.transitioning)
                section("Playback and privacy") {
                    Picker("Streaming quality", selection: Binding(get: { coordinator.quality }, set: { coordinator.quality = $0 })) {
                        ForEach(StreamQuality.allCases) { value in Text(value.label).tag(value) }
                    }.accessibilityIdentifier("quality")
                    Toggle("Private viewing", isOn: Binding(get: { coordinator.session.privateViewing }, set: { coordinator.setPrivateViewing($0) }))
                        .accessibilityIdentifier("privateViewing")
                    Text(coordinator.session.privateViewing ? "Watch progress stays on this device." : "Watch progress syncs with your server.")
                        .font(.system(size: 24)).foregroundStyle(Color.tvMuted)
                    if coordinator.session.api?.isSimulatorPreview == true {
                        Label("This test build won’t change watch history or library state on this server.", systemImage: "lock")
                            .font(.system(size: 24)).foregroundStyle(Color.tvMuted)
                    }
                }
                HStack(spacing: 24) {
                    TVMark()
                    if !version.isEmpty { Text("Version " + version).font(.system(size: 24)).foregroundStyle(Color.tvTertiary) }
                }
            }
            .frame(maxWidth: 1360, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, TVLayout.margin).padding(.top, 40).padding(.bottom, 90)
        }
        .scrollClipDisabled()
        .ignoresSafeArea(edges: .horizontal)
        .background(Color.reelBackground.ignoresSafeArea())
        .fullScreenCover(isPresented: $addingServer) { TVConnectView(addingServer: true) }
        // The dialog takes the system tint so its focused action keeps a dark label (see ReelTVApp).
        .tint(Color.reelText)
        .confirmationDialog("Sign out \(removing?.name ?? "this account")?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), titleVisibility: .visible) {
            Button("Sign out", role: .destructive) { if let account = removing { removing = nil; Task { await coordinator.remove(account) } } }
            Button("Cancel", role: .cancel) { removing = nil }
        } message: { Text("This removes the saved sign-in from this Apple TV.") }
        .tint(nil)
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(title).font(.system(size: 30, weight: .bold)).tracking(-0.3)
            content()
        }.focusSection()
    }

    private func accountRow(_ account: Account) -> some View {
        let current = account.id == coordinator.session.account?.id
        return HStack(spacing: 32) {
            Image(systemName: "server.rack").font(.system(size: 32)).foregroundStyle(Color.tvMuted).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Text(account.serverName).font(.system(size: 30, weight: .semibold))
                Text(account.name + "  " + (account.server.host ?? "")).font(.system(size: 24)).foregroundStyle(Color.tvMuted)
            }
            Spacer()
            if current {
                Label("Current", systemImage: "checkmark").font(.system(size: 24, weight: .semibold)).foregroundStyle(Color.reelBlue)
            } else {
                Button("Open") { Task { await coordinator.select(account) } }
                    .accessibilityLabel("Open \(account.name) on \(account.serverName)").accessibilityIdentifier("open-" + account.id)
            }
            Button("Sign out") { removing = account }
                .accessibilityLabel("Sign out \(account.name) on \(account.serverName)").accessibilityIdentifier("remove-" + account.id)
        }
        .padding(.horizontal, 32).padding(.vertical, 24)
        .background(Color.reelSurface, in: RoundedRectangle(cornerRadius: TVLayout.artworkRadius, style: .continuous))
        .focusSection()
    }
}
