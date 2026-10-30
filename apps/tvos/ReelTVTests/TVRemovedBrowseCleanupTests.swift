import Foundation
import XCTest
@testable import ReelTV

@MainActor final class TVRemovedBrowseCleanupTests: XCTestCase {
    @MainActor private final class Vault: AccountVaultStorage {
        var value: AccountVault
        var failRead = false
        var failSave = false
        init(_ value: AccountVault) { self.value = value }
        func read() throws -> AccountVault { if failRead { throw ReelError.storage }; return value }
        func save(_ value: AccountVault) throws { if failSave { throw ReelError.storage }; self.value = value }
        func clear() throws { value = AccountVault() }
    }
    @MainActor private final class BrowseStorage: BrowsePreferencesStorage {
        var data: [BrowseAccountScope: Data] = [:]
        var failures: Set<BrowseAccountScope> = []
        var attempts: [BrowseAccountScope] = []
        func read(account: BrowseAccountScope) throws -> Data? { data[account] }
        func write(_ bytes: Data, account: BrowseAccountScope) throws { data[account] = bytes }
        func remove(account: BrowseAccountScope) throws {
            attempts.append(account)
            if failures.contains(account) { throw BrowsePreferencesError.writeFailed }
            data[account] = nil
        }
    }
    @MainActor private final class Services {
        var failCredentials = false
        var failRevoke = false
        var value: SessionAccountServices {
            SessionAccountServices(authenticate: { _, _, _, _ in throw ReelError.invalidResponse }, revoke: { _, _ in if self.failRevoke { throw ReelError.storage } },
                                   removeCredentials: { _, _ in if self.failCredentials { throw ReelError.storage } })
        }
    }
    @MainActor private struct Fixture {
        let vault: Vault
        let files: BrowseStorage
        let preferences: BrowsePreferencesStore
        let services: Services
        let defaults: UserDefaults
        let suite: String
        let session: Session
        let coordinator: TVCoordinator
        func dispose() { defaults.removePersistentDomain(forName: suite) }
    }
    private func account(_ user: String, server: String = "https://synthetic.invalid/jellyfin") -> Account {
        Account(server: URL(string: server)!, token: "synthetic-private-token-" + user, userID: user,
                name: "Synthetic " + user, serverName: "Owned test")
    }
    private func scope(_ account: Account) throws -> BrowseAccountScope { try BrowseAccountScope(server: account.server, userID: account.userID) }
    private func fixture(_ accounts: [Account], active: Account?) throws -> Fixture {
        try TVFixture.requireQAHost()
        let suite = "Reel.TVRemovedBrowseCleanup." + UUID().uuidString, files = BrowseStorage(), services = Services()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let vault = Vault(AccountVault(accounts: accounts, activeID: active?.id))
        let session = Session(storage: vault, defaults: defaults, services: services.value), preferences = BrowsePreferencesStore(storage: files)
        return Fixture(vault: vault, files: files, preferences: preferences, services: services, defaults: defaults, suite: suite,
                       session: session, coordinator: TVCoordinator(session: session, browsePreferences: preferences))
    }

    func testTVConsumerRemovesOnlyCapturedCommittedScopeAndKeepsActiveSibling() async throws {
        let first = account("first"), sibling = account("sibling"), f = try fixture([first, sibling], active: first)
        defer { f.dispose() }
        let removed = try scope(first), saved = try scope(sibling)
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: removed))
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(category: "Episodes"), account: saved))
        let siblingBytes = f.files.data[saved]
        await f.coordinator.remove(first)
        XCTAssertEqual(f.vault.value.accounts, [sibling]); XCTAssertEqual(f.session.account, sibling)
        XCTAssertEqual(f.files.attempts, [removed]); XCTAssertNil(f.files.data[removed]); XCTAssertEqual(f.files.data[saved], siblingBytes)
        XCTAssertTrue(f.coordinator.removedBrowseCleanup.pending.isEmpty)
    }

    func testFailedVaultCommitCannotDeleteChoicesThroughTVConsumer() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let identity = try scope(first)
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let original = f.files.data; f.vault.failSave = true
        await f.coordinator.remove(first)
        XCTAssertEqual(f.session.account, first); XCTAssertEqual(f.files.data, original); XCTAssertTrue(f.files.attempts.isEmpty)
        XCTAssertTrue(f.coordinator.removedBrowseCleanup.pending.isEmpty); XCTAssertNotNil(f.coordinator.error)
    }

    func testCredentialWarningSurvivesBrowseCleanupFailureAndLastAccountTransition() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let identity = try scope(first)
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        let original = f.files.data; f.files.failures.insert(identity); f.services.failCredentials = true; f.services.failRevoke = true
        await f.coordinator.remove(first)
        XCTAssertNil(f.session.account); XCTAssertTrue(f.vault.value.accounts.isEmpty)
        XCTAssertTrue(f.session.notice?.contains("additional saved credentials") == true, "TV callback must never overwrite the pre-existing root credential warning")
        XCTAssertTrue(f.session.notice?.contains("local browse settings remain") == true)
        XCTAssertTrue(f.session.notice?.contains("revoke its session") == true)
        XCTAssertEqual(f.coordinator.removedBrowseCleanup.pending, [identity]); XCTAssertNotNil(f.coordinator.removedBrowseCleanup.message)
        XCTAssertEqual(f.files.data, original); XCTAssertNil(f.coordinator.error)
        let queued = try JSONEncoder().encode(f.coordinator.removedBrowseCleanup.pending)
        let text = String(decoding: queued, as: UTF8.self)
        XCTAssertFalse(text.contains(first.token)); XCTAssertFalse(text.contains(first.name))
    }

    func testRetryFreshVaultReadProtectsNormalizedReaddedAccountAndNewChoices() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let identity = try scope(first)
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: identity)); f.files.failures.insert(identity)
        await f.coordinator.remove(first); f.files.failures.remove(identity)
        let readded = account("first", server: "https://SYNTHETIC.invalid:443/jellyfin/")
        // Session's cached vault is empty; only the durable vault is restored.
        f.vault.value = AccountVault(accounts: [readded], activeID: readded.id)
        var newer = BrowseChoices(); newer.genreID = "newer-genre"; newer.viewStyle = .list
        XCTAssertTrue(f.preferences.save(newer, for: BrowseScope(), account: identity))
        let bytes = f.files.data, attempts = f.files.attempts
        f.coordinator.removedBrowseCleanup.retry(using: f.session)
        XCTAssertEqual(f.files.data, bytes); XCTAssertEqual(f.files.attempts, attempts)
        XCTAssertTrue(f.coordinator.removedBrowseCleanup.pending.isEmpty); XCTAssertEqual(f.session.account, readded)
    }

    func testUnreadableVaultBlocksRetryThenRecoveryClearsOnlyRemovedScope() async throws {
        let first = account("first"), sibling = account("sibling"), f = try fixture([first, sibling], active: first)
        defer { f.dispose() }
        let identity = try scope(first), saved = try scope(sibling)
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: identity))
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: saved))
        f.files.failures.insert(identity); await f.coordinator.remove(first); f.files.failures.remove(identity)
        let before = f.files.data, attempts = f.files.attempts
        f.vault.failRead = true; f.coordinator.removedBrowseCleanup.retry(using: f.session)
        XCTAssertEqual(f.files.data, before); XCTAssertEqual(f.files.attempts, attempts)
        XCTAssertEqual(f.coordinator.removedBrowseCleanup.pending, [identity])
        f.vault.failRead = false; f.coordinator.removedBrowseCleanup.retry(using: f.session)
        XCTAssertNil(f.files.data[identity]); XCTAssertEqual(f.files.data[saved], before[saved])
        XCTAssertTrue(f.coordinator.removedBrowseCleanup.pending.isEmpty); XCTAssertEqual(f.session.account, sibling)
    }

    func testColdProcessRetainsRemovedVaultAndUndeletedChoicesWithoutDurableRetryClaim() async throws {
        let first = account("first"), f = try fixture([first], active: first)
        defer { f.dispose() }
        let identity = try scope(first)
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: identity)); f.files.failures.insert(identity)
        await f.coordinator.remove(first)
        let bytes = f.files.data, attempts = f.files.attempts
        let restarted = Session(storage: f.vault, defaults: f.defaults, services: f.services.value)
        let freshStore = BrowsePreferencesStore(storage: f.files), fresh = TVCoordinator(session: restarted, browsePreferences: freshStore)
        XCTAssertNil(restarted.account); XCTAssertTrue(restarted.accounts.isEmpty)
        XCTAssertTrue(fresh.removedBrowseCleanup.pending.isEmpty, "Retry intent is transient noncredential state, not a durable tombstone")
        XCTAssertEqual(f.files.data, bytes); XCTAssertEqual(f.files.attempts, attempts)
    }

    func testInvalidRemovedIdentityCannotFallbackToNextActiveAccount() async throws {
        let first = account("invalid", server: "ftp://synthetic.invalid"), sibling = account("sibling"), f = try fixture([first, sibling], active: first)
        defer { f.dispose() }
        let saved = try scope(sibling)
        XCTAssertTrue(f.preferences.save(BrowseChoices(), for: BrowseScope(), account: saved))
        let bytes = f.files.data
        await f.coordinator.remove(first)
        XCTAssertEqual(f.session.account, sibling); XCTAssertEqual(f.files.data, bytes); XCTAssertTrue(f.files.attempts.isEmpty)
        XCTAssertTrue(f.session.notice?.contains("account identity") == true); XCTAssertTrue(f.coordinator.removedBrowseCleanup.pending.isEmpty)
    }
}
