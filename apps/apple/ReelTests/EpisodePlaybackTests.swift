import XCTest
@testable import Reel

final class EpisodePlaybackTests: XCTestCase {
    private func episode(_ id: String, series: String = "series") -> MediaItem {
        MediaItem(Id: id, Name: id, Type: "Episode", SeriesId: series)
    }
    func testNeighborsPreserveServerEpisodeOrderAndBoundaries() {
        let items = [episode("one"), episode("two"), episode("three")]
        XCTAssertNil(EpisodePlayback.neighbors(of: items[0], in: items).previous)
        XCTAssertEqual(EpisodePlayback.neighbors(of: items[0], in: items).next?.id, "two")
        XCTAssertEqual(EpisodePlayback.neighbors(of: items[1], in: items).previous?.id, "one")
        XCTAssertEqual(EpisodePlayback.neighbors(of: items[1], in: items).next?.id, "three")
        XCTAssertNil(EpisodePlayback.neighbors(of: items[2], in: items).next)
    }
    func testMissingCurrentAndForeignSeriesCannotStartUnrelatedEpisode() {
        let current = episode("one")
        XCTAssertNil(EpisodePlayback.neighbors(of: current, in: [episode("two")]).next)
        XCTAssertNil(EpisodePlayback.neighbors(of: current, in: [current, episode("foreign", series: "other")]).next)
        XCTAssertNil(EpisodePlayback.neighbors(of: current, in: [current, current, episode("two")]).next)
    }
    func testSegmentsRequireKnownTypeValidBoundsAndRealDuration() {
        let segments = [
            MediaSegment(Id: "intro", Type: "Intro", StartTicks: 0, EndTicks: 40),
            MediaSegment(Id: "negative", Type: "Intro", StartTicks: -1, EndTicks: 40),
            MediaSegment(Id: "reversed", Type: "Intro", StartTicks: 80, EndTicks: 40),
            MediaSegment(Id: "past-end", Type: "Intro", StartTicks: 80, EndTicks: 120),
            MediaSegment(Id: "unknown", Type: "Advertisement", StartTicks: 0, EndTicks: 40)
        ]
        XCTAssertEqual(EpisodePlayback.segments(segments, duration: 100).map(\.id), ["intro"])
        XCTAssertEqual(EpisodePlayback.segments(segments, duration: nil).map(\.id), ["intro", "past-end"])
    }
}
