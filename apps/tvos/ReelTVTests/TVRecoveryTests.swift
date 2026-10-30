import XCTest
@testable import ReelTV

@MainActor final class TVRecoveryTests: XCTestCase {
    private final class Store: AccountVaultStorage {
        var available = false
        var writes = 0
        var clears = 0
        let original = Account(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-preserved", userID: "tv-preserved", name: "Alex", serverName: "Reel Cinema")
        func read() throws -> AccountVault {
            guard available else { throw ReelError.storage }
            return AccountVault(accounts: [original], activeID: original.id)
        }
        func save(_ vault: AccountVault) throws { writes += 1 }
        func clear() throws { clears += 1 }
    }

    func testUnavailableTVSessionRejectsAuthenticationWithoutWritesAndRecoversOriginalAccount() async throws {
        try TVFixture.requireQAHost()
        let store = Store()
        let suite = "app.reelclient.tv.qa.recovery-contract." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var authentications = 0
        let services = SessionAccountServices(authenticate: { _, _, _, _ in authentications += 1; return store.original }, revoke: { _, _ in }, removeCredentials: { _, _ in })
        let session = Session(storage: store, defaults: defaults, services: services)
        let coordinator = TVCoordinator(session: session)
        XCTAssertFalse(coordinator.session.savedAccountsAvailable)
        XCTAssertNil(coordinator.session.account)
        do { try await coordinator.session.signIn(server: "http://127.0.0.1:18966", username: "replacement", password: "demo"); XCTFail("Unavailable vault accepted new authentication") }
        catch { XCTAssertTrue(error is SavedAccountStorageError) }
        XCTAssertEqual(authentications, 0)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.clears, 0)
        store.available = true
        try coordinator.session.retrySavedAccounts()
        XCTAssertTrue(coordinator.session.savedAccountsAvailable)
        XCTAssertEqual(coordinator.session.account, store.original)
        XCTAssertEqual(store.writes, 0)
        XCTAssertEqual(store.clears, 0)
    }
}
