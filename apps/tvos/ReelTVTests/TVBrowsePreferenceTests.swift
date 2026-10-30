import Foundation
import XCTest
@testable import ReelTV

@MainActor private final class TVBrowseMemoryStorage: BrowsePreferencesStorage {
    var data: [BrowseAccountScope: Data] = [:]
    var unreadable = false
    var failWrites = false
    var writes = 0
    func read(account: BrowseAccountScope) throws -> Data? {
        if unreadable { throw BrowsePreferencesError.unreadable }
        return data[account]
    }
    func write(_ bytes: Data, account: BrowseAccountScope) throws {
        writes += 1
        if failWrites { throw BrowsePreferencesError.writeFailed }
        data[account] = bytes
    }
    func remove(account: BrowseAccountScope) throws { data[account] = nil }
}

@MainActor final class TVBrowsePreferenceTests: XCTestCase {
    private func account(_ user: String) throws -> BrowseAccountScope { try BrowseAccountScope(server: TVParityFixture.base, userID: user) }
    private func seed(_ storage: TVBrowseMemoryStorage, user: String, root: BrowseRootLocation, scope: BrowseScope, choices: BrowseChoices) throws -> BrowseAccountScope {
        let account = try account(user)
        var document = BrowseDocument(account: account); document.root = root
        document.entries = [.init(scope: scope, choices: choices)]
        storage.data[account] = try JSONEncoder().encode(document)
        return account
    }

    func testSeeAllOverridesGlobalQueryWithoutSavingRootOrScopePredicates() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-intent"
        try await TVParityFixture.control(user, ["reset": true])
        let storage = TVBrowseMemoryStorage(), scope = BrowseScope(category: "Episodes")
        var saved = BrowseChoices(); saved.sort = .title; saved.direction = .ascending
        saved.genreID = "library-drama"; saved.watchStatus = "Watched"; saved.favoritesOnly = true; saved.viewStyle = .list
        let account = try seed(storage, user: user, root: BrowseRootLocation(libraryID: "library-shows", category: "Series"), scope: scope, choices: saved)
        let original = storage.data[account]
        let preferences = BrowsePreferencesStore(storage: storage), store = TVBrowseStore(preferences: preferences)
        await store.open(api: TVParityFixture.api(user), destination: TVLibraryDestination(category: "Episodes", sort: .recentlyAdded, parent: nil), searching: false, search: "")
        XCTAssertEqual(store.scope, BrowseScope(category: "Episodes"))
        XCTAssertEqual(store.query.parameters(start: 0)["sortOrder"], "Descending,Ascending")
        XCTAssertNil(store.query.parameters(start: 0)["genreIds"]); XCTAssertNil(store.query.parameters(start: 0)["isPlayed"])
        XCTAssertNil(store.query.parameters(start: 0)["filters"]); XCTAssertNil(store.query.parameters(start: 0)["parentId"])
        XCTAssertEqual(store.choices.viewStyle, .list)
        XCTAssertEqual(storage.data[account], original); XCTAssertEqual(storage.writes, 0)
        await store.change(api: TVParityFixture.api(user)) { $0.viewStyle = .grid }
        let updated = try JSONDecoder().decode(BrowseDocument.self, from: XCTUnwrap(storage.data[account]))
        XCTAssertEqual(updated.root, BrowseRootLocation(libraryID: "library-shows", category: "Series"))
        var expected = saved; expected.viewStyle = .grid
        XCTAssertEqual(updated.choices(for: scope), expected, "Presentation-only intent edits must not clear saved query predicates")
    }

    func testRemovedOptionIDsAreValidatedBeforeFirstItemsAndQueryRestoresAcrossStore() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-options-restore"
        try await TVParityFixture.control(user, ["reset": true])
        let storage = TVBrowseMemoryStorage()
        var choices = BrowseChoices(); choices.sort = .recentlyAdded; choices.direction = .descending; choices.genreID = "library-drama"
        _ = try seed(storage, user: user, root: BrowseRootLocation(libraryID: "removed-library", category: "Episodes"), scope: BrowseScope(category: "Episodes"), choices: choices)
        try await TVParityFixture.control(user, ["removedGenre": true], options: true)
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: storage))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        XCTAssertEqual(store.scope.libraryID, ""); XCTAssertEqual(store.choices.genreID, "")
        let requests = try await TVParityFixture.requests(user)
        let first = try XCTUnwrap(requests.first { $0["path"] as? String == "/Items" })
        let params = try XCTUnwrap(first["query"] as? [String: String])
        XCTAssertEqual(params["includeitemtypes"], "Episode"); XCTAssertNil(params["genreids"]); XCTAssertNil(params["parentid"])
        XCTAssertTrue(requests.prefix { $0["path"] as? String != "/Items" }.contains { $0["path"] as? String == "/UserViews" })
        XCTAssertTrue(requests.prefix { $0["path"] as? String != "/Items" }.contains { $0["path"] as? String == "/Genres" })
        await store.change(api: TVParityFixture.api(user)) { $0.direction = .ascending; $0.watchStatus = "Unwatched" }
        let restored = TVBrowseStore(preferences: BrowsePreferencesStore(storage: storage))
        await restored.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        XCTAssertEqual(restored.scope.category, "Episodes"); XCTAssertEqual(restored.choices.direction, .ascending)
        XCTAssertEqual(restored.choices.watchStatus, "Unwatched")
    }

    func testOptionsFailureBlocksSavedIDsUntilExplicitSafeDefaultsAndKeepsFile() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-options-error"
        try await TVParityFixture.control(user, ["reset": true, "failOptions": 1])
        let storage = TVBrowseMemoryStorage()
        var choices = BrowseChoices(); choices.genreID = "library-drama"
        let account = try seed(storage, user: user, root: BrowseRootLocation(libraryID: "library-shows", category: "Episodes"), scope: BrowseScope(libraryID: "library-shows", category: "Episodes"), choices: choices)
        let original = storage.data[account]
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: storage))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        XCTAssertFalse(store.optionsReady); XCTAssertNotNil(store.optionsError)
        let requests = try await TVParityFixture.requests(user)
        XCTAssertFalse(requests.contains { $0["path"] as? String == "/Items" })
        await store.browseWithDefaults(api: TVParityFixture.api(user))
        XCTAssertTrue(store.usingTemporaryDefaults); XCTAssertFalse(store.items.isEmpty)
        XCTAssertEqual(storage.data[account], original)
        await store.retryOptions(api: TVParityFixture.api(user))
        XCTAssertEqual(store.scope.libraryID, "library-shows"); XCTAssertEqual(store.scope.category, "Episodes")
        XCTAssertEqual(store.choices.genreID, "library-drama")
    }

    func testUnreadableIntentViewChangeDoesNotOverwriteRecoveredQueryScope() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-intent-recovery"
        try await TVParityFixture.control(user, ["reset": true])
        let storage = TVBrowseMemoryStorage(), scope = BrowseScope(category: "Episodes")
        var choices = BrowseChoices(); choices.genreID = "library-drama"; choices.watchStatus = "Watched"
        let account = try seed(storage, user: user, root: BrowseRootLocation(category: "Series"), scope: scope, choices: choices)
        let original = storage.data[account]; storage.unreadable = true
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: storage))
        await store.open(api: TVParityFixture.api(user), destination: TVLibraryDestination(category: "Episodes", sort: .recentlyAdded, parent: nil), searching: false, search: "")
        XCTAssertEqual(store.preferenceStatus, .unavailable)
        await store.change(api: TVParityFixture.api(user)) { $0.viewStyle = .list }
        XCTAssertEqual(storage.data[account], original); XCTAssertEqual(storage.writes, 0)
        storage.unreadable = false
        await store.retryPreferences(api: TVParityFixture.api(user))
        let recovered = try JSONDecoder().decode(BrowseDocument.self, from: XCTUnwrap(storage.data[account]))
        XCTAssertEqual(recovered.choices(for: scope).genreID, "library-drama")
        XCTAssertEqual(recovered.choices(for: scope).watchStatus, "Watched")
        XCTAssertEqual(recovered.choices(for: scope).viewStyle, .list)
        XCTAssertEqual(recovered.root.category, "Series")
    }

    func testInactiveLibraryReentryRestoresChoicesChangedByAnotherRouteBeforeItems() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-shared-route"
        try await TVParityFixture.control(user, ["reset": true])
        let storage = TVBrowseMemoryStorage(), account = try account(user)
        let preferences = BrowsePreferencesStore(storage: storage), store = TVBrowseStore(preferences: preferences)
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        XCTAssertEqual(store.scope.category, "All")
        store.cancel()
        var choices = BrowseChoices(); choices.genreID = "library-drama"; choices.viewStyle = .list
        XCTAssertTrue(preferences.save(choices, for: BrowseScope(category: "Episodes"), account: account))
        XCTAssertTrue(preferences.saveRoot(BrowseRootLocation(category: "Episodes"), account: account))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        XCTAssertEqual(store.scope.category, "Episodes"); XCTAssertEqual(store.choices.viewStyle, .list)
        XCTAssertEqual(store.choices.genreID, "library-drama")
        XCTAssertTrue(store.items.allSatisfy { $0.Type == "Episode" })
        let requests = try await TVParityFixture.requests(user)
        let last = try XCTUnwrap(requests.last { $0["path"] as? String == "/Items" }?["query"] as? [String: String])
        XCTAssertEqual(last["includeitemtypes"], "Episode"); XCTAssertEqual(last["genreids"], "library-drama")
    }

    func testWriteFailureKeepsExplicitQueryInMemoryAndRetryPreservesOtherScopes() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-write-error", storage = TVBrowseMemoryStorage()
        try await TVParityFixture.control(user, ["reset": true])
        let account = try seed(storage, user: user, root: BrowseRootLocation(), scope: BrowseScope(), choices: BrowseChoices())
        var initial = try JSONDecoder().decode(BrowseDocument.self, from: XCTUnwrap(storage.data[account]))
        var episode = BrowseChoices(); episode.genreID = "library-drama"
        initial.entries.append(.init(scope: BrowseScope(category: "Episodes"), choices: episode))
        storage.data[account] = try JSONEncoder().encode(initial)
        let original = storage.data[account]
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: storage))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        storage.failWrites = true
        await store.change(api: TVParityFixture.api(user)) { $0.favoritesOnly = true }
        XCTAssertEqual(store.preferenceStatus, .dirty); XCTAssertNotNil(store.preferenceError)
        XCTAssertTrue(store.choices.favoritesOnly); XCTAssertEqual(storage.data[account], original)
        XCTAssertFalse(store.items.isEmpty); XCTAssertTrue(store.items.allSatisfy(\.isFavorite))
        storage.failWrites = false
        await store.retryPreferences(api: TVParityFixture.api(user))
        XCTAssertEqual(store.preferenceStatus, .ready); XCTAssertNil(store.preferenceError)
        let recovered = try JSONDecoder().decode(BrowseDocument.self, from: XCTUnwrap(storage.data[account]))
        XCTAssertTrue(recovered.choices(for: BrowseScope()).favoritesOnly)
        XCTAssertEqual(recovered.choices(for: BrowseScope(category: "Episodes")), episode)
    }

    func testUnreadableRegularViewOnlyPatchPreservesRecoveredQueryAndRoot() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-regular-view-recovery", storage = TVBrowseMemoryStorage()
        try await TVParityFixture.control(user, ["reset": true])
        var saved = BrowseChoices(); saved.genreID = "library-drama"; saved.watchStatus = "Watched"; saved.favoritesOnly = true
        let account = try seed(storage, user: user, root: BrowseRootLocation(category: "Series"), scope: BrowseScope(), choices: saved)
        let original = storage.data[account]; storage.unreadable = true
        let store = TVBrowseStore(preferences: BrowsePreferencesStore(storage: storage))
        await store.open(api: TVParityFixture.api(user), destination: nil, searching: false, search: "")
        await store.change(api: TVParityFixture.api(user)) { $0.viewStyle = .list }
        XCTAssertEqual(storage.data[account], original); XCTAssertEqual(storage.writes, 0)
        storage.unreadable = false
        await store.retryPreferences(api: TVParityFixture.api(user))
        let recovered = try JSONDecoder().decode(BrowseDocument.self, from: XCTUnwrap(storage.data[account]))
        XCTAssertEqual(recovered.root.category, "Series")
        var expected = saved; expected.viewStyle = .list
        XCTAssertEqual(recovered.choices(for: BrowseScope()), expected)
        XCTAssertEqual(store.scope.category, "Series"); XCTAssertEqual(store.choices.viewStyle, .grid)
    }
}
