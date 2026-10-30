import AVFoundation
import XCTest
@testable import ReelTV

@MainActor final class TVAudioRetentionTests: XCTestCase {
    private let server = URL(string: "http://127.0.0.1:18969")!
    private func api(_ user: String = "tv-multiaudio", history: Bool = true) -> JellyfinAPI {
        let value = JellyfinAPI(server: server, token: "fixture-" + user, userID: user, deviceID: "tv-multiaudio-tests", historyEnabled: history)
        PlaybackReporter.updatePrivacy(api: value)
        return value
    }

    func testInitialExplicitAudioOverridesOppositePlayerPolicyWithoutChangingIt() async throws {
        try await run { player, api in
            let policy = AVPlayerMediaSelectionCriteria(preferredLanguages: ["en"], preferredMediaCharacteristics: nil)
            player.player.setMediaSelectionCriteria(policy, forMediaCharacteristic: .audible)
            let before = self.criteria(player.player)
            try await self.start(player, api, audio: 3)
            try await self.assertAudio(player, language: "es")
            XCTAssertEqual(before, self.criteria(player.player))
            let capture = try await player.captureCurrentAudioChoice(api: api)
            XCTAssertEqual(capture.audioIndex, 3)
        }
    }

    func testNilInitialChoicePreservesPolicyAndLaterNativeSelectionIsNotReapplied() async throws {
        try await run { player, api in
            player.player.setMediaSelectionCriteria(AVPlayerMediaSelectionCriteria(preferredLanguages: ["es"], preferredMediaCharacteristics: nil), forMediaCharacteristic: .audible)
            let before = self.criteria(player.player)
            try await self.start(player, api, audio: nil)
            XCTAssertEqual(before, self.criteria(player.player))
            try await self.select(player, language: "en")
            try await Task.sleep(for: .seconds(1.2))
            try await self.assertAudio(player, language: "en")
            XCTAssertEqual(before, self.criteria(player.player))
        }
    }

    func testActualNativeAudioSurvivesOrdinaryRetryAndStillAutoplays() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            player.player.pause()
            await player.player.seek(to: CMTime(seconds: 8, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            let old = try XCTUnwrap(player.player.currentItem)
            player.retry(api: api, quality: .balanced)
            try await self.ready(player, replacing: old)
            try await self.assertAudio(player, language: "es")
            XCTAssertGreaterThan(player.player.rate, 0)
            XCTAssertGreaterThanOrEqual(player.player.currentTime().seconds, 8)
            let state = try await self.state()
            let info = try XCTUnwrap(self.negotiations(state).last)
            XCTAssertEqual((info["body"] as? [String: Any])?["AudioStreamIndex"] as? Int, 3)
            XCTAssertEqual((info["body"] as? [String: Any])?["StartTimeTicks"] as? Int, 80_000_000)
        }
    }

    func testExplicitPausedRetryRetainsActualAudioPositionAndFirstPausedReport() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            let old = try XCTUnwrap(player.player.currentItem)
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.ready(player, replacing: old, paused: true, at: 8)
            try await self.assertAudio(player, language: "es")
            await player.flushReports()
            try await self.assertLastStartPaused()
        }
    }

    func testRetryMetadataFallbackPreservesNativeAudioAndEightSecondPausedIntent() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            let old = try XCTUnwrap(player.player.currentItem)
            try await self.control(["failNextMaster": true])
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.ready(player, replacing: old, paused: true, at: 8)
            try await self.assertAudio(player, language: "es")
            await player.flushReports()
            let value = try await self.state(), infos = self.negotiations(value)
            XCTAssertEqual(infos.count, 3)
            XCTAssertTrue(infos.suffix(2).allSatisfy { ($0["body"] as? [String: Any])?["AudioStreamIndex"] as? Int == 3 && ($0["body"] as? [String: Any])?["StartTimeTicks"] as? Int == 80_000_000 })
            try await self.assertLastStartPaused()
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-1", "synthetic-multiaudio-session-2"])
        }
    }

    func testRetryVideoFailureFallbackKeepsValidatedAudio() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            let old = try XCTUnwrap(player.player.currentItem)
            let witness = FailureWitness()
            let observation = player.player.observe(\.currentItem, options: [.initial, .new]) { observed, _ in
                let item = observed.currentItem
                Task { @MainActor [weak item] in if let item { witness.watch(item) } }
            }
            defer { observation.invalidate(); witness.stop() }
            try await self.control(["failNextVideo": true])
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.ready(player, replacing: old, paused: true, at: 8)
            try await self.assertAudio(player, language: "es")
            let value = try await self.state()
            XCTAssertEqual(value["failedVideos"] as? [Int], [2])
            XCTAssertTrue(witness.sawFailure, "This case must reach actual AVPlayerItem.failed, separately from metadata-load fallback.")
            XCTAssertEqual(self.negotiations(value).count, 3)
            XCTAssertTrue(self.negotiations(value).suffix(2).allSatisfy { ($0["body"] as? [String: Any])?["AudioStreamIndex"] as? Int == 3 })
            try await self.assertLastStartPaused()
        }
    }

    func testUnresolvableNativeAudioKeepsOldPlaybackAndHasRecoveryError() async throws {
        try await run { player, api in
            try await self.control(["unresolvableAudio": true])
            try await self.start(player, api, audio: nil)
            let item = try XCTUnwrap(player.player.currentItem), count = try await self.state()["multiAudioNegotiations"] as? [[String: Any]]
            player.retry(api: api, quality: .balanced)
            try await self.wait { player.audioSelectionError != nil }
            XCTAssertTrue(player.player.currentItem === item)
            XCTAssertGreaterThan(player.player.rate, 0)
            XCTAssertNil(player.error)
            let after = try await self.state()
            XCTAssertEqual((after["multiAudioNegotiations"] as? [[String: Any]])?.count, count?.count)
        }
    }

    func testSelectionChangedDuringCaptureCannotCommitOldHandoff() async throws {
        try await reset()
        let gate = Gate(), player = PlaybackController(beforeAudioCapture: { await gate.waitIfArmed() }), api = api()
        do {
            try await start(player, api)
            try await select(player, language: "es")
            gate.arm()
            let task = Task { try await player.captureCurrentAudioChoice(api: api) }
            try await gate.entered()
            try await select(player, language: "en")
            gate.release()
            do { _ = try await task.value; XCTFail("Changed native selection must reject the parked snapshot.") } catch { XCTAssertTrue(error is PlaybackAudioSelection.SelectionError) }
            try await assertAudio(player, language: "en")
            let after = try await state()
            XCTAssertEqual((after["multiAudioNegotiations"] as? [[String: Any]])?.count, 1)
            player.stop(); await player.flushReports()
        } catch { gate.release(); player.stop(); await player.flushReports(); throw error }
    }

    func testCanceledRetryCaptureCannotTouchDecodedAccountReplacement() async throws {
        try await reset()
        let gate = Gate(), player = PlaybackController(beforeAudioCapture: { await gate.waitIfArmed() }), first = api(), next = api("tv-audio-other")
        do {
            try await start(player, first)
            try await select(player, language: "es")
            gate.arm(); player.resumeOnDevice(at: 8, api: first, quality: .original, initiallyPaused: true)
            try await gate.entered()
            player.present(try await next.item("movie-3"), fromBeginning: true)
            player.start(api: next, quality: .original)
            try await ready(player)
            let item = try XCTUnwrap(player.player.currentItem)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            gate.release(); await player.flushReports()
            try await Task.sleep(for: .milliseconds(300))
            XCTAssertTrue(player.player.currentItem === item)
            XCTAssertGreaterThan(player.player.rate, 0)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            XCTAssertNil(player.audioSelectionError)
            player.stop(); await player.flushReports()
            let value = try await state()
            XCTAssertEqual(negotiations(value).count, 1)
            try assertCleanup(value, sessions: ["synthetic-multiaudio-session-1"])
        } catch { gate.release(); player.stop(); await player.flushReports(); throw error }
    }

    func testHandoffCommitAndReturnUseActualAudioAndLegibleChoices() async throws {
        try await run(history: false) { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            try await self.selectCaptions(player, on: true)
            let capture = try await player.captureCurrentPlaybackChoices(api: api)
            XCTAssertEqual(capture.audioIndex, 3); XCTAssertEqual(capture.subtitleIndex, 2)
            XCTAssertTrue(player.commitHandoff(from: capture))
            XCTAssertNil(player.player.currentItem)
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.ready(player, paused: true, at: 8)
            try await self.assertAudio(player, language: "es")
            try await self.assertCaptions(player, on: true)
            player.stop(); await player.flushReports()
            let value = try await self.state()
            XCTAssertFalse(self.reports(value).contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-1", "synthetic-multiaudio-session-2"])
        }
    }

    func testStaleHandoffCannotStopNewItem() async throws {
        try await run { player, api in
            try await self.start(player, api)
            let old = try await player.captureCurrentPlaybackChoices(api: api)
            player.present(try await api.item("movie-3"), fromBeginning: true)
            player.start(api: api, quality: .original)
            try await self.ready(player)
            let current = try XCTUnwrap(player.player.currentItem)
            XCTAssertFalse(player.commitHandoff(from: old))
            XCTAssertTrue(player.player.currentItem === current)
            XCTAssertGreaterThan(player.player.rate, 0)
        }
    }

    func testOfflineNativeAudioAndCaptionChoiceSurvivePausedRetryWithoutHistory() async throws {
        try await run { player, api in
            let request = api.request("Videos/reel-audio-local/movie.mp4", query: ["ApiKey": "fixture-tv-multiaudio"])
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reel-audio-" + UUID().uuidString + ".mp4")
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: "offline-" + url.lastPathComponent) }
            player.presentDownload(try await api.item("movie-1"), url: url); player.start(api: api, quality: .original)
            try await self.ready(player)
            try await self.select(player, language: "es"); try await self.selectCaptions(player, on: true)
            let old = try XCTUnwrap(player.player.currentItem)
            player.resumeOnDevice(at: 8, api: api, quality: .original, initiallyPaused: true)
            try await self.ready(player, replacing: old, paused: true, at: 8)
            try await self.assertAudio(player, language: "es"); try await self.assertCaptions(player, on: true)
            XCTAssertEqual(player.method, "Offline")
            let value = try await self.state()
            XCTAssertTrue(self.reports(value).isEmpty)
        }
    }

    func testEOFAppSeekCreatesFreshPausedSessionAndRetainsActualTracks() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es"); try await self.selectCaptions(player, on: true)
            let old = try await self.finish(player)
            player.seek(to: 80_000_000)
            try await self.ready(player, replacing: old, paused: true, at: 8)
            XCTAssertFalse(player.ended)
            try await self.assertAudio(player, language: "es"); try await self.assertCaptions(player, on: true)
            await player.flushReports(); try await self.assertLastStartPaused()
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 2)
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-1"])
        }
    }

    func testEOFReplayCreatesFreshPlayingSessionAndIgnoresOldReplayToken() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            let old = try await self.finish(player), token = try XCTUnwrap(player.endedSessionID)
            await player.replay(endedID: token, api: api, quality: .original)
            try await self.ready(player, replacing: old)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            try await self.assertAudio(player, language: "es")
            let fresh = try XCTUnwrap(player.player.currentItem)
            await player.replay(endedID: token, api: api, quality: .original)
            XCTAssertTrue(player.player.currentItem === fresh)
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 2)
        }
    }

    func testEOFNativeSeekCreatesFreshPausedSessionRatherThanRevivingStoppedStream() async throws {
        try await run { player, api in
            try await self.start(player, api)
            let old = try await self.finish(player)
            await player.player.seek(to: CMTime(seconds: 5, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
            try await self.ready(player, replacing: old, paused: true, at: 5)
            XCTAssertFalse(player.ended)
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 2)
        }
    }

    func testEOFNativeSeekThenPlayCreatesOnlyOneFreshPlayingSession() async throws {
        try await run { player, api in
            try await self.start(player, api)
            let old = try await self.finish(player)
            await player.player.seek(to: .zero, toleranceBefore: .zero, toleranceAfter: .zero)
            player.player.play()
            try await self.ready(player, replacing: old)
            XCTAssertFalse(player.ended)
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 2)
        }
    }

    func testIdleEOFDoesNotCreateAnUnrequestedSession() async throws {
        try await run { player, api in
            try await self.start(player, api)
            let old = try await self.finish(player)
            try await Task.sleep(for: .seconds(1.2))
            XCTAssertTrue(player.ended); XCTAssertTrue(player.player.currentItem === old)
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 1)
        }
    }

    func testManagedEOFSeekStartsFreshPausedAndLeavesPlaybackToGroupAuthority() async throws {
        try await run { player, api in
            try await self.start(player, api)
            let old = try await self.finish(player)
            player.syncPlayManaged = true
            defer { player.syncPlayManaged = false }
            try await player.seekForManagedPlayback(to: 80_000_000)
            try await self.ready(player, replacing: old, paused: true, at: 8)
            XCTAssertFalse(player.ended)
            try await self.assertLastStartPaused()
            player.player.playImmediately(atRate: 1)
            try await self.ready(player)
        }
    }

    func testOfflineEOFSeekAndReplayUseFreshItemsWithActualTracksAndNoHistory() async throws {
        try await run { player, api in
            let (data, response) = try await URLSession.shared.data(for: api.request("Videos/reel-audio-local/movie.mp4", query: ["ApiKey": "fixture-tv-multiaudio"]))
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("reel-audio-eof-" + UUID().uuidString + ".mp4")
            try data.write(to: url, options: .atomic)
            defer { try? FileManager.default.removeItem(at: url); UserDefaults.standard.removeObject(forKey: "offline-" + url.lastPathComponent) }
            player.presentDownload(try await api.item("movie-1"), url: url); player.start(api: api, quality: .original)
            try await self.ready(player); try await self.select(player, language: "es"); try await self.selectCaptions(player, on: true)
            let old = try await self.finish(player)
            player.seek(to: 80_000_000)
            try await self.ready(player, replacing: old, paused: true, at: 8)
            try await self.assertAudio(player, language: "es"); try await self.assertCaptions(player, on: true)
            let second = try await self.finish(player), token = try XCTUnwrap(player.endedSessionID)
            await player.replay(endedID: token, api: api, quality: .original)
            try await self.ready(player, replacing: second)
            try await self.assertAudio(player, language: "es"); try await self.assertCaptions(player, on: true)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            let value = try await self.state()
            XCTAssertTrue(self.reports(value).isEmpty)
        }
    }

    func testLaterManagedEOFSeekCancelsOlderParkedRestartBeforeAnyOldSeekOrStart() async throws {
        try await reset()
        let gate = Gate(), player = PlaybackController(beforeAudioCapture: { await gate.waitIfArmed() }), value = api()
        do {
            try await start(player, value); _ = try await finish(player)
            player.syncPlayManaged = true
            gate.arm()
            let first = Task { try await player.seekForManagedPlayback(to: 80_000_000) }
            try await gate.entered()
            first.cancel()
            let second = Task { try await player.seekForManagedPlayback(to: 120_000_000) }
            try await second.value
            try await ready(player, paused: true, at: 12)
            let fresh = try XCTUnwrap(player.player.currentItem)
            gate.release()
            do { try await first.value; XCTFail("Canceled group command must not complete as accepted.") } catch { XCTAssertTrue(error is CancellationError) }
            await player.flushReports()
            XCTAssertTrue(player.player.currentItem === fresh)
            XCTAssertEqual(player.player.currentTime().seconds, 12, accuracy: 0.12)
            let infos = negotiations(try await state())
            XCTAssertEqual(infos.count, 2)
            XCTAssertEqual((infos.last?["body"] as? [String: Any])?["StartTimeTicks"] as? Int, 120_000_000)
            player.syncPlayManaged = false; player.stop(); await player.flushReports()
        } catch { gate.release(); player.syncPlayManaged = false; player.stop(); await player.flushReports(); throw error }
    }

    func testCanceledEOFCaptureCannotRestartAnOldAccountAfterReplacement() async throws {
        try await reset()
        let gate = Gate(), player = PlaybackController(beforeAudioCapture: { await gate.waitIfArmed() }), first = api(), next = api("tv-audio-other")
        do {
            try await start(player, first); _ = try await finish(player)
            let token = try XCTUnwrap(player.endedSessionID)
            gate.arm()
            let replay = Task { await player.replay(endedID: token, api: first, quality: .original) }
            try await gate.entered()
            player.present(try await next.item("movie-3"), fromBeginning: true); player.start(api: next, quality: .original)
            try await ready(player)
            let fresh = try XCTUnwrap(player.player.currentItem)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            gate.release(); await replay.value; await player.flushReports()
            XCTAssertTrue(player.player.currentItem === fresh); XCTAssertGreaterThan(player.player.rate, 0)
            XCTAssertLessThan(player.player.currentTime().seconds, 5)
            let infos = negotiations(try await state())
            XCTAssertEqual(infos.count, 1)
            player.stop(); await player.flushReports()
        } catch { gate.release(); player.stop(); await player.flushReports(); throw error }
    }

    func testCastFreshNegotiationRejectsChangedProviderAndCleansOnlyItsOwnPlan() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            let item = try XCTUnwrap(player.player.currentItem), media = try XCTUnwrap(player.activeItem)
            let captured = try await player.captureCurrentPlaybackChoices(api: api)
            let selection = try player.castSelection(from: captured)
            try await self.control(["unresolvableAudio": true])
            do {
                _ = try await api.prepareCast(media, position: 8, bitrate: StreamQuality.original.rawValue, mediaSourceID: selection.sourceID, audioIndex: selection.audioIndex, subtitleIndex: selection.subtitleIndex, selection: selection)
                XCTFail("Changed server identity must fail before receiver Load.")
            } catch { XCTAssertTrue(error is CastPlaybackError) }
            XCTAssertTrue(player.player.currentItem === item); XCTAssertGreaterThan(player.player.rate, 0)
            try await self.assertAudio(player, language: "es")
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 2)
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-2"])
        }
    }

    func testCapturedOffSurvivesFreshDetailsDefaultAndRejectsNegotiatedEnabledSubtitles() async throws {
        try await run { player, api in
            try await self.start(player, api)
            let original = try XCTUnwrap(player.player.currentItem), media = try XCTUnwrap(player.activeItem)
            let capture = try await player.captureCurrentPlaybackChoices(api: api)
            let selection = try player.castSelection(from: capture)
            XCTAssertEqual(selection.subtitleIndex, -1)
            try await self.control(["detailsSubtitleDefault": true])
            let detail = try await api.item(media.id)
            XCTAssertEqual(detail.MediaSources?.first?.DefaultSubtitleStreamIndex, 2)
            let off = try await api.prepareCast(media, position: 8, bitrate: StreamQuality.original.rawValue, mediaSourceID: selection.sourceID,
                                                audioIndex: selection.audioIndex, subtitleIndex: selection.subtitleIndex, selection: selection)
            XCTAssertEqual(off.subtitleIndex, -1); XCTAssertEqual(off.source.DefaultSubtitleStreamIndex, -1)
            let cleanup = PlaybackReporter()
            cleanup.enqueue(api: api, endpoint: "", body: ["PlaySessionId": off.sessionID, "CleanupEncoder": true], cleanup: true)
            await cleanup.flush()
            try await self.control(["negotiatedSubtitleEnabled": true])
            do {
                _ = try await api.prepareCast(media, position: 8, bitrate: StreamQuality.original.rawValue, mediaSourceID: selection.sourceID,
                                               audioIndex: selection.audioIndex, subtitleIndex: selection.subtitleIndex, selection: selection)
                XCTFail("An actual negotiated enabled subtitle must not silently replace captured Off.")
            } catch { XCTAssertTrue(error is CastPlaybackError) }
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 3)
            XCTAssertTrue(self.negotiations(value).suffix(2).allSatisfy { ($0["body"] as? [String: Any])?["SubtitleStreamIndex"] as? Int == -1 })
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-2", "synthetic-multiaudio-session-3"])
            XCTAssertTrue(player.player.currentItem === original); XCTAssertGreaterThan(player.player.rate, 0)
        }
    }
    func testCapturedOffRejectsEncodedOrConflictingPlanAndCleansOnlyRejectedSessions() async throws {
        try await run { player, api in
            try await self.start(player, api)
            let original = try XCTUnwrap(player.player.currentItem), media = try XCTUnwrap(player.activeItem)
            let selection = try player.castSelection(from: try await player.captureCurrentPlaybackChoices(api: api))
            XCTAssertEqual(selection.subtitleIndex, -1)
            try await self.control(["detailsSubtitleDefault": true])
            let freshDetails = try await api.item(media.id)
            XCTAssertEqual(freshDetails.MediaSources?.first?.DefaultSubtitleStreamIndex, 2)
            let before = player.player.currentTime().seconds
            let attempts: [([String: Bool], Bool)] = [(["encodedSubtitlePlan": true], true),
                (["encodedSubtitlePlan": true, "omittedSubtitleDefault": true], true),
                (["conflictingSubtitlePlan": true], true), (["encodedSubtitlePlan": true], false)]
            for (controls, captured) in attempts {
                try await self.control(controls)
                do {
                    _ = try await api.prepareCast(media, position: 8, bitrate: StreamQuality.original.rawValue, mediaSourceID: selection.sourceID,
                                                   audioIndex: selection.audioIndex, subtitleIndex: -1, selection: captured ? selection : nil)
                    XCTFail("An explicit selected/encoded/ambiguous plan cannot be reported as captured Off.")
                } catch { XCTAssertTrue(error is CastPlaybackError) }
            }
            try await self.wait { player.player.currentTime().seconds.isFinite && player.player.currentTime().seconds > before + 0.2 }
            XCTAssertTrue(player.player.currentItem === original); XCTAssertGreaterThan(player.player.rate, 0)
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 5)
            XCTAssertTrue(self.negotiations(value).suffix(4).allSatisfy { ($0["body"] as? [String: Any])?["SubtitleStreamIndex"] as? Int == -1 })
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-2", "synthetic-multiaudio-session-3", "synthetic-multiaudio-session-4", "synthetic-multiaudio-session-5"])
        }
    }

    func testRetryRejectsDifferentReturnedVersionWithIdenticalTracksAndCleansNewSession() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            try await self.control(["changedSource": true])
            player.retry(api: api, quality: .balanced)
            try await self.wait { player.error != nil && !player.preparing && !player.resolvingReplacement }
            await player.flushReports()
            XCTAssertNil(player.player.currentItem)
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 2)
            XCTAssertEqual((self.negotiations(value).last?["body"] as? [String: Any])?["MediaSourceId"] as? String, "movie-1-multiaudio")
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-1", "synthetic-multiaudio-session-2"])
            XCTAssertEqual(self.reports(value).filter { $0["path"] as? String == "/Sessions/Playing" }.count, 1)
        }
    }
    func testEOFReplayRejectsDifferentReturnedVersionAndNeverReusesCleanedSession() async throws {
        try await run { player, api in
            try await self.start(player, api)
            try await self.select(player, language: "es")
            _ = try await self.finish(player)
            let token = try XCTUnwrap(player.endedSessionID)
            try await self.control(["changedSource": true])
            await player.replay(endedID: token, api: api, quality: .original)
            try await self.wait { player.error != nil && !player.preparing && !player.resolvingReplacement }
            await player.flushReports()
            XCTAssertNil(player.player.currentItem)
            let value = try await self.state()
            XCTAssertEqual(self.negotiations(value).count, 2)
            XCTAssertEqual((self.negotiations(value).last?["body"] as? [String: Any])?["StartTimeTicks"] as? Int, 0)
            try self.assertCleanup(value, sessions: ["synthetic-multiaudio-session-1", "synthetic-multiaudio-session-2"])
            XCTAssertEqual(self.reports(value).filter { $0["path"] as? String == "/Sessions/Playing" }.count, 1)
        }
    }

    private func start(_ player: PlaybackController, _ api: JellyfinAPI, audio: Int? = 1) async throws {
        player.present(try await api.item("movie-1"), audio: audio, subtitle: -1, fromBeginning: true, mediaSourceID: "movie-1-multiaudio")
        player.start(api: api, quality: .original)
        try await ready(player)
    }
    private func finish(_ player: PlaybackController) async throws -> AVPlayerItem {
        let item = try XCTUnwrap(player.player.currentItem)
        await player.player.seek(to: CMTime(seconds: 119, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player.player.play()
        try await wait { player.ended }
        XCTAssertTrue(player.player.currentItem === item); XCTAssertEqual(player.player.rate, 0)
        await player.flushReports()
        return item
    }
    private func ready(_ player: PlaybackController, replacing old: AVPlayerItem? = nil, paused: Bool = false, at position: Double? = nil) async throws {
        try await wait {
            player.error != nil || player.audioSelectionError != nil || (player.player.currentItem != nil && player.player.currentItem !== old && !player.preparing && !player.resolvingReplacement && !player.restartingEnded && (player.player.currentItem?.presentationSize.width ?? 0) > 0 && player.player.currentItem?.status == .readyToPlay && player.player.currentTime().seconds.isFinite && (paused || player.player.rate > 0))
        }
        XCTAssertNil(player.error); XCTAssertNil(player.audioSelectionError)
        guard player.error == nil, player.audioSelectionError == nil, !player.preparing, let item = player.player.currentItem, item !== old else { throw URLError(.cannotDecodeContentData) }
        XCTAssertGreaterThan(item.presentationSize.width, 0)
        let before = player.player.currentTime().seconds
        if let position { XCTAssertEqual(before, position, accuracy: 0.15) }
        if paused {
            XCTAssertEqual(player.player.rate, 0)
            try await Task.sleep(for: .seconds(1.2))
            XCTAssertEqual(player.player.currentTime().seconds, before, accuracy: 0.02)
            XCTAssertEqual(player.player.timeControlStatus, .paused)
        } else {
            try await wait(seconds: 3) { player.player.currentItem === item && player.player.rate > 0 && player.player.currentTime().seconds > before + 0.2 }
        }
    }
    private func select(_ player: PlaybackController, language: String) async throws {
        let item = try XCTUnwrap(player.player.currentItem), loaded = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loaded), matches = group.options.filter { ($0.extendedLanguageTag ?? $0.locale?.identifier ?? "").prefix(2) == language }
        XCTAssertEqual(matches.count, 1)
        item.select(try XCTUnwrap(matches.first), in: group)
        try await wait { String((item.currentMediaSelection.selectedMediaOption(in: group)?.extendedLanguageTag ?? "").prefix(2)) == language }
        try await assertAudio(player, language: language)
    }
    private func assertAudio(_ player: PlaybackController, language: String) async throws {
        let item = try XCTUnwrap(player.player.currentItem), loaded = try await item.asset.loadMediaSelectionGroup(for: .audible)
        let group = try XCTUnwrap(loaded), selected = try XCTUnwrap(item.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertEqual(String((selected.extendedLanguageTag ?? selected.locale?.identifier ?? "").prefix(2)), language)
        XCTAssertTrue(selected.isPlayable)
        XCTAssertTrue(item.tracks.contains { $0.isEnabled && $0.assetTrack?.mediaType == .audio })
    }
    private func selectCaptions(_ player: PlaybackController, on: Bool) async throws {
        let item = try XCTUnwrap(player.player.currentItem), loaded = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loaded)
        // AVFoundation adds a forced-only variant of an MP4 subtitle track; the fixture has one regular track.
        let regular = group.options.filter { !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) }
        if on { XCTAssertEqual(regular.count, 1) }
        item.select(on ? regular.first : nil, in: group)
        try await assertCaptions(player, on: on)
    }
    private func assertCaptions(_ player: PlaybackController, on: Bool) async throws {
        let item = try XCTUnwrap(player.player.currentItem), loaded = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loaded)
        XCTAssertEqual(item.currentMediaSelection.selectedMediaOption(in: group) != nil, on)
    }
    private struct Criteria: Equatable {
        let exists: Bool
        let languages: [String]?
        let characteristics: [String]?
        let principal: [String]?
    }
    private func criteria(_ player: AVPlayer) -> Criteria {
        let value = player.mediaSelectionCriteria(forMediaCharacteristic: .audible)
        return Criteria(exists: value != nil, languages: value?.preferredLanguages,
                        characteristics: value?.preferredMediaCharacteristics?.map(\.rawValue),
                        principal: value?.principalMediaCharacteristics?.map(\.rawValue))
    }
    private func wait(seconds: Double = 20, _ body: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while ContinuousClock.now < deadline {
            if body() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("Bounded native audio/replay effect did not finish."); throw URLError(.timedOut)
    }
    private func run(history: Bool = true, _ body: (PlaybackController, JellyfinAPI) async throws -> Void) async throws {
        try await reset()
        let player = PlaybackController(), value = api(history: history)
        do { try await body(player, value); player.stop(); await player.flushReports() }
        catch { player.stop(); await player.flushReports(); throw error }
    }
    private func reset() async throws {
        try TVFixture.requireQAHost()
        try await post("reset", [:]); try await post("control", ["failReports": false, "failCleanup": false])
    }
    private func control(_ value: [String: Bool]) async throws { try await post("audio-control", value) }
    private func post(_ path: String, _ body: [String: Bool]) async throws {
        try TVFixture.requireQAHost()
        guard ["reset", "control", "audio-control"].contains(path) else { throw ReelError.previewProtected }
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
    private func reports(_ value: [String: Any]) -> [[String: Any]] { value["reports"] as? [[String: Any]] ?? [] }
    private func negotiations(_ value: [String: Any]) -> [[String: Any]] { reports(value).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-multiaudio" } }
    private func assertLastStartPaused() async throws {
        let events = reports(try await state()).filter { $0["path"] as? String == "/Sessions/Playing" && $0["user"] as? String == "tv-multiaudio" }
        let last = try XCTUnwrap(events.last?["body"] as? [String: Any]), session = try XCTUnwrap(last["PlaySessionId"] as? String)
        XCTAssertEqual(last["IsPaused"] as? Bool, true)
        let current = reports(try await state()).filter { ($0["body"] as? [String: Any])?["PlaySessionId"] as? String == session && ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true }
        XCTAssertTrue(current.allSatisfy { ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == true })
    }
    private func assertCleanup(_ value: [String: Any], sessions: [String]) throws {
        let cleanups = try XCTUnwrap(value["multiAudioCleanups"] as? [[String: Any]])
        XCTAssertEqual(cleanups.count, sessions.count)
        for session in sessions {
            XCTAssertEqual(cleanups.filter { $0["playSessionId"] as? [String] == [session] && $0["user"] as? String == "tv-multiaudio" && $0["deviceId"] as? [String] == ["tv-multiaudio-tests"] }.count, 1)
        }
    }
    @MainActor private final class FailureWitness {
        private(set) var sawFailure = false
        private var seen: Set<ObjectIdentifier> = []
        private var observations: [NSKeyValueObservation] = []
        func watch(_ item: AVPlayerItem) {
            guard seen.insert(ObjectIdentifier(item)).inserted else { return }
            observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                let failed = observed.status == .failed
                Task { @MainActor [weak self] in if failed { self?.sawFailure = true } }
            })
        }
        func stop() { observations.forEach { $0.invalidate() }; observations.removeAll() }
    }
    @MainActor private final class Gate {
        private var armed = false, entries = 0
        private var continuation: CheckedContinuation<Void, Never>?
        func arm() { armed = true }
        func waitIfArmed() async { guard armed else { return }; armed = false; entries += 1; await withCheckedContinuation { continuation = $0 } }
        func entered() async throws {
            for _ in 0..<300 { if entries > 0 { return }; try await Task.sleep(for: .milliseconds(20)) }
            XCTFail("Actual current-item capture did not enter the owned gate."); throw URLError(.timedOut)
        }
        func release() { continuation?.resume(); continuation = nil }
    }
}
