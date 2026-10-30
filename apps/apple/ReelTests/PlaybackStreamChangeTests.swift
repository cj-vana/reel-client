import AVFoundation
import XCTest
@testable import Reel

final class PlaybackStreamChangeTests: XCTestCase {
    private let source = MediaSource(Id: "original", MediaStreams: [
        MediaStream(Index: 1, Type: "Audio", DisplayTitle: "English"),
        MediaStream(Index: 7, Type: "Audio", DisplayTitle: "Spanish"),
        MediaStream(Index: 4, Type: "Subtitle", DisplayTitle: "Captions")
    ])
    private func item(_ sources: [MediaSource]) -> MediaItem { MediaItem(Id: "movie", Name: "Movie", MediaSources: sources) }

    func testTrackIndexMustBelongToCurrentVersionAndCorrectType() throws {
        let media = item([source, MediaSource(Id: "other", MediaStreams: [MediaStream(Index: 12, Type: "Audio")])])
        XCTAssertEqual(try PlaybackStreamChange.audio(7).source(in: media, currentSourceID: "original").Id, "original")
        XCTAssertThrowsError(try PlaybackStreamChange.audio(12).source(in: media, currentSourceID: "original"))
        XCTAssertThrowsError(try PlaybackStreamChange.audio(4).source(in: media, currentSourceID: "original"))
        XCTAssertThrowsError(try PlaybackStreamChange.subtitle(7).source(in: media, currentSourceID: "original"))
        XCTAssertThrowsError(try PlaybackStreamChange.audio(-1).source(in: media, currentSourceID: "original"))
    }
    func testSubtitleOffAndServerDefaultsDoNotRequireFakeTrackIndices() throws {
        for change: PlaybackStreamChange in [.audio(nil), .subtitle(nil), .subtitle(-1), .subtitle(4)] {
            XCTAssertEqual(try change.source(in: item([source]), currentSourceID: "original").Id, "original")
        }
        XCTAssertThrowsError(try PlaybackStreamChange.subtitle(-2).source(in: item([source]), currentSourceID: "original"))
    }
    func testAmbiguousMissingAndEmptySourcesAreRejected() {
        for sources in [[source, source], [], [MediaSource(Id: "")]] {
            XCTAssertThrowsError(try PlaybackStreamChange.version("original").source(in: item(sources), currentSourceID: "original"))
        }
        XCTAssertThrowsError(try PlaybackStreamChange.audio(1).source(in: item([source]), currentSourceID: nil))
        XCTAssertThrowsError(try PlaybackStreamChange.version("").source(in: item([MediaSource(Id: "")]), currentSourceID: ""))
    }
    func testDuplicateTrackIdentityIsRejectedInsteadOfPickingFirst() {
        var duplicate = source; duplicate.MediaStreams?.append(MediaStream(Index: 7, Type: "Audio", DisplayTitle: "Another Spanish"))
        XCTAssertThrowsError(try PlaybackStreamChange.audio(7).source(in: item([duplicate]), currentSourceID: "original"))
    }
    @MainActor func testUnavailableSessionCannotChangeChoicesOrResetSleepTimer() async throws {
        let controller = PlaybackController()
        controller.setSleepTimer(minutes: 15)
        let deadline = controller.sleepDeadline
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:19166")!, token: "fixture-boundary", userID: "boundary", deviceID: "player-stream-boundary")
        do {
            try await controller.changeStreamSelection(.version("original"), metadata: item([source]), api: api, quality: .original)
            XCTFail("An idle session cannot accept a stream change.")
        } catch { }
        XCTAssertNil(controller.activeItem)
        XCTAssertEqual(controller.sleepDeadline, deadline)
        controller.stop()
    }
    @MainActor func testPrivateTranscodedVersionChangePreservesPositionPauseAndSleep() async throws {
        try await requireFixture(port: 18966)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-track-output", userID: "tv-track-output", deviceID: "player-options-private", historyEnabled: false)
        let media = try await api.item("movie-1")
        let controller = PlaybackController()
        defer { controller.stop() }
        controller.present(media)
        controller.start(api: api, quality: .original)
        try await ready(controller)
        controller.player.pause()
        controller.seek(to: 80_000_000)
        try await position(8, controller)
        controller.setSleepTimer(minutes: 15)
        let deadline = controller.sleepDeadline
        try await controller.changeStreamSelection(.version("movie-1-alternate"), metadata: media, api: api, quality: .original)
        try await ready(controller)
        try await position(8, controller)
        XCTAssertEqual(controller.player.rate, 0)
        XCTAssertEqual(controller.sleepDeadline, deadline)
        XCTAssertEqual(controller.currentSourceID, "movie-1-alternate")
        XCTAssertFalse(api.recordsHistory)
        controller.retry(api: api, quality: .balanced, bitrate: 8_000_000, initiallyPaused: true)
        try await ready(controller)
        try await position(8, controller)
        XCTAssertEqual(controller.currentBitrate, 8_000_000)
        XCTAssertEqual(controller.player.rate, 0)
        XCTAssertEqual(controller.sleepDeadline, deadline)
    }
    @MainActor func testAudioSubtitleAndOffKeepSelectedAudioPauseAndSleep() async throws {
        try await requireFixture(port: 18969)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18969")!, token: "fixture-tv-multiaudio", userID: "tv-multiaudio", deviceID: "player-options-tracks")
        let media = try await api.item("movie-1")
        let controller = PlaybackController()
        defer { controller.stop() }
        controller.present(media, fromBeginning: true)
        controller.start(api: api, quality: .original)
        try await ready(controller)
        controller.player.pause()
        controller.seek(to: 80_000_000)
        try await position(8, controller)
        controller.setSleepTimer(minutes: 15)
        let deadline = controller.sleepDeadline
        for change: PlaybackStreamChange in [.audio(3), .subtitle(2), .subtitle(-1)] {
            try await controller.changeStreamSelection(change, metadata: media, api: api, quality: .original)
            try await ready(controller)
            try await position(8, controller)
            let selected = try await controller.captureCurrentPlaybackChoices(api: api)
            XCTAssertEqual(selected.audioIndex, 3)
            if case .subtitle(let value) = change { XCTAssertEqual(selected.subtitleIndex, value) }
            XCTAssertEqual(controller.player.rate, 0)
            XCTAssertEqual(controller.sleepDeadline, deadline)
        }
        let active = controller.player.currentItem
        controller.syncPlayManaged = true
        do { try await controller.changeStreamSelection(.audio(1), metadata: media, api: api, quality: .original); XCTFail("Managed sessions must reject local track replacement") }
        catch { }
        XCTAssertTrue(controller.player.currentItem === active)
        controller.syncPlayManaged = false
    }
    @MainActor func testExplicitStartPositionOverridesStaleResumeWhilePreservingSuppliedChapterPosition() async throws {
        try await requireFixture(port: 18966)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-track-output", userID: "tv-track-output", deviceID: "player-start-over", historyEnabled: false)
        var media = try await api.item("movie-1")
        if media.UserData == nil { media.UserData = UserData() }
        media.UserData?.PlaybackPositionTicks = 80_000_000
        let controller = PlaybackController()
        defer { controller.stop() }
        for ticks: Int64 in [0, 80_000_000] {
            controller.present(media, startPositionTicks: ticks)
            controller.start(api: api, quality: .original, initiallyPaused: true)
            try await ready(controller)
            try await position(Double(ticks) / ticksPerSecond, controller)
            XCTAssertEqual(controller.player.rate, 0)
        }
        controller.present(media, fromBeginning: true)
        controller.start(api: api, quality: .original, initiallyPaused: true)
        try await ready(controller)
        try await position(8, controller)
    }
    @MainActor func testAccountMismatchCannotReplaceAnActiveStream() async throws {
        try await requireFixture(port: 18969)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18969")!, token: "fixture-tv-multiaudio", userID: "tv-multiaudio", deviceID: "player-account-fence")
        let other = JellyfinAPI(server: api.server, token: "fixture-other", userID: "other", deviceID: "player-account-fence")
        let media = try await api.item("movie-1")
        let controller = PlaybackController()
        defer { controller.stop() }
        controller.present(media); controller.start(api: api, quality: .original)
        try await ready(controller)
        controller.setSleepTimer(minutes: 15)
        let native = controller.player.currentItem, deadline = controller.sleepDeadline
        do {
            try await controller.changeStreamSelection(.audio(3), metadata: media, api: other, quality: .original)
            XCTFail("A different account cannot replace the current stream.")
        } catch { }
        XCTAssertTrue(controller.player.currentItem === native)
        XCTAssertEqual(controller.sleepDeadline, deadline)
    }
    @MainActor func testPreparationTimeoutRetainsAttemptedQualityForRetry() async throws {
        try await requireFixture(port: 18966)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-player-timeout", userID: "tv-player-timeout", deviceID: "player-timeout")
        let media = try await api.item("movie-1")
        try await setPreparationDelay(true)
        let controller = PlaybackController()
        defer { controller.stop() }
        controller.present(media, fromBeginning: true)
        controller.start(api: api, quality: .balanced, bitrate: 8_000_000)
        for _ in 0..<350 {
            if controller.error != nil && !controller.preparing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await setPreparationDelay(false)
        XCTAssertNotNil(controller.error)
        XCTAssertFalse(controller.preparing)
        XCTAssertEqual(controller.currentBitrate, 8_000_000)
        controller.retry(api: api, quality: .balanced, bitrate: controller.currentBitrate)
        try await ready(controller)
        XCTAssertNil(controller.error)
        XCTAssertEqual(controller.currentBitrate, 8_000_000)
    }
    @MainActor private func setPreparationDelay(_ enabled: Bool) async throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18966/qa/episode-control")!)
        request.httpMethod = "POST"
        request.setValue(ProcessInfo.processInfo.environment["REEL_TV_QA_OWNER"], forHTTPHeaderField: "X-Reel-TV-Owner")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["delayPreparation": enabled])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    @MainActor func testContentChangeDuringCaptureRejectsStaleStreamSelection() async throws {
        try await requireFixture(port: 18969)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18969")!, token: "fixture-tv-multiaudio", userID: "tv-multiaudio", deviceID: "player-content-fence")
        let media = try await api.item("movie-1")
        var suspend = false
        var gate: CheckedContinuation<Void, Never>?
        let controller = PlaybackController(beforeAudioCapture: {
            if suspend { await withCheckedContinuation { gate = $0 } }
        })
        defer { gate?.resume(); controller.stop() }
        controller.present(media); controller.start(api: api, quality: .original)
        try await ready(controller)
        suspend = true
        let change = Task { try await controller.changeStreamSelection(.audio(3), metadata: media, api: api, quality: .original) }
        for _ in 0..<100 { if gate != nil { break }; try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(gate)
        let replacement = MediaItem(Id: "replacement-item", Name: "Replacement", MediaSources: media.MediaSources)
        controller.present(replacement)
        gate?.resume(); gate = nil
        switch await change.result {
        case .success: XCTFail("A captured choice must not mutate newly presented content.")
        case .failure: break
        }
        XCTAssertEqual(controller.activeItem?.id, "replacement-item")
        XCTAssertNil(controller.currentMediaSource)
    }
    @MainActor private func requireFixture(port: Int) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let owner = environment["REEL_TV_QA_OWNER"], !owner.isEmpty,
              environment["SIMULATOR_UDID"] == environment["REEL_PLAYER_QA_DEVICE_UDID"],
              environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("Reel QA Improvements Player ") == true else {
            throw XCTSkip("Requires the exact owned player simulator and synthetic fixture identity.")
        }
        let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/qa/tv-identity")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(identity["owner"] as? String, owner)
        XCTAssertEqual(identity["port"] as? Int, port)
    }
    @MainActor private func ready(_ controller: PlaybackController) async throws {
        for _ in 0..<200 {
            if !controller.preparing && !controller.resolvingReplacement && controller.player.currentItem?.status == .readyToPlay { return }
            if let error = controller.error { XCTFail(error); throw ReelError.noStream }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native playback did not become ready"); throw ReelError.noStream
    }
    @MainActor private func position(_ expected: Double, _ controller: PlaybackController) async throws {
        for _ in 0..<80 {
            if abs(controller.player.currentTime().seconds - expected) < 0.2 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(controller.player.currentTime().seconds, expected, accuracy: 0.2)
    }

}
