import SwiftUI

struct TVRemovedBrowseCleanupNotice: View {
    @Environment(TVCoordinator.self) private var coordinator
    @State private var showingResult = false

    var body: some View {
        let cleanup = coordinator.removedBrowseCleanup
        if !cleanup.pending.isEmpty || (showingResult && cleanup.message != nil) {
            HStack(alignment: .center, spacing: 35) {
                VStack(alignment: .leading, spacing: 12) {
                    if let message = cleanup.message {
                        Text(message).font(.system(size: 23)).foregroundStyle(Color.tvMuted)
                    }
                }.frame(maxWidth: 1200, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 20)
                if !cleanup.pending.isEmpty {
                    Button("Retry clearing browse choices") {
                        cleanup.retryAndPresent(using: coordinator.session)
                        showingResult = cleanup.pending.isEmpty
                    }.accessibilityIdentifier("retryRemovedBrowseChoices")
                } else {
                    Button("Done") { showingResult = false }
                        .accessibilityIdentifier("dismissRemovedBrowseCleanup")
                }
            }
            .padding(.horizontal, 85).padding(.vertical, 24)
            .frame(maxWidth: .infinity)
            .background(Color.reelSurface)
            .focusSection().accessibilityElement(children: .contain)
            .accessibilityIdentifier("removedBrowseCleanupNotice")
            .accessibilityValue("\(cleanup.pending.count) removed connections need browse-choice cleanup")
        }
    }
}
