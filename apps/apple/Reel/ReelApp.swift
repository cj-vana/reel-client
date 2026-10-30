import SwiftUI

@main struct ReelApp: App {
    @UIApplicationDelegateAdaptor(DownloadAppDelegate.self) private var downloadDelegate
    @State private var session = Session()
    @State private var removedBrowseCleanup = RemovedBrowsePreferencesCleanup()
    @State private var downloads = Downloads()
    @State private var preferences = ServerPreferences()
    @State private var mediaHub = MediaHub()
    @State private var remoteSessions = RemoteSessions()
    @State private var syncPlay = SyncPlayClient()

    var body: some Scene {
        WindowGroup {
            Group {
                if !session.savedAccountsAvailable { SavedAccountsRecoveryView() }
                else if session.account != nil { MainView().id(session.revision) }
                else { ConnectView() }
            }
            .onAppear {
                removedBrowseCleanup.install(on: session)
            }
            .safeAreaInset(edge: .bottom) { RemovedBrowseCleanupNotice(cleanup: removedBrowseCleanup) }
            .environment(session)
            .environment(downloads)
            .environment(preferences)
            .environment(mediaHub)
            .environment(remoteSessions)
            .environment(syncPlay)
            .onChange(of: session.revision) { _, _ in
                mediaHub.clearAccount()
                remoteSessions.reset(api: session.api)
                syncPlay.detach()
                CastCoordinator.shared.endCasting()
            }
            .preferredColorScheme(.dark)
            .tint(Color.reelBlue)
            .foregroundStyle(Color.reelText)
            .alert("Reel", isPresented: Binding(get: { session.notice != nil }, set: { if !$0 { session.notice = nil } })) {
                Button("OK") { session.notice = nil }
            } message: { Text(session.notice ?? "") }
        }
    }
}

struct SavedAccountsRecoveryView: View {
    @Environment(Session.self) private var session
    @State private var retryFailed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                ReelMark()
                Image(systemName: "lock.shield").font(.system(size: 48)).foregroundStyle(Color.reelBlue).accessibilityHidden(true)
                Text("Saved connections unavailable").font(.largeTitle.bold())
                Text("Saved connections are temporarily unavailable. Unlock your device, then retry. Reel will read your saved connections before making any changes.")
                    .font(.body).foregroundStyle(Color.reelMuted)
                if retryFailed {
                    Text("Saved connections are still unavailable. Please try again after unlocking your device.")
                        .foregroundStyle(.orange).accessibilityIdentifier("savedAccountsRecoveryError")
                }
                Button {
                    do { try session.retrySavedAccounts(); retryFailed = false }
                    catch { retryFailed = true }
                } label: {
                    Text("Retry saved connections").frame(maxWidth: .infinity)
                }.buttonStyle(PrimaryButton()).accessibilityIdentifier("retrySavedAccounts")
            }
            .frame(maxWidth: 520, alignment: .leading).padding(28).frame(maxWidth: .infinity)
        }
        .background(Color.reelBackground).accessibilityIdentifier("savedAccountsRecovery")
    }
}
