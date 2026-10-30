import SwiftUI

struct TVSessionGate: View {
    @Environment(TVCoordinator.self) private var coordinator
    @State private var retryFailed = false

    var body: some View {
        Group {
            if !coordinator.session.savedAccountsAvailable {
                VStack(spacing: 30) {
                    TVMark()
                    Image(systemName: "lock.shield").font(.system(size: 58)).foregroundStyle(Color.reelBlue)
                    Text("Your saved connections are protected.").font(.system(size: 44, weight: .semibold))
                    Text("Reel couldn’t open your saved sign-ins. Retry to reconnect without changing your saved connections.")
                        .font(.system(size: 28)).foregroundStyle(Color.tvMuted).multilineTextAlignment(.center).frame(maxWidth: 1050)
                    if retryFailed {
                        Text("Still unavailable. Your saved connections haven’t been changed.")
                            .font(.system(size: 24)).foregroundStyle(Color.tvMuted).accessibilityIdentifier("savedConnectionsRetryError")
                    }
                    Button("Retry saved connections") {
                        do { try coordinator.session.retrySavedAccounts(); retryFailed = false }
                        catch { retryFailed = true }
                    }.buttonStyle(.borderedProminent).foregroundStyle(Color.reelBackground).accessibilityIdentifier("retrySavedConnections")
                }
                .padding(90).frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.reelBackground)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("savedConnectionsUnavailable")
            } else if coordinator.session.account == nil { TVConnectView() }
            else { TVRootView().id(coordinator.session.revision) }
        }
    }
}
