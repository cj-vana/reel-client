import AVFoundation
import XCTest
@testable import ReelTV

@MainActor final class TVCoreTests: XCTestCase {
    private func api(_ name: String = "tv-unit") -> JellyfinAPI {
        JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-" + name, userID: name, deviceID: "tv-qa-" + name)
    }

    func testRuntimeAndTimeLeftLabels() {
        let second: Int64 = 10_000_000
        XCTAssertEqual(TVMetadata.runtime(6_720 * second), "1h 52m")
        XCTAssertEqual(TVMetadata.runtime(3_600 * second), "1h")
        XCTAssertEqual(TVMetadata.runtime(2_880 * second), "48m")
        XCTAssertEqual(TVMetadata.runtime(14 * second), "14s")
        XCTAssertEqual(TVMetadata.runtime(second / 3), "1s", "Very short media never reads as zero or a fraction of a minute.")
        XCTAssertNil(TVMetadata.runtime(0))
        XCTAssertNil(TVMetadata.runtime(nil))

        var movie = MediaItem(Id: "movie", Name: "Movie")
        movie.RunTimeTicks = 6_720 * second
        XCTAssertNil(TVMetadata.remaining(movie), "Nothing is left to report before playback starts.")
        movie.UserData = UserData(PlaybackPositionTicks: 1_800 * second)
        XCTAssertEqual(TVMetadata.remaining(movie), "1h 22m left")
        movie.UserData = UserData(PlaybackPositionTicks: 6_720 * second)
        XCTAssertNil(TVMetadata.remaining(movie))
    }

    func testServerAndCredentialBoundaries() throws {
        XCTAssertThrowsError(try JellyfinAPI.normalize("http://remote.example"))
        XCTAssertThrowsError(try JellyfinAPI.normalize("https://user:password@example.com"))
        XCTAssertEqual(try JellyfinAPI.normalize("https://example.com/jellyfin/").path, "/jellyfin")
        let api = api()
        XCTAssertNil(api.imageRequest(MediaItem(Id: "fixture", Name: "Fixture"), backdrop: false, width: 500).url?.query?.range(of: "fixture-tv-unit"))
        XCTAssertThrowsError(try GatewayHeaderStore.validated([GatewayHeader(name: "Authorization", value: "secret")]))
    }

    func testSimulatorProtectsNonloopbackMutationsBeforeNetwork() async throws {
        let api = JellyfinAPI(server: URL(string: "https://example.invalid")!, token: "qa-only", userID: "qa", deviceID: "tv-only")
        XCTAssertTrue(api.isSimulatorPreview)
        do { try await api.favorite("fixture", value: true); XCTFail("Mutation escaped preview") }
        catch { XCTAssertEqual(error as? ReelError, .previewProtected) }
    }

    func testActualFixtureLibraryPaginationAndSeasonIdentity() async throws {
        let store = TVBrowseStore()
        await store.load(api: api(), filter: .all)
        XCTAssertNil(store.error); XCTAssertEqual(store.items.count, 60); XCTAssertTrue(store.hasMore)
        await store.load(api: api(), filter: .all, append: true)
        XCTAssertEqual(store.items.count, 75); XCTAssertEqual(Set(store.items.map(\.id)).count, 75); XCTAssertFalse(store.hasMore)
        let detail = TVDetailStore()
        await detail.load(id: "series-7", api: api())
        XCTAssertNil(detail.error); XCTAssertEqual(detail.seasons.count, 2); XCTAssertEqual(detail.episodes.count, 3)
        detail.seasonID = "season-2"
        await detail.loadEpisodes(api: api())
        XCTAssertTrue(detail.episodes.allSatisfy { $0.ParentIndexNumber == 2 })
    }

    func testHomeEmptyAndPartialFailureRecovery() async throws {
        try await TVFixture.reset()
        let empty = TVHomeStore()
        await empty.load(api: api("empty"))
        XCTAssertNil(empty.featured); XCTAssertNil(empty.error); XCTAssertFalse(empty.loading)
        let partial = TVHomeStore()
        await partial.load(api: api("flaky"))
        XCTAssertNotNil(partial.featured); XCTAssertTrue(partial.partial)
        await partial.load(api: api("flaky"))
        XCTAssertNotNil(partial.featured); XCTAssertFalse(partial.partial)
    }

    func testLateDetailResponseCannotReplaceANewerTitle() async throws {
        let store = TVDetailStore()
        let old = Task { await store.load(id: "movie-1", api: api("slow")) }
        try await Task.sleep(for: .milliseconds(60))
        await store.load(id: "movie-3", api: api("tv-fresh"))
        await old.value
        XCTAssertEqual(store.item?.id, "movie-3")
        XCTAssertFalse(store.loading)
    }

    func testSearchAndFiltersComeFromTheRealContract() async throws {
        let store = TVBrowseStore()
        await store.load(api: api(), filter: .series)
        XCTAssertEqual(store.items.count, 3)
        XCTAssertTrue(store.items.allSatisfy(\.isSeries))
        await store.load(api: api(), filter: .series, search: "Out of the Blue")
        XCTAssertEqual(store.items.map(\.id), ["series-7"])
        await store.load(api: api(), filter: .all, search: "Out of the Blue")
        XCTAssertEqual(Set(store.items.map(\.id)), ["series-7", "episode-1-1", "episode-1-2", "episode-1-3"])
        await store.load(api: api(), filter: .all, search: "Nothing matches this title")
        XCTAssertTrue(store.items.isEmpty)
    }

    func testRealNativeDirectAndHLSDecodeSeekAndCleanup() async throws {
        try await TVFixture.reset()
        let api = api("tv-native")
        var item = try await api.item("movie-3")
        item.UserData = UserData(PlaybackPositionTicks: 50_000_000)
        let controller = PlaybackController()
        defer { controller.stop() }
        for quality in [StreamQuality.original, .dataSaver] {
            try await api.post("Sessions/Playing/Progress", body: ["ItemId": item.id, "PositionTicks": Int64(50_000_000)])
            controller.present(item)
            controller.start(api: api, quality: quality)
            for _ in 0..<150 {
                if !controller.preparing { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(controller.error)
            XCTAssertEqual(controller.player.currentItem?.status, .readyToPlay)
            XCTAssertEqual(controller.method, quality == .original ? "DirectPlay" : "Transcode")
            for _ in 0..<40 {
                if controller.player.currentTime().seconds > 5.1 { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertGreaterThan(controller.player.currentTime().seconds, 5.1)
            XCTAssertGreaterThan(controller.player.currentItem?.presentationSize.width ?? 0, 0, "Playback must actually expose a decoded video size.")
            controller.seek(to: 80_000_000)
            for _ in 0..<40 {
                if abs(controller.player.currentTime().seconds - 8) < 0.5 { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertEqual(controller.player.currentTime().seconds, 8, accuracy: 0.6)
            controller.stop(); await controller.flushReports()
        }
        let reports = try await TVFixture.reports().filter { $0["user"] as? String == "tv-native" }
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Sessions/Playing" })
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Sessions/Playing/Stopped" })
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Videos/ActiveEncodings" })
    }

    func testPrivateNativeHLSStillCleansEncoderWithoutHistory() async throws {
        try await TVFixture.reset()
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-private", userID: "tv-private", deviceID: "tv-private-qa", historyEnabled: false)
        PlaybackReporter.updatePrivacy(api: api)
        let item = try await api.item("movie-3")
        let controller = PlaybackController()
        defer { controller.stop() }
        controller.present(item)
        controller.start(api: api, quality: .dataSaver)
        for _ in 0..<150 {
            if !controller.preparing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.method, "Transcode")
        for _ in 0..<60 {
            if controller.player.currentTime().seconds > 0.3 { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(controller.player.currentTime().seconds, 0.3)
        XCTAssertGreaterThan(controller.player.currentItem?.presentationSize.width ?? 0, 0)
        controller.stop(); await controller.flushReports()
        let reports = try await TVFixture.reports().filter { $0["user"] as? String == "tv-private" }
        XCTAssertFalse(reports.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Videos/ActiveEncodings" })
    }

    func testFailedReportAndCleanupSurviveReporterReplacementAndStayAccountScoped() async throws {
        try await TVFixture.reset()
        try await TVFixture.control(failReports: true, failCleanup: true)
        let api = api("tv-report-recovery")
        let reporter = PlaybackReporter()
        reporter.enqueue(api: api, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "movie-3", "PositionTicks": Int64(80_000_000), "PlaySessionId": "tv-report-session", "CleanupEncoder": true], cleanup: true)
        await reporter.flush()
        let saved = try XCTUnwrap(UserDefaults.standard.data(forKey: "pendingWatchReports"))
        let serialized = try XCTUnwrap(String(data: saved, encoding: .utf8))
        XCTAssertTrue(serialized.contains("tv-report-recovery"))
        XCTAssertFalse(serialized.contains("fixture-tv-report-recovery"), "The persisted journal must never contain the account token.")
        try await TVFixture.control(failReports: false, failCleanup: false)
        let restored = PlaybackReporter()
        await restored.retryStored(api: self.api("tv-other-account"))
        let otherAccountReports = try await TVFixture.reports()
        XCTAssertFalse(otherAccountReports.contains { $0["user"] as? String == "tv-report-recovery" && $0["path"] as? String == "/Sessions/Playing/Stopped" })
        await restored.retryStored(api: api)
        let reports = try await TVFixture.reports().filter { $0["user"] as? String == "tv-report-recovery" }
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Sessions/Playing/Stopped" && ($0["body"] as? [String: Any])?["PositionTicks"] as? Int == 80_000_000 })
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Videos/ActiveEncodings" })
    }

    func testSelectedSpeedChangesActualNativeRateAndKeepsPausedPlaybackPaused() async throws {
        try await TVFixture.reset()
        let api = api("tv-speed")
        let controller = PlaybackController()
        controller.present(try await api.item("movie-3"))
        controller.start(api: api, quality: .original)
        for _ in 0..<150 {
            if controller.isPlaying { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(controller.error)
        XCTAssertTrue(controller.isPlaying)
        for speed in [Float(0.75), 1, 1.25, 1.5, 2] {
            controller.speed = speed
            XCTAssertEqual(controller.player.rate, speed)
        }
        controller.player.pause()
        for _ in 0..<30 {
            if !controller.isPlaying { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(controller.isPlaying)
        controller.speed = 1.5
        XCTAssertEqual(controller.player.rate, 0)
        controller.stop(); await controller.flushReports()
    }
}
