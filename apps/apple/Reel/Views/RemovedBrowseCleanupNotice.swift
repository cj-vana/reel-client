import SwiftUI

struct RemovedBrowseCleanupNotice: View {
    @Environment(Session.self) private var session
    let cleanup: RemovedBrowsePreferencesCleanup

    var body: some View {
        if !cleanup.pending.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(cleanup.message ?? "Saved browse choices for a removed connection still need cleanup.")
                    .font(.footnote).fixedSize(horizontal: false, vertical: true)
                Button("Retry clearing browse choices") {
                    cleanup.retryAndPresent(using: session)
                }
                .accessibilityIdentifier("retryRemovedBrowseChoices")
            }
            .frame(maxWidth: 640, alignment: .leading)
            .padding(16)
            .frame(maxWidth: .infinity)
            .background(Color.reelSurface)
            .accessibilityIdentifier("removedBrowseCleanupNotice")
        }
    }
}
