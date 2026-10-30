import XCTest
@testable import ReelTV

@MainActor final class TVSharedSessionBrowseCleanupTests: XCTestCase {
    @MainActor private final class VaultStore: AccountVaultStorage {
        var value: AccountVault
        var failRead = false
        var failSave = false
        var successfulSaves = 0
        var onSaved: (() -> Void)?
        var onRead: (() -> Void)?
        init(_ value: AccountVault) { self.value = value }
        func read() throws -> AccountVault {
            onRead?()
            if failRead { throw ReelError.storage }
            return value
        }
        func save(_ vault: AccountVault) throws {
            if failSave { throw ReelError.storage }
            value = vault; successfulSaves += 1; onSaved?()
        }
        func clear() throws { value = AccountVault() }
    }

    @MainActor private final class BrowseStorage: BrowsePreferencesStorage {
        var values: [BrowseAccountScope: Data] = [:]
        var failing: Set<BrowseAccountScope> = []
        var attempts: [BrowseAccountScope] = []
        func read(account: BrowseAccountScope) throws -> Data? { values[account] }
        func write(_ data: Data, account: BrowseAccountScope) throws { values[account] = data }
        func remove(account: BrowseAccountScope) throws {
            attempts.append(account)
            if failing.contains(account) { throw BrowsePreferencesError.writeFailed }
            values[account] = nil
        }
    }

    @MainActor private final class RefusingBrowseFileStorage: BrowsePreferencesStorage {
        let files: FileBrowsePreferencesStorage
        init(directory: URL) { files = FileBrowsePreferencesStorage(directory: directory) }
        func read(account: BrowseAccountScope) throws -> Data? { try files.read(account: account) }
        func write(_ data: Data, account: BrowseAccountScope) throws { try files.write(data, account: account) }
        func remove(account: BrowseAccountScope) throws { throw BrowsePreferencesError.writeFailed }
    }

    @MainActor private final class Services {
        var authenticationResult: Account?
        var holdAuthentication = false
        var authenticationPending: CheckedContinuation<Account, any Error>?
        var onAuthenticationReturned: (() -> Void)?
        var failCredentials = false
        var failRevoke = false
        var useProductionCredentialRules = false
        var onCredentialCleanup: (() -> Void)?
        var clearedSeerrIDs: [String] = []
        var clearedGatewayServers: [URL] = []
        var events: [String] = []
        var value: SessionAccountServices {
            SessionAccountServices(authenticate: { _, _, _, _ in
                self.events.append("authenticate")
                let result: Account
                if self.holdAuthentication { result = try await withCheckedThrowingContinuation { self.authenticationPending = $0 } }
                else {
                    guard let value = self.authenticationResult else { throw ReelError.invalidResponse }
                    result = value
                }
                self.onAuthenticationReturned?()
                return result
            }, revoke: { _, _ in
                self.events.append("revoke")
                if self.failRevoke { throw ReelError.storage }
            }, removeCredentials: { account, remaining in
                self.events.append("credentials")
                if self.failCredentials { throw ReelError.storage }
                if self.useProductionCredentialRules {
                    try SessionAccountServices.removeSavedCredentials(account, remaining: remaining,
                        removeSeerr: { self.clearedSeerrIDs.append($0) }, removeGateway: { self.clearedGatewayServers.append($0) })
                }
                self.onCredentialCleanup?()
            })
        }
    }

    @MainActor private struct Fixture {
        let session: Session
        let vault: VaultStore
        let services: Services
        let defaults: UserDefaults
        let suite: String
        func dispose() { defaults.removePersistentDomain(forName: suite) }
    }

    private func account(_ user: String, server: String = "https://synthetic.invalid/jellyfin") -> Account {
        Account(server: URL(string: server)!, token: "synthetic-token-" + user, userID: user, name: user, serverName: "Synthetic")
    }
    private func fixture(_ accounts: [Account], active: Account?) throws -> Fixture {
        let suite = "Reel.SessionBrowseCleanupTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let vault = VaultStore(AccountVault(accounts: accounts, activeID: active?.id)), services = Services()
        return Fixture(session: Session(storage: vault, defaults: defaults, services: services.value), vault: vault,
                       services: services, defaults: defaults, suite: suite)
    }
    private func scope(_ account: Account) throws -> BrowseAccountScope { try BrowseAccountScope(server: account.server, userID: account.userID) }
    private func install(_ cleanup: RemovedBrowsePreferencesCleanup, on session: Session) {
        cleanup.install(on: session)
    }
    private func waitForAuthentication(_ services: Services) async throws {
        for _ in 0..<100 {
            if services.authenticationPending != nil { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The synthetic authentication did not start.")
        throw ReelError.invalidResponse
    }
    private func resumeAuthentication(_ services: Services, result: Account) throws {
        let pending = try XCTUnwrap(services.authenticationPending)
        services.authenticationPending = nil; pending.resume(returning: result)
    }

    func testActiveRemovalHookSeesCommittedVaultAndCapturedRemovedAccount() async throws {
        let first = account("first"), second = account("second"), f = try fixture([first, second], active: first)
        defer { f.dispose() }
        var events: [String] = [], removed: [Account] = [], committed: AccountVault?
        f.vault.onSaved = { events.append("saved") }
        f.session.afterRemove = { target in
            events.append("after"); removed.append(target); committed = f.vault.value
            XCTAssertEqual(f.session.account, second)
            XCTAssertEqual(f.services.events, ["credentials"])
        }
        try await f.session.remove(first) { events.append("local") }
        XCTAssertEqual(events, ["saved", "local", "after"])
        XCTAssertEqual(removed, [first]); XCTAssertEqual(committed, AccountVault(accounts: [second], activeID: second.id))
        XCTAssertEqual(f.services.events, ["credentials", "revoke"])
    }

    func testInactiveRemovalTargetsOnlyRemovedAccountAndKeepsActiveRevision() async throws {
        let first = account("first"), second = account("second"), f = try fixture([first, second], active: second)
        defer { f.dispose() }
        let revision = f.session.revision
        var targets: [Account] = []
        f.session.afterRemove = { targets.append($0) }
        try await f.session.remove(first)
        XCTAssertEqual(targets, [first]); XCTAssertEqual(f.session.account, second)
        XCTAssertEqual(f.session.revision, revision); XCTAssertEqual(f.vault.value.accounts, [second])
    }

    func testFailedVaultSaveCannotInvokeHookOrDeleteBrowseChoices() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let storage = BrowseStorage(), preferences = BrowsePreferencesStore(storage: storage)
        let identity = try scope(first), original = f.vault.value
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let bytes = storage.values
        let cleanup = RemovedBrowsePreferencesCleanup(store: preferences); install(cleanup, on: f.session)
        f.vault.failSave = true
        do { try await f.session.remove(first); XCTFail("Failed vault commit was accepted") } catch { }
        XCTAssertEqual(storage.values, bytes); XCTAssertTrue(storage.attempts.isEmpty); XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertEqual(f.vault.value, original); XCTAssertEqual(f.session.account, first)
    }

    func testUnreadableVaultAndMissingAccountNeverInvokeHook() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        var callbacks = 0
        f.session.afterRemove = { _ in callbacks += 1 }
        try await f.session.remove(account("missing"))
        f.vault.failRead = true
        do { try await f.session.remove(first); XCTFail("Unreadable vault allowed removal") } catch { }
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(f.vault.successfulSaves, 0); XCTAssertEqual(f.vault.value.accounts, [first])
    }

    func testCancelledSuspendedRemovalCannotInvokeHook() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        var continuation: CheckedContinuation<Void, Never>?, callbacks = 0
        f.session.beforeRemove = { _ in await withCheckedContinuation { continuation = $0 } }
        f.session.afterRemove = { _ in callbacks += 1 }
        let task = Task { try await f.session.remove(first) }
        defer { task.cancel(); continuation?.resume(); f.session.beforeRemove = nil }
        for _ in 0..<100 {
            if continuation != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let started = try XCTUnwrap(continuation); continuation = nil
        task.cancel(); started.resume()
        do { try await task.value; XCTFail("Cancelled removal committed") } catch is CancellationError { }
        XCTAssertEqual(callbacks, 0); XCTAssertEqual(f.vault.successfulSaves, 0); XCTAssertEqual(f.vault.value.accounts, [first])
    }

    func testStaleSelectionChangedCredentialsAndLateReadFailureCannotInvokeHook() async throws {
        for mode in 0..<3 {
            let first = account("first"), second = account("second"), f = try fixture([first, second], active: first)
            defer { f.dispose() }
            var callbacks = 0
            f.session.afterRemove = { _ in callbacks += 1 }
            f.session.beforeRemove = { _ in
                if mode == 0 { try? await f.session.select(second) }
                else if mode == 1 {
                    let changed = Account(server: first.server, token: "synthetic-refreshed", userID: first.userID,
                                          name: first.name, serverName: first.serverName)
                    f.vault.value.accounts = [changed, second]
                } else { f.vault.failRead = true }
            }
            do { try await f.session.remove(first); XCTFail("Stale removal committed") } catch { }
            XCTAssertEqual(callbacks, 0); XCTAssertEqual(f.vault.value.accounts.count, 2)
        }
    }

    func testPostCommitCredentialAndRevocationFailuresDoNotSuppressHookOrRestoreVault() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        f.services.failCredentials = true; f.services.failRevoke = true
        var targets: [Account] = []
        f.session.afterRemove = { targets.append($0) }
        try await f.session.remove(first)
        XCTAssertEqual(targets, [first]); XCTAssertTrue(f.vault.value.accounts.isEmpty); XCTAssertNil(f.session.account)
        XCTAssertNotNil(f.session.notice); XCTAssertEqual(f.services.events, ["credentials", "revoke"])
    }

    func testFailedBrowseCleanupRetainsOnlyScopedRetryAndNeverRollsBackRemoval() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let storage = BrowseStorage(), identity = try scope(first)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let bytes = storage.values; storage.failing.insert(identity); install(cleanup, on: f.session)
        try await f.session.remove(first)
        XCTAssertNil(f.session.account); XCTAssertTrue(f.vault.value.accounts.isEmpty)
        XCTAssertEqual(cleanup.pending, [identity]); XCTAssertNotNil(cleanup.message); XCTAssertEqual(storage.values, bytes)
    }

    func testRetryRefusesDeletionUntilVaultCanBeRead() async throws {
        let first = account("first"), f = try fixture([], active: nil)
        defer { f.dispose() }
        let storage = BrowseStorage(), identity = try scope(first)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        storage.failing.insert(identity); XCTAssertFalse(cleanup.didCommitRemoval(identity, using: f.session))
        storage.failing.remove(identity); f.vault.failRead = true
        let attempts = storage.attempts
        cleanup.retry(using: f.session)
        XCTAssertEqual(storage.attempts, attempts); XCTAssertEqual(cleanup.pending, [identity])
        XCTAssertNotNil(cleanup.message)
    }

    func testRetryAfterReaddPreservesNewerPreferencesAndDropsStaleIntent() async throws {
        let first = account("first"), f = try fixture([], active: nil)
        defer { f.dispose() }
        let storage = BrowseStorage(), identity = try scope(first)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        storage.failing.insert(identity); XCTAssertFalse(cleanup.didCommitRemoval(identity, using: f.session)); storage.failing.remove(identity)
        try await f.session.accept(first)
        var newer = BrowseChoices(); newer.genreID = "new-sign-in-genre"
        XCTAssertTrue(preferences.save(newer, for: BrowseScope(), account: identity))
        let bytes = storage.values, attempts = storage.attempts
        cleanup.retry(using: f.session)
        XCTAssertEqual(storage.values, bytes); XCTAssertEqual(storage.attempts, attempts); XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertEqual(f.session.account, first); XCTAssertEqual(preferences.choices(for: BrowseScope(), account: identity), newer)
    }

    func testRetryFencesAgainstExternallyRestoredNormalizedAccountBeforeDeletion() async throws {
        let first = account("first"), restored = account("first", server: "https://SYNTHETIC.invalid:443/jellyfin/"), f = try fixture([], active: nil)
        defer { f.dispose() }
        let storage = BrowseStorage(), identity = try scope(first)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        storage.failing.insert(identity); XCTAssertFalse(cleanup.didCommitRemoval(identity, using: f.session)); storage.failing.remove(identity)
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let bytes = storage.values, attempts = storage.attempts
        // The Session snapshot is still empty. Retry must re-read the durable vault.
        f.vault.value = AccountVault(accounts: [restored], activeID: restored.id)
        cleanup.retry(using: f.session)
        XCTAssertEqual(storage.values, bytes); XCTAssertEqual(storage.attempts, attempts); XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertEqual(f.session.account, restored)
    }

    func testRetryStillRemovedScopeClearsOnlyItsBytesAndKeepsSavedSibling() async throws {
        let first = account("first"), sibling = account("sibling"), f = try fixture([sibling], active: sibling)
        defer { f.dispose() }
        let storage = BrowseStorage(), removed = try scope(first), saved = try scope(sibling)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: removed))
        var siblingChoices = BrowseChoices(); siblingChoices.viewStyle = .list
        XCTAssertTrue(preferences.save(siblingChoices, for: BrowseScope(), account: saved))
        let siblingBytes = storage.values[saved]
        storage.failing.insert(removed); XCTAssertFalse(cleanup.didCommitRemoval(removed, using: f.session)); storage.failing.remove(removed)
        cleanup.retry(using: f.session)
        XCTAssertNil(storage.values[removed]); XCTAssertEqual(storage.values[saved], siblingBytes); XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertEqual(f.session.account, sibling)
    }

    func testMultipleCleanupFailuresRetryIndependentlyAndRetainOnlyStillFailedScopes() throws {
        let first = try scope(account("first")), second = try scope(account("second")), f = try fixture([], active: nil)
        defer { f.dispose() }
        let storage = BrowseStorage(), cleanup = RemovedBrowsePreferencesCleanup(store: BrowsePreferencesStore(storage: storage))
        storage.failing = [first, second]
        XCTAssertFalse(cleanup.didCommitRemoval(first, using: f.session)); XCTAssertFalse(cleanup.didCommitRemoval(second, using: f.session))
        XCTAssertFalse(cleanup.didCommitRemoval(first, using: f.session)); XCTAssertEqual(cleanup.pending, [first, second])
        storage.failing.remove(first); cleanup.retry(using: f.session)
        XCTAssertEqual(cleanup.pending, [second]); XCTAssertNotNil(cleanup.message)
        storage.failing.remove(second); cleanup.retry(using: f.session)
        XCTAssertTrue(cleanup.pending.isEmpty)
    }

    func testInstalledConsumerPreservesCombinedCredentialBrowseAndRevocationWarningsWithoutRollback() async throws {
        for failRevoke in [false, true] {
            let first = account("first"), f = try fixture([first], active: first)
            defer { f.dispose() }
            let storage = BrowseStorage(), identity = try scope(first)
            let cleanup = RemovedBrowsePreferencesCleanup(store: BrowsePreferencesStore(storage: storage))
            storage.failing.insert(identity); f.services.failCredentials = true; f.services.failRevoke = failRevoke
            cleanup.install(on: f.session)
            try await f.session.remove(first)
            let message = try XCTUnwrap(f.session.notice), browseMessage = try XCTUnwrap(cleanup.message)
            XCTAssertTrue(message.contains("additional saved credentials"))
            XCTAssertTrue(message.contains(browseMessage))
            XCTAssertEqual(message.contains("server was unavailable to revoke"), failRevoke)
            XCTAssertEqual(cleanup.pending, [identity]); XCTAssertNil(f.session.account); XCTAssertTrue(f.vault.value.accounts.isEmpty)
            // Replaying the same consumer notification cannot accumulate duplicate paragraphs.
            f.session.afterRemove?(first)
            XCTAssertEqual(f.session.notice, message)
            XCTAssertEqual(f.session.notice?.components(separatedBy: browseMessage).count, 2)
        }
    }

    func testInvalidScopeConsumerPreservesExistingPostCommitWarning() async throws {
        let invalid = account(String(repeating: "u", count: 513)), f = try fixture([invalid], active: invalid)
        defer { f.dispose() }
        let storage = BrowseStorage(), cleanup = RemovedBrowsePreferencesCleanup(store: BrowsePreferencesStore(storage: storage))
        f.services.failCredentials = true; cleanup.install(on: f.session)
        try await f.session.remove(invalid)
        let message = try XCTUnwrap(f.session.notice)
        XCTAssertTrue(message.contains("additional saved credentials")); XCTAssertTrue(message.contains("local browse settings remain"))
        XCTAssertTrue(message.contains("identity couldn’t be read")); XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertTrue(storage.attempts.isEmpty); XCTAssertNil(f.session.account); XCTAssertTrue(f.vault.value.accounts.isEmpty)
    }

    func testFreshSessionAndFileStoreKeepCommittedRemovalAndPreservedChoicesWithoutAutoCleanup() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Reel.BrowseCleanup." + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let identity = try scope(first), storage = RefusingBrowseFileStorage(directory: directory)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        var choices = BrowseChoices(); choices.viewStyle = .list; choices.genreID = "synthetic-retained-genre"
        XCTAssertTrue(preferences.save(choices, for: BrowseScope(), account: identity))
        let file = try storage.files.file(account: identity), original = try Data(contentsOf: file)
        cleanup.install(on: f.session); try await f.session.remove(first)
        XCTAssertEqual(cleanup.pending, [identity]); XCTAssertNil(f.session.account)
        let committedVaultBytes = try JSONEncoder().encode(f.vault.value)
        let coldVault = VaultStore(try AccountVault.decode(committedVaultBytes))
        let coldSession = Session(storage: coldVault, defaults: f.defaults, services: f.services.value)
        let coldPreferences = BrowsePreferencesStore(storage: FileBrowsePreferencesStorage(directory: directory))
        let coldCleanup = RemovedBrowsePreferencesCleanup(store: coldPreferences)
        coldCleanup.install(on: coldSession)
        XCTAssertNil(coldSession.account); XCTAssertTrue(coldSession.accounts.isEmpty); XCTAssertTrue(coldCleanup.pending.isEmpty)
        XCTAssertEqual(try Data(contentsOf: file), original)
        XCTAssertEqual(coldPreferences.choices(for: BrowseScope(), account: identity), choices)
        XCTAssertEqual(try Data(contentsOf: file), original, "A fresh store read cannot automatically delete or repair retained choices.")
        // This is a new-instance/real-file regression; actual app termination/relaunch is a separate UI check.
    }

    func testInitialAliasRemovalPreservesSharedBrowseGatewayAndTokenUntilFinalOwner() async throws {
        let first = account("first"), alias = account("first", server: "https://SYNTHETIC.invalid:443/jellyfin/")
        XCTAssertNotEqual(first.id, alias.id)
        let f = try fixture([first, alias], active: first)
        defer { f.dispose() }
        f.services.useProductionCredentialRules = true
        let identity = try scope(first); XCTAssertEqual(identity, try scope(alias))
        let storage = BrowseStorage(), preferences = BrowsePreferencesStore(storage: storage)
        var choices = BrowseChoices(); choices.viewStyle = .list; choices.genreID = "synthetic-shared"
        XCTAssertTrue(preferences.save(choices, for: BrowseScope(), account: identity))
        let bytes = storage.values
        let cleanup = RemovedBrowsePreferencesCleanup(store: preferences); cleanup.install(on: f.session)
        try await f.session.remove(first)
        XCTAssertEqual(f.session.account, alias); XCTAssertEqual(f.vault.value.accounts, [alias])
        XCTAssertEqual(storage.values, bytes); XCTAssertTrue(storage.attempts.isEmpty); XCTAssertTrue(cleanup.pending.isEmpty)
        XCTAssertEqual(f.services.clearedSeerrIDs, [first.id]); XCTAssertTrue(f.services.clearedGatewayServers.isEmpty)
        XCTAssertFalse(f.services.events.contains("revoke"))
        try await f.session.remove(alias)
        XCTAssertTrue(f.vault.value.accounts.isEmpty); XCTAssertNil(f.session.account)
        XCTAssertNil(storage.values[identity]); XCTAssertEqual(storage.attempts, [identity])
        XCTAssertEqual(f.services.clearedSeerrIDs, [first.id, alias.id])
        XCTAssertEqual(f.services.clearedGatewayServers, [alias.server])
        XCTAssertEqual(f.services.events.filter { $0 == "revoke" }.count, 1)
    }

    func testInitialRemovalRereadsExternallyRestoredAliasBeforeDeletingSharedPreferences() async throws {
        let first = account("first"), alias = account("first", server: "https://synthetic.invalid/jellyfin/")
        let f = try fixture([first], active: first)
        defer { f.dispose() }
        let storage = BrowseStorage(), identity = try scope(first)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let bytes = storage.values
        f.services.onCredentialCleanup = { f.vault.value = AccountVault(accounts: [alias], activeID: alias.id) }
        cleanup.install(on: f.session); try await f.session.remove(first)
        XCTAssertEqual(f.session.account, alias); XCTAssertEqual(storage.values, bytes); XCTAssertTrue(storage.attempts.isEmpty)
        XCTAssertTrue(cleanup.pending.isEmpty); XCTAssertFalse(f.services.events.contains("revoke"))
    }

    func testInitialPostCommitReadFailureRetainsLocalBytesAndScopedRetryWithoutLogout() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let storage = BrowseStorage(), identity = try scope(first)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let bytes = storage.values
        f.services.onCredentialCleanup = { f.vault.failRead = true }
        cleanup.install(on: f.session); try await f.session.remove(first)
        XCTAssertTrue(f.vault.value.accounts.isEmpty); XCTAssertEqual(storage.values, bytes); XCTAssertTrue(storage.attempts.isEmpty)
        XCTAssertEqual(cleanup.pending, [identity]); XCTAssertFalse(f.services.events.contains("revoke"))
        XCTAssertTrue(f.session.notice?.contains("references could not be verified") == true)
        f.vault.failRead = false; cleanup.retry(using: f.session)
        XCTAssertNil(storage.values[identity]); XCTAssertTrue(cleanup.pending.isEmpty)
    }

    func testInitialSavedAliasDropsStalePendingScopeWithoutDeletingNewerChoices() throws {
        let first = account("first"), alias = account("first", server: "https://synthetic.invalid/jellyfin/")
        let f = try fixture([], active: nil)
        defer { f.dispose() }
        let storage = BrowseStorage(), identity = try scope(first)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        storage.failing.insert(identity); XCTAssertFalse(cleanup.didCommitRemoval(identity, using: f.session))
        storage.failing.remove(identity)
        var newer = BrowseChoices(); newer.genreID = "synthetic-newer"
        XCTAssertTrue(preferences.save(newer, for: BrowseScope(), account: identity))
        let bytes = storage.values, attempts = storage.attempts
        f.vault.value = AccountVault(accounts: [alias], activeID: alias.id)
        XCTAssertTrue(cleanup.didCommitRemoval(identity, using: f.session))
        XCTAssertEqual(storage.values, bytes); XCTAssertEqual(storage.attempts, attempts); XCTAssertTrue(cleanup.pending.isEmpty)
    }

    func testDifferentTokenAliasPreservesSharedSettingsButRevokesOnlyRemovedToken() async throws {
        let first = account("first")
        let alias = Account(server: URL(string: "https://synthetic.invalid/jellyfin/")!, token: "synthetic-distinct-token",
                            userID: first.userID, name: first.name, serverName: first.serverName)
        let f = try fixture([first, alias], active: first)
        defer { f.dispose() }
        f.services.useProductionCredentialRules = true
        let storage = BrowseStorage(), identity = try scope(first), preferences = BrowsePreferencesStore(storage: storage)
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let bytes = storage.values
        let cleanup = RemovedBrowsePreferencesCleanup(store: preferences); cleanup.install(on: f.session)
        try await f.session.remove(first)
        XCTAssertEqual(f.session.account, alias); XCTAssertEqual(storage.values, bytes); XCTAssertTrue(storage.attempts.isEmpty)
        XCTAssertTrue(f.services.clearedGatewayServers.isEmpty); XCTAssertEqual(f.services.events.filter { $0 == "revoke" }.count, 1)
    }

    func testSameTokenReferenceUsesTokenAuthorityRatherThanSavedUserLabel() async throws {
        let first = account("first")
        let sibling = Account(server: URL(string: "https://synthetic.invalid:443/jellyfin/")!, token: first.token,
                              userID: "another-saved-label", name: "Synthetic", serverName: "Synthetic")
        let f = try fixture([first, sibling], active: first)
        defer { f.dispose() }
        f.services.useProductionCredentialRules = true
        let storage = BrowseStorage(), removed = try scope(first), saved = try scope(sibling)
        let preferences = BrowsePreferencesStore(storage: storage), cleanup = RemovedBrowsePreferencesCleanup(store: preferences)
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: removed))
        XCTAssertTrue(preferences.save(BrowseChoices(), for: BrowseScope(), account: saved))
        let siblingBytes = storage.values[saved]
        cleanup.install(on: f.session); try await f.session.remove(first)
        XCTAssertNil(storage.values[removed]); XCTAssertEqual(storage.values[saved], siblingBytes)
        XCTAssertTrue(f.services.clearedGatewayServers.isEmpty); XCTAssertFalse(f.services.events.contains("revoke"))
    }

    func testGatewayReferenceCheckKeepsUsersButDistinguishesBasePaths() throws {
        let first = account("first"), sameServer = account("second", server: "https://SYNTHETIC.invalid:443/jellyfin/")
        let otherPath = account("second", server: "https://synthetic.invalid/other")
        for (remaining, expectedClears) in [([sameServer], 0), ([otherPath], 1), ([], 1)] {
            var seerr: [String] = [], gateway: [URL] = []
            try SessionAccountServices.removeSavedCredentials(first, remaining: AccountVault(accounts: remaining),
                removeSeerr: { seerr.append($0) }, removeGateway: { gateway.append($0) })
            XCTAssertEqual(seerr, [first.id]); XCTAssertEqual(gateway.count, expectedClears)
        }
    }

    func testUnknownGatewayReferencePreservesSharedHeadersAndReportsFailure() throws {
        let first = account("first"), malformed = account("second", server: "https://synthetic.invalid/jellyfin?unexpected=1")
        var gatewayCalls = 0, seerrCalls = 0
        XCTAssertThrowsError(try SessionAccountServices.removeSavedCredentials(first, remaining: AccountVault(accounts: [malformed]),
            removeSeerr: { _ in seerrCalls += 1 }, removeGateway: { _ in gatewayCalls += 1 }))
        XCTAssertEqual(seerrCalls, 1); XCTAssertEqual(gatewayCalls, 0)
    }

    func testTokenReferencePolicyDistinguishesBasePathAndRejectsUnverifiableSharedToken() throws {
        let first = account("first")
        let otherPath = Account(server: URL(string: "https://synthetic.invalid/other")!, token: first.token,
                                userID: first.userID, name: first.name, serverName: first.serverName)
        let malformed = Account(server: URL(string: "https://synthetic.invalid/jellyfin?unexpected=1")!, token: first.token,
                                userID: first.userID, name: first.name, serverName: first.serverName)
        XCTAssertFalse(try SessionAccountServices.hasRemainingTokenReference(first, remaining: AccountVault(accounts: [otherPath])))
        XCTAssertFalse(try SessionAccountServices.hasRemainingTokenReference(first, remaining: AccountVault()))
        XCTAssertThrowsError(try SessionAccountServices.hasRemainingTokenReference(first, remaining: AccountVault(accounts: [malformed])))
    }

    func testCancelledAuthenticationReturningReusedNormalizedAliasTokenPreservesSavedSession() async throws {
        let saved = account("first", server: "https://SYNTHETIC.invalid:443/jellyfin/"), result = account("first")
        let f = try fixture([saved], active: saved); defer { f.dispose() }
        f.services.holdAuthentication = true
        let task = Task { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services); task.cancel(); try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Cancelled authentication was saved") } catch is CancellationError { }
        XCTAssertEqual(f.vault.value.accounts, [saved]); XCTAssertEqual(f.session.account, saved)
        XCTAssertEqual(f.vault.successfulSaves, 0); XCTAssertFalse(f.services.events.contains("revoke"))
    }

    func testSupersededAuthenticationReturningReusedAliasTokenPreservesBothSavedRows() async throws {
        let saved = account("first", server: "https://synthetic.invalid/jellyfin/"), sibling = account("sibling"), result = account("first")
        let f = try fixture([saved, sibling], active: saved); defer { f.dispose() }
        f.services.holdAuthentication = true
        let task = Task { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services); try await f.session.select(sibling); try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Superseded authentication was saved") } catch is CancellationError { }
        XCTAssertEqual(f.vault.value.accounts, [saved, sibling]); XCTAssertEqual(f.session.account, sibling)
        XCTAssertEqual(f.vault.successfulSaves, 1); XCTAssertFalse(f.services.events.contains("revoke"))
    }

    func testFailedAuthenticationSaveKeepsExistingNormalizedAliasTokenAlive() async throws {
        let saved = account("first", server: "https://synthetic.invalid/jellyfin/"), result = account("first")
        let f = try fixture([saved], active: saved); defer { f.dispose() }
        f.services.authenticationResult = result; f.vault.failSave = true
        do { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic"); XCTFail("Failed save was accepted") }
        catch ReelError.storage { }
        XCTAssertEqual(f.vault.value.accounts, [saved]); XCTAssertEqual(f.session.account, saved)
        XCTAssertEqual(f.vault.successfulSaves, 0); XCTAssertFalse(f.services.events.contains("revoke"))
    }

    func testCancelledAuthenticationWithDifferentUnreferencedTokenStillCleansReturnedSession() async throws {
        let saved = account("first", server: "https://synthetic.invalid/jellyfin/")
        let result = Account(server: URL(string: "https://synthetic.invalid/jellyfin")!, token: "synthetic-new-token", userID: saved.userID, name: saved.name, serverName: saved.serverName)
        let f = try fixture([saved], active: saved); defer { f.dispose() }
        f.services.holdAuthentication = true
        let task = Task { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services); task.cancel(); try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Cancelled authentication was saved") } catch is CancellationError { }
        XCTAssertEqual(f.services.events.filter { $0 == "revoke" }.count, 1)
        XCTAssertEqual(f.vault.value.accounts, [saved]); XCTAssertEqual(f.vault.successfulSaves, 0)
    }

    func testFailedSaveWithUnreferencedReturnedTokenStillPerformsCleanup() async throws {
        let result = account("new"), f = try fixture([], active: nil); defer { f.dispose() }
        f.services.authenticationResult = result; f.vault.failSave = true
        do { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic"); XCTFail("Failed save was accepted") }
        catch ReelError.storage { }
        XCTAssertTrue(f.vault.value.accounts.isEmpty); XCTAssertEqual(f.vault.successfulSaves, 0)
        XCTAssertEqual(f.services.events.filter { $0 == "revoke" }.count, 1)
    }

    func testUnverifiableFailedAuthOwnershipSkipsLogoutAndCombinesPriorNotice() async throws {
        let result = account("first")
        let saved = Account(server: URL(string: "https://synthetic.invalid/jellyfin?unexpected=1")!, token: result.token,
                            userID: result.userID, name: result.name, serverName: result.serverName)
        let f = try fixture([saved], active: saved); defer { f.dispose() }
        f.session.notice = "Synthetic prior warning"; f.services.holdAuthentication = true
        let task = Task { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services); task.cancel(); try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Cancelled authentication was saved") } catch is CancellationError { }
        XCTAssertFalse(f.services.events.contains("revoke")); XCTAssertEqual(f.vault.value.accounts, [saved])
        XCTAssertTrue(f.session.notice?.contains("Synthetic prior warning") == true)
        XCTAssertTrue(f.session.notice?.contains("references could not be verified") == true)
    }

    func testFailedReturnedSessionCleanupPreservesOriginalCancellationAndReportsUnconfirmedCleanup() async throws {
        let result = account("new"), f = try fixture([], active: nil); defer { f.dispose() }
        f.services.holdAuthentication = true; f.services.failRevoke = true
        let task = Task { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services); task.cancel(); try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Cancelled authentication was saved") } catch is CancellationError { }
        XCTAssertTrue(f.vault.value.accounts.isEmpty); XCTAssertEqual(f.vault.successfulSaves, 0)
        XCTAssertEqual(f.services.events.filter { $0 == "revoke" }.count, 1)
        XCTAssertTrue(f.session.notice?.contains("Cleanup of its returned server session could not be confirmed.") == true)
    }

    func testFailedAuthFreshReadDenialRefusesUnsafeLogoutWithoutReplacingVault() async throws {
        let result = account("new"), f = try fixture([], active: nil); defer { f.dispose() }
        f.services.holdAuthentication = true
        let task = Task { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services); task.cancel(); f.vault.failRead = true; try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Cancelled authentication was saved") } catch is CancellationError { }
        XCTAssertTrue(f.vault.value.accounts.isEmpty); XCTAssertFalse(f.services.events.contains("revoke"))
        XCTAssertTrue(f.session.notice?.contains("references could not be verified") == true)
        XCTAssertFalse(f.session.savedAccountsAvailable)
    }

    func testProtectedAuthenticationSnapshotReferenceIsNotForgottenAfterConcurrentRowRemoval() async throws {
        let saved = account("first", server: "https://synthetic.invalid/jellyfin/"), result = account("first")
        let f = try fixture([saved], active: saved); defer { f.dispose() }
        f.services.holdAuthentication = true
        let task = Task { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services)
        f.vault.value = AccountVault() // A separate writer removed the saved row; never reinsert it.
        task.cancel(); try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Cancelled authentication was saved") } catch is CancellationError { }
        XCTAssertTrue(f.vault.value.accounts.isEmpty); XCTAssertTrue(f.session.accounts.isEmpty)
        XCTAssertFalse(f.services.events.contains("revoke")); XCTAssertEqual(f.vault.successfulSaves, 0)
    }

    func testQueuedSavedAliasBeforeCleanupJobStartsIsReadBeforeAnyRevocationDecision() async throws {
        let result = account("first"), alias = account("first", server: "https://SYNTHETIC.invalid:443/jellyfin/")
        let f = try fixture([], active: nil); defer { f.dispose() }
        var trace: [String] = [], returned = false
        var insertion: Task<Void, Never>?
        f.services.holdAuthentication = true
        f.services.onAuthenticationReturned = {
            returned = true; trace.append("authentication-returned")
            // Offer the exact interleaving with a higher-priority queued actor job.
            // The positive witness below is mandatory; scheduling failure cannot pass.
            insertion = Task(priority: .high) { @MainActor in
                f.vault.value = AccountVault(accounts: [alias], activeID: alias.id)
                trace.append("reference-inserted")
            }
        }
        f.vault.onRead = { if returned { trace.append("cleanup-read") } }
        let task = Task(priority: .low) { try await f.session.signIn(server: result.server.absoluteString, username: result.name, password: "synthetic") }
        defer { task.cancel(); insertion?.cancel(); f.services.authenticationPending?.resume(throwing: CancellationError()); f.services.authenticationPending = nil }
        try await waitForAuthentication(f.services); task.cancel(); try resumeAuthentication(f.services, result: result)
        do { try await task.value; XCTFail("Cancelled authentication was saved") } catch is CancellationError { }
        await insertion?.value
        let inserted = try XCTUnwrap(trace.firstIndex(of: "reference-inserted"))
        let read = try XCTUnwrap(trace.firstIndex(of: "cleanup-read"))
        XCTAssertLessThan(inserted, read, "The required queued-before-cleanup interleaving must actually occur: \(trace)")
        XCTAssertEqual(f.session.account, alias); XCTAssertEqual(f.vault.value.accounts, [alias])
        XCTAssertFalse(f.services.events.contains("revoke")); XCTAssertEqual(f.vault.successfulSaves, 0)
    }
}
