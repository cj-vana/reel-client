import XCTest
@testable import ReelTV

@MainActor private final class TVRequestMemoryStorage: BrowsePreferencesStorage {
    var data: [BrowseAccountScope: Data] = [:]
    func read(account: BrowseAccountScope) throws -> Data? { data[account] }
    func write(_ value: Data, account: BrowseAccountScope) throws { data[account] = value }
    func remove(account: BrowseAccountScope) throws { data[account] = nil }
}

@MainActor final class TVBrowseRequestTests: XCTestCase {
    private func started(_ user: String, start: String, count: Int = 1) async throws {
        for _ in 0..<100 {
            let requests = try await TVParityFixture.requests(user)
            if requests.filter({ $0["path"] as? String == "/Items" && ($0["query"] as? [String: String])?["startindex"] == start }).count >= count { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Expected actual outgoing page request did not start")
    }

    func testLaterFailureUnexpectedEmptyAndOverlapKeepRawCursorAndLoadedResults() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-page-recovery"
        try await TVParityFixture.control(user, ["reset": true, "failLater": 1, "emptyLater": 1, "overlapLater": 1])
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: TVRequestMemoryStorage()))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        let original = store.items.map(\.id)
        XCTAssertEqual(original.count, 60); XCTAssertEqual(store.page.nextIndex, 60)
        await store.loadMore(api: TVParityFixture.api(user))
        XCTAssertNotNil(store.error); XCTAssertEqual(store.items.map(\.id), original); XCTAssertEqual(store.page.nextIndex, 60)
        await store.loadMore(api: TVParityFixture.api(user))
        XCTAssertTrue(store.error?.contains("unexpectedly empty") == true)
        XCTAssertEqual(store.items.map(\.id), original); XCTAssertEqual(store.page.nextIndex, 60)
        await store.loadMore(api: TVParityFixture.api(user))
        XCTAssertNil(store.error); XCTAssertEqual(store.items.count, 119); XCTAssertEqual(store.page.nextIndex, 120)
        await store.loadMore(api: TVParityFixture.api(user))
        XCTAssertEqual(store.items.count, 143); XCTAssertEqual(store.page.nextIndex, 144); XCTAssertFalse(store.hasMore)
        XCTAssertEqual(Set(store.items.map(\.id)).count, store.items.count)
        let requests = try await TVParityFixture.requests(user)
        XCTAssertEqual(requests.filter { $0["path"] as? String == "/Items" }.compactMap { ($0["query"] as? [String: String])?["startindex"] }, ["0", "60", "60", "60", "120"])
    }

    func testDelayedOldPageFailureCannotReplaceNewCategorySuccess() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-page-fence"
        try await TVParityFixture.control(user, ["reset": true])
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: TVRequestMemoryStorage()))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        try await TVParityFixture.control(user, ["delayLaterMs": 1000, "failLater": 1])
        let old = Task { await store.loadMore(api: TVParityFixture.api(user)) }
        try await started(user, start: "60")
        await store.selectCategory("Episodes", api: TVParityFixture.api(user))
        await old.value
        try await Task.sleep(for: .milliseconds(1100))
        XCTAssertNil(store.error); XCTAssertFalse(store.loading)
        XCTAssertEqual(store.items.count, 12); XCTAssertTrue(store.items.allSatisfy { $0.Type == "Episode" })
        XCTAssertEqual(store.page.nextIndex, 12)
    }

    func testOldAccountPageCannotCommitAfterSwitch() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let oldUser = "library-tv-request-old", newUser = "library-tv-request-new"
        try await TVParityFixture.control(oldUser, ["reset": true, "delayFirstMs": 900, "failFirst": 1])
        try await TVParityFixture.control(newUser, ["reset": true, "empty": true])
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: TVRequestMemoryStorage()))
        let old = Task { await store.open(api: TVParityFixture.api(oldUser), destination: nil, searching: false, search: "") }
        try await started(oldUser, start: "0")
        await store.open(api: TVParityFixture.api(newUser), destination: nil, searching: false, search: "")
        await old.value
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertNil(store.error); XCTAssertFalse(store.loading); XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.total, 0)
        XCTAssertEqual(store.scope, BrowseScope())
    }
    func testDelayedOldOptionsCannotReplaceNewAccountOptions() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let oldUser = "library-tv-options-old", newUser = "library-tv-options-new"
        try await TVParityFixture.control(oldUser, ["reset": true, "delayOptionsMs": 900])
        try await TVParityFixture.control(oldUser, ["removedLibrary": true], options: true)
        try await TVParityFixture.control(newUser, ["reset": true, "empty": true])
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: TVRequestMemoryStorage()))
        let old = Task { await store.open(api: TVParityFixture.api(oldUser), destination: nil, searching: false, search: "") }
        var optionsStarted = false
        for _ in 0..<100 {
            let requests = try await TVParityFixture.requests(oldUser)
            if requests.contains(where: { $0["path"] as? String == "/Genres" }) { optionsStarted = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(optionsStarted, "The old account’s metadata request must actually start before switching")
        await store.open(api: TVParityFixture.api(newUser), destination: nil, searching: false, search: "")
        await old.value
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertTrue(store.libraries.contains { $0.id == "library-shows" })
        XCTAssertTrue(store.items.isEmpty); XCTAssertNil(store.error); XCTAssertNil(store.optionsError)
    }

    func testSameQueryReentryKeepsRowsWhileRefreshingWithoutLosingCurrentContent() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-reentry"
        try await TVParityFixture.control(user, ["reset": true])
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: TVRequestMemoryStorage()))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        let original = store.items.map(\.id)
        store.cancel()
        try await TVParityFixture.control(user, ["delayFirstMs": 900])
        let reopen = Task { await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "") }
        try await started(user, start: "0", count: 2)
        XCTAssertTrue(store.loading)
        XCTAssertEqual(store.items.map(\.id), original, "Back/re-entry must not remove current focus targets while the same query refreshes")
        await reopen.value
        XCTAssertEqual(store.items.map(\.id), original); XCTAssertNil(store.error)
    }

    func testDelayedSearchFailureAndBlankInputCannotReplaceNewEmptyResult() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-search-fence"
        try await TVParityFixture.control(user, ["reset": true, "delayFirstMs": 900, "failFirst": 1])
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: TVRequestMemoryStorage()))
        let old = Task { await store.open(api: TVParityFixture.api(user), destination: nil, searching: true, search: "North") }
        try await started(user, start: "0")
        store.prepareSearch("Nothing matches")
        XCTAssertFalse(store.loading); XCTAssertNil(store.error); XCTAssertTrue(store.items.isEmpty)
        XCTAssertEqual(store.searchText, "Nothing matches", "Fence old page/error immediately, before the UI debounce elapses")
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: true, search: "Nothing matches")
        await old.value
        try await Task.sleep(for: .milliseconds(1000))
        XCTAssertNil(store.error); XCTAssertTrue(store.items.isEmpty); XCTAssertEqual(store.total, 0)
        XCTAssertEqual(store.searchText, "Nothing matches"); XCTAssertFalse(store.loading)
        let before = try await TVParityFixture.requests(user).filter { $0["path"] as? String == "/Items" }.count
        store.prepareSearch(" ")
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: true, search: " ")
        let after = try await TVParityFixture.requests(user).filter { $0["path"] as? String == "/Items" }.count
        XCTAssertEqual(before, after); XCTAssertFalse(store.loading); XCTAssertTrue(store.items.isEmpty)
    }

    func testMissingOptionalTotalsUseRawPageLengthUntilShortTerminalPage() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-no-total"
        try await TVParityFixture.control(user, ["reset": true])
        try await TVParityFixture.control(user, ["omitTotals": true], options: true)
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: TVRequestMemoryStorage()))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        XCTAssertNil(store.total); XCTAssertEqual(store.items.count, 60); XCTAssertTrue(store.hasMore)
        await store.loadMore(api: TVParityFixture.api(user))
        XCTAssertEqual(store.items.count, 120); XCTAssertTrue(store.hasMore); XCTAssertNil(store.total)
        await store.loadMore(api: TVParityFixture.api(user))
        XCTAssertEqual(store.items.count, 144); XCTAssertEqual(store.page.nextIndex, 144); XCTAssertFalse(store.hasMore)
    }

}
