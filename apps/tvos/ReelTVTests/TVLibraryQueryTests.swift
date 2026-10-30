import Foundation
import XCTest
@testable import ReelTV

final class TVLibraryQueryTests: XCTestCase {
    func testEpisodeFavoriteGenreWatchLibraryComposeBeforePaging() {
        var query = LibraryQuery()
        query.category = "Episodes"; query.sort = .recentlyAdded; query.direction = .descending
        query.libraryID = "shows"; query.genreID = "drama"; query.watchStatus = "Unwatched"; query.favoritesOnly = true; query.search = " North "
        let values = query.parameters(start: 120)
        XCTAssertEqual(values["includeItemTypes"], "Episode")
        XCTAssertEqual(values["sortBy"], "DateCreated,SortName")
        XCTAssertEqual(values["sortOrder"], "Descending,Ascending")
        XCTAssertEqual(values["genreIds"], "drama"); XCTAssertEqual(values["parentId"], "shows")
        XCTAssertEqual(values["isPlayed"], "false"); XCTAssertEqual(values["filters"], "IsFavorite")
        XCTAssertEqual(values["searchTerm"], "North"); XCTAssertEqual(values["startIndex"], "120")
        XCTAssertEqual(values["fields"], "Overview,Genres,DateCreated,DateLastMediaAdded")
    }

    func testSeriesUpdatedSortUsesTokenNotDTOFieldAndExplicitTieDirection() {
        var query = LibraryQuery(category: "Series", sort: .latestEpisodeAdded)
        XCTAssertEqual(query.parameters(start: 0)["sortBy"], "DateLastContentAdded,SortName")
        XCTAssertEqual(query.parameters(start: 0)["sortOrder"], "Descending,Ascending")
        query.direction = .ascending
        XCTAssertEqual(query.parameters(start: 60)["sortOrder"], "Ascending,Ascending")
        query.sort = .recentlyAdded
        XCTAssertEqual(query.parameters(start: 0)["sortBy"], "DateCreated,SortName")
        query.category = "Episodes"; query.sort = .latestEpisodeAdded
        XCTAssertEqual(query.parameters(start: 0)["sortBy"], "DateCreated,SortName")
        query.sort = .title; query.direction = .descending
        XCTAssertEqual(query.parameters(start: 0)["sortOrder"], "Descending")
    }

    func testPlaylistKeepsEndpointOrderAndRepeatedEntryIdentity() {
        var query = LibraryQuery()
        query.parentID = "list"; query.parentType = "Playlist"; query.favoritesOnly = true
        query.genreID = "ignored"; query.search = "ignored"; query.sort = .recentlyAdded
        XCTAssertEqual(query.path, "Playlists/list/Items")
        XCTAssertEqual(query.parameters(start: 60), ["startIndex": "60", "limit": "60", "enableTotalRecordCount": "true"])
        var first = MediaItem(Id: "same", Name: "Repeated title"); first.PlaylistItemId = "entry-one"
        var second = first; second.PlaylistItemId = "entry-two"
        var page = LibraryPagination()
        page.append(ItemPage(Items: [first, second], TotalRecordCount: 2), playlist: true)
        XCTAssertEqual(page.items.map(\.listingID), ["entry-one", "entry-two"])
        XCTAssertFalse(page.hasMore)
    }

    func testPlaylistWithoutOptionalServerEntryTagsStillHasDistinctDisplayRows() {
        let item = MediaItem(Id: "same", Name: "Repeated title")
        let first = TVBrowseRow(item: item, position: 0, playlist: true)
        let second = TVBrowseRow(item: item, position: 1, playlist: true)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.accessibilityID, second.accessibilityID)
        XCTAssertEqual(first.item.id, second.item.id, "UI identity must not replace the actual playback item ID")
        XCTAssertEqual(TVBrowseRow(item: item, position: 0, playlist: false).id, .item("same"))
    }

    func testRawCursorDoesNotRewindWhenBoundaryRecordsRepeat() {
        var page = LibraryPagination()
        let items = (0..<60).map { MediaItem(Id: String($0), Name: "Title \($0)") }
        page.append(ItemPage(Items: items, TotalRecordCount: 121), playlist: false)
        let overlap = [items[59]] + (61..<120).map { MediaItem(Id: String($0), Name: "Title \($0)") }
        page.append(ItemPage(Items: overlap, TotalRecordCount: 121), playlist: false)
        XCTAssertEqual(page.items.count, 119)
        XCTAssertEqual(page.nextIndex, 120)
        XCTAssertTrue(page.hasMore)
        page.append(ItemPage(Items: [MediaItem(Id: "120", Name: "Last")], TotalRecordCount: 121), playlist: false)
        XCTAssertEqual(page.nextIndex, 121); XCTAssertFalse(page.hasMore)
    }

    func testEpisodeMetadataDoesNotInventMissingNumbersAndDTOFieldsStayDistinct() throws {
        let missing = MediaItem(Id: "missing", Name: "No numbered metadata", Type: "Episode")
        XCTAssertEqual(missing.episodeNumberText, "")
        XCTAssertFalse(missing.subtitle.contains("S1")); XCTAssertFalse(missing.subtitle.contains("E1"))
        let special = MediaItem(Id: "special", Name: "Special", Type: "Episode", IndexNumber: 0, ParentIndexNumber: 0)
        XCTAssertEqual(special.episodeNumberText, "S0 E0")
        let data = Data(#"{"Id":"series","Name":"An old series","Type":"Series","DateCreated":"2020-01-01T00:00:00Z","DateLastMediaAdded":"2026-10-25T00:00:00.0000000Z"}"#.utf8)
        let decoded = try JSONDecoder().decode(MediaItem.self, from: data)
        XCTAssertNotNil(decoded.addedDateText); XCTAssertNotNil(decoded.lastMediaAddedDateText)
        XCTAssertNotEqual(decoded.addedDateText, decoded.lastMediaAddedDateText)
        XCTAssertNil(missing.addedDateText); XCTAssertNil(missing.lastMediaAddedDateText)
        for stamp in ["0001-01-01T00:00:00Z", "2026-02-31T00:00:00Z", "2026-10-25T25:00:00Z", "not-a-server-date"] {
            var invalid = decoded; invalid.DateCreated = stamp; invalid.DateLastMediaAdded = stamp
            XCTAssertNil(invalid.addedDateText, stamp); XCTAssertNil(invalid.lastMediaAddedDateText, stamp)
        }
    }
}
