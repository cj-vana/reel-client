import XCTest
@testable import Reel

@MainActor final class CatalogueInvalidationTests: XCTestCase {
    private final class Vault: AccountVaultStorage {
        var value: AccountVault
        init(_ value: AccountVault) { self.value = value }
        func read() throws -> AccountVault { value }
        func save(_ value: AccountVault) throws { self.value = value }
        func clear() throws { value = AccountVault() }
    }
    private func account(_ id: String) -> Account {
        Account(server: URL(string: "https://synthetic.invalid/jellyfin")!, token: "synthetic-" + id, userID: id, name: id, serverName: "Synthetic")
    }
    private func withSession(_ body: (Session, Account, Account) async throws -> Void) async throws {
        let first = account("first"), sibling = account("sibling")
        let suite = "Reel.CatalogueInvalidationTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let services = SessionAccountServices(authenticate: { _, _, _, _ in throw ReelError.invalidResponse },
                                              revoke: { _, _ in }, removeCredentials: { _, _ in })
        let session = Session(storage: Vault(AccountVault(accounts: [first, sibling], activeID: first.id)), defaults: defaults, services: services)
        try await body(session, first, sibling)
    }

    func testCurrentAccountRevisionPublishesExactlyOneImmediateCatalogueEpoch() async throws {
        try await withSession { session, first, _ in
            let old = session.libraryRevision
            XCTAssertTrue(session.invalidateCatalogue(accountID: first.id, revision: session.revision))
            XCTAssertEqual(session.libraryRevision, old + 1)
        }
    }

    func testSiblingAndStaleRevisionCannotInvalidateCurrentCatalogue() async throws {
        try await withSession { session, first, sibling in
            let old = session.libraryRevision
            XCTAssertFalse(session.invalidateCatalogue(accountID: sibling.id, revision: session.revision))
            XCTAssertFalse(session.invalidateCatalogue(accountID: first.id, revision: UUID()))
            XCTAssertEqual(session.libraryRevision, old)
        }
    }

    func testSwitchAndReauthenticationFenceAnAlreadyCapturedMutation() async throws {
        try await withSession { session, first, sibling in
            let captured = session.revision, old = session.libraryRevision
            try await session.select(sibling)
            XCTAssertFalse(session.invalidateCatalogue(accountID: first.id, revision: captured))
            try await session.accept(first)
            XCTAssertFalse(session.invalidateCatalogue(accountID: first.id, revision: captured))
            XCTAssertEqual(session.libraryRevision, old)
            XCTAssertTrue(session.invalidateCatalogue(accountID: first.id, revision: session.revision))
        }
    }
}
