import AVFoundation
import XCTest
@testable import ReelTV

@MainActor final class TVPausedStartupTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:18968")!

    private func api(_ user: String = "tv-track-output") -> JellyfinAPI {
        let value = JellyfinAPI(server: server, token: "fixture-" + user, userID: user, deviceID: "tv-paused-startup-qa", historyEnabled: true)
        PlaybackReporter.updatePrivacy(api: value)
        return value
    }

    func testExplicitPausedStartupKeepsSeekPositionWithoutUnpausedEventOrTimeAdvance() async throws {
        try await run { player, api in
            player.present(try await api.item("movie-1"), subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.paused(player, at: 8)
            try await self.assertPausedHistory()
        }
    }

    func testPausedMetadataPreparationFallbackRetainsPauseAndEightSecondPosition() async throws {
        try await run { player, api in
            try await self.control(["subtitleMetadataFailure": true])
            player.present(try await api.item("movie-1"), subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.paused(player, at: 8)
            try await self.assertFallbackAndPausedHistory()
        }
    }

    func testPausedAVItemFailureFallbackRetainsPauseAndEightSecondPosition() async throws {
        try await run { player, api in
            try await self.control(["subtitleMetadataFailure": true])
            // nil avoids the selection metadata loader, so the missing master
            // reaches AVPlayerItem.status.failed instead of its preparation catch.
            player.present(try await api.item("movie-1"), fromBeginning: true, mediaSourceID: "movie-1-source")
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.paused(player, at: 8)
            try await self.assertFallbackAndPausedHistory()
        }
    }

    func testFailedPausedSubtitleChoiceRetryDoesNotAutoplay() async throws {
        try await run { player, api in
            try await self.control(["subtitleWrongName": true])
            player.present(try await api.item("movie-1"), subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            for _ in 0..<300 {
                if player.error != nil { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertNotNil(player.error)
            try await self.control(["subtitleWrongName": false])
            player.retry(api: api, quality: .original)
            try await self.paused(player, at: 8)
            try await self.assertPausedHistory()
        }
    }

    func testLaterPlayAndNewOrdinaryPresentRestoreAutoplayDefaults() async throws {
        try await run { player, api in
            let media = try await api.item("movie-1")
            player.present(media, subtitle: -1, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.paused(player, at: 8)
            try await self.assertPausedHistory()
            player.player.play()
            try await self.playing(player)
            player.retry(api: api, quality: .original)
            try await self.playing(player)
            player.present(media, subtitle: -1, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.start(api: api, quality: .original)
            try await self.playing(player)
            await player.flushReports()
            let state = try await self.state()
            let starts = self.reports(state).filter { $0["path"] as? String == "/Sessions/Playing" }.compactMap { ($0["body"] as? [String: Any])?["IsPaused"] as? Bool }
            XCTAssertEqual(starts, [true, false, false])
        }
    }

    func testLocalPausedResumeRetryUsesFreshPositionAndOrdinaryLocalStartStillPlays() async throws {
        try await run { player, api in
            let token = try XCTUnwrap(api.token)
            let (data, response) = try await URLSession.shared.data(for: api.request("Videos/movie-3/stream", query: ["static": "true", "ApiKey": token]))
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertGreaterThan(data.count, 1024)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reel-paused-" + UUID().uuidString + ".mp4")
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: "offline-" + url.lastPathComponent) }
            let media = try await api.item("movie-3")
            player.presentDownload(media, url: url)
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.paused(player, at: 8)
            XCTAssertEqual(player.method, "Offline")
            player.player.play()
            try await self.playing(player)
            player.seek(to: 120_000_000)
            for _ in 0..<100 {
                if player.player.currentTime().seconds >= 12 { break }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThanOrEqual(player.player.currentTime().seconds, 12)
            player.retry(api: api, quality: .original)
            try await self.playing(player)
            XCTAssertGreaterThanOrEqual(player.player.currentTime().seconds, 12, "Ordinary local retry must not reuse the consumed eight-second resume.")
            player.resumeOnDevice(at: 4, api: api, quality: .original, initiallyPaused: true)
            try await self.paused(player, at: 4)
            player.presentDownload(media, url: url)
            player.start(api: api, quality: .original)
            try await self.playing(player)
            let state = try await self.state()
            XCTAssertFalse(self.reports(state).contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        }
    }

    func testCanceledQueuedLocalPausedStartupCannotSeekOrPauseOnlineReplacement() async throws {
        try await reset()
        let gate = Gate(), firstAPI = api(), nextAPI = api("tv-subtitle-other-account")
        let token = try XCTUnwrap(firstAPI.token)
        let (data, response) = try await URLSession.shared.data(for: firstAPI.request("Videos/movie-3/stream", query: ["static": "true", "ApiKey": token]))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reel-paused-local-" + UUID().uuidString + ".mp4")
        try data.write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: "offline-" + url.lastPathComponent) }
        let player = PlaybackController(beforeInitialPlayback: { await gate.waitOnce() })
        do {
            player.presentDownload(try await firstAPI.item("movie-3"), url: url)
            player.resumeOnDevice(at: 8, api: firstAPI, quality: .original, initiallyPaused: true)
            try await gate.entered()
            XCTAssertEqual(player.player.currentItem?.status, .readyToPlay)
            player.present(try await nextAPI.item("movie-3"), fromBeginning: true)
            player.start(api: nextAPI, quality: .original)
            try await playing(player)
            let current = try XCTUnwrap(player.player.currentItem)
            XCTAssertLessThan(player.player.currentTime().seconds, 5, "Establish early decoded B before releasing canceled local A.")
            gate.release(); await player.flushReports()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(player.player.currentItem === current)
            XCTAssertGreaterThan(player.player.rate, 0)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            let last = try await state()
            let starts = reports(last).filter { $0["path"] as? String == "/Sessions/Playing" }
            XCTAssertEqual(starts.count, 1)
            XCTAssertEqual(starts.first?["user"] as? String, "tv-subtitle-other-account")
            XCTAssertEqual((starts.first?["body"] as? [String: Any])?["IsPaused"] as? Bool, false)
            player.stop(); await player.flushReports()
        } catch { gate.release(); player.stop(); await player.flushReports(); throw error }
    }

    func testCanceledQueuedPausedStartupCannotPauseSeekOrReportForReplacement() async throws {
        try await reset()
        let gate = Gate(), firstAPI = api(), nextAPI = api("tv-subtitle-other-account")
        let player = PlaybackController(beforeInitialPlayback: { await gate.waitOnce() })
        do {
            player.present(try await firstAPI.item("movie-1"), subtitle: 2, fromBeginning: true, mediaSourceID: "movie-1-source")
            player.resumeOnDevice(at: 8, api: firstAPI, quality: .original, initiallyPaused: true)
            try await gate.entered()
            let first = try await state()
            let info = reports(first).last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }
            XCTAssertEqual((info?["body"] as? [String: Any])?["StartTimeTicks"] as? Int, 80_000_000)
            player.present(try await nextAPI.item("movie-3"), fromBeginning: true)
            player.start(api: nextAPI, quality: .original)
            try await playing(player)
            let item = try XCTUnwrap(player.player.currentItem)
            XCTAssertLessThan(player.player.currentTime().seconds, 5, "Establish early decoded B before releasing canceled online A.")
            gate.release()
            await player.flushReports()
            try await Task.sleep(for: .milliseconds(400))
            XCTAssertTrue(player.player.currentItem === item)
            XCTAssertGreaterThan(player.player.rate, 0)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            let last = try await state()
            let starts = reports(last).filter { $0["path"] as? String == "/Sessions/Playing" }
            XCTAssertEqual(starts.filter { $0["user"] as? String == "tv-track-output" }.count, 0)
            XCTAssertEqual(starts.filter { $0["user"] as? String == "tv-subtitle-other-account" }.count, 1)
            player.stop(); await player.flushReports()
        } catch {
            gate.release(); player.stop(); await player.flushReports(); throw error
        }
    }

    private func run(_ body: (PlaybackController, JellyfinAPI) async throws -> Void) async throws {
        try await reset()
        let player = PlaybackController()
        do { try await body(player, api()); player.stop(); await player.flushReports() }
        catch { player.stop(); await player.flushReports(); throw error }
    }

    private func paused(_ player: PlaybackController, at seconds: Double) async throws {
        for _ in 0..<400 {
            if player.error != nil || (!player.preparing && !player.resolvingReplacement && player.player.currentItem?.status == .readyToPlay) { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertNil(player.error)
        guard player.error == nil, !player.preparing else { throw URLError(.cannotDecodeContentData) }
        XCTAssertEqual(player.player.currentTime().seconds, seconds, accuracy: 0.12)
        XCTAssertEqual(player.player.rate, 0)
        XCTAssertFalse(player.isPlaying)
        let position = player.player.currentTime().seconds
        try await Task.sleep(for: .seconds(1))
        XCTAssertEqual(player.player.currentTime().seconds, position, accuracy: 0.02)
        XCTAssertEqual(player.player.timeControlStatus, .paused)
        player.reportPauseState(); await player.flushReports()
    }

    private func playing(_ player: PlaybackController) async throws {
        let started = ContinuousClock.now, initial = player.player.currentTime()
        let readinessDeadline = started.advanced(by: .seconds(15))
        var readyItem: AVPlayerItem?
        while ContinuousClock.now < readinessDeadline {
            if let error = player.error { XCTFail(error); throw URLError(.cannotDecodeContentData) }
            if let item = player.player.currentItem, item.status == .readyToPlay, !player.preparing, !player.resolvingReplacement,
               player.player.rate > 0, item.presentationSize.width > 0, player.player.currentTime().seconds.isFinite {
                readyItem = item; break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard let item = readyItem else {
            attachPlayingTime(player, initial: initial, baseline: nil, started: started)
            XCTFail("A finite decoded current item did not become ready for playback."); throw URLError(.timedOut)
        }
        let baseline = player.player.currentTime()
        guard baseline.seconds.isFinite else { throw URLError(.cannotDecodeContentData) }
        let advanceDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        var advanced = false
        while ContinuousClock.now < advanceDeadline {
            try Task.checkCancellation()
            guard player.player.currentItem === item, item.status == .readyToPlay, player.error == nil else { break }
            let now = player.player.currentTime().seconds
            if player.player.rate > 0, now.isFinite, now > baseline.seconds + 0.2 { advanced = true; break }
            try await Task.sleep(for: .milliseconds(20))
        }
        attachPlayingTime(player, initial: initial, baseline: baseline, started: started)
        XCTAssertTrue(advanced, "The same ready decoded item must measurably advance after a fresh finite baseline.")
        guard advanced else { throw URLError(.timedOut) }
        XCTAssertTrue(player.isPlaying)
    }

    private func attachPlayingTime(_ player: PlaybackController, initial: CMTime, baseline: CMTime?, started: ContinuousClock.Instant) {
        func time(_ value: CMTime) -> [String: Any] {
            ["flags": value.flags.rawValue, "value": value.value, "timescale": value.timescale,
             "seconds": value.seconds.isFinite ? value.seconds as Any : String(describing: value.seconds)]
        }
        let state: [String: Any] = ["initial": time(initial), "baseline": baseline.map(time) as Any? ?? NSNull(),
                                    "final": time(player.player.currentTime()), "rate": player.player.rate,
                                    "preparing": player.preparing, "elapsed": String(describing: started.duration(to: ContinuousClock.now))]
        attach(state, name: "Playing readiness finite baseline and measured advancement")
    }

    private func assertPausedHistory() async throws {
        let value = try await state()
        let events = reports(value).filter { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true }
        XCTAssertEqual(events.filter { $0["path"] as? String == "/Sessions/Playing" }.count, 1)
        XCTAssertTrue(events.allSatisfy { ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == true }, "Paused startup must never send an unpaused start or progress event.")
        attach(value, name: "Explicit paused startup public native state and history")
    }

    private func assertFallbackAndPausedHistory() async throws {
        let value = try await state()
        let infos = reports(value).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }
        XCTAssertEqual(infos.count, 2)
        XCTAssertTrue(infos.allSatisfy { ($0["body"] as? [String: Any])?["StartTimeTicks"] as? Int == 80_000_000 })
        let cleanup = try XCTUnwrap(value["subtitleCleanups"] as? [[String: Any]])
        XCTAssertEqual(cleanup.count, 1)
        XCTAssertEqual(cleanup.first?["deviceId"] as? [String], ["tv-paused-startup-qa"])
        XCTAssertEqual(cleanup.first?["playSessionId"] as? [String], ["synthetic-bad-metadata-session"])
        try await assertPausedHistory()
    }

    private func reset() async throws { try await post("reset", [:]); try await post("control", ["failReports": false, "failCleanup": false]) }
    private func control(_ body: [String: Bool]) async throws { try await post("tv-control", body) }
    private func post(_ path: String, _ body: [String: Bool]) async throws {
        try TVFixture.requireQAHost()
        var request = try await TVFixture.request(server.appendingPathComponent("qa/" + path))
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private func state() async throws -> [String: Any] {
        try TVFixture.requireQAHost()
        let (data, response) = try await URLSession.shared.data(for: try await TVFixture.request(server.appendingPathComponent("qa/state")))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func reports(_ state: [String: Any]) -> [[String: Any]] { state["reports"] as? [[String: Any]] ?? [] }
    private func attach(_ state: [String: Any], name: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: state, options: [.sortedKeys]) else { return }
        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        receipt.name = name; receipt.lifetime = .keepAlways; add(receipt)
    }

    @MainActor private final class Gate {
        private var entries = 0
        private var continuation: CheckedContinuation<Void, Never>?
        private var released = false
        func waitOnce() async {
            entries += 1
            guard entries == 1, !released else { return }
            await withCheckedContinuation { continuation = $0 }
        }
        func entered() async throws {
            for _ in 0..<300 {
                if entries > 0 { return }
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTFail("Paused startup never reached the real ready gate."); throw URLError(.timedOut)
        }
        func release() { released = true; continuation?.resume(); continuation = nil }
    }
}
