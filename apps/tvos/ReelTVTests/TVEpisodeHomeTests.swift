import XCTest
@testable import ReelTV

@MainActor final class TVEpisodeHomeTests: XCTestCase {
    func testIndividualEpisodesUseSharedRecencyQueryAndOpenExactIdentity() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-episode-home"
        try await TVParityFixture.control(user, ["reset": true])
        let store = TVHomeStore()
        await store.load(api: TVParityFixture.api(user))
        XCTAssertEqual(store.episodes.count, 12)
        XCTAssertEqual(Set(store.episodes.map(\.id)).count, 12)
        XCTAssertLessThan(Set(store.episodes.compactMap(\.SeriesId)).count, store.episodes.count)
        let requests = try await TVParityFixture.requests(user)
        let query = try XCTUnwrap(requests.first { ($0["query"] as? [String: Any])?["includeitemtypes"] as? String == "Episode" }?["query"] as? [String: String])
        XCTAssertEqual(query["sortby"], "DateCreated,SortName")
        XCTAssertEqual(query["sortorder"], "Descending,Ascending")
        XCTAssertEqual(query["startindex"], "0")
        XCTAssertEqual(query["limit"], "18")
        XCTAssertTrue(query["fields"]?.contains("DateCreated") == true)
        XCTAssertTrue(store.episodes.allSatisfy { $0.Type == "Episode" })
        let item = try XCTUnwrap(store.episodes.first)
        let detail = try await TVParityFixture.api(user).item(item.id)
        XCTAssertEqual(detail.id, item.id)
        XCTAssertEqual(detail.SeriesId, item.SeriesId)
    }

    func testHealthyShelvesPublishWhileEpisodesAreHeldAndFailureRetriesLocally() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-episode-isolation"
        try await TVParityFixture.control(user, ["reset": true, "failEpisodeFeed": 1])
        try await TVParityFixture.control(user, ["holdEpisodeFeed": true], options: true)
        let store = TVHomeStore()
        let load = Task { await store.load(api: TVParityFixture.api(user)) }
        for _ in 0..<500 {
            if !store.movies.isEmpty { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(store.movies.isEmpty)
        XCTAssertTrue(store.episodesLoading, "A held optional episode feed must not gate healthy films")
        let filmIDs = store.movies.map(\.id)
        try await TVParityFixture.control(user, ["holdEpisodeFeed": false], options: true)
        await load.value
        XCTAssertNotNil(store.episodeError)
        XCTAssertEqual(store.movies.map(\.id), filmIDs)
        try await TVParityFixture.control(user, ["delayEpisodeFeedMs": 0])
        await store.retryEpisodes(api: TVParityFixture.api(user))
        XCTAssertNil(store.episodeError)
        XCTAssertEqual(store.episodes.count, 12)
        XCTAssertEqual(store.movies.map(\.id), filmIDs)
    }

    func testCancelledEpisodeResponseCannotOverwriteNewAccount() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let oldUser = "library-tv-episode-old", newUser = "library-tv-episode-new"
        try await TVParityFixture.control(oldUser, ["reset": true, "delayEpisodeFeedMs": 900, "failEpisodeFeed": 1])
        try await TVParityFixture.control(newUser, ["reset": true, "empty": true])
        let store = TVHomeStore()
        let old = Task { await store.load(api: TVParityFixture.api(oldUser)) }
        try await Task.sleep(for: .milliseconds(80))
        store.cancel()
        await store.load(api: TVParityFixture.api(newUser))
        await old.value
        XCTAssertTrue(store.episodes.isEmpty)
        XCTAssertTrue(store.movies.isEmpty)
        XCTAssertNil(store.episodeError)
        XCTAssertFalse(store.loading)
    }

    func testConcurrentEpisodeRetryIsDisabledWithoutDuplicateHTTPFetch() async throws {
        _ = try await TVParityFixture.requireOwnedHost()
        let user = "library-tv-episode-double-retry"
        try await TVParityFixture.control(user, ["reset": true])
        let store = TVHomeStore()
        await store.load(api: TVParityFixture.api(user))
        try await TVParityFixture.control(user, ["delayEpisodeFeedMs": 900])
        let first = Task { await store.retryEpisodes(api: TVParityFixture.api(user)) }
        var began = false
        for _ in 0..<100 {
            let rows = try await TVParityFixture.requests(user)
            if rows.filter({ ($0["query"] as? [String: String])?["limit"] == "18" && ($0["query"] as? [String: String])?["includeitemtypes"] == "Episode" }).count == 2 { began = true; break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(began); XCTAssertTrue(store.episodesLoading)
        await store.retryEpisodes(api: TVParityFixture.api(user))
        await first.value
        let rows = try await TVParityFixture.requests(user)
        XCTAssertEqual(rows.filter { ($0["query"] as? [String: String])?["limit"] == "18" && ($0["query"] as? [String: String])?["includeitemtypes"] == "Episode" }.count, 2)
        XCTAssertFalse(store.episodesLoading); XCTAssertNil(store.episodeError)
    }
}
