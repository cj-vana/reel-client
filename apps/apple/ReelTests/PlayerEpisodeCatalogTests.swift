import XCTest
@testable import Reel

final class PlayerEpisodeCatalogTests: XCTestCase {
    func testOnlyUnambiguousEpisodesFromTheCurrentSeriesCanBeChosen() {
        let first = MediaItem(Id: "first", Name: "First", Type: "Episode", SeriesId: "series")
        let last = MediaItem(Id: "last", Name: "Last", Type: "Episode", SeriesId: "series")
        let duplicate = MediaItem(Id: "duplicate", Name: "Duplicate", Type: "Episode", SeriesId: "series")
        let response = [first,
            MediaItem(Id: "foreign", Name: "Foreign", Type: "Episode", SeriesId: "other"),
            MediaItem(Id: "movie", Name: "Movie", Type: "Movie", SeriesId: "series"),
            MediaItem(Id: "unknown", Name: "Unknown", Type: "Episode"),
            MediaItem(Id: "", Name: "No ID", Type: "Episode", SeriesId: "series"),
            duplicate, duplicate, last]
        XCTAssertEqual(PlayerEpisodeCatalog.episodes(in: response, seriesID: "series").map(\.id), ["first", "last"])
        XCTAssertTrue(PlayerEpisodeCatalog.episodes(in: response, seriesID: "unrelated").isEmpty)
    }

    func testSeasonsPreserveServerOrderAndAllowMissingParentMetadata() {
        let second = MediaItem(Id: "second", Name: "Season 2", Type: "Season", SeriesId: "series")
        let specials = MediaItem(Id: "specials", Name: "Specials", Type: "Season")
        let duplicate = MediaItem(Id: "duplicate", Name: "Duplicate", Type: "Season")
        let response = [second, specials,
            MediaItem(Id: "foreign", Name: "Foreign", Type: "Season", SeriesId: "other"),
            MediaItem(Id: "episode", Name: "Episode", Type: "Episode", SeriesId: "series"),
            MediaItem(Id: "", Name: "No ID", Type: "Season"), duplicate, duplicate]
        XCTAssertEqual(PlayerEpisodeCatalog.seasons(in: response, seriesID: "series").map(\.id), ["second", "specials"])
        XCTAssertTrue(PlayerEpisodeCatalog.seasons(in: [], seriesID: "series").isEmpty)
    }
}
