import Foundation
import Observation

/// Only noncredential identities survive a failed post-removal cleanup.
@MainActor @Observable final class RemovedBrowsePreferencesCleanup {
    private(set) var pending: [BrowseAccountScope] = []
    private(set) var message: String?
    @ObservationIgnored private let store: BrowsePreferencesStore

    init(store: BrowsePreferencesStore = .shared) { self.store = store }

    /// Install at the app root, whose lifetime includes the signed-out screen.
    func install(on session: Session) {
        session.afterRemove = { [weak self, weak session] removed in
            guard let self, let session else { return }
            do {
                let scope = try BrowseAccountScope(server: removed.server, userID: removed.userID)
                if !self.didCommitRemoval(scope, using: session), let message = self.message {
                    self.present(message, using: session)
                }
            } catch {
                self.present("The sign-in removal is complete. Its local browse settings remain because their account identity couldn’t be read for cleanup.", using: session)
            }
        }
    }

    private func present(_ message: String, using session: Session) {
        session.appendNotice(message)
    }

    func retryAndPresent(using session: Session) {
        retry(using: session)
        if let message { present(message, using: session) }
    }

    /// Called by Session.afterRemove, after the credential vault commit succeeds.
    @discardableResult func didCommitRemoval(_ scope: BrowseAccountScope, using session: Session) -> Bool {
        let saved: Set<BrowseAccountScope>
        do { saved = try savedScopes(using: session) }
        catch {
            if !pending.contains(scope) { pending.append(scope) }
            message = "The sign-in removal is complete. Its local browse settings remain because saved connections could not be verified. Unlock your device, then retry."
            return false
        }
        if saved.contains(scope) {
            // Raw saved URLs may be distinct aliases of this normalized identity.
            pending.removeAll { $0 == scope }
            if pending.isEmpty { message = nil }
            return true
        }
        if store.removeAccount(scope) {
            pending.removeAll { $0 == scope }
            if pending.isEmpty { message = nil }
            return true
        }
        if !pending.contains(scope) { pending.append(scope) }
        message = "The sign-in removal is complete. Its local browse settings remain because they couldn’t be cleared. Retry when storage is available."
        return false
    }

    private func savedScopes(using session: Session) throws -> Set<BrowseAccountScope> {
        try session.retrySavedAccounts()
        return try Set(session.accounts.map { try BrowseAccountScope(server: $0.server, userID: $0.userID) })
    }

    /// No suspension is allowed between the fresh vault check and local deletion.
    func retry(using session: Session) {
        guard !pending.isEmpty else { return }
        let savedScopes: Set<BrowseAccountScope>
        do {
            savedScopes = try self.savedScopes(using: session)
        } catch {
            message = "Saved connections must be readable before browse cleanup can retry. Unlock your device, then retry. No browse choices were cleared."
            return
        }
        var failed: [BrowseAccountScope] = []
        var restored = false
        for scope in pending {
            if savedScopes.contains(scope) {
                // A new sign-in now owns this identity. Never delete its newer choices.
                restored = true
            } else if !store.removeAccount(scope) {
                failed.append(scope)
            }
        }
        pending = failed
        if !failed.isEmpty {
            message = "The sign-ins remain removed. Some local browse settings still couldn’t be cleared. Retry when storage is available."
        } else if restored {
            message = "Reconnected accounts kept their current browse choices. Cleanup for the other removed accounts is complete."
        } else {
            message = "Saved browse choices for removed accounts were cleared."
        }
    }
}
