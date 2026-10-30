import SwiftUI

enum WatchedStatusStyle { case standard, tile, chip }

/// The watched control and its status messages. `content` places the control
/// (for example inside a row of actions); messages always follow below it.
struct WatchedStatusButton<Content: View>: View {
    let item: MediaItem
    var identifier = "watchStatus"
    var style = WatchedStatusStyle.standard
    @ViewBuilder var content: (WatchedStatusMenu) -> Content
    @Environment(Session.self) private var session
    @State private var confirmation: WatchedMutationPlan?
    @State private var retryPlan: WatchedMutationPlan?
    @State private var readback: WatchedReadback?
    @State private var readbackMessage: String?
    @State private var checkingServer = false
    @State private var readbackRequestID = UUID()
    @State private var operationID = UUID()
    @State private var requiresScopeConfirmation = false
    @State private var busy = false
    @State private var error: String?
    private var watched: Bool? {
        item.itemWatched
    }
    private var historyAllowed: Bool { session.api?.recordsHistory == true }
    private var canChange: Bool { historyAllowed && item.supportsWatchedMutation }
    private var currentScope: WatchedMutationScope { WatchedMutationScope(item: item) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content(menu)
            if !historyAllowed {
                Text(session.api?.isSimulatorPreview == true ? "This build can’t change watched status on this server." : "Turn off Private viewing to change watched status.")
                    .font(.caption).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
            }
            if !item.supportsWatchedMutation {
                Text("Jellyfin has not supplied supported type metadata. Watched status cannot be changed for this title.")
                    .font(.caption).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier + "Unavailable")
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier + "Error")
                if let plan = retryPlan {
                    Button(checkingServer ? "Checking current status…" : "Check server status") {
                        let admission = WatchedReadbackAdmission(plan: plan, operationID: operationID, scope: currentScope)
                        Task { @MainActor in await checkServerStatus(plan, admission: admission) }
                    }.disabled(busy || checkingServer).accessibilityIdentifier(identifier + "CheckStatus")
                    if let readback, !readback.matches(plan.played) {
                        Button("Request \(plan.played ? "watched" : "unwatched") again") { confirmation = plan }
                            .disabled(busy || checkingServer || !canChange).accessibilityIdentifier(identifier + "Retry")
                    }
                }
            }
            if let readbackMessage {
                Text(readbackMessage).font(.caption).foregroundStyle(Color.reelMuted).fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier(identifier + "Readback")
            }
        }
        .confirmationDialog(confirmation?.confirmationTitle ?? "Change watched status?", isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }), titleVisibility: .visible) {
            if let plan = confirmation {
                Button(plan.actionLabel, role: .destructive) { confirmation = nil; perform(plan) }
                    .accessibilityIdentifier(identifier + "Confirm")
                Button("Cancel", role: .cancel) { confirmation = nil }
                    .accessibilityIdentifier(identifier + "Cancel")
            }
        } message: {
            if let plan = confirmation {
                Text((retryPlan == nil ? "" : "The earlier request was not confirmed. This sends another explicit request for the captured desired status. ") + plan.confirmationMessage)
            }
        }
        .onChange(of: session.revision) { _, _ in
            clearPendingState()
        }
        .onChange(of: currentScope) { old, new in
            clearPendingState()
            if old.itemID == new.itemID {
                requiresScopeConfirmation = true
                readbackMessage = "Jellyfin changed this title’s type metadata. Review its current scope before making another change."
            }
        }
    }

    private var menu: WatchedStatusMenu {
        let fullyWatched = watched == true || item.aggregateUnplayedCount == 0
        let title: String
        switch style {
        case .standard: title = checkingServer ? "Checking server status…" : busy ? "Saving watched status…" : watched == true ? "Watched" : "Watched status"
        case .tile, .chip: title = checkingServer ? "Checking…" : busy ? "Saving…" : "Watched"
        }
        return WatchedStatusMenu(
            title: title, systemImage: fullyWatched ? "checkmark.circle.fill" : "checkmark.circle", highlighted: fullyWatched,
            style: style, aggregate: item.isAggregate, type: item.Type, identifier: identifier,
            accessibilityLabel: "Watched status for \(item.Name)",
            accessibilityValue: checkingServer ? "Checking" : busy ? "Saving" : watched.map { $0 ? "Watched" : "Unwatched" } ?? "Unknown",
            disabled: busy || checkingServer || !canChange,
            choose: { choose($0) })
    }

    private func choose(_ played: Bool) {
        guard !busy, !checkingServer, canChange, let account = session.account else { return }
        let plan = WatchedMutationPlan(item: item, played: played, account: account, revision: session.revision)
        guard plan.path != nil else { error = "This title has invalid target metadata. Reload the collection before changing its status."; return }
        if let retryPlan {
            guard retryPlan.matchesScope(item), retryPlan.isCurrent(account: session.account, revision: session.revision) else {
                clearPendingState(); requiresScopeConfirmation = true
                readbackMessage = "Review the title’s current metadata before choosing another watched change."
                return
            }
            guard let readback else { error = "Check the current server status before sending another watched request."; return }
            if readback.matches(played) { readbackMessage = readback.summary + " No additional change was sent."; return }
            confirmation = retryPlan.desiring(played); return
        }
        error = nil; readbackMessage = nil
        if plan.requiresConfirmation || requiresScopeConfirmation { confirmation = plan } else { perform(plan) }
    }

    private func perform(_ plan: WatchedMutationPlan) {
        guard !busy, !checkingServer, canChange, plan.matchesScope(item), plan.isCurrent(account: session.account, revision: session.revision),
              let api = session.api, let path = plan.path else { return }
        let operation = UUID(); operationID = operation
        let admission = WatchedReadbackAdmission(plan: plan, operationID: operation, scope: plan.scope)
        busy = true; error = nil; retryPlan = nil; readback = nil; readbackMessage = nil
        requiresScopeConfirmation = false
        Task { @MainActor in
            defer { if operationID == operation { busy = false } }
            guard operationID == operation, plan.matchesScope(item), plan.isCurrent(account: session.account, revision: session.revision), session.api?.recordsHistory == true else { return }
            do {
                try await api.post(path, query: ["userId": api.userID ?? ""], method: plan.method)
                _ = session.invalidateCatalogue(accountID: plan.accountID, revision: plan.accountRevision)
            } catch {
                // Even an old UI target can have reached the server. Account
                // fencing belongs to catalogue invalidation; UI fencing is local.
                _ = session.invalidateCatalogue(accountID: plan.accountID, revision: plan.accountRevision)
                guard operationID == operation, plan.matchesScope(item), plan.isCurrent(account: session.account, revision: session.revision) else { return }
                self.error = "The watched change was not confirmed. " + error.localizedDescription + " The server may have received it."
                retryPlan = plan
                // A failed transport can follow an accepted server write. Re-read
                // current data, while making no claim that the write succeeded.
                busy = false
                await checkServerStatus(plan, admission: admission)
            }
        }
    }

    private func checkServerStatus(_ plan: WatchedMutationPlan, admission: WatchedReadbackAdmission) async {
        guard admission.isCurrent(operationID: operationID, scope: currentScope, account: session.account, revision: session.revision),
              !busy, !checkingServer, plan.matchesScope(item), plan.isCurrent(account: session.account, revision: session.revision), let api = session.api else { return }
        let operation = admission.operationID, scope = admission.scope
        let generation = UUID(); readbackRequestID = generation; checkingServer = true
        defer { if operationID == operation, currentScope == scope, readbackRequestID == generation { checkingServer = false } }
        do {
            let value = try await api.item(plan.itemID)
            try Task.checkCancellation()
            guard operationID == operation, currentScope == scope, readbackRequestID == generation, plan.isCurrent(account: session.account, revision: session.revision) else { return }
            let refreshedPlan = try plan.refreshed(from: value)
            guard refreshedPlan.scope == scope else {
                confirmation = nil; retryPlan = nil; readback = nil; requiresScopeConfirmation = true
                readbackMessage = "Jellyfin returned changed type metadata. Reload this title and review its current scope before making another change. The earlier request remains uncertain."
                _ = session.invalidateCatalogue(accountID: plan.accountID, revision: plan.accountRevision)
                return
            }
            let observed = WatchedReadback(item: value); readback = observed
            retryPlan = refreshedPlan
            readbackMessage = observed.summary + " The earlier request’s result remains uncertain; this does not count updated descendants."
            _ = session.invalidateCatalogue(accountID: plan.accountID, revision: plan.accountRevision)
        } catch {
            guard operationID == operation, currentScope == scope, readbackRequestID == generation, plan.isCurrent(account: session.account, revision: session.revision) else { return }
            readback = nil
            readbackMessage = "Current server status could not be checked. No additional change was sent. " + error.localizedDescription
        }
    }

    private func clearPendingState() {
        confirmation = nil; retryPlan = nil; error = nil; readback = nil; readbackMessage = nil
        operationID = UUID(); readbackRequestID = UUID(); checkingServer = false; busy = false
        requiresScopeConfirmation = false
    }
}

extension WatchedStatusButton where Content == WatchedStatusMenu {
    init(item: MediaItem, identifier: String = "watchStatus", style: WatchedStatusStyle = .standard) {
        self.init(item: item, identifier: identifier, style: style) { $0 }
    }
}

struct WatchedStatusMenu: View {
    let title: String
    let systemImage: String
    let highlighted: Bool
    let style: WatchedStatusStyle
    let aggregate: Bool
    let type: String?
    let identifier: String
    let accessibilityLabel: String
    let accessibilityValue: String
    let disabled: Bool
    let choose: @MainActor (Bool) -> Void

    /// A movie or episode toggles in one tap. A series or season keeps a menu,
    /// because each choice applies to everything inside it.
    var body: some View {
        if aggregate {
            Menu {
                Button(WatchedMutationPlan.actionLabel(type: type, bulk: true, played: true)) { choose(true) }
                    .accessibilityIdentifier(identifier + "MarkWatched")
                Button(WatchedMutationPlan.actionLabel(type: type, bulk: true, played: false)) { choose(false) }
                    .accessibilityIdentifier(identifier + "MarkUnwatched")
            } label: { label }
                .font(.subheadline).disabled(disabled)
                .accessibilityIdentifier(identifier).accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue)
        } else {
            Button { choose(!highlighted) } label: { label }
                .buttonStyle(.plain).font(.subheadline).disabled(disabled)
                .accessibilityIdentifier(identifier).accessibilityLabel(accessibilityLabel)
                .accessibilityValue(accessibilityValue)
                .accessibilityHint(highlighted ? "Marks this title as unwatched." : "Marks this title as watched.")
        }
    }

    @ViewBuilder private var label: some View {
        switch style {
        case .standard:
            Label(title, systemImage: systemImage)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 44, alignment: .leading).contentShape(Rectangle())
        case .tile:
            ActionTile(title: title, systemImage: systemImage, highlighted: highlighted)
        case .chip:
            HStack(spacing: 7) {
                Image(systemName: systemImage).foregroundStyle(highlighted ? Color.reelBlue : Color.reelMuted)
                Text(title).foregroundStyle(Color.reelText)
            }
            .font(.subheadline.weight(.semibold)).padding(.horizontal, 14).frame(minHeight: 44)
            .background(Color.reelFill, in: Capsule()).contentShape(Capsule())
        }
    }
}

struct UnwatchedCountBadge: View {
    let item: MediaItem
    var body: some View {
        if let count = item.aggregateUnplayedCount {
            Text("\(count) unwatched")
                .font(.caption2.weight(.semibold)).foregroundStyle(Color.reelText)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color.reelBackground.opacity(0.9), in: Capsule())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("unwatchedCount-\(item.id)")
        }
    }
}
