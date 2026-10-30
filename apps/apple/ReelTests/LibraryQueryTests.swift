import XCTest
@testable import Reel

final class LibraryQueryTests: XCTestCase {
    func testTitleUsesAscendingServerOrder() {
        let q = LibraryQuery().parameters(start: 0)
        XCTAssertEqual(q["sortBy"], "SortName")
        XCTAssertEqual(q["sortOrder"], "Ascending")
        XCTAssertEqual(q["enableTotalRecordCount"], "true")
    }

    func testRecentlyAddedUsesNewestFirstAndTitleForTies() {
        let q = LibraryQuery(sort: .recentlyAdded).parameters(start: 60)
        XCTAssertEqual(q["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(q["sortOrder"], "Descending,Ascending")
        XCTAssertEqual(q["startIndex"], "60")
    }

    func testReleaseYearUsesNewestFirstAndTitleForTies() {
        let q = LibraryQuery(sort: .releaseYear).parameters(start: 0)
        XCTAssertEqual(q["sortBy"], "ProductionYear,SortName")
        XCTAssertEqual(q["sortOrder"], "Descending,Ascending")
    }

    func testEachCategoryUsesItsServerType() {
        for (category, types) in [("All", "Movie,Series"), ("Movies", "Movie"), ("Series", "Series"), ("Episodes", "Episode"), ("Favorites", "Movie,Series"), ("Collections", "BoxSet"), ("Playlists", "Playlist")] {
            let q = LibraryQuery(category: category).parameters(start: 0)
            XCTAssertEqual(q["includeItemTypes"], types, category)
            XCTAssertEqual(q["filters"], category == "Favorites" ? "IsFavorite" : nil)
        }
    }

    func testSeriesLatestEpisodeAddedIsDistinctFromSeriesCreated() {
        let episodeAdded = LibraryQuery(category: "Series", sort: .latestEpisodeAdded).parameters(start: 60)
        let seriesAdded = LibraryQuery(category: "Series", sort: .recentlyAdded).parameters(start: 60)
        XCTAssertEqual(episodeAdded["sortBy"], "DateLastContentAdded,SortName")
        XCTAssertEqual(episodeAdded["sortOrder"], "Descending,Ascending")
        XCTAssertEqual(episodeAdded["includeItemTypes"], "Series")
        XCTAssertEqual(seriesAdded["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(seriesAdded["startIndex"], episodeAdded["startIndex"])
    }

    func testNewestEpisodeFeedUsesIndividualEpisodesAndServerDateOrder() {
        let query = LibraryQuery(category: "Episodes", sort: .recentlyAdded).parameters(start: 0, limit: 18)
        XCTAssertEqual(query["includeItemTypes"], "Episode")
        XCTAssertEqual(query["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(query["sortOrder"], "Descending,Ascending")
        XCTAssertEqual(query["limit"], "18")
        XCTAssertNil(query["groupItems"], "The Items endpoint returns individual DTOs; Latest grouping is not used.")
    }

    func testEpisodeAddedSortCannotLeakIntoMovieOrEpisodeQueries() {
        for category in ["All", "Movies", "Episodes", "Collections"] {
            XCTAssertEqual(LibraryQuery(category: category, sort: .latestEpisodeAdded).parameters(start: 0)["sortBy"], "DateCreated,SortName", category)
        }
    }

    func testHomeWithOnlyNewEpisodesIsNotEmpty() {
        XCTAssertTrue(HomeData().isEmpty)
        XCTAssertFalse(HomeData(episodes: [MediaItem(Id: "episode", Name: "Episode", Type: "Episode")]).isEmpty)
    }

    func testCombinedFiltersSurvivePagination() {
        let options = LibraryQuery(search: "  Quiet  ", category: "Favorites", sort: .recentlyAdded, libraryID: "films", genreID: "drama", watchStatus: "Unwatched")
        var first = options.parameters(start: 0)
        var next = options.parameters(start: 60)
        XCTAssertEqual(first.removeValue(forKey: "startIndex"), "0")
        XCTAssertEqual(next.removeValue(forKey: "startIndex"), "60")
        XCTAssertEqual(first, next)
        XCTAssertEqual(first["parentId"], "films")
        XCTAssertEqual(first["genreIds"], "drama")
        XCTAssertEqual(first["searchTerm"], "Quiet")
        XCTAssertEqual(first["isPlayed"], "false")
        XCTAssertEqual(first["filters"], "IsFavorite")
    }

    func testWatchStatusAnyOmitsRestriction() {
        XCTAssertNil(LibraryQuery().parameters(start: 0)["isPlayed"])
        XCTAssertEqual(LibraryQuery(watchStatus: "Watched").parameters(start: 0)["isPlayed"], "true")
        XCTAssertEqual(LibraryQuery(watchStatus: "Unwatched").parameters(start: 0)["isPlayed"], "false")
    }

    func testSearchRequiresANonblankTermAndIncludesEpisodes() {
        XCTAssertFalse(LibraryQuery(search: " \n ", isSearch: true).canLoad)
        let options = LibraryQuery(search: "  Blue\n", isSearch: true)
        XCTAssertTrue(options.canLoad)
        XCTAssertEqual(options.parameters(start: 0)["includeItemTypes"], "Movie,Series,Episode")
        XCTAssertEqual(options.parameters(start: 0)["searchTerm"], "Blue")
        XCTAssertTrue(LibraryQuery().canLoad)
    }

    func testCollectionScopeOverridesLibraryAndIncludesItsEntries() {
        let q = LibraryQuery(libraryID: "films", parentID: "collection", parentType: "BoxSet").parameters(start: 0)
        XCTAssertEqual(q["parentId"], "collection")
        XCTAssertEqual(q["includeItemTypes"], "Movie,Series,Episode,Video,MusicVideo,BoxSet,Playlist")
    }

    func testPlaylistOmitsUnsupportedSortSearchAndFilters() {
        let options = LibraryQuery(search: "ignored", category: "Favorites", sort: .recentlyAdded, libraryID: "films", genreID: "drama", watchStatus: "Watched", parentID: "playlist", parentType: "Playlist")
        XCTAssertEqual(options.path, "Playlists/playlist/Items")
        XCTAssertEqual(options.parameters(start: 60), ["startIndex": "60", "limit": "60", "enableTotalRecordCount": "true"])
    }

    func testPaginationDeduplicatesWithinAndAcrossPagesUsingRawOffset() {
        let a = MediaItem(Id: "a", Name: "A")
        let b = MediaItem(Id: "b", Name: "B")
        var page = LibraryPagination()
        page.append(ItemPage(Items: [a, a, b], TotalRecordCount: 5), playlist: false)
        XCTAssertEqual(page.items.map(\.id), ["a", "b"])
        XCTAssertEqual(page.nextIndex, 3)
        XCTAssertTrue(page.hasMore)
        page.append(ItemPage(Items: [b, MediaItem(Id: "c", Name: "C")], TotalRecordCount: 5), playlist: false)
        XCTAssertEqual(page.items.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(page.nextIndex, 5)
        XCTAssertFalse(page.hasMore)
    }

    func testPlaylistRetainsRepeatedMediaWithDistinctEntryIDs() {
        var a = MediaItem(Id: "a", Name: "A"); a.PlaylistItemId = "entry-1"
        var b = a; b.PlaylistItemId = "entry-2"
        var page = LibraryPagination()
        page.append(ItemPage(Items: [a, b], TotalRecordCount: 2), playlist: true)
        XCTAssertEqual(page.items.map(\.listingID), ["entry-1", "entry-2"])
        XCTAssertEqual(page.items.map(\.id), ["a", "a"])
    }

    func testPaginationWithoutTotalProbesNextPageAndStopsOnEmpty() {
        var page = LibraryPagination()
        page.append(ItemPage(Items: [MediaItem(Id: "a", Name: "A")], TotalRecordCount: nil), playlist: false, limit: 1)
        XCTAssertNil(page.total)
        XCTAssertTrue(page.hasMore)
        page.append(ItemPage(Items: [], TotalRecordCount: 90), playlist: false)
        XCTAssertFalse(page.hasMore, "A stale server total must not cause endless Load more.")
    }

    func testPageBoundsAreClamped() {
        XCTAssertEqual(LibraryQuery().parameters(start: -1, limit: 500)["startIndex"], "0")
        XCTAssertEqual(LibraryQuery().parameters(start: 0, limit: 500)["limit"], "200")
        XCTAssertEqual(LibraryQuery().parameters(start: 0, limit: 0)["limit"], "1")
    }
}
