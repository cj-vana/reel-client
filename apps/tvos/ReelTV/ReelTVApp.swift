import SwiftUI

@main struct ReelTVApp: App {
    @State private var coordinator = TVCoordinator.forApplication()
    var body: some Scene {
        WindowGroup {
            TVSessionGate()
            .safeAreaInset(edge: .bottom) { TVRemovedBrowseCleanupNotice() }
            .environment(coordinator)
            .environment(coordinator.session)
            .environment(coordinator.playback)
            .environment(coordinator.preferences)
            .preferredColorScheme(.dark)
            // Neutral controls: tvOS fills focused buttons with the tint, so the primary action reads white.
            // Confirmation dialogs draw their actions in the tint too, so each one resets it (`.tint(nil)` after
            // the dialog). Mint is applied only to progress and selection marks.
            .tint(Color.reelText)
            .background(Color.reelBackground)
            .alert("Reel", isPresented: Binding(get: { coordinator.error != nil || coordinator.session.notice != nil }, set: { if !$0 { coordinator.error = nil; coordinator.session.notice = nil } })) {
                Button("OK") { coordinator.error = nil; coordinator.session.notice = nil }
            } message: { Text(coordinator.error ?? coordinator.session.notice ?? "") }
        }
    }
}
