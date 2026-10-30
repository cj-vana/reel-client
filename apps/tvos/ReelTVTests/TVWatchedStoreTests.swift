import Foundation
import XCTest
@testable import ReelTV

@MainActor final class TVWatchedStoreTests: XCTestCase {
    @MainActor private final class Vault: AccountVaultStorage {
        var value: AccountVault
        init(_ value: AccountVault) { self.value = value }
        func read() throws -> AccountVault { value }
        func save(_ value: AccountVault) throws { self.value = value }
        func clear() throws { value = AccountVault() }
    }
    private func fixture(server: String = "http://127.0.0.1:18970") throws -> (Session, UserDefaults, String) {
        let name = "Reel.TVWatched." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let account = Account(server: URL(string: server)!, token: "synthetic-only", userID: "library-tv-watched-unit", name: "Fixture", serverName: "Fixture")
        let vault = Vault(AccountVault(accounts: [account], activeID: account.id))
        let services = SessionAccountServices(authenticate: { _, _, _, _ in throw ReelError.invalidResponse }, revoke: { _, _ in }, removeCredentials: { _, _ in })
        return (Session(storage: vault, defaults: defaults, services: services), defaults, name)
    }
    private func item(_ id: String, type: String = "Episode", played: Bool? = nil) -> MediaItem {
        MediaItem(Id: id, Name: id, Type: type, UserData: UserData(Played: played))
    }
    private func wait(_ store: TVWatchedStore) async throws {
        for _ in 0..<2000 { if !store.busy { return }; try await Task.sleep(for: .milliseconds(1)) }
        XCTFail("Bounded store operation did not finish")
    }
    func testAggregateCountNeverTurnsUnknownNegativeMalformedOrLeafIntoZero() throws {
        for raw in ["null", "-1", "\"wrong\"", "999999999999999999999999"] {
            let data = Data("{\"Id\":\"a\",\"Name\":\"Aggregate\",\"Type\":\"Series\",\"UserData\":{\"UnplayedItemCount\":\(raw)}}".utf8)
            XCTAssertNil(try JSONDecoder().decode(MediaItem.self, from: data).aggregateUnplayedCount)
        }
        XCTAssertEqual(MediaItem(Id: "a", Name: "A", Type: "Series", UserData: UserData(UnplayedItemCount: 0)).aggregateUnplayedCount, 0)
        XCTAssertNil(MediaItem(Id: "a", Name: "A", Type: "Episode", UserData: UserData(UnplayedItemCount: 20)).aggregateUnplayedCount)
    }
    func testCancelAndDuplicatePlaylistSelectionProduceZeroThenOneExplicitWrite() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), row = item("episode-a")
        store.configure(session: session, key: "playlist", items: [row, row]); store.begin(); store.selectLoaded([row, row], session: session)
        XCTAssertEqual(store.selected, [row.id])
        var writes: [String] = []; store.send = { plan, _ in writes.append(plan.itemID + ":" + plan.method) }
        store.request([row, row], played: false, session: session, key: "playlist"); XCTAssertEqual(store.confirmation?.plans.count, 1)
        store.confirmation = nil; XCTAssertTrue(writes.isEmpty)
        store.request([row, row], played: false, session: session, key: "playlist"); store.confirm(session: session); store.confirm(session: session)
        try await wait(store); XCTAssertEqual(writes, ["episode-a:DELETE"]); XCTAssertEqual(session.libraryRevision, 1)
    }
    func testQueryChangeClearsSelectionAndStaleConfirmationBeforeWrites() throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), row = item("a")
        store.configure(session: session, key: "old", items: [row]); store.begin(); store.toggle(row)
        store.request([row], played: true, session: session, key: "old")
        store.configure(session: session, key: "new", items: [row]); store.confirm(session: session)
        XCTAssertTrue(store.selected.isEmpty); XCTAssertNil(store.confirmation); XCTAssertTrue(store.entries.isEmpty); XCTAssertFalse(store.busy)
    }
    func testPrivateAndNonloopbackProtectedGuardsRefusePlansWithoutSend() throws {
        for server in ["http://127.0.0.1:18970", "https://synthetic.invalid"] {
            let (session, defaults, suite) = try fixture(server: server); defer { defaults.removePersistentDomain(forName: suite) }
            if server.contains("127.0.0.1") { session.privateViewing = true }
            let store = TVWatchedStore(), row = item("a")
            store.configure(session: session, key: "q", items: [row]); store.request([row], played: true, session: session, key: "q")
            XCTAssertNotNil(TVWatchedStore.refusal(session)); XCTAssertNil(store.confirmation); XCTAssertFalse(store.busy)
        }
    }
    func testPermissionFailureStopsUnsentTargetsAndRetryExcludesAcceptedID() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), rows = [item("a"), item("b"), item("c")]
        store.configure(session: session, key: "q", items: rows)
        var writes: [String] = []; var deny = true
        store.send = { plan, _ in writes.append(plan.itemID); if plan.itemID == "b" && deny { throw ReelError.unauthorized } }
        store.request(rows, played: true, session: session, key: "q"); store.confirm(session: session); try await wait(store)
        XCTAssertEqual(writes, ["a", "b"]); XCTAssertEqual(store.retryable.map(\.itemID), ["b", "c"])
        deny = false; store.retry(session: session); try await wait(store)
        XCTAssertEqual(writes, ["a", "b", "b", "c"]); XCTAssertTrue(store.entries.allSatisfy { $0.outcome == .saved })
    }
    func testTransportUncertaintyUsesAuthoritativeReadbackAndNeverBlindReplay() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), rows = [item("a"), item("b"), item("c")]
        store.configure(session: session, key: "q", items: rows)
        var writes: [String] = []; store.send = { plan, _ in writes.append(plan.itemID); throw ReelError.unavailable }
        store.read = { id, _ in self.item(id, played: id == "a" ? true : id == "b" ? false : nil) }
        store.request(rows, played: true, session: session, key: "q"); store.confirm(session: session); try await wait(store)
        XCTAssertEqual(store.entries[0].outcome, .confirmed)
        XCTAssertEqual(store.retryable.map(\.itemID), ["b"]); XCTAssertTrue(store.uncertain)
        store.send = { plan, _ in writes.append(plan.itemID) }; store.retry(session: session); try await wait(store)
        XCTAssertEqual(writes, ["a", "b", "c", "b"]); XCTAssertTrue(store.uncertain)
    }
    func testPrivateChangeAfterFirstAcceptedWriteStopsRemainingRequests() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), rows = [item("a"), item("b")]
        store.configure(session: session, key: "q", items: rows)
        var writes: [String] = []; store.send = { plan, _ in writes.append(plan.itemID); session.privateViewing = true }
        store.request(rows, played: false, session: session, key: "q"); store.confirm(session: session); try await wait(store)
        XCTAssertEqual(writes, ["a"]); XCTAssertEqual(store.entries[1].outcome, .notStarted)
    }
    func testScopeRefreshDropsVanishedSelectionButPaginationAndViewKeepExistingIDs() throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), a = item("a"), b = item("b")
        store.configure(session: session, key: "q", items: [a]); store.begin(); store.toggle(a)
        store.configure(session: session, key: "q", items: [a,b]); XCTAssertEqual(store.selected, ["a"])
        store.configure(session: session, key: "q", items: [b]); XCTAssertTrue(store.selected.isEmpty)
        store.finishSelection(); XCTAssertFalse(store.selecting)
    }
    func testCatalogueInvalidationRefusesOldAccountOrRevision() throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let account = try XCTUnwrap(session.account)
        XCTAssertFalse(session.invalidateCatalogue(accountID: "other", revision: session.revision))
        XCTAssertFalse(session.invalidateCatalogue(accountID: account.id, revision: UUID()))
        XCTAssertTrue(session.invalidateCatalogue(accountID: account.id, revision: session.revision)); XCTAssertEqual(session.libraryRevision, 1)
    }
    func testUnknownKindWithPlayedFlagCannotBecomeEligibleLeaf() throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), unknown = MediaItem(Id: "unknown", Name: "Unknown", UserData: UserData(Played: true))
        store.configure(session: session, key: "q", items: [unknown]); store.begin(); store.toggle(unknown)
        XCTAssertTrue(store.selected.isEmpty); XCTAssertNotNil(store.message)
        store.request([unknown], played: false, session: session, key: "q")
        XCTAssertNil(store.confirmation); XCTAssertFalse(store.busy)
        for kind in ["MusicAlbum", "MusicArtist", "PhotoAlbum", "Folder"] {
            XCTAssertTrue(TVWatchedStore.eligible(item("known", type: kind)))
        }
    }
    func testCancelOfIssuedRequestPreservesUncertainAndNeverStartsNextTarget() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), rows = [item("a"), item("b")]
        store.configure(session: session, key: "q", items: rows)
        var started = false, writes: [String] = []
        store.send = { plan, _ in writes.append(plan.itemID); started = true; try await Task.sleep(for: .seconds(20)) }
        store.request(rows, played: true, session: session, key: "q"); store.confirm(session: session)
        for _ in 0..<1000 { if started { break }; await Task.yield() }
        XCTAssertTrue(started); store.cancelRemaining(); try await wait(store)
        XCTAssertEqual(writes, ["a"]); XCTAssertTrue(store.uncertain); XCTAssertEqual(store.entries[1].outcome, .notStarted)
        store.read = { id, _ in self.item(id, played: true) }; store.checkStatus(session: session); try await wait(store)
        XCTAssertEqual(store.entries[0].outcome, .confirmed); XCTAssertEqual(writes, ["a"])
    }
    func testSelectionIsBoundedAndNewInstanceHasNoDurableRetryState() throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let rows = (0..<501).map { item("item-\($0)") }, store = TVWatchedStore()
        store.configure(session: session, key: "q", items: rows); store.begin(); store.selectLoaded(rows, session: session)
        XCTAssertEqual(store.selected.count, 500); XCTAssertNotNil(store.message)
        let cold = TVWatchedStore(); cold.configure(session: session, key: "q", items: rows)
        XCTAssertTrue(cold.selected.isEmpty); XCTAssertTrue(cold.entries.isEmpty); XCTAssertNil(cold.confirmation)
    }

    func testBackDuringSubmissionRetainsUncertainIssuedResultBeforeLeavingSelection() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), rows = [item("a"), item("b")]
        store.configure(session: session, key: "q", items: rows); store.begin(); store.selectLoaded(rows, session: session)
        var started = false
        store.send = { _, _ in started = true; try await Task.sleep(for: .seconds(20)) }
        store.request(rows, played: true, session: session, key: "q"); store.confirm(session: session)
        for _ in 0..<1000 { if started { break }; await Task.yield() }
        XCTAssertTrue(started); store.exitWithBack(); try await wait(store)
        XCTAssertFalse(store.selecting); XCTAssertTrue(store.selected.isEmpty)
        XCTAssertTrue(store.uncertain); XCTAssertEqual(store.entries[1].outcome, .notStarted)
    }

    func testSameIDTypeOrFolderScopeChangeDropsOldConfirmationBeforeDispatch() throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), leaf = item("same", type: "Movie")
        store.configure(session: session, key: "q", items: [leaf]); store.request([leaf], played: true, session: session, key: "q")
        XCTAssertNotNil(store.confirmation)
        let folder = MediaItem(Id: "same", Name: "Folder", Type: "Movie", IsFolder: true)
        store.configure(session: session, key: "q", items: [folder]); store.confirm(session: session)
        XCTAssertNil(store.confirmation); XCTAssertFalse(store.busy); XCTAssertNotNil(store.message)
        store.request([folder], played: false, session: session, key: "q"); XCTAssertTrue(store.confirmation?.plans.first?.isBulk == true)
        let unknown = MediaItem(Id: "same", Name: "Unknown", Type: "Unproven", UserData: UserData(Played: true))
        store.configure(session: session, key: "q", items: [unknown]); store.confirm(session: session)
        XCTAssertFalse(store.busy); XCTAssertNil(store.confirmation)
    }
    func testContainerReadbackNeverConfirmsDescendantsAndRepeatRequiresFreshConfirmation() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), row = item("series", type: "Series")
        store.configure(session: session, key: "q", items: [row]); var writes = 0
        store.send = { _, _ in writes += 1; throw ReelError.unavailable }
        store.read = { id, _ in MediaItem(Id: id, Name: "Series", Type: "Series", UserData: UserData(Played: true, UnplayedItemCount: 0)) }
        store.request([row], played: true, session: session, key: "q"); store.confirm(session: session); try await wait(store)
        XCTAssertEqual(writes, 1); XCTAssertTrue(store.retryable.isEmpty); XCTAssertEqual(store.reviewPlans.count, 1)
        XCTAssertFalse(store.entries.contains { $0.outcome == .confirmed })
        store.retry(session: session); XCTAssertEqual(writes, 1)
        store.reviewChanges(session: session); XCTAssertTrue(store.confirmation?.plans.first?.isBulk == true)
        store.confirmation = nil; XCTAssertEqual(writes, 1)
        store.send = { _, _ in writes += 1 }; store.reviewChanges(session: session); store.confirm(session: session); try await wait(store)
        XCTAssertEqual(writes, 2); XCTAssertEqual(store.entries.first?.outcome, .saved)
    }
    func testReadbackWiderTypeRetainsDesiredValueAndRequiresScopeReview() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), row = item("same", type: "Movie")
        store.configure(session: session, key: "q", items: [row]); var writes = 0
        store.send = { _, _ in writes += 1; throw ReelError.unavailable }
        store.read = { id, _ in MediaItem(Id: id, Name: "Updated album", Type: "MusicAlbum", UserData: UserData(Played: false, UnplayedItemCount: 0)) }
        store.request([row], played: false, session: session, key: "q"); store.confirm(session: session); try await wait(store)
        XCTAssertTrue(store.retryable.isEmpty); XCTAssertEqual(store.reviewPlans.first?.type, "MusicAlbum"); XCTAssertEqual(store.reviewPlans.first?.played, false)
        store.reviewChanges(session: session); XCTAssertTrue(store.confirmation?.message.contains("outside the current filters") == true)
        XCTAssertEqual(writes, 1); XCTAssertFalse(store.entries.contains { $0.outcome == .confirmed })
    }
    func testUnsupportedReadbackCannotReuseOldLeafAuthorityUntilFreshMetadata() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), row = item("same")
        store.configure(session: session, key: "q", items: [row]); var writes = 0
        store.send = { _, _ in writes += 1; throw ReelError.unavailable }
        store.read = { id, _ in MediaItem(Id: id, Name: "Unsupported", Type: "Recording", UserData: UserData(Played: true)) }
        store.request([row], played: true, session: session, key: "q"); store.confirm(session: session); try await wait(store)
        XCTAssertTrue(store.retryable.isEmpty); XCTAssertTrue(store.uncertain)
        store.request([row], played: false, session: session, key: "q"); XCTAssertNil(store.confirmation)
        store.retry(session: session); XCTAssertEqual(writes, 1)
    }
    func testEphemeralLaneBlocksPeerControlsAndIgnoresStaleRelease() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let lane = TVWatchedLane(), first = TVWatchedStore(), second = TVWatchedStore(), row = item("a")
        first.configure(session: session, key: "q", items: [row], lane: lane)
        second.configure(session: session, key: "q", items: [row], lane: lane)
        var started = false
        first.send = { _, _ in started = true; try await Task.sleep(for: .seconds(20)) }
        first.request([row], played: true, session: session, key: "q"); first.confirm(session: session)
        for _ in 0..<1000 { if started { break }; await Task.yield() }
        XCTAssertTrue(started); XCTAssertTrue(lane.busy); XCTAssertTrue(second.anotherOperation)
        second.request([row], played: false, session: session, key: "q"); XCTAssertNil(second.confirmation)
        first.cancelRemaining(); try await wait(first); XCTAssertFalse(lane.busy)
        let old = UUID(), current = UUID(); XCTAssertTrue(lane.acquire(old)); lane.release(old)
        XCTAssertTrue(lane.acquire(current)); lane.release(old); XCTAssertTrue(lane.busy); lane.release(current)
        second.send = { _, _ in }; second.request([row], played: false, session: session, key: "q"); second.confirm(session: session); try await wait(second)
        XCTAssertFalse(lane.busy); XCTAssertEqual(second.entries.first?.outcome, .saved)
    }
    func testNavigationInvalidationClearsRetryAndSelectionWithoutReplaying() async throws {
        let (session, defaults, suite) = try fixture(); defer { defaults.removePersistentDomain(forName: suite) }
        let store = TVWatchedStore(), row = item("a"); var writes = 0
        store.configure(session: session, key: "q", items: [row]); store.begin(); store.toggle(row)
        store.send = { _, _ in writes += 1; throw ReelError.unauthorized }
        store.request([row], played: true, session: session, key: "q"); store.confirm(session: session); try await wait(store)
        XCTAssertEqual(store.retryable.count, 1)
        store.invalidate(); store.configure(session: session, key: "q", items: [row]); store.retry(session: session)
        XCTAssertEqual(writes, 1); XCTAssertTrue(store.entries.isEmpty); XCTAssertTrue(store.selected.isEmpty); XCTAssertFalse(store.selecting)
    }

}
