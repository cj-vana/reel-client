import SwiftUI

struct TVUnwatchedCount: View {
    let item: MediaItem
    var stale = false
    /// Shown only when the server reports a usable count; a card still says "Unwatched count unavailable" to VoiceOver.
    /// Plain text, so it never reads as a control beside the buttons it sits near.
    var body: some View {
        if item.isAggregate, let count = item.aggregateUnplayedCount {
            VStack(alignment: .leading, spacing: 4) {
            Text("\(count) unwatched")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.tvMuted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("unwatchedCount-" + item.id)
                .accessibilityLabel("\(count) unwatched")
                .accessibilityValue(stale ? "May be out of date. Refresh to check." : "Server supplied count")
            if stale { Text("Count may be out of date").font(.system(size: 20)).foregroundStyle(Color.tvMuted) }
            }
        }
    }
}

struct TVWatchedFeedback: View {
    let store: TVWatchedStore
    @Environment(Session.self) private var session
    @State private var showingDetails = false
    private var outcomeText: String {
        if store.busy { return "Updating watched status…" }
        if store.entries.contains(where: { if case .failed = $0.outcome { true } else { false } }) { return "Some titles couldn’t be updated." }
        if store.entries.contains(where: { if case .unsupported = $0.outcome { true } else { false } }) { return "Some titles don’t support this change." }
        if store.uncertain { return "Some changes still need confirmation." }
        if !store.reviewPlans.isEmpty { return "Review the selected titles before trying again." }
        if store.entries.contains(where: { $0.outcome == .notStarted }) { return "Some titles weren’t updated." }
        if store.entries.allSatisfy({ $0.outcome == .confirmed }) { return "Watched status confirmed." }
        return store.entries.count == 1 ? "Jellyfin accepted the change." : "Jellyfin accepted the changes."
    }
    var body: some View {
        if !store.entries.isEmpty {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 25) {
                    Text(outcomeText).font(.system(size: 23, weight: .medium)).accessibilityIdentifier("watchedOutcome")
                    Spacer()
                    Button(showingDetails ? "Hide details" : "Details") { showingDetails.toggle() }
                        .accessibilityIdentifier("watchedResultDetails")
                        .accessibilityValue(showingDetails ? "Expanded" : "Collapsed")
                }.focusSection()
                if showingDetails {
                    Text(store.summary).font(.system(size: 20)).foregroundStyle(Color.tvMuted).accessibilityIdentifier("watchedSummary")
                }
                ForEach(store.entries) { entry in
                    switch entry.outcome {
                    case .failed(let reason), .uncertain(let reason), .review(let reason), .unsupported(let reason):
                        Text(entry.plan.name + ": " + reason).font(.system(size: 21)).foregroundStyle(.orange)
                            .accessibilityIdentifier("watchedResult-" + entry.id)
                    default: EmptyView()
                    }
                }
                if let message = store.message { Text(message).font(.system(size: 20)).foregroundStyle(Color.tvMuted) }
                HStack(spacing: 25) {
                    if store.busy {
                        ProgressView()
                        Button("Stop remaining work") { store.cancelRemaining() }.accessibilityIdentifier("cancelWatchedRemaining")
                    } else {
                        if !store.retryable.isEmpty {
                            Button("Retry failed and remaining changes") { store.retry(session: session) }
                                .disabled(!store.canStart || TVWatchedStore.refusal(session) != nil).accessibilityIdentifier("retryWatchedChanges")
                        }
                        if !store.reviewPlans.isEmpty {
                            Button("Review unconfirmed scope") { store.reviewChanges(session: session) }
                                .disabled(!store.canStart || TVWatchedStore.refusal(session) != nil).accessibilityIdentifier("reviewWatchedScope")
                        }
                        if store.uncertain {
                            Button("Check unconfirmed status") { store.checkStatus(session: session) }.disabled(!store.canStart).accessibilityIdentifier("checkWatchedStatus")
                        }
                        Button("Dismiss result") { store.dismissResult() }.accessibilityIdentifier("dismissWatchedResult")
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).focusSection()
            }.padding(25).frame(maxWidth: .infinity, alignment: .leading).background(Color.reelSurface)
                .accessibilityElement(children: .contain)
                .accessibilityIdentifier("watchedResults")
        } else if let message = store.message {
            Text(message).foregroundStyle(.orange).accessibilityIdentifier("watchedActionError")
        }
    }
}

private struct TVWatchedPresentation: ViewModifier {
    let store: TVWatchedStore
    @Environment(Session.self) private var session
    @Environment(\.scenePhase) private var phase
    func body(content: Content) -> some View {
        // The content keeps the app's off-white tint; the dialog takes the system one, so its focused (white)
        // action keeps a dark label.
        content.tint(Color.reelText).confirmationDialog(store.confirmation?.title ?? "Change watched status?", isPresented: Binding(get: { store.confirmation != nil }, set: { if !$0 { store.confirmation = nil } }), titleVisibility: .visible) {
            if let pending = store.confirmation {
                Button(pending.action, role: .destructive) { store.confirm(session: session) }
                    .accessibilityIdentifier("confirmWatchedChanges")
                Button("Cancel", role: .cancel) { store.confirmation = nil }.accessibilityIdentifier("cancelWatchedChanges")
            }
        } message: { if let pending = store.confirmation { Text(pending.message) } }
        .tint(nil)
        .onChange(of: session.privateViewing) { _, _ in store.policyChanged() }
        .onChange(of: session.revision) { _, _ in store.invalidate() }
        .onChange(of: phase) { _, value in if value == .background { store.policyChanged() } }
        .onDisappear { store.invalidate() }
    }
}
extension View {
    func watchedPresentation(_ store: TVWatchedStore) -> some View { modifier(TVWatchedPresentation(store: store)) }
}

/// The watched menu and its feedback. `leading` puts other actions on the same row as the menu,
/// so a details screen can show one action row while this view keeps its own operation state.
struct TVWatchedControls<Leading: View>: View {
    let item: MediaItem
    let scopeKey: String
    var identifier = "watchStatus"
    var dataReady = true
    /// The visible label: the state, "Watched", unless another watched control shares the screen.
    var title = "Watched"
    @ViewBuilder var leading: () -> Leading
    @Environment(Session.self) private var session
    @Environment(TVCoordinator.self) private var coordinator
    @State private var store = TVWatchedStore()
    private var watched: Bool { item.isAggregate ? item.aggregateUnplayedCount == 0 : item.itemWatched == true }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 24) {
                leading()
                control.disabled(!store.canStart || !dataReady || !TVWatchedStore.eligible(item) || TVWatchedStore.refusal(session) != nil)
                .accessibilityIdentifier(identifier).accessibilityLabel("Watched status for " + item.Name)
                .accessibilityValue(item.isAggregate ? WatchedReadback(item: item).summary : item.itemWatched.map { $0 ? "Watched" : "Unwatched" } ?? "Unknown")
            }.focusSection()
            if store.anotherOperation { Text("Another watched operation is in progress.").font(.system(size: 23)).foregroundStyle(Color.tvMuted) }
            if !TVWatchedStore.eligible(item) {
                Text("Watched changes are unavailable for this item type. Reload its metadata before trying again.").font(.system(size: 23)).foregroundStyle(Color.tvMuted).accessibilityIdentifier(identifier + "TypeRefusal")
            }
            if let reason = TVWatchedStore.refusal(session) {
                Text(reason).font(.system(size: 23)).foregroundStyle(Color.tvMuted).accessibilityIdentifier(identifier + "Refusal")
            }
            TVWatchedFeedback(store: store)
        }.focusSection().watchedPresentation(store)
            .onAppear { store.configure(session: session, key: scopeKey, items: [item], lane: coordinator.watchedLane) }
            .onChange(of: scopeKey) { _, _ in store.configure(session: session, key: scopeKey, items: [item], lane: coordinator.watchedLane) }
            .onChange(of: item) { _, _ in store.configure(session: session, key: scopeKey, items: [item], lane: coordinator.watchedLane) }
    }
    /// A series or season offers scoped actions in a menu. A movie or episode has one state, so the control
    /// toggles it; the confirmation still follows either way. VoiceOver hears "Watched status for" and the
    /// item's name.
    @ViewBuilder private var control: some View {
        let label = Label(title, systemImage: watched ? "checkmark.circle.fill" : "checkmark.circle")
        if item.isAggregate {
            Menu {
                Button(TVWatchedStore.action(type: item.Type, played: true)) { choose(true) }.accessibilityIdentifier(identifier + "MarkWatched")
                Button(TVWatchedStore.action(type: item.Type, played: false)) { choose(false) }.accessibilityIdentifier(identifier + "MarkUnwatched")
            } label: { label }
        } else {
            Button { choose(!watched) } label: { label }
                .accessibilityAddTraits(watched ? .isSelected : [])
        }
    }

    private func choose(_ played: Bool) {
        store.request([item], played: played, session: session, key: scopeKey)
    }
}

extension TVWatchedControls where Leading == EmptyView {
    init(item: MediaItem, scopeKey: String, identifier: String = "watchStatus", dataReady: Bool = true, title: String = "Watched") {
        self.init(item: item, scopeKey: scopeKey, identifier: identifier, dataReady: dataReady, title: title) { EmptyView() }
    }
}

struct TVSelectionExit: ViewModifier {
    let active: Bool
    let action: () -> Void
    func body(content: Content) -> some View {
        content.onExitCommand(perform: active ? action : nil)
    }
}
