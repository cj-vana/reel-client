import XCTest
import Vision

private enum TVJourneyFailure: Error { case unavailableControl(String), playbackDidNotStart, unsafeEnvironment }

@MainActor final class TVJourneys: XCTestCase {
    func testRemoteActualNativeAudioRetainsRenditionAcrossCaptionOnOffAndDefault() async throws {
        try await multiAudioRetention()
    }

    func testRemoteEOFReplayAllocatesFreshSessionWithActualAudioAndCaptions() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Owned synthetic TV simulator only.")
        #else
        try await multiAudioReset()
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        app.launchArguments = ["-reel-qa-reset", "-privateViewing", "NO", "-streamQuality", "0"]
        app.launch(); defer { app.terminate() }
        try signIn(app, user: "tv-multiaudio", server: "http://127.0.0.1:18969")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Synthetic multi-audio captions", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await multiAudioReady(app); try await multiAudioPause(true, app: app)
        try await selectNativeAudio("Spanish", app: app)
        try choose("Chapters", app: app); try choose("Near the end", app: app)
        try await multiAudioPause(false, app: app)
        XCTAssertTrue(app.buttons["replay"].waitForExistence(timeout: 10))
        let (_, ended) = try await multiAudioState()
        XCTAssertEqual((ended["multiAudioNegotiations"] as? [[String: Any]])?.count, 1)
        try select(app.buttons["replay"], in: app)
        try await multiAudioReady(app)
        try await multiAudioFrames(true, phase: "Fresh real EOF replay", app: app)
        try await multiAudioPause(true, app: app); try await expectNativeAudio("Spanish", app: app)
        let (_, replayed) = try await multiAudioState()
        let infos = (replayed["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-multiaudio" }
        XCTAssertEqual(infos.count, 2)
        let body = try XCTUnwrap(infos.last?["body"] as? [String: Any])
        XCTAssertEqual(body["StartTimeTicks"] as? Int, 0); XCTAssertEqual(body["AudioStreamIndex"] as? Int, 3)
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, 2)
        try await multiAudioReceipt("Fresh EOF replay")
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        let (data, final) = try await multiAudioState()
        try expectExactMultiAudioCleanups(final, expected: 2)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Exact EOF replay old and fresh session ownership"; attachment.lifetime = .keepAlways; add(attachment)
        #endif
    }

    func testRemoteAmbiguousAudioCaptionFailureKeepsPlaybackAndProvidesAllRecoveryActions() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Owned synthetic TV simulator only.")
        #else
        try await multiAudioReset()
        try await multiAudioControl(["unresolvableAudio": true])
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        app.launchArguments = ["-reel-qa-reset", "-privateViewing", "NO", "-streamQuality", "0"]
        app.launch(); defer { app.terminate() }
        try signIn(app, user: "tv-multiaudio", server: "http://127.0.0.1:18969")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app); try choose("Off", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await multiAudioReady(app); try await multiAudioPause(true, app: app)
        try await selectNativeAudio("Spanish", app: app)
        for recovery in ["continueAfterSubtitleError", "reloadSubtitleTracks"] {
            try choose("Subtitles", app: app); try choose("Synthetic multi-audio captions", app: app)
            XCTAssertTrue(app.staticTexts["subtitleMenuError"].waitForExistence(timeout: 10))
            let (_, failed) = try await multiAudioState()
            XCTAssertEqual((failed["multiAudioNegotiations"] as? [[String: Any]])?.count, 1)
            XCTAssertTrue(app.buttons["continueAfterSubtitleError"].exists)
            XCTAssertTrue(app.buttons["reloadSubtitleTracks"].exists)
            XCTAssertTrue(app.buttons["closePlayer"].exists)
            capture("Ambiguous actual audible mapping recovery " + recovery, app: app)
            try select(app.buttons[recovery], in: app)
            await waitUntilGone(app.staticTexts["subtitleMenuError"], timeout: 5)
            try await expectNativeAudio("Spanish", app: app)
        }
        try choose("Subtitles", app: app); try choose("Synthetic multi-audio captions", app: app)
        XCTAssertTrue(app.staticTexts["subtitleMenuError"].waitForExistence(timeout: 10))
        try select(app.buttons["closePlayer"], in: app)
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 10))
        let (_, final) = try await multiAudioState()
        try expectExactMultiAudioCleanups(final, expected: 1)
        #endif
    }

    private func multiAudioControl(_ body: [String: Bool]) async throws {
        _ = try await multiAudioState() // exact owned simulator/name guard before fixture mutation
        var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18969/qa/audio-control")!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func multiAudioRetention() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The original multi-audible fixture is simulator-only.")
        #else
        try await multiAudioReset()
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        app.launchArguments = ["-reel-qa-reset", "-privateViewing", "NO", "-streamQuality", "0"]
        app.launch()
        defer { app.terminate() }
        try signIn(app, user: "tv-multiaudio", server: "http://127.0.0.1:18969")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Off", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await multiAudioReady(app)
        try await multiAudioPause(true, app: app)
        try await selectNativeAudio("English", app: app)
        try await selectNativeAudio("Spanish", app: app)
        try await multiAudioPause(false, app: app)
        try await multiAudioFrames(false, phase: "Native Spanish audible before caption restart", app: app)
        try await multiAudioPause(true, app: app)
        try await expectNativeAudio("Spanish", app: app)
        try await multiAudioReceipt("native-spanish")

        for (title, index, captions) in [("Synthetic multi-audio captions", Optional(2), Optional(true)), ("Off", Optional(-1), Optional(false)), ("Server default", Optional<Int>.none, Optional<Bool>.none)] {
            let (_, before) = try await multiAudioState()
            let previous = (before["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-multiaudio" }.count
            let position = try nativeElapsedSeconds(app)
            try choose("Subtitles", app: app)
            try choose(title, app: app)
            try await multiAudioReady(app)
            var starts: [[String: Any]] = []
            for _ in 0..<50 {
                let (_, state) = try await multiAudioState()
                starts = (state["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-multiaudio" }
                if starts.count > previous { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard starts.count == previous + 1 else {
                XCTFail("The actual caption action must create exactly one fresh own negotiation.")
                throw TVJourneyFailure.playbackDidNotStart
            }
            let body = try XCTUnwrap(starts.last?["body"] as? [String: Any])
            XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, index)
            let ticks = try XCTUnwrap((body["StartTimeTicks"] as? NSNumber)?.int64Value)
            XCTAssertTrue((Int64(max(0, position - 1)) * 10_000_000...Int64(position + 3) * 10_000_000).contains(ticks))
            try await expectPausedMultiAudioReplacement(near: position, app: app)
            try await multiAudioPause(false, app: app)
            try await multiAudioFrames(captions, phase: title + " with native Spanish audible", app: app)
            try await multiAudioPause(true, app: app)
            try await expectNativeAudio("Spanish", app: app)
            try await multiAudioReceipt(title)
        }
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        let (data, state) = try await multiAudioState()
        try expectExactMultiAudioCleanups(state)
        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        receipt.name = "Native Audio and caption restart complete receipt without diagnostics"; receipt.lifetime = .keepAlways; add(receipt)
        #endif
    }

    private func expectPausedMultiAudioReplacement(near position: Int, app: XCUIApplication) async throws {
        var firstStart: [String: Any]?
        var session: String?
        for _ in 0..<50 {
            let (_, state) = try await multiAudioState()
            let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
            if let current = (state["multiAudioNegotiations"] as? [[String: Any]])?.last?["session"] as? String,
               let negotiation = reports.lastIndex(where: { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-multiaudio" }),
               let start = reports.dropFirst(negotiation + 1).first(where: { $0["path"] as? String == "/Sessions/Playing" && $0["user"] as? String == "tv-multiaudio" && ($0["body"] as? [String: Any])?["PlaySessionId"] as? String == current }) {
                firstStart = try XCTUnwrap(start["body"] as? [String: Any]); session = current; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let body = try XCTUnwrap(firstStart, "The replacement must actually start its own playback session before resume.")
        let sessionID = try XCTUnwrap(session)
        guard body["IsPaused"] as? Bool == true else {
            XCTFail("A subtitle restart from paused playback must start paused, before any remote resume.")
            throw TVJourneyFailure.playbackDidNotStart
        }
        let ticks = try XCTUnwrap((body["PositionTicks"] as? NSNumber)?.int64Value)
        let bounds = Int64(max(0, position - 1)) * 10_000_000...Int64(position + 3) * 10_000_000
        let elapsed = try nativeElapsedSeconds(app)
        guard bounds.contains(ticks), (max(0, position - 1)...position + 3).contains(elapsed) else {
            XCTFail("Actual post-seek Playing and native decoded positions must retain the prior position before resume.")
            throw TVJourneyFailure.playbackDidNotStart
        }
        try await Task.sleep(for: .milliseconds(1200))
        guard try nativeElapsedSeconds(app) == elapsed else {
            XCTFail("Replacement must remain paused before the actual resume action.")
            throw TVJourneyFailure.playbackDidNotStart
        }
        let (_, after) = try await multiAudioState()
        let events = (after["reports"] as? [[String: Any]] ?? []).filter {
            ["/Sessions/Playing", "/Sessions/Playing/Progress"].contains($0["path"] as? String ?? "") && $0["user"] as? String == "tv-multiaudio" && ($0["body"] as? [String: Any])?["PlaySessionId"] as? String == sessionID
        }
        guard !events.isEmpty, events.allSatisfy({ ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == true }) else {
            XCTFail("No current-session unpaused event may precede resume.")
            throw TVJourneyFailure.playbackDidNotStart
        }
        let proof = try JSONSerialization.data(withJSONObject: ["firstPlaying": body, "nativeElapsed": elapsed, "priorElapsed": position, "sameSessionEvents": events], options: [.sortedKeys])
        let attachment = XCTAttachment(data: proof, uniformTypeIdentifier: "public.json")
        attachment.name = "Actual paused replacement before resume " + sessionID; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func expectExactMultiAudioCleanups(_ state: [String: Any], expected: Int = 4) throws {
        let negotiations = try XCTUnwrap(state["multiAudioNegotiations"] as? [[String: Any]])
        let cleanups = try XCTUnwrap(state["multiAudioCleanups"] as? [[String: Any]])
        let sessions = try negotiations.map { try XCTUnwrap($0["session"] as? String) }
        guard sessions.count == expected, Set(sessions).count == expected, cleanups.count == expected else {
            XCTFail("Every distinct negotiated session must have exactly one cleanup, without extras.")
            throw TVJourneyFailure.playbackDidNotStart
        }
        var device: String?
        for negotiation in negotiations {
            let session = try XCTUnwrap(negotiation["session"] as? String)
            let expectedDevice = try XCTUnwrap(negotiation["deviceId"] as? String)
            XCTAssertEqual(negotiation["user"] as? String, "tv-multiaudio")
            XCTAssertFalse(expectedDevice.isEmpty)
            if let device { XCTAssertEqual(expectedDevice, device) } else { device = expectedDevice }
            let matching = cleanups.filter { $0["playSessionId"] as? [String] == [session] }
            XCTAssertEqual(matching.count, 1, "Exactly one cleanup is required for " + session)
            let cleanup = try XCTUnwrap(matching.first)
            XCTAssertEqual(cleanup["user"] as? String, "tv-multiaudio")
            XCTAssertEqual(cleanup["deviceId"] as? [String], [expectedDevice])
        }
    }

    private func multiAudioReset() async throws {
        #if !targetEnvironment(simulator)
        throw TVJourneyFailure.unsafeEnvironment
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV",
              ProcessInfo.processInfo.environment["REEL_TV_QA_DEVICE_UDID"] != nil && ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == ProcessInfo.processInfo.environment["REEL_TV_QA_DEVICE_UDID"] else { throw TVJourneyFailure.unsafeEnvironment }
        for (action, body) in [("reset", "{}"), ("control", "{\"failReports\":false,\"failCleanup\":false,\"reportDelay\":0}")] {
            var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18969/qa/" + action)!)
            request.httpMethod = "POST"; request.httpBody = Data(body.utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        #endif
    }

    private func multiAudioState() async throws -> (Data, [String: Any]) {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV",
              ProcessInfo.processInfo.environment["REEL_TV_QA_DEVICE_UDID"] != nil && ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == ProcessInfo.processInfo.environment["REEL_TV_QA_DEVICE_UDID"] else { throw TVJourneyFailure.unsafeEnvironment }
        let (data, response) = try await URLSession.shared.data(for: try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18969/qa/state")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return (data, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    private func multiAudioReady(_ app: XCUIApplication) async throws {
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        XCTAssertFalse(app.buttons["retryPlayer"].exists)
        XCUIRemote.shared.press(.up)
        let clock = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "(00|01):[0-5][0-9]"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [clock], timeout: 15)
    }

    private func multiAudioPause(_ paused: Bool, app: XCUIApplication) async throws {
        var current: (reports: [[String: Any]], paused: Bool, session: String)?
        for _ in 0..<50 {
            let (_, state) = try await multiAudioState()
            let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
            if let session = (state["multiAudioNegotiations"] as? [[String: Any]])?.last?["session"] as? String,
               let negotiation = reports.lastIndex(where: { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-multiaudio" }),
               let start = reports.indices.dropFirst(negotiation + 1).first(where: { reports[$0]["path"] as? String == "/Sessions/Playing" && reports[$0]["user"] as? String == "tv-multiaudio" && (reports[$0]["body"] as? [String: Any])?["PlaySessionId"] as? String == session }),
               let event = reports[start...].last(where: { ["/Sessions/Playing", "/Sessions/Playing/Progress"].contains($0["path"] as? String ?? "") && $0["user"] as? String == "tv-multiaudio" && ($0["body"] as? [String: Any])?["PlaySessionId"] as? String == session }),
               let value = (event["body"] as? [String: Any])?["IsPaused"] as? Bool { current = (reports, value, session); break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let state = try XCTUnwrap(current, "This actual player must report its own state before native PlayPause.")
        if state.paused != paused {
            XCUIRemote.shared.press(.playPause)
            var matched = false
            for _ in 0..<100 {
                let (_, after) = try await multiAudioState()
                let reports = try XCTUnwrap(after["reports"] as? [[String: Any]])
                if reports.dropFirst(state.reports.count).contains(where: { $0["path"] as? String == "/Sessions/Playing/Progress" && $0["user"] as? String == "tv-multiaudio" && ($0["body"] as? [String: Any])?["PlaySessionId"] as? String == state.session && ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == paused }) { matched = true; break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertTrue(matched)
        }
        XCTAssertFalse(app.buttons["replay"].exists)
        if paused {
            let elapsed = try nativeElapsedSeconds(app)
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(try nativeElapsedSeconds(app), elapsed)
        }
    }

    private func selectNativeAudio(_ title: String, app: XCUIApplication) async throws {
        XCUIRemote.shared.press(.up)
        try select(app.cells.matching(identifier: "AVAudibleSettings").firstMatch, in: app)
        let selected = app.cells.matching(NSPredicate(format: "(label == %@ AND selected == true) OR label == %@", title, "selected, " + title)).firstMatch
        if !selected.exists {
            let row = app.cells.matching(NSPredicate(format: "label == %@ OR label == %@", title, "selected, " + title)).firstMatch
            try select(row, in: app)
        }
        let popup = app.cells.matching(NSPredicate(format: "label IN %@", ["English", "Spanish", "selected, English", "selected, Spanish"])).firstMatch
        if popup.exists && popup.isHittable {
            XCUIRemote.shared.press(.menu)
            await waitUntilGone(popup, timeout: 5)
        }
        try await expectNativeAudio(title, app: app)
    }

    private func expectNativeAudio(_ title: String, app: XCUIApplication) async throws {
        XCUIRemote.shared.press(.up)
        try select(app.cells.matching(identifier: "AVAudibleSettings").firstMatch, in: app)
        let selected = app.cells.matching(NSPredicate(format: "(label == %@ AND selected == true) OR label == %@", title, "selected, " + title)).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        capture("Native Audio checked " + title, app: app)
        captureHierarchy("Native Audio checked hierarchy " + title, app: app)
        XCUIRemote.shared.press(.menu)
        await waitUntilGone(selected, timeout: 5)
    }

    private func multiAudioFrames(_ captions: Bool?, phase: String, app: XCUIApplication) async throws {
        let elapsed = try nativeElapsedSeconds(app)
        var confirmed = 0
        for frame in 0..<8 {
            let screenshot = app.screenshot()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: try XCTUnwrap(screenshot.image.cgImage)).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            let picture = XCTAttachment(screenshot: screenshot); picture.name = phase + " frame\(frame)"; picture.lifetime = .keepAlways; add(picture)
            let text = XCTAttachment(string: words); text.name = phase + " OCR\(frame)"; text.lifetime = .keepAlways; add(text)
            if words.contains("MULTI AUDIO FIXTURE") && words.contains("ORIGINAL GENERATED VIDEO") && (captions.map { words.contains("REEL TV MULTI AUDIO CAPTION") == $0 } ?? true) { confirmed += 1 } else { confirmed = 0 }
            if confirmed == 2 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(confirmed, 2)
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@ AND label MATCHES %@", String(format: "%02d:%02d", elapsed / 60, elapsed % 60), "(00|01):[0-5][0-9]"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [advancing], timeout: 10)
    }

    private func multiAudioReceipt(_ phase: String) async throws {
        let (data, state) = try await multiAudioState()
        let requests = try XCTUnwrap(state["multiAudioRequests"] as? [[String: Any]])
        let negotiation = try XCTUnwrap((state["multiAudioNegotiations"] as? [[String: Any]])?.last)
        let master = try XCTUnwrap(negotiation["source"] as? String)
        let prefix = String(master.dropLast("master.m3u8".count))
        XCTAssertTrue(requests.contains { $0["method"] as? String == "GET" && ($0["path"] as? String)?.hasPrefix(prefix + "es/segment") == true })
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Multi-audible phase \(phase) without diagnostics"; attachment.lifetime = .keepAlways; add(attachment)
        print("REEL_QA_AUDIO_PHASE " + phase + " time=" + String(Date().timeIntervalSince1970))
    }

    func testRemoteSignInHomeDetailsAndBack() async throws {
        let app = try await launchFreshQAApp()
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15))
        capture("Connect", app: app)
        try signIn(app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        capture("Home", app: app)
        try select(app.buttons["heroDetails"], in: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        capture("Movie detail", app: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 10))
    }

    func testRemoteMovieVersionsAudioSubtitlesPlaybackStartOverAndSavedRelaunch() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try select(app.buttons["heroDetails"], in: app)
        XCTAssertTrue(app.buttons["sourceOptions"].waitForExistence(timeout: 15))
        try select(app.buttons["sourceOptions"], in: app)
        try choose("Alternate version", app: app)
        expectMenu("sourceOptions", contains: "Alternate version", app: app)
        try select(app.buttons["audioOptions"], in: app)
        try choose("Alternate English", app: app)
        expectMenu("audioOptions", contains: "Alternate English", app: app)
        XCTAssertFalse(app.buttons["subtitleOptions"].exists)
        try select(app.buttons["sourceOptions"], in: app)
        try choose("Original", app: app)
        expectMenu("audioOptions", contains: "Default", app: app)
        try select(app.buttons["audioOptions"], in: app)
        try choose("English · AAC stereo", app: app)
        try select(app.buttons["audioOptions"], in: app)
        try choose("Server default", app: app)
        expectMenu("audioOptions", contains: "Default", app: app)
        try select(app.buttons["audioOptions"], in: app)
        try choose("English · AAC stereo", app: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("English · VTT", app: app)
        expectMenu("subtitleOptions", contains: "English · VTT", app: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Server default", app: app)
        expectMenu("subtitleOptions", contains: "Default", app: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Off", app: app)
        expectMenu("subtitleOptions", contains: "Off", app: app)
        try await Task.sleep(for: .milliseconds(400))
        capture("Movie selected tracks", app: app)
        try select(app.buttons["detailPlay"], in: app, activate: false)
        capture("Focused primary Play", app: app)
        XCUIRemote.shared.press(.select)
        try await waitForPlaybackStarts(1)
        let initialReports = try await fixtureReports()
        let initial = try XCTUnwrap(initialReports.first { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }?["body"] as? [String: Any])
        XCTAssertEqual(initial["MediaSourceId"] as? String, "movie-1-source")
        XCTAssertEqual(initial["AudioStreamIndex"] as? Int, 1)
        XCTAssertEqual(initial["SubtitleStreamIndex"] as? Int, -1)
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        XCTAssertFalse(app.buttons["retryPlayer"].exists)
        XCUIRemote.shared.press(.playPause)
        try choose("Quality", app: app)
        try choose("High · 20 Mbps", app: app)
        try await waitForPlaybackStarts(2)
        let changedReports = try await fixtureReports()
        let changed = try XCTUnwrap(changedReports.last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }?["body"] as? [String: Any])
        XCTAssertEqual(changed["MaxStreamingBitrate"] as? Int, 20_000_000)
        XCUIRemote.shared.press(.playPause)
        try choose("Speed", app: app)
        try choose("2×", app: app)
        try choose("Chapters", app: app)
        let beforeChapter = try await fixtureReports().count
        try choose("A new chapter", app: app)
        try await waitForChapterSeek(after: beforeChapter)
        await waitUntilGone(app.cells["A new chapter"], timeout: 5)
        let settledTimeline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "00:08"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [settledTimeline], timeout: 15)
        capture("Native chapter and transport controls", app: app)
        captureHierarchy("Native player hierarchy", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        XCTAssertTrue(app.buttons["startOver"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["detailPlay"].label.contains("Resume"))
        let savedReports = try await fixtureReports()
        let saved = try XCTUnwrap(savedReports.last { $0["path"] as? String == "/Sessions/Playing/Stopped" && $0["user"] as? String == "tv-ui" }?["body"] as? [String: Any])
        let savedTicks = try XCTUnwrap(saved["PositionTicks"] as? Int)
        XCTAssertGreaterThan(savedTicks, 0)
        try select(app.buttons["detailPlay"], in: app)
        try await waitForPlaybackStarts(3)
        let resumedReports = try await fixtureReports()
        let resumed = try XCTUnwrap(resumedReports.last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }?["body"] as? [String: Any])
        let resumedTicks = try XCTUnwrap(resumed["StartTimeTicks"] as? Int)
        XCTAssertEqual(resumedTicks, savedTicks)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        XCTAssertTrue(app.buttons["startOver"].waitForExistence(timeout: 15))
        try select(app.buttons["startOver"], in: app)
        try await waitForPlaybackStarts(4)
        let restartedReports = try await fixtureReports()
        let restarted = try XCTUnwrap(restartedReports.last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }?["body"] as? [String: Any])
        XCTAssertEqual(restarted["StartTimeTicks"] as? Int, 0)
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        app.terminate()
        app.launchArguments = []
        app.launch()
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.textFields["server"].exists)
        capture("Saved sign-in relaunch", app: app)
    }

    func testRemoteNativeTransportFocusAndQuality() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        try select(app.buttons["heroPlay"], in: app)
        try await waitForPlaybackStarts(1)
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        XCUIRemote.shared.press(.playPause)
        XCUIRemote.shared.press(.up)
        capture("Native transport after Pause and Up", app: app)
        captureHierarchy("Native focus before choosing quality", app: app)
        for (index, quality) in [("High · 20 Mbps", 20_000_000), ("Balanced · 8 Mbps", 8_000_000), ("Original / auto", 120_000_000), ("Data saver · 2 Mbps", 2_000_000)].enumerated() {
            try choose("Quality", app: app)
            try choose(quality.0, app: app)
            try await waitForPlaybackStarts(index + 2)
            let reports = try await fixtureReports()
            let changed = try XCTUnwrap(reports.last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }?["body"] as? [String: Any])
            XCTAssertEqual(changed["MaxStreamingBitrate"] as? Int, quality.1)
            await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
            XCUIRemote.shared.press(.playPause)
        }
        capture("Native quality changed", app: app)
        try await closeNativePlayer(returningTo: app.buttons["heroPlay"], app: app)
    }

    func testRemoteEveryNativeSpeedAndOpeningChapterChoice() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        try select(app.buttons["heroPlay"], in: app)
        try await waitForPlaybackStarts(1)
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        XCUIRemote.shared.press(.playPause)
        XCUIRemote.shared.press(.up)
        for speed in ["0.75×", "1×", "1.25×", "1.5×", "2×"] {
            try choose("Speed", app: app)
            try choose(speed, app: app)
            try choose("Speed", app: app)
            let selectedSpeed = app.cells.matching(NSPredicate(format: "(label == %@ AND selected == true) OR label == %@", speed, "selected, " + speed)).firstMatch
            XCTAssertTrue(selectedSpeed.waitForExistence(timeout: 5))
            capture("Native selected speed " + speed, app: app)
            captureHierarchy("Native selected speed state " + speed, app: app)
            XCUIRemote.shared.press(.menu)
        }
        try choose("Chapters", app: app)
        let beforeSeek = try await fixtureReports().count
        try choose("Opening", app: app)
        try await waitForChapterSeek(after: beforeSeek, at: 0)
        capture("Opening chapter returns to zero", app: app)
        try await closeNativePlayer(returningTo: app.buttons["heroPlay"], app: app)
    }

    func testRemoteNativeDirectionalSkippingCommitsAndReturnsToLibrary() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        try select(app.buttons["heroPlay"], in: app)
        try await waitForPlaybackStarts(1)
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)

        func pausePosition(after boundary: Int) async throws -> Int {
            for _ in 0..<100 {
                let reports = try await fixtureReports()
                if let body = reports.dropFirst(boundary).last(where: {
                    $0["user"] as? String == "tv-ui" && $0["path"] as? String == "/Sessions/Playing/Progress" && ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == true
                })?["body"] as? [String: Any], let ticks = body["PositionTicks"] as? Int { return ticks }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("Native Pause did not report a fresh timeline position.")
            throw TVJourneyFailure.unavailableControl("native paused timeline")
        }

        func playingPosition(after boundary: Int, since commit: ContinuousClock.Instant, within range: ClosedRange<Int>) async throws -> Int {
            // The forward range starts eight seconds beyond the paused point.
            // A five-second deadline measured before PlayPause prevents normal
            // resumed playback from satisfying a missing directional action.
            let deadline = commit.advanced(by: .seconds(5))
            while ContinuousClock.now < deadline {
                let reports = try await fixtureReports()
                guard ContinuousClock.now < deadline else { break }
                if let body = reports.dropFirst(boundary).last(where: {
                    guard $0["user"] as? String == "tv-ui", $0["path"] as? String == "/Sessions/Playing/Progress",
                          let body = $0["body"] as? [String: Any], body["IsPaused"] as? Bool == false,
                          let ticks = body["PositionTicks"] as? Int else { return false }
                    return range.contains(ticks)
                })?["body"] as? [String: Any], let ticks = body["PositionTicks"] as? Int { return ticks }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("Native directional transport did not commit the expected playing timeline range: \(range).")
            throw TVJourneyFailure.unavailableControl("native directional seek effect")
        }

        let beforePause = try await fixtureReports().count
        XCUIRemote.shared.press(.playPause)
        let original = try await pausePosition(after: beforePause)
        XCTAssertLessThan(original, 80_000_000, "The short synthetic clip must have room for a ten-second forward action.")
        captureHierarchy("Native timeline before directional transport", app: app)
        let beforeRight = try await fixtureReports().count
        XCUIRemote.shared.press(.right)
        capture("Native Right transport preview", app: app)
        let forwardCommit = ContinuousClock.now
        XCUIRemote.shared.press(.playPause)
        let forward = try await playingPosition(after: beforeRight, since: forwardCommit, within: (original + 80_000_000)...(original + 140_000_000))
        let forwardTimeline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "00:(1[0-9]|20)"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [forwardTimeline], timeout: 5)
        capture("Native forward transport committed", app: app)
        captureHierarchy("Native forward transport effect", app: app)

        let beforeSecondPause = try await fixtureReports().count
        XCUIRemote.shared.press(.playPause)
        let pausedForward = try await pausePosition(after: beforeSecondPause)
        XCTAssertGreaterThanOrEqual(pausedForward, forward)
        let beforeLeft = try await fixtureReports().count
        XCUIRemote.shared.press(.left)
        capture("Native Left transport preview", app: app)
        let backwardCommit = ContinuousClock.now
        XCUIRemote.shared.press(.playPause)
        _ = try await playingPosition(after: beforeLeft, since: backwardCommit, within: max(0, pausedForward - 120_000_000)...max(0, pausedForward - 70_000_000))
        let returnedTimeline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "00:0[0-9]"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [returnedTimeline], timeout: 5)
        capture("Native backward transport committed", app: app)
        captureHierarchy("Native backward transport effect", app: app)
        try await closeNativePlayer(returningTo: app.buttons["heroPlay"], app: app)
    }

    func testRemoteLibraryFiltersAndSearch() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["filter-Series"].waitForExistence(timeout: 15))
        try select(app.buttons["filter-Series"], in: app)
        XCTAssertTrue(app.staticTexts["libraryCount"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["libraryCount"].label, "3 of 3 titles")
        capture("Series library", app: app)
        try select(app.buttons["item-series-7"], in: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["detailTitle"].label, "Out of the Blue")
        XCTAssertTrue(app.buttons["episode-episode-1-1"].waitForExistence(timeout: 15))
        capture("Series seasons and episodes", app: app)
        captureHierarchy("Series controls", app: app)
        XCUIRemote.shared.press(.menu)
        try select(app.buttons["filter-Movies"], in: app)
        XCTAssertEqual(app.staticTexts["libraryCount"].label, "60 of 72 titles")
        try select(app.buttons["filter-All"], in: app)
        XCTAssertEqual(app.staticTexts["libraryCount"].label, "60 of 75 titles")
        try openTab("Search", app: app)
        XCTAssertTrue(app.staticTexts["A title in mind?"].waitForExistence(timeout: 15))
        try enter("Nothing matches this title", into: app.textFields["search"], app: app)
        XCTAssertTrue(app.staticTexts["No titles found."].waitForExistence(timeout: 15))
        try enter("Out of the Blue", into: app.textFields["search"], replacing: "Nothing matches this title", app: app)
        XCTAssertTrue(app.buttons["item-series-7"].waitForExistence(timeout: 15))
        try select(app.buttons["item-series-7"], in: app)
        XCTAssertTrue(app.buttons["episode-episode-1-1"].waitForExistence(timeout: 15))
    }

    func testRemoteOwnedSubtitlesOnOffOnRetainsPositionWithPrivateViewing() async throws {
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        try await subtitleControl("reset", [:])
        try await subtitleControl("control", ["failReports": false, "failCleanup": false])
        try signIn(app, user: "tv-track-output", server: "http://127.0.0.1:18968")
        try openTab("Settings", app: app)
        try select(control("privateViewing", app: app), in: app)
        await expectPrivateViewing(true, app: app)
        try openTab("Home", app: app)
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Synthetic captions", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await subtitlePlaybackReady(app)
        XCTAssertFalse(app.cells.matching(identifier: "AVLegibleSettings").firstMatch.exists)
        XCTAssertTrue(app.cells.matching(identifier: "AVAudibleSettings").firstMatch.isHittable)
        try await assertSubtitlePixels(true, phase: "Owned Subtitles initial explicit On", app: app)
        try await expectOwnedSubtitle("Synthetic captions", app: app)
        let beforeOff = try nativeElapsedSeconds(app)
        XCTAssertGreaterThanOrEqual(beforeOff, 3)
        try choose("Subtitles", app: app)
        try choose("Off", app: app)
        try await subtitlePlaybackReady(app)
        try await assertSubtitlePixels(false, phase: "Owned Subtitles Off actively playing", app: app)
        try await expectOwnedSubtitle("Off", app: app)
        let beforeOn = try nativeElapsedSeconds(app)
        try choose("Subtitles", app: app)
        try choose("Synthetic captions", app: app)
        try await subtitlePlaybackReady(app)
        try await assertSubtitlePixels(true, phase: "Owned Subtitles On again actively playing", app: app)
        try await expectOwnedSubtitle("Synthetic captions", app: app)
        let beforeDefault = try nativeElapsedSeconds(app)
        try choose("Subtitles", app: app)
        try choose("Server default", app: app)
        try await subtitlePlaybackReady(app)
        try await assertSubtitlePixels(nil, phase: "Owned Subtitles default preserves system policy with decoded video", app: app)
        try await expectOwnedSubtitle("Server default", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        let (data, state) = try await subtitleState()
        let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
        let negotiations = reports.filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.compactMap { $0["body"] as? [String: Any] }
        XCTAssertEqual(negotiations.count, 4)
        guard negotiations.count == 4 else { throw TVJourneyFailure.unavailableControl("four subtitle negotiations") }
        XCTAssertEqual(negotiations.prefix(3).compactMap { $0["SubtitleStreamIndex"] as? Int }, [2, -1, 2])
        XCTAssertNil(negotiations[3]["SubtitleStreamIndex"])
        XCTAssertTrue(((beforeOff - 1) * 10_000_000...(beforeOff + 10) * 10_000_000).contains(negotiations[1]["StartTimeTicks"] as? Int ?? -1))
        XCTAssertTrue(((beforeOn - 1) * 10_000_000...(beforeOn + 10) * 10_000_000).contains(negotiations[2]["StartTimeTicks"] as? Int ?? -1))
        XCTAssertTrue(((beforeDefault - 1) * 10_000_000...(beforeDefault + 10) * 10_000_000).contains(negotiations[3]["StartTimeTicks"] as? Int ?? -1))
        XCTAssertFalse(reports.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        XCTAssertEqual((state["subtitleCleanups"] as? [[String: Any]])?.count, 4)
        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        receipt.name = "Owned Subtitles private On Off On local position and cleanup receipt"; receipt.lifetime = .keepAlways; add(receipt)
    }

    func testRemoteOwnedSubtitleMismatchRetriesAndOffRecovers() async throws {
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        try await subtitleControl("reset", [:])
        try await subtitleControl("control", ["failReports": false, "failCleanup": false])
        try signIn(app, user: "tv-track-output", server: "http://127.0.0.1:18968")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Off", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await subtitlePlaybackReady(app)
        try await subtitleControl("tv-control", ["subtitleWrongName": true])
        try choose("Subtitles", app: app)
        try choose("Synthetic captions", app: app)
        XCTAssertTrue(app.buttons["retryPlayer"].waitForExistence(timeout: 30))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "couldn’t be matched safely")).firstMatch.exists)
        capture("Owned Subtitles mismatch actionable recovery", app: app)
        try await subtitleControl("tv-control", ["subtitleWrongName": false])
        try select(app.buttons["retryPlayer"], in: app)
        try await subtitlePlaybackReady(app)
        try await assertSubtitlePixels(true, phase: "Owned Subtitles retry genuine cue", app: app)
        try await expectOwnedSubtitle("Synthetic captions", app: app)
        try choose("Subtitles", app: app)
        try choose("Off", app: app)
        try await subtitlePlaybackReady(app)
        try await assertSubtitlePixels(false, phase: "Owned Subtitles Off after recovery", app: app)
        try await expectOwnedSubtitle("Off", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
    }

    func testRemotePausedSubtitleSwitchNeverResumesUntilNativePlay() async throws {
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        try await subtitleControl("reset", [:])
        try await subtitleControl("control", ["failReports": false, "failCleanup": false])
        try signIn(app, user: "tv-track-output", server: "http://127.0.0.1:18968")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Synthetic captions", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await subtitlePlaybackReady(app)
        try await assertSubtitlePixels(true, phase: "Playing before explicit native pause", app: app)
        try await assertMovingSubtitleRegion(app)
        let (_, playingState) = try await subtitleState()
        let pauseBoundary = (playingState["reports"] as? [[String: Any]] ?? []).count
        XCUIRemote.shared.press(.playPause)
        try await subtitlePause(true, after: pauseBoundary)
        let (_, pausedState) = try await subtitleState()
        let switchBoundary = (pausedState["reports"] as? [[String: Any]] ?? []).count
        try choose("Subtitles", app: app)
        try choose("Off", app: app)
        try await subtitlePlaybackReady(app)
        try await assertPausedSubtitleFrame(app)
        try await expectOwnedSubtitle("Off", app: app)
        let (_, switched) = try await subtitleState()
        let events = (switched["reports"] as? [[String: Any]] ?? []).dropFirst(switchBoundary).filter { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true }
        XCTAssertEqual(events.filter { $0["path"] as? String == "/Sessions/Playing" }.count, 1)
        XCTAssertTrue(events.allSatisfy { ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == true })
        let resumeBoundary = (switched["reports"] as? [[String: Any]] ?? []).count
        XCUIRemote.shared.press(.playPause)
        try await subtitlePause(false, after: resumeBoundary)
        try await assertSubtitlePixels(false, phase: "Off advances only after actual native Play", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
    }

    func testRemoteAmbiguousSubtitleCatalogContinueBackAndReloadRecover() async throws {
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        try await subtitleControl("reset", [:])
        try await subtitleControl("control", ["failReports": false, "failCleanup": false])
        try await subtitleControl("tv-control", ["subtitleCatalogAmbiguous": true])
        try signIn(app, user: "tv-track-output", server: "http://127.0.0.1:18968")
        try select(app.buttons["heroDetails"], in: app)
        for round in 0..<2 {
            try select(app.buttons["subtitleOptions"], in: app)
            try choose("Off", app: app)
            try select(app.buttons["detailPlay"], in: app)
            try await subtitlePlaybackReady(app)
            try await setCatalogPlaybackPaused(true, app: app)
            try choose("Subtitles", app: app)
            try chooseSubtitleCatalogError(app)
            XCTAssertTrue(app.buttons["continueAfterSubtitleError"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "can’t be distinguished safely")).firstMatch.exists)
            capture("Ambiguous subtitle catalog focused recovery \(round)", app: app)
            if round == 0 {
                try select(app.buttons["closePlayer"], in: app)
                let back = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["detailPlay"])
                await fulfillment(of: [back], timeout: 10)
                XCTAssertFalse(app.cells["Quality"].exists)
            }
        }
        let (_, beforeContinue) = try await subtitleState()
        let count = (beforeContinue["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count
        try select(app.buttons["continueAfterSubtitleError"], in: app)
        try await subtitlePlaybackReady(app)
        try await setCatalogPlaybackPaused(false, app: app)
        try await assertSubtitlePixels(false, phase: "Ambiguous catalog Continue preserves running video", app: app)
        try await setCatalogPlaybackPaused(true, app: app)
        let (_, continued) = try await subtitleState()
        XCTAssertEqual((continued["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count, count)
        try choose("Subtitles", app: app)
        try chooseSubtitleCatalogError(app)
        try await subtitleControl("tv-control", ["subtitleCatalogUnavailable": true])
        try select(app.buttons["reloadSubtitleTracks"], in: app)
        try choose("Subtitles", app: app)
        try chooseSubtitleCatalogError(app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "track list couldn’t load")).firstMatch.waitForExistence(timeout: 5))
        capture("Subtitle metadata request failure stays recoverable", app: app)
        try await subtitleControl("tv-control", ["subtitleCatalogUnavailable": false, "subtitleCatalogAmbiguous": false, "subtitleCatalogDelay": true])
        try select(app.buttons["reloadSubtitleTracks"], in: app)
        XCUIRemote.shared.press(.up)
        try choose("Subtitles", app: app)
        let loading = app.cells.matching(NSPredicate(format: "label == %@", "Loading subtitle tracks…")).firstMatch
        XCTAssertTrue(loading.waitForExistence(timeout: 2))
        let (_, beforeLoadingActivation) = try await subtitleState()
        let negotiations = (beforeLoadingActivation["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count
        let pausedElapsed = try nativeElapsedSeconds(app)
        for _ in 0..<3 { XCUIRemote.shared.press(.down) }
        XCUIRemote.shared.press(.select)
        if !loading.exists { try choose("Subtitles", app: app) }
        XCTAssertTrue(loading.waitForExistence(timeout: 2), "The attempted activation must still be inside the held loading state.")
        let (loadingReceipt, afterLoadingActivation) = try await subtitleState()
        XCTAssertEqual((afterLoadingActivation["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }.count, negotiations, "Remote activation while the public menu actions are disabled must not restart playback.")
        XCTAssertEqual(try nativeElapsedSeconds(app), pausedElapsed)
        let receipt = XCTAttachment(data: loadingReceipt, uniformTypeIdentifier: "public.json")
        receipt.name = "Held subtitle loading remote activation has no negotiation"; receipt.lifetime = .keepAlways; add(receipt)
        captureHierarchy("Subtitle loading menu after attempted remote activation", app: app)
        capture("Subtitle track metadata reload loading state", app: app)
        try await subtitleControl("tv-control", ["subtitleCatalogDelay": false])
        if loading.exists { XCUIRemote.shared.press(.menu) }
        await waitUntilGone(loading, timeout: 10)
        try choose("Subtitles", app: app)
        try choose("Synthetic captions", app: app)
        try await subtitlePlaybackReady(app)
        try await setCatalogPlaybackPaused(false, app: app)
        try await assertSubtitlePixels(true, phase: "Reloaded unambiguous subtitle catalog renders genuine cue", app: app)
        try await setCatalogPlaybackPaused(true, app: app)
        try await expectOwnedSubtitle("Synthetic captions", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
    }

    private func setCatalogPlaybackPaused(_ paused: Bool, app: XCUIApplication) async throws {
        var currentState: (reports: [[String: Any]], paused: Bool)?
        for _ in 0..<50 {
            let (_, state) = try await subtitleState()
            let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
            if let negotiation = reports.lastIndex(where: { $0["user"] as? String == "tv-track-output" && $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }),
               let start = reports.indices.dropFirst(negotiation + 1).first(where: { reports[$0]["user"] as? String == "tv-track-output" && reports[$0]["path"] as? String == "/Sessions/Playing" }),
               let event = reports[start...].last(where: { $0["user"] as? String == "tv-track-output" && ["/Sessions/Playing", "/Sessions/Playing/Progress"].contains($0["path"] as? String ?? "") }),
               let current = (event["body"] as? [String: Any])?["IsPaused"] as? Bool {
                currentState = (reports, current)
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        let current = try XCTUnwrap(currentState, "The current negotiated player must publish its own start/pause state before any toggle.")
        if current.paused != paused {
            XCUIRemote.shared.press(.playPause)
            try await subtitlePause(paused, after: current.reports.count)
        }
        XCTAssertFalse(app.buttons["replay"].exists)
        if paused {
            let elapsed = try nativeElapsedSeconds(app)
            try await Task.sleep(for: .milliseconds(1200))
            XCTAssertEqual(try nativeElapsedSeconds(app), elapsed)
        }
    }

    private func assertPausedSubtitleFrame(_ app: XCUIApplication) async throws {
        let initialElapsed = try nativeElapsedSeconds(app)
        var crops: [Data] = []
        for frame in 0..<2 {
            let screenshot = app.screenshot()
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]; request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: image).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            XCTAssertTrue(words.contains("ORIGINAL VERSION") && words.contains("SYNTHETIC 440 HZ"))
            XCTAssertFalse(words.contains("REEL TV CAPTION CHECK"))
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 120)))
            crops.append(try XCTUnwrap(UIImage(cgImage: crop).pngData()))
            let picture = XCTAttachment(screenshot: screenshot)
            picture.name = "Paused Off rendered video frame \(frame)"; picture.lifetime = .keepAlways; add(picture)
            if frame == 0 { try await Task.sleep(for: .seconds(1)) }
        }
        XCTAssertEqual(crops[0], crops[1], "The same source region proven to move during playback must remain stable after the paused subtitle change.")
        XCTAssertEqual(try nativeElapsedSeconds(app), initialElapsed)
    }

    private func chooseSubtitleCatalogError(_ app: XCUIApplication) throws {
        // AVKit adds the warning image's spoken name when this row gains focus.
        let row = app.cells.matching(NSPredicate(format: "label == %@ OR label == %@", "Track list unavailable", "Track list unavailable, warning")).firstMatch
        captureHierarchy("Subtitle catalog recovery menu before activation", app: app)
        capture("Subtitle catalog recovery menu before activation", app: app)
        try select(row, in: app)
    }

    private func assertMovingSubtitleRegion(_ app: XCUIApplication) async throws {
        var crops: [Data] = []
        for frame in 0..<2 {
            let screenshot = app.screenshot()
            let image = try XCTUnwrap(screenshot.image.cgImage)
            let crop = try XCTUnwrap(image.cropping(to: CGRect(x: 0, y: 0, width: 400, height: 120)))
            crops.append(try XCTUnwrap(UIImage(cgImage: crop).pngData()))
            let picture = XCTAttachment(screenshot: screenshot)
            picture.name = "Playing moving-source-region counterfactual \(frame)"; picture.lifetime = .keepAlways; add(picture)
            if frame == 0 { try await Task.sleep(for: .seconds(1)) }
        }
        XCTAssertNotEqual(crops[0], crops[1], "The paused-image comparison requires this exact source region to change while actively playing in the same journey.")
    }

    private func expectOwnedSubtitle(_ title: String, app: XCUIApplication) async throws {
        try choose("Subtitles", app: app)
        let selected = app.cells.matching(NSPredicate(format: "(label == %@ AND selected == true) OR label == %@", title, "selected, " + title)).firstMatch
        XCTAssertTrue(selected.waitForExistence(timeout: 5))
        capture("Owned Subtitles checked " + title, app: app)
        captureHierarchy("Owned Subtitles checked hierarchy " + title, app: app)
        XCUIRemote.shared.press(.menu)
        await waitUntilGone(selected, timeout: 5)
    }

    private func nativeElapsedSeconds(_ app: XCUIApplication) throws -> Int {
        let label = app.otherElements["AXElapsedTime"].label
        let parts = label.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2 else { throw TVJourneyFailure.unavailableControl("native elapsed position: " + label) }
        return parts[0] * 60 + parts[1]
    }

    func researchEmptySubtitleLanguageFilterKeepsAudioCaptionsAndTransportUsable() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Native player capability probes require the disposable TV simulator.")
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV" else { throw TVJourneyFailure.unsafeEnvironment }
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        try await subtitleControl("reset", [:])
        try await subtitleControl("control", ["failReports": false, "failCleanup": false])
        try signIn(app, user: "tv-track-output", server: "http://127.0.0.1:18968")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Synthetic captions", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await subtitlePlaybackReady(app)
        capture("Subtitle-language filter initial native transport", app: app)
        captureHierarchy("Subtitle-language filter controls inventory", app: app)
        var observedControls: [[String: Any]] = []
        for identifier in ["AVLegibleSettings", "AVAudibleSettings", "Quality", "Speed", "Chapters"] {
            let element = app.cells.matching(identifier: identifier).firstMatch
            let exists = element.exists
            observedControls.append(["identifier": identifier, "exists": exists,
                                     "hittable": exists && element.isHittable, "label": exists ? element.label : "absent"])
        }
        let observed = XCTAttachment(data: try JSONSerialization.data(withJSONObject: observedControls, options: [.prettyPrinted, .sortedKeys]), uniformTypeIdentifier: "public.json")
        observed.name = "Subtitle-language filter actual control labels and reachability"
        observed.lifetime = .keepAlways; add(observed)
        XCTAssertFalse(app.cells.matching(identifier: "AVLegibleSettings").firstMatch.exists, "The built-in Subtitle control must disappear before an owned replacement is considered.")
        XCTAssertTrue(app.cells.matching(identifier: "AVAudibleSettings").firstMatch.isHittable, "The native Audio control must remain reachable.")
        XCTAssertTrue(app.cells["Quality"].isHittable)
        XCTAssertTrue(app.cells["Speed"].exists)
        XCTAssertTrue(app.cells["Chapters"].exists)

        func reports() async throws -> [[String: Any]] {
            let (_, state) = try await subtitleState()
            return try XCTUnwrap(state["reports"] as? [[String: Any]])
        }
        func progress(after boundary: Int, paused: Bool, within range: ClosedRange<Int>? = nil, deadline: ContinuousClock.Instant) async throws -> Int {
            while ContinuousClock.now < deadline {
                let values = try await reports()
                guard ContinuousClock.now < deadline else { break }
                for value in values.dropFirst(boundary).reversed() {
                    guard value["user"] as? String == "tv-track-output", value["path"] as? String == "/Sessions/Playing/Progress",
                          let body = value["body"] as? [String: Any], body["IsPaused"] as? Bool == paused,
                          let ticks = body["PositionTicks"] as? Int, range?.contains(ticks) != false else { continue }
                    return ticks
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTFail("The native transport did not report its fresh paused/seek state.")
            throw TVJourneyFailure.unavailableControl("native transport capability effect")
        }
        let pauseBoundary = try await reports().count
        XCUIRemote.shared.press(.playPause)
        let paused = try await progress(after: pauseBoundary, paused: true, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        XCTAssertLessThan(paused, 80_000_000)
        let seekBoundary = try await reports().count
        XCUIRemote.shared.press(.right)
        capture("Subtitle-language filter retains native Right preview", app: app)
        let commit = ContinuousClock.now
        XCUIRemote.shared.press(.playPause)
        _ = try await progress(after: seekBoundary, paused: false, within: (paused + 80_000_000)...(paused + 140_000_000), deadline: commit.advanced(by: .seconds(5)))
        let forwardTimeline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "00:(1[0-9]|20)"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [forwardTimeline], timeout: 5)
        capture("Subtitle-language filter retains committed native seek", app: app)

        let qualityPauseBoundary = try await reports().count
        XCUIRemote.shared.press(.playPause)
        _ = try await progress(after: qualityPauseBoundary, paused: true, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        try select(app.cells.matching(identifier: "AVAudibleSettings").firstMatch, in: app)
        let englishAudio = app.cells.matching(NSPredicate(format: "(label == %@ AND selected == true) OR label == %@", "English", "selected, English")).firstMatch
        XCTAssertTrue(englishAudio.waitForExistence(timeout: 5), "Opening the native Audio menu must expose its selected English rendition.")
        capture("Subtitle-language filter retains native selected Audio", app: app)
        captureHierarchy("Subtitle-language filter native Audio menu", app: app)
        XCUIRemote.shared.press(.menu)
        await waitUntilGone(englishAudio, timeout: 5)
        XCTAssertTrue(app.cells["Quality"].isHittable)
        try choose("Quality", app: app)
        try choose("Data saver · 2 Mbps", app: app)
        var changedQuality = false
        for _ in 0..<150 {
            let values = try await reports()
            let negotiations = values.filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }
            let starts = values.filter { $0["path"] as? String == "/Sessions/Playing" }
            if negotiations.count == 2, starts.count == 2,
               (negotiations.last?["body"] as? [String: Any])?["MaxStreamingBitrate"] as? Int == 2_000_000 { changedQuality = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(changedQuality, "The surviving Quality menu must negotiate and start the selected bitrate.")
        try await subtitlePlaybackReady(app)
        let menuPauseBoundary = try await reports().count
        XCUIRemote.shared.press(.playPause)
        _ = try await progress(after: menuPauseBoundary, paused: true, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        for speed in ["1.25×", "1×"] {
            try choose("Speed", app: app)
            try choose(speed, app: app)
            try choose("Speed", app: app)
            let selected = app.cells.matching(NSPredicate(format: "(label == %@ AND selected == true) OR label == %@", speed, "selected, " + speed)).firstMatch
            XCTAssertTrue(selected.waitForExistence(timeout: 5))
            capture("Subtitle-language filter retains selected speed " + speed, app: app)
            XCUIRemote.shared.press(.menu)
        }
        try choose("Chapters", app: app)
        let chapterBoundary = try await reports().count
        try choose("A new chapter", app: app)
        _ = try await progress(after: chapterBoundary, paused: true, within: 80_000_000...83_000_000, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        await waitUntilGone(app.cells["A new chapter"], timeout: 5)
        let chapterTimeline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "00:08"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [chapterTimeline], timeout: 10)
        capture("Subtitle-language filter retains native chapter effect", app: app)
        captureHierarchy("Subtitle-language filter final transport hierarchy", app: app)
        let resumeBoundary = try await reports().count
        XCUIRemote.shared.press(.playPause)
        _ = try await progress(after: resumeBoundary, paused: false, deadline: ContinuousClock.now.advanced(by: .seconds(10)))
        XCUIRemote.shared.press(.up)
        try await assertSubtitlePixels(true, phase: "Subtitle-language filter preserves genuine authored VTT", app: app)
        try await subtitleReceipt(2, phase: "Subtitle-language filter preserves authenticated authored VTT")
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        #endif
    }

    func testRemoteExplicitSubtitleStartupAndOwnedMenuAllowLaterChanges() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Subtitle policy journeys require the disposable TV simulator.")
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV" else { throw TVJourneyFailure.unsafeEnvironment }
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        @MainActor func startFresh(_ buttonID: String) async throws {
            func negotiations(_ state: [String: Any]) -> [[String: Any]] {
                (state["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-track-output" }
            }
            let (_, before) = try await subtitleState()
            let previousCount = negotiations(before).count
            try select(app.buttons[buttonID], in: app)
            try await subtitlePlaybackReady(app)
            var current: [[String: Any]] = []
            for _ in 0..<50 {
                let (_, state) = try await subtitleState()
                current = negotiations(state)
                if current.count > previousCount { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard current.count == previousCount + 1 else {
                XCTFail("The actual startup button must produce exactly one fresh matching negotiation.")
                throw TVJourneyFailure.unavailableControl("fresh startup receipt")
            }
            let body = try XCTUnwrap(current[previousCount]["body"] as? [String: Any])
            XCTAssertEqual((body["StartTimeTicks"] as? NSNumber)?.int64Value, 0, "Each startup policy phase uses an actual fresh start, so this short fixture cannot expire while its menus are tested.")
        }
        try await subtitleControl("reset", [:])
        try await subtitleControl("control", ["failReports": false, "failCleanup": false])
        try signIn(app, user: "tv-track-output", server: "http://127.0.0.1:18968")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Synthetic captions", app: app)
        try await startFresh("detailPlay")
        try await expectOwnedSubtitle("Synthetic captions", app: app)
        try await assertSubtitlePixels(true, phase: "Explicit On baseline", app: app)
        try await subtitleReceipt(2, phase: "Explicit On baseline")
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)

        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Off", app: app)
        try await startFresh("startOver")
        try await assertSubtitlePixels(false, phase: "Explicit startup Off after prior On", app: app)
        try await subtitleReceipt(-1, phase: "Explicit Off with real retained rendition")
        try await ownedCaptionChoice(true, app: app)
        try await assertSubtitlePixels(true, phase: "Owned On after app Off", app: app)
        try await ownedCaptionChoice(false, app: app)
        try await assertSubtitlePixels(false, phase: "Owned Off on the same title", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)

        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Synthetic captions", app: app)
        try await startFresh("startOver")
        try await assertSubtitlePixels(true, phase: "Explicit startup On after prior Off", app: app)
        try await subtitleReceipt(2, phase: "Explicit startup On after Off")
        try await ownedCaptionChoice(false, app: app)
        try await assertSubtitlePixels(false, phase: "Later owned Off stays Off after explicit startup On", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        #endif
    }

    func testRemoteUnmatchedSubtitleRetryAndDetailsOffRecoverWithoutWrongTrack() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Subtitle recovery requires the disposable TV simulator.")
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV" else { throw TVJourneyFailure.unsafeEnvironment }
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        try await subtitleControl("reset", [:])
        try await subtitleControl("control", ["failReports": false, "failCleanup": false])
        try await subtitleControl("tv-control", ["subtitleWrongName": true])
        try signIn(app, user: "tv-track-output", server: "http://127.0.0.1:18968")
        try select(app.buttons["heroDetails"], in: app)
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Synthetic captions", app: app)
        try select(app.buttons["detailPlay"], in: app)
        XCTAssertTrue(app.buttons["retryPlayer"].waitForExistence(timeout: 25))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "The selected subtitles couldn’t be matched safely.")).firstMatch.exists)
        capture("Unmatched subtitle actionable error", app: app)
        try select(app.buttons["retryPlayer"], in: app)
        var completedRetry = false
        for _ in 0..<100 {
            let (_, state) = try await subtitleState()
            let requests = (state["reports"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }
            let masters = (state["trackRequests"] as? [[String: Any]] ?? []).filter { ($0["path"] as? String)?.hasSuffix("/master.m3u8") == true }
            if requests.count == 2, (state["subtitleCleanups"] as? [[String: Any]] ?? []).count == 2, masters.count >= 2,
               (requests.last?["body"] as? [String: Any])?["SubtitleStreamIndex"] as? Int == 2 { completedRetry = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(completedRetry, "Retry must finish the second metadata mismatch and its owned encoder cleanup.")
        XCTAssertTrue(app.buttons["retryPlayer"].waitForExistence(timeout: 25))
        capture("Unmatched subtitle retry remains recoverable", app: app)
        try select(app.buttons["closePlayer"], in: app)
        XCTAssertTrue(app.buttons["subtitleOptions"].waitForExistence(timeout: 15))
        try select(app.buttons["subtitleOptions"], in: app)
        try choose("Off", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await subtitlePlaybackReady(app)
        try await assertSubtitlePixels(false, phase: "Details Off recovers mismatched subtitles", app: app)
        try await subtitleReceipt(-1, phase: "Mismatch recovery uses Off on retained rendition", requiresCaptionRequest: false)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        #endif
    }

    private func subtitleControl(_ action: String, _ body: [String: Bool]) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Subtitle fixture mutations are simulator-only.")
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV", ["reset", "control", "tv-control"].contains(action) else { throw TVJourneyFailure.unsafeEnvironment }
        var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18968/qa/" + action)!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        #endif
    }

    private func subtitleState() async throws -> (Data, [String: Any]) {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV" else { throw TVJourneyFailure.unsafeEnvironment }
        let (data, response) = try await URLSession.shared.data(for: try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18968/qa/state")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return (data, try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]))
    }

    private func subtitlePlaybackReady(_ app: XCUIApplication) async throws {
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        XCTAssertFalse(app.buttons["retryPlayer"].exists)
        XCUIRemote.shared.press(.up)
        let timeline = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "00:[0-5][0-9]"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [timeline], timeout: 15)
    }

    private func ownedCaptionChoice(_ enabled: Bool, app: XCUIApplication) async throws {
        try choose("Subtitles", app: app)
        try choose(enabled ? "Synthetic captions" : "Off", app: app)
        try await subtitlePlaybackReady(app)
        try await expectOwnedSubtitle(enabled ? "Synthetic captions" : "Off", app: app)
    }

    private func subtitlePause(_ paused: Bool, after count: Int) async throws {
        for _ in 0..<100 {
            let (_, state) = try await subtitleState()
            if (state["reports"] as? [[String: Any]] ?? []).dropFirst(count).contains(where: { $0["user"] as? String == "tv-track-output" && $0["path"] as? String == "/Sessions/Playing/Progress" && ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == paused }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The native caption transition did not produce a fresh matching pause state.")
        throw TVJourneyFailure.unavailableControl("subtitle pause report")
    }

    private func assertSubtitlePixels(_ captions: Bool?, phase: String, app: XCUIApplication) async throws {
        let initialElapsed = app.otherElements["AXElapsedTime"].label
        var confirmed = 0
        for attempt in 0..<8 {
            let screenshot = app.screenshot()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            try VNImageRequestHandler(cgImage: try XCTUnwrap(screenshot.image.cgImage)).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            let picture = XCTAttachment(screenshot: screenshot)
            picture.name = phase + " frame\(attempt)"; picture.lifetime = .keepAlways; add(picture)
            let text = XCTAttachment(string: words)
            text.name = phase + " OCR\(attempt)"; text.lifetime = .keepAlways; add(text)
            if words.contains("ORIGINAL VERSION") && words.contains("SYNTHETIC 440 HZ") && (captions.map { words.contains("REEL TV CAPTION CHECK") == $0 } ?? true) { confirmed += 1 }
            else { confirmed = 0 }
            if confirmed == 2 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(confirmed, 2, "The actual rendered caption state must match in two advancing-video frames: " + phase)
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@ AND label MATCHES %@", initialElapsed, "00:[0-5][0-9]"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [advancing], timeout: 10)
    }

    private func subtitleReceipt(_ index: Int, phase: String, requiresCaptionRequest: Bool = true) async throws {
        let (data, state) = try await subtitleState()
        let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
        let body = try XCTUnwrap(reports.last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-track-output" }?["body"] as? [String: Any])
        XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, index)
        let requests = try XCTUnwrap(state["trackRequests"] as? [[String: Any]])
        XCTAssertEqual(requests.contains { ($0["path"] as? String)?.hasSuffix("/captions.vtt") == true }, requiresCaptionRequest)
        XCTAssertTrue(requests.allSatisfy { ($0["path"] as? String)?.hasPrefix("/Videos/reel-tracks/original440/on/") == true })
        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        receipt.name = phase + " API and media receipt"; receipt.lifetime = .keepAlways; add(receipt)
    }

    func testRemoteAlternateVersionActuallyRendersItsSelectedMedia() async throws {
        try await playTrackOutput(alternate: true, audio: 4, captions: false)
    }

    func testRemoteSelectedWebVTTActuallyRendersNativeCaptionPixels() async throws {
        try await playTrackOutput(alternate: false, audio: 1, captions: true)
    }

    func testRemoteOwnedSubtitleMenuRetainsSelectedWebVTTFixture() async throws {
        try await playTrackOutput(alternate: false, audio: 1, captions: true, inspectOwnedCaptions: true)
    }

    func testRemoteAlternateAudioWithSubtitlesOffRendersWithoutCaptions() async throws {
        try await playTrackOutput(alternate: false, audio: 3, captions: false)
    }

    func testRemoteSavedVaultRecoveryKeepsAuthenticationUnavailableUntilRetrySucceeds() async throws {
        let app = try await launchFreshQAApp(extraArguments: ["-reel-tv-qa-vault-unavailable"])
        XCTAssertTrue(app.buttons["retrySavedConnections"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.textFields["server"].exists)
        XCTAssertFalse(app.buttons["connect"].exists)
        capture("Unavailable saved connections", app: app)
        try select(app.buttons["retrySavedConnections"], in: app)
        XCTAssertTrue(app.staticTexts["savedConnectionsRetryError"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.textFields["server"].exists)
        capture("Saved connections retry failure", app: app)
        try select(app.buttons["retrySavedConnections"], in: app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        XCTAssertFalse(app.buttons["retrySavedConnections"].exists)
        capture("Recovered original saved connection", app: app)
    }

    func testRemoteValidationAndWrongPasswordCorrection() async throws {
        let app = try await launchFreshQAApp()
        try select(app.buttons["connect"], in: app)
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 5))
        try enter("not a server", into: app.textFields["server"], app: app)
        try select(app.buttons["connect"], in: app)
        XCTAssertTrue(app.staticTexts["connectionError"].label.contains("username"))
        try enter("tv-auth", into: app.textFields["username"], app: app)
        try enter("wrong", into: app.secureTextFields["password"], app: app)
        try select(app.buttons["connect"], in: app)
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 5))
        try enter("http://example.com", into: app.textFields["server"], replacing: "not a server", app: app)
        try select(app.buttons["connect"], in: app)
        XCTAssertTrue(app.staticTexts["connectionError"].label.contains("HTTPS"))
        try enter("http://127.0.0.1:18966", into: app.textFields["server"], replacing: "http://example.com", app: app)
        try select(app.buttons["connect"], in: app)
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["connectionError"].label.contains("sign-in"))
        capture("Wrong password preserves form", app: app)
        try enter("demo", into: app.secureTextFields["password"], replacing: "wrong", app: app)
        try select(app.buttons["connect"], in: app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
    }

    func testRemoteInitialSignInCancelButtonAndBackRejectLateAuthentication() async throws {
        let app = try await launchFreshQAApp()
        try enter("http://127.0.0.1:18966", into: app.textFields["server"], app: app)
        try enter("tv-slow-auth", into: app.textFields["username"], app: app)
        try enter("demo", into: app.secureTextFields["password"], app: app)
        for useBack in [false, true] {
            try select(app.buttons["connect"], in: app)
            XCTAssertTrue(app.buttons["cancelConnection"].waitForExistence(timeout: 2))
            if useBack { XCUIRemote.shared.press(.menu) }
            else { try select(app.buttons["cancelConnection"], in: app) }
            let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["connect"])
            await fulfillment(of: [enabled], timeout: 3)
            try await Task.sleep(for: .milliseconds(4300))
            XCTAssertTrue(app.textFields["server"].exists)
            XCTAssertFalse(app.staticTexts["heroTitle"].exists)
        }
        try enter("tv-ui", into: app.textFields["username"], replacing: "tv-slow-auth", app: app)
        try select(app.buttons["connect"], in: app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
    }

    func testRemoteExpiredSavedSessionCanBeRemovedAndReplaced() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "expired")
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 20))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 20))
        try openTab("Settings", app: app)
        try select(accountButton("remove-", server: "Reel Cinema", app: app), in: app)
        try choose("Sign out", app: app)
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15))
        try signIn(app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
    }

    func testRemoteMissingArtworkKeepsReadableHomeAndDetails() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "missingart")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        capture("Missing artwork Home fallback", app: app)
        try select(app.buttons["heroDetails"], in: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["detailPlay"].isHittable)
        capture("Missing artwork detail fallback", app: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 10))
    }

    func testRemoteEmptyHomeRefreshAndManageServers() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "empty")
        XCTAssertTrue(app.staticTexts["Your library is empty."].waitForExistence(timeout: 20))
        capture("Empty Home", app: app)
        try select(app.buttons["Refresh library"], in: app)
        XCTAssertTrue(app.staticTexts["Your library is empty."].waitForExistence(timeout: 15))
        try select(app.buttons["Manage servers"], in: app)
        XCTAssertTrue(app.buttons["addServer"].waitForExistence(timeout: 15))
    }

    func testRemotePartialHomeRetryRestoresShelf() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "flaky")
        XCTAssertTrue(app.buttons["partialRetry"].waitForExistence(timeout: 20))
        capture("Partial Home", app: app)
        try select(app.buttons["partialRetry"], in: app)
        await waitUntilGone(app.buttons["partialRetry"], timeout: 15)
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
    }

    func testRemoteFullHomeFailureRetryRecovers() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-home-recovery")
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 20))
        capture("Home unavailable", app: app)
        try await configureTVHomeFailure(false)
        try select(app.buttons["retry"], in: app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
    }

    func testRemoteNavigationDuringHomeLoadingAndReturn() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-home-slow")
        XCTAssertTrue(control("homeLoading", app: app).waitForExistence(timeout: 2))
        capture("Home loading", app: app)
        try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["filter-Series"].waitForExistence(timeout: 15))
        try openTab("Home", app: app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
    }

    func testRemoteLibraryAndSearchFailuresRetryWithoutLosingNavigation() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-browse-recovery")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        XCTAssertTrue(app.staticTexts["The library couldn’t load."].waitForExistence(timeout: 15))
        capture("Library error with native Retry", app: app)
        try await configureTVState(["browseFailure": false])
        try select(app.buttons["retry"], in: app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "libraryCount").matching(NSPredicate(format: "label == %@", "60 of 75 titles")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item-")).count, 0)
        try await configureTVState(["browseFailure": true])
        try openTab("Search", app: app)
        try enter("Out of the Blue", into: app.textFields["search"], app: app)
        XCTAssertTrue(app.staticTexts["The library couldn’t load."].waitForExistence(timeout: 15))
        try await configureTVState(["browseFailure": false])
        try select(app.buttons["retry"], in: app)
        XCTAssertTrue(app.buttons["item-series-7"].waitForExistence(timeout: 15))
        capture("Search recovered without replacing query", app: app)
        XCTAssertEqual(app.textFields["search"].value as? String, "Out of the Blue")
    }

    func testRemoteLibraryAppendFailureKeepsTitlesAndLoadMoreRetries() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-append-recovery")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        try select(app.buttons["loadMore"], in: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "503")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["libraryCount"].label, "60 of 75 titles")
        XCTAssertGreaterThan(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "item-")).count, 0)
        try await configureTVState(["appendFailure": false])
        try select(app.buttons["loadMore"], in: app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "libraryCount").matching(NSPredicate(format: "label == %@", "75 of 75 titles")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["loadMore"].exists)
    }

    func testRemoteLibraryLoadingAndEmptyFilterRemainNavigable() async throws {
        var app = try await launchFreshQAApp()
        try signIn(app, user: "tv-browse-slow")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        XCTAssertTrue(control("libraryLoading", app: app).waitForExistence(timeout: 2))
        capture("Library loading", app: app)
        try openTab("Search", app: app)
        XCTAssertTrue(app.staticTexts["A title in mind?"].waitForExistence(timeout: 10))
        try openTab("Library", app: app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "libraryCount").matching(NSPredicate(format: "label == %@", "60 of 75 titles")).firstMatch.waitForExistence(timeout: 15))
        app.terminate()
        app = try await launchFreshQAApp()
        try signIn(app, user: "empty")
        XCTAssertTrue(app.staticTexts["Your library is empty."].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        XCTAssertTrue(app.staticTexts["No titles found."].waitForExistence(timeout: 15))
        try select(app.buttons["filter-Series"], in: app)
        XCTAssertTrue(app.staticTexts["No titles found."].waitForExistence(timeout: 15))
        try openTab("Home", app: app)
        XCTAssertTrue(app.staticTexts["Your library is empty."].waitForExistence(timeout: 10))
    }

    func testRemoteDetailAndEpisodeRetryAndEmptySeasons() async throws {
        var app = try await launchFreshQAApp()
        try signIn(app, user: "tv-detail-recovery")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try select(app.buttons["heroDetails"], in: app)
        XCTAssertTrue(app.staticTexts["This title couldn’t load."].waitForExistence(timeout: 15))
        try await configureTVState(["detailFailure": false])
        try select(app.buttons["retry"], in: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        capture("Detail recovered", app: app)
        app.terminate()
        app = try await launchFreshQAApp()
        try signIn(app, user: "tv-episode-recovery")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Search", app: app)
        try enter("Out of the Blue", into: app.textFields["search"], app: app)
        try select(app.buttons["item-series-7"], in: app)
        XCTAssertTrue(app.staticTexts["Episodes couldn’t load."].waitForExistence(timeout: 15))
        try await configureTVState(["episodeFailure": false])
        try select(app.buttons["retry"], in: app)
        XCTAssertTrue(app.buttons["episode-episode-1-1"].waitForExistence(timeout: 15))
        capture("Episodes recovered", app: app)
        app.terminate()
        app = try await launchFreshQAApp()
        try signIn(app, user: "tv-empty-seasons")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Search", app: app)
        try enter("Out of the Blue", into: app.textFields["search"], app: app)
        try select(app.buttons["item-series-7"], in: app)
        XCTAssertTrue(app.staticTexts["No episodes here yet."].waitForExistence(timeout: 15))
        XCTAssertFalse(app.segmentedControls["season"].exists)
        capture("Series with no seasons", app: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.textFields["search"].waitForExistence(timeout: 10))
    }

    func testRemoteDetailLoadingBackRejectsLateTitle() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-detail-slow")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try select(app.buttons["heroDetails"], in: app)
        XCTAssertTrue(app.activityIndicators.firstMatch.waitForExistence(timeout: 2))
        capture("Title Details loading", app: app)
        XCUIRemote.shared.press(.menu)
        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertTrue(app.buttons["heroDetails"].isHittable)
        XCTAssertFalse(app.staticTexts["detailTitle"].exists)
    }

    func testRemoteSettingsAccountsPrivacyQualityAndRemovalPersist() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-settings")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Settings", app: app)
        for quality in ["High · 20 Mbps", "Balanced · 8 Mbps", "Original / auto", "Data saver · 2 Mbps"] {
            try await selectSegment(quality, in: "quality", app: app)
        }
        try select(control("privateViewing", app: app), in: app)
        await expectPrivateViewing(true, app: app)
        XCTAssertTrue(app.staticTexts["Watch progress stays on this device."].exists)
        capture("Private viewing and quality", app: app)
        try select(control("privateViewing", app: app), in: app)
        await expectPrivateViewing(false, app: app)
        try select(control("privateViewing", app: app), in: app)
        await expectPrivateViewing(true, app: app)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Settings", app: app)
        XCTAssertTrue(control("privateViewing", app: app).waitForExistence(timeout: 10))
        await expectPrivateViewing(true, app: app, timeout: 10)
        XCTAssertTrue(app.segmentedControls["quality"].buttons["Data saver · 2 Mbps"].isSelected)
        try select(app.buttons["addServer"], in: app)
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 10))
        try select(app.buttons["Cancel"], in: app)
        XCTAssertTrue(app.buttons["addServer"].waitForExistence(timeout: 10))
        try select(app.buttons["addServer"], in: app)
        try signIn(app, user: "tv-second", server: "http://127.0.0.1:18967")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Settings", app: app)
        XCTAssertTrue(accountButton("remove-", server: "Reel Cinema", app: app).waitForExistence(timeout: 10))
        XCTAssertTrue(accountButton("remove-", server: "Reel Second Cinema", app: app).exists)
        capture("Two saved servers", app: app)
        try select(accountButton("open-", server: "Reel Cinema", app: app), in: app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Settings", app: app)
        XCTAssertTrue(accountButton("open-", server: "Reel Second Cinema", app: app).waitForExistence(timeout: 10))
        try select(accountButton("remove-", server: "Reel Second Cinema", app: app), in: app)
        try choose("Cancel", app: app)
        XCTAssertTrue(accountButton("remove-", server: "Reel Second Cinema", app: app).exists)
        try select(accountButton("remove-", server: "Reel Second Cinema", app: app), in: app)
        try choose("Sign out", app: app)
        await waitUntilGone(accountButton("remove-", server: "Reel Second Cinema", app: app), timeout: 10)
        try select(accountButton("remove-", server: "Reel Cinema", app: app), in: app)
        try choose("Sign out", app: app)
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15))
        app.terminate(); app.launch()
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.staticTexts["heroTitle"].exists)
    }

    func testRemoteLibraryPaginationSeasonEpisodeAndSearchClear() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        try select(app.buttons["loadMore"], in: app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "libraryCount").matching(NSPredicate(format: "label == %@", "75 of 75 titles")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["loadMore"].exists)
        try openTab("Search", app: app)
        try enter("Out of the Blue", into: app.textFields["search"], app: app)
        try select(app.buttons["item-series-7"], in: app)
        try await selectSegment("Season 2", in: "season", app: app)
        XCTAssertTrue(app.buttons["episode-episode-2-1"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["episode-episode-1-1"].exists)
        try select(app.buttons["episode-episode-2-1"], in: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        capture("Season two episode detail", app: app)
        try select(app.buttons["detailPlay"], in: app)
        try await waitForPlaybackStarts(1)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        XCUIRemote.shared.press(.menu)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.textFields["search"].waitForExistence(timeout: 10))
        try enter("", into: app.textFields["search"], replacing: "Out of the Blue", app: app)
        XCTAssertTrue(app.staticTexts["A title in mind?"].waitForExistence(timeout: 10))
    }

    func testRemotePrivateViewingDecodesHLSAndClosesWithoutHistory() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-private-ui")
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        try openTab("Settings", app: app)
        try await selectSegment("Data saver · 2 Mbps", in: "quality", app: app)
        try select(control("privateViewing", app: app), in: app)
        await expectPrivateViewing(true, app: app, timeout: 10)
        try openTab("Home", app: app)
        try select(app.buttons["heroPlay"], in: app)
        try await Task.sleep(for: .seconds(2))
        XCUIRemote.shared.press(.playPause)
        XCUIRemote.shared.press(.up)
        XCTAssertTrue(app.otherElements.matching(identifier: "AXElapsedTime").matching(NSPredicate(format: "label MATCHES %@", "00:0[1-9]")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["retryPlayer"].exists)
        capture("Private HLS native playback", app: app)
        try await closeNativePlayer(returningTo: app.buttons["heroPlay"], app: app)
        let reports = try await fixtureReports().filter { $0["user"] as? String == "tv-private-ui" }
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" })
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Videos/ActiveEncodings" })
        XCTAssertFalse(reports.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
    }

    func testRemoteWatchSyncWarningAndBackgroundPauseRecover() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "tv-watch-sync")
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 20))
        try await configureReportFailure(true)
        do {
            try select(app.buttons["heroPlay"], in: app)
            let message = control("watchSyncMessage", app: app)
            XCTAssertTrue(message.waitForExistence(timeout: 15))
            XCTAssertTrue(message.label.contains("progress"))
            XCUIRemote.shared.press(.up)
            XCTAssertTrue(app.otherElements.matching(identifier: "AXElapsedTime").matching(NSPredicate(format: "label MATCHES %@", "00:0[1-9]")).firstMatch.waitForExistence(timeout: 10))
            capture("Watch progress warning with actual video", app: app)
            captureHierarchy("Watch progress warning hierarchy", app: app)
            try await configureReportFailure(false)
            let beforeBackground = try await fixtureReports().count
            XCUIRemote.shared.press(.home)
            let background = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue), object: app)
            await fulfillment(of: [background], timeout: 10)
            try await waitForPauseReport(true, after: beforeBackground, user: "tv-watch-sync")
            let beforeActivation = try await fixtureReports().count
            app.activate()
            await waitUntilGone(message, timeout: 10)
            // AVKit may restore its playing state on foreground activation.
            // Require a fresh foreground receipt instead of reusing the prior
            // background pause, then let its native activation transition settle.
            let wasPaused = try await freshPauseState(after: beforeActivation, user: "tv-watch-sync")
            let beforeResume = try await fixtureReports().count
            XCUIRemote.shared.press(.playPause)
            try await waitForPauseReport(!wasPaused, after: beforeResume, user: "tv-watch-sync")
            if !wasPaused {
                let beforePlaying = try await fixtureReports().count
                XCUIRemote.shared.press(.playPause)
                try await waitForPauseReport(false, after: beforePlaying, user: "tv-watch-sync")
            }
            capture("Foreground native playback after sync recovery", app: app)
            try await closeNativePlayer(returningTo: app.buttons["heroPlay"], app: app)
        } catch {
            try? await configureReportFailure(false)
            app.terminate()
            throw error
        }
    }

    func testRemotePlaybackErrorBackAndRetryRecoverToRealVideo() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app, user: "failed-recovery")
        try select(app.buttons["heroPlay"], in: app)
        XCTAssertTrue(app.buttons["retryPlayer"].waitForExistence(timeout: 45))
        capture("Native playback failure", app: app)
        try select(app.buttons["closePlayer"], in: app)
        let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["heroPlay"])
        await fulfillment(of: [home], timeout: 10)
        try select(app.buttons["heroPlay"], in: app)
        XCTAssertTrue(app.buttons["retryPlayer"].waitForExistence(timeout: 45))
        try await configurePlaybackRecovery()
        try select(app.buttons["retryPlayer"], in: app)
        try await waitForPlaybackStarts(1, user: "failed-recovery")
        XCTAssertFalse(app.buttons["retryPlayer"].exists)
        capture("Native playback recovered", app: app)
        try await closeNativePlayer(returningTo: app.buttons["heroPlay"], app: app)
    }

    func testRemoteEndedPlayAgainStartsFromZero() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        try select(app.buttons["heroPlay"], in: app)
        try await waitForPlaybackStarts(1)
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        let beforePause = try await fixtureReports().count
        XCUIRemote.shared.press(.playPause)
        try await waitForPauseReport(true, after: beforePause, user: "tv-ui")
        XCUIRemote.shared.press(.up)
        try choose("Speed", app: app)
        try choose("2×", app: app)
        try choose("Chapters", app: app)
        let beforeChapter = try await fixtureReports().count
        try choose("A new chapter", app: app)
        let seek = try await waitForChapterSeek(after: beforeChapter)
        if try XCTUnwrap(seek["IsPaused"] as? Bool) { XCUIRemote.shared.press(.playPause) }
        XCTAssertTrue(app.buttons["replay"].waitForExistence(timeout: 20))
        capture("Native completed playback", app: app)
        try select(app.buttons["replay"], in: app)
        try await waitForPlaybackStarts(2)
        let reports = try await fixtureReports()
        let replay = try XCTUnwrap(reports.last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" }?["body"] as? [String: Any])
        XCTAssertEqual(replay["StartTimeTicks"] as? Int, 0)
        XCTAssertFalse(app.buttons["replay"].exists)
        try await closeNativePlayer(returningTo: app.buttons["heroPlay"], app: app)
    }

    func testRemotePreparingBackRejectsLateMediaCompletion() async throws {
        let app = try await launchFreshQAApp(quality: 2_000_000)
        try signIn(app, user: "tv-ui-slow-media")
        try select(app.buttons["heroPlay"], in: app)
        XCTAssertTrue(app.buttons["cancelPreparing"].waitForExistence(timeout: 3))
        capture("Cancelable native preparation", app: app)
        try select(app.buttons["cancelPreparing"], in: app)
        let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["heroPlay"])
        await fulfillment(of: [home], timeout: 10)
        try await Task.sleep(for: .milliseconds(6500))
        XCTAssertTrue(app.buttons["heroPlay"].isHittable)
        XCTAssertFalse(app.buttons["retryPlayer"].exists)
        XCTAssertFalse(app.otherElements["AXElapsedTime"].exists)
        let reports = try await fixtureReports().filter { $0["user"] as? String == "tv-ui-slow-media" }
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/Videos/ActiveEncodings" })
        XCTAssertFalse(reports.contains { $0["path"] as? String == "/Sessions/Playing" })
    }

    func testRemoteNativeInfoBackClosesTheMatchingPlayer() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        try select(app.buttons["heroPlay"], in: app)
        try await waitForPlaybackStarts(1)
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        XCUIRemote.shared.press(.playPause)
        XCUIRemote.shared.press(.down)
        try choose("Back to library", app: app)
        let home = XCTNSPredicateExpectation(predicate: NSPredicate(format: "hittable == true"), object: app.buttons["heroPlay"])
        await fulfillment(of: [home], timeout: 10)
        XCTAssertFalse(app.cells["Quality"].exists)
    }

    func testRemoteEveryHomeShelfOpensItsOwnTitle() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        for (id, title) in [("episode-1-1", "A new beginning"), ("episode-1-2", "Below the surface"), ("movie-2", "After the Last Light"), ("series-8", "Wild Country")] {
            try select(app.buttons["item-" + id].firstMatch, in: app, activate: false)
            capture("Home shelf focus " + id, app: app)
            XCUIRemote.shared.press(.select)
            XCTAssertTrue(app.staticTexts.matching(identifier: "detailTitle").matching(NSPredicate(format: "label == %@", title)).firstMatch.waitForExistence(timeout: 15))
            if id.hasPrefix("episode-") {
                XCTAssertEqual(app.staticTexts["detailEpisodeContext"].label, "Out of the Blue · S1 E" + (id == "episode-1-1" ? "1" : "2"))
                // Play leads the single action row; the watched menu follows it on the same row.
                XCTAssertLessThan(app.buttons["detailPlay"].frame.minX, app.buttons["detailWatchStatus"].frame.minX)
                XCTAssertEqual(app.buttons["detailPlay"].frame.midY, app.buttons["detailWatchStatus"].frame.midY, accuracy: 30)
            }
            capture("Home shelf detail " + id, app: app)
            XCUIRemote.shared.press(.menu)
            await waitUntilGone(app.staticTexts["detailTitle"], timeout: 10)
        }
    }

    /// Arrows, Select and Back only: browse Home rows, return to a row's remembered card, reach the
    /// tab bar, open a series from Shows, switch seasons and start an episode.
    func testRemoteOnlyHomeRowsTabBarSeriesSeasonAndEpisode() async throws {
        let app = try await launchFreshQAApp()
        try signIn(app)
        XCTAssertTrue(app.staticTexts["heroTitle"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 10))
        capture("Tour 1 Home featured", app: app)

        // Launch focus may start on the tab bar or the featured actions; Down reaches the first row.
        for _ in 0..<3 where !app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "item-")).firstMatch.exists {
            XCUIRemote.shared.press(.down)
        }
        let first = try focusedCard(app)
        try await waitForHeroTitle(first.title, app: app)
        capture("Tour 2 Home focused card", app: app)
        XCUIRemote.shared.press(.right)
        let remembered = try await focusedCard(changedFrom: first.id, app: app)
        try await waitForHeroTitle(remembered.title, app: app)
        XCUIRemote.shared.press(.down)
        let below = try await focusedCard(changedFrom: remembered.id, app: app)
        XCUIRemote.shared.press(.up)
        let returned = try await focusedCard(changedFrom: below.id, app: app)
        XCTAssertEqual(returned.id, remembered.id, "The first row returns focus to its last focused card.")

        XCUIRemote.shared.press(.select)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.menu)
        await waitUntilGone(app.staticTexts["detailTitle"], timeout: 10)
        try await Task.sleep(for: .milliseconds(600))
        capture("Tour 2b Home after Back", app: app)
        captureHierarchy("Tour 2b Home after Back", app: app)
        XCTAssertEqual(try focusedCard(app).id, remembered.id, "Back from details returns focus to the card that opened them.")

        XCUIRemote.shared.press(.up)
        let tab = app.tabBars.buttons.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 5), "Up from the first row reaches the tab bar.")
        XCTAssertEqual(tab.label, "Home")
        capture("Tour 3 Tab bar focused", app: app)

        XCUIRemote.shared.press(.down)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 5))
        try select(app.buttons["heroDetails"], in: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["detailFavorite"].exists)
        try await Task.sleep(for: .milliseconds(800))
        capture("Tour 4 Movie details", app: app)
        XCUIRemote.shared.press(.menu)
        await waitUntilGone(app.staticTexts["detailTitle"], timeout: 10)

        try openTab("Series", app: app)
        XCTAssertEqual(app.staticTexts["libraryTitle"].label, "Series")
        try select(app.buttons["item-series-7"], in: app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "detailTitle").matching(NSPredicate(format: "label == %@", "Out of the Blue")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["episode-episode-1-1"].waitForExistence(timeout: 15))
        try await Task.sleep(for: .milliseconds(800))
        capture("Tour 5 Series details", app: app)
        try await selectSegment("Season 2", in: "season", app: app)
        XCTAssertTrue(app.buttons["episode-episode-2-1"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["episode-episode-1-1"].exists)
        capture("Tour 6 Season 2 episodes", app: app)

        try select(app.buttons["episode-episode-2-1"], in: app)
        XCTAssertTrue(app.staticTexts.matching(identifier: "detailTitle").matching(NSPredicate(format: "label == %@", "A new beginning")).firstMatch.waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["detailEpisodeContext"].label, "Out of the Blue · S2 E1")
        let before = try await fixtureReports().count
        try select(app.buttons["startOver"].exists ? app.buttons["startOver"] : app.buttons["detailPlay"], in: app)
        try await waitForEpisodeStart("episode-2-1", after: before)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 15))
        capture("Tour 7 Player", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts.matching(identifier: "detailTitle").matching(NSPredicate(format: "label == %@", "Out of the Blue")).firstMatch.waitForExistence(timeout: 10))
        capture("Tour 7b Back to series", app: app)
        XCTAssertEqual(app.segmentedControls["season"].value as? String, "Season 2", "Back returns to the series with Season 2 still chosen.")
        XCUIRemote.shared.press(.menu)
        await waitUntilGone(app.staticTexts["detailTitle"], timeout: 10)
        try openTab("Settings", app: app)
        XCTAssertTrue(control("privateViewing", app: app).waitForExistence(timeout: 10))
        capture("Tour 8 Settings", app: app)
    }

    /// The focused Home card's identifier and title, read once (an element query re-resolves on every access).
    private func focusedCard(_ app: XCUIApplication) throws -> (id: String, title: String) {
        let focused = app.buttons.matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH %@", "item-")).firstMatch
        guard focused.waitForExistence(timeout: 5) else {
            captureHierarchy("No focused card", app: app)
            throw TVJourneyFailure.unavailableControl("focused card")
        }
        return (focused.identifier, focused.label)
    }

    private func focusedCard(changedFrom previous: String?, app: XCUIApplication) async throws -> (id: String, title: String) {
        for _ in 0..<30 {
            if let card = try? focusedCard(app), card.id != previous { return card }
            try await Task.sleep(for: .milliseconds(100))
        }
        captureHierarchy("Focus did not move", app: app)
        throw TVJourneyFailure.unavailableControl("moved card focus")
    }

    /// The spotlight follows a focused card after its short settle delay.
    private func waitForHeroTitle(_ title: String, app: XCUIApplication) async throws {
        let matched = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", title), object: app.staticTexts["heroTitle"])
        await fulfillment(of: [matched], timeout: 5)
    }

    private func waitForEpisodeStart(_ id: String, after count: Int) async throws {
        for _ in 0..<100 {
            if try await fixtureReports().dropFirst(count).contains(where: {
                $0["path"] as? String == "/Sessions/Playing" && ($0["body"] as? [String: Any])?["ItemId"] as? String == id
            }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The synthetic server did not receive a playback start for \(id).")
        throw TVJourneyFailure.playbackDidNotStart
    }

    func testRemoteHomeScreenIconFocusLaunchesTheQAApp() async throws {
        let app = try await launchFreshQAApp()
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15))
        XCUIRemote.shared.press(.home)
        let home = XCUIApplication(bundleIdentifier: "com.apple.PineBoard")
        let homeForeground = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue), object: home)
        await fulfillment(of: [homeForeground], timeout: 10)
        let appBackground = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state != %d", XCUIApplication.State.runningForeground.rawValue), object: app)
        await fulfillment(of: [appBackground], timeout: 10)
        captureHierarchy("TV Home icon hierarchy", app: home)
        // This disposable simulator has Settings, Reel and this test runner in
        // its Home dock. PineBoard exposes the dock as one focus element; the
        // captured native screen establishes the order, and launch verifies the
        // selected icon's identity without pretending an absent AX label exists.
        for _ in 0..<3 { XCUIRemote.shared.press(.left) }
        capture("TV Home dock at its leading edge", app: home)
        XCUIRemote.shared.press(.right)
        try await Task.sleep(for: .milliseconds(1200))
        capture("Focused Reel app icon", app: home)
        XCUIRemote.shared.press(.select)
        let foreground = XCTNSPredicateExpectation(predicate: NSPredicate(format: "state == %d", XCUIApplication.State.runningForeground.rawValue), object: app)
        await fulfillment(of: [foreground], timeout: 10)
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 10))
    }

    private func configurePlaybackRecovery() async throws {
        var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18966/qa/control")!)
        request.httpMethod = "POST"
        request.httpBody = Data("{\"recoveryAllowed\":true}".utf8)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func playTrackOutput(alternate: Bool, audio: Int, captions: Bool, inspectOwnedCaptions: Bool = false) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Track-output tests require the disposable TV simulator.")
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV" else { throw TVJourneyFailure.unsafeEnvironment }
        // Stop the prior owned app before reset so an old media loader cannot
        // contribute requests to the next track-output observation window.
        XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa").terminate()
        let app = try await launchFreshQAApp()
        defer { app.terminate() }
        try signIn(app, user: "tv-track-output")
        try select(app.buttons["heroDetails"], in: app)
        XCTAssertTrue(app.buttons["sourceOptions"].waitForExistence(timeout: 15))
        if alternate {
            try select(app.buttons["sourceOptions"], in: app)
            try choose("Alternate version", app: app)
        }
        try select(app.buttons["audioOptions"], in: app)
        try choose(alternate ? "Alternate 880 Hz" : audio == 1 ? "Synthetic 440 Hz" : "Synthetic 880 Hz", app: app)
        if alternate { XCTAssertFalse(app.buttons["subtitleOptions"].exists) }
        else {
            try select(app.buttons["subtitleOptions"], in: app)
            try choose(captions ? "Synthetic captions" : "Off", app: app)
        }
        try select(app.buttons["detailPlay"], in: app)
        try await waitForPlaybackStarts(1, user: "tv-track-output")
        await waitUntilGone(app.otherElements["playerPreparing"], timeout: 20)
        XCTAssertFalse(app.buttons["retryPlayer"].exists)
        if inspectOwnedCaptions {
            XCUIRemote.shared.press(.up)
            XCTAssertFalse(app.cells.matching(identifier: "AVLegibleSettings").firstMatch.exists)
            try await expectOwnedSubtitle("Synthetic captions", app: app)
        }
        XCUIRemote.shared.press(.up)
        let playing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label MATCHES %@", "00:0[1-9]"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [playing], timeout: 10)
        let initialElapsed = app.otherElements["AXElapsedTime"].label
        let expectedVersion = alternate ? "ALTERNATE VERSION" : "ORIGINAL VERSION"
        var confirmedFrames = 0
        for attempt in 0..<8 {
            let screenshot = app.screenshot()
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.recognitionLanguages = ["en-US"]
            request.usesLanguageCorrection = false
            let image = try XCTUnwrap(screenshot.image.cgImage)
            try VNImageRequestHandler(cgImage: image).perform([request])
            let words = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            let picture = XCTAttachment(screenshot: screenshot)
            picture.name = "Track output \(alternate ? "alternate" : "original") audio\(audio) captions\(captions) frame\(attempt)"
            picture.lifetime = .keepAlways; add(picture)
            let text = XCTAttachment(string: words)
            text.name = "Native rendered track OCR \(attempt)"
            text.lifetime = .keepAlways; add(text)
            if words.contains(expectedVersion) && words.contains("SYNTHETIC \(audio == 1 ? 440 : 880) HZ") && words.contains("REEL TV CAPTION CHECK") == captions { confirmedFrames += 1 }
            else { confirmedFrames = 0 }
            if confirmedFrames == 2 { break }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTAssertEqual(confirmedFrames, 2, "The native rendered video must show the selected version/tone label and matching genuine caption state in two frames.")
        let advancing = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label != %@ AND label MATCHES %@", initialElapsed, "00:[0-5][0-9]"), object: app.otherElements["AXElapsedTime"])
        await fulfillment(of: [advancing], timeout: 10)
        let reports = try await fixtureReports()
        let body = try XCTUnwrap(reports.last { $0["path"] as? String == "/Items/movie-1/PlaybackInfo" && $0["user"] as? String == "tv-track-output" }?["body"] as? [String: Any])
        XCTAssertEqual(body["MediaSourceId"] as? String, alternate ? "movie-1-alternate" : "movie-1-source")
        XCTAssertEqual(body["AudioStreamIndex"] as? Int, audio)
        if alternate { XCTAssertNil(body["SubtitleStreamIndex"]) }
        else { XCTAssertEqual(body["SubtitleStreamIndex"] as? Int, captions ? 2 : -1) }
        let (data, response) = try await URLSession.shared.data(for: try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18966/qa/state")!))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let requests = try XCTUnwrap(state["trackRequests"] as? [[String: Any]])
        let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        receipt.name = "Actual track API and media request receipt"
        receipt.lifetime = .keepAlways; add(receipt)
        let prefix = "/Videos/reel-tracks/" + (alternate ? "alternate880" : audio == 1 ? "original440" : "original880") + (captions ? "/on/" : "/off/")
        XCTAssertTrue(requests.contains { ($0["path"] as? String) == prefix + "master.m3u8" })
        XCTAssertTrue(requests.contains { ($0["path"] as? String)?.hasPrefix(prefix + "segment") == true })
        XCTAssertEqual(requests.contains { ($0["path"] as? String)?.hasSuffix("captions.vtt") == true }, captions)
        XCTAssertTrue(requests.allSatisfy { ($0["path"] as? String)?.hasPrefix(prefix) == true })
        captureHierarchy("Actual track output hierarchy", app: app)
        try await closeNativePlayer(returningTo: app.buttons["detailPlay"], app: app)
        #endif
    }

    private func configureReportFailure(_ failed: Bool) async throws {
        var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18966/qa/control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: ["failReports": failed, "failCleanup": false])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func control(_ id: String, app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    /// The explainer under Private viewing reads the same either way, so the switch's own value is the
    /// signal: tvOS reports 1 when it is on and 0 when it is off.
    private func expectPrivateViewing(_ on: Bool, app: XCUIApplication, timeout: TimeInterval = 5) async {
        let reported = NSPredicate { object, _ in
            let value = (object as? XCUIElement)?.value
            return ((value as? NSNumber)?.boolValue ?? ((value as? String) == "1")) == on
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: reported, object: control("privateViewing", app: app))], timeout: timeout)
    }

    private func selectSegment(_ title: String, in id: String, app: XCUIApplication) async throws {
        let picker = app.segmentedControls[id]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        let buttons = picker.buttons.allElementsBoundByIndex
        let targetIndex = try XCTUnwrap(buttons.firstIndex { $0.label == title })
        let selectedIndex = try XCTUnwrap(buttons.firstIndex { $0.isSelected })
        if selectedIndex != targetIndex {
            // The native segmented picker owns one focus region for its buttons.
            // Focus its current selection, then move by real segment indices.
            try select(buttons[selectedIndex], in: app, activate: false)
            for _ in 0..<abs(targetIndex - selectedIndex) { XCUIRemote.shared.press(targetIndex > selectedIndex ? .right : .left) }
            XCUIRemote.shared.press(.select)
        }
        let selected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "selected == true"), object: picker.buttons[title])
        await fulfillment(of: [selected], timeout: 5)
    }

    private func accountButton(_ prefix: String, server: String, app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@ AND label ENDSWITH %@", prefix, " on " + server)).firstMatch
    }

    private func launchFreshQAApp(extraArguments: [String] = [], quality: Int = 120_000_000) async throws -> XCUIApplication {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Account-reset journeys are restricted to a disposable tvOS simulator.")
        #else
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV" else {
            throw TVJourneyFailure.unsafeEnvironment
        }
        for action in ["reset", "control"] {
            var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18966/qa/" + action)!)
            request.httpMethod = "POST"
            request.httpBody = Data("{\"failReports\":false,\"failCleanup\":false,\"reportDelay\":0,\"recoveryAllowed\":false}".utf8)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (_, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        }
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        app.launchArguments = ["-reel-qa-reset", "-privateViewing", "NO", "-streamQuality", String(quality)] + extraArguments
        app.launch()
        return app
        #endif
    }

    private func configureTVHomeFailure(_ failed: Bool) async throws {
        try await configureTVState(["homeFailure": failed])
    }

    private func configureTVState(_ values: [String: Bool]) async throws {
        var request = try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18966/qa/tv-control")!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: values)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }

    private func expectMenu(_ id: String, contains value: String, app: XCUIApplication) {
        XCTAssertTrue(app.buttons.matching(identifier: id).matching(NSPredicate(format: "label CONTAINS %@", value)).firstMatch.waitForExistence(timeout: 10))
    }

    private func signIn(_ app: XCUIApplication, user: String = "tv-ui", server: String = "http://127.0.0.1:18966") throws {
        try enter(server, into: app.textFields["server"], app: app)
        try enter(user, into: app.textFields["username"], app: app)
        try enter("demo", into: app.secureTextFields["password"], app: app)
        try select(app.buttons["connect"], in: app)
    }

    private func enter(_ text: String, into field: XCUIElement, replacing previous: String = "", app: XCUIApplication) throws {
        try select(field, in: app)
        if !previous.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: previous.count)) }
        field.typeText(text)
        XCUIRemote.shared.press(.menu)
    }

    /// Menu reveals the tab bar from content. Pressed while the tab bar already holds focus on Home, it leaves the
    /// app, so Menu is only for focus that is in content.
    private func openTab(_ name: String, app: XCUIApplication) throws {
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons[name])
        if XCTWaiter().wait(for: [reachable], timeout: 2) != .completed, focusIsInContent(app) { XCUIRemote.shared.press(.menu) }
        try select(app.buttons[name], in: app)
    }

    /// True when an element outside the tab bar reports focus. Tab buttons can read as not hittable even while the
    /// tab bar holds focus, so hittability alone cannot tell content focus from tab bar focus.
    private func focusIsInContent(_ app: XCUIApplication) -> Bool {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else { return false }
        let tabBar = app.tabBars.firstMatch
        return !(tabBar.exists && tabBar.frame.contains(CGPoint(x: focused.frame.midX, y: focused.frame.midY)))
    }

    private func choose(_ title: String, app: XCUIApplication) throws {
        try select(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch, in: app)
    }

    private func waitUntilGone(_ element: XCUIElement, timeout: TimeInterval) async {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)
        await fulfillment(of: [expectation], timeout: timeout)
    }

    private func fixtureReports() async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(for: try await TVFixtureOwnership.request(URL(string: "http://127.0.0.1:18966/qa/state")!))
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return try XCTUnwrap(state["reports"] as? [[String: Any]])
    }

    @discardableResult
    private func waitForChapterSeek(after count: Int, at position: Int = 80_000_000) async throws -> [String: Any] {
        for _ in 0..<80 {
            let reports = try await fixtureReports()
            for report in reports.dropFirst(count) {
                guard report["user"] as? String == "tv-ui", report["path"] as? String == "/Sessions/Playing/Progress",
                      let body = report["body"] as? [String: Any], let ticks = body["PositionTicks"] as? Int else { continue }
                if (position...position + 3_000_000).contains(ticks) { return body }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Selecting the chapter did not report the completed native seek at its original timeline position (\(position) ticks).")
        throw TVJourneyFailure.unavailableControl("chapter seek effect")
    }

    private func closeNativePlayer(returningTo target: XCUIElement, app: XCUIApplication) async throws {
        // A start receipt can precede AVKit's first rendered hierarchy. Establish
        // the native presentation before interpreting absent controls as closed.
        guard app.cells["Quality"].waitForExistence(timeout: 10) else {
            captureHierarchy("Native player did not appear before Back", app: app)
            XCTFail("The native presentation was not ready for its Back action.")
            throw TVJourneyFailure.unavailableControl("native player before Back")
        }
        // A first Back dismisses AVKit's menus/transport. Verify the player itself
        // is gone before accepting controls that also exist underneath its modal.
        for index in 0..<3 {
            if !app.cells["Quality"].exists && !app.otherElements["AXElapsedTime"].exists && target.isHittable { break }
            guard app.state == .runningForeground else { throw TVJourneyFailure.unavailableControl("native Back") }
            captureHierarchy("Before native Back \(index + 1)", app: app)
            XCUIRemote.shared.press(.menu)
            for _ in 0..<20 {
                if !app.cells["Quality"].exists && !app.otherElements["AXElapsedTime"].exists && target.exists && target.isHittable { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            captureHierarchy("After native Back \(index + 1)", app: app)
        }
        let returned = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == true AND hittable == true"), object: target)
        await fulfillment(of: [returned], timeout: 10)
        if !target.isHittable {
            capture("Native Back did not return", app: app)
            captureHierarchy("Native Back did not return hierarchy", app: app)
        }
        XCTAssertFalse(app.cells["Quality"].exists)
        XCTAssertFalse(app.otherElements["AXElapsedTime"].exists)
        guard target.exists && target.isHittable else { throw TVJourneyFailure.unavailableControl("return from native player") }
    }

    private func waitForPauseReport(_ paused: Bool, after count: Int, user: String) async throws {
        for _ in 0..<100 {
            let reports = try await fixtureReports()
            if reports.dropFirst(count).contains(where: {
                $0["user"] as? String == user && $0["path"] as? String == "/Sessions/Playing/Progress" && ($0["body"] as? [String: Any])?["IsPaused"] as? Bool == paused
            }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The native background/resume action did not report its matching pause state.")
        throw TVJourneyFailure.unavailableControl("pause report")
    }

    private func freshPauseState(after count: Int, user: String) async throws -> Bool {
        for _ in 0..<120 {
            let reports = try await fixtureReports()
            if reports.dropFirst(count).contains(where: { $0["user"] as? String == user && $0["path"] as? String == "/Sessions/Playing/Progress" }) {
                try await Task.sleep(for: .milliseconds(700))
                let settled = try await fixtureReports().dropFirst(count)
                let body = try XCTUnwrap(settled.last { $0["user"] as? String == user && $0["path"] as? String == "/Sessions/Playing/Progress" }?["body"] as? [String: Any])
                return try XCTUnwrap(body["IsPaused"] as? Bool)
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Native foreground activation did not produce a fresh progress receipt.")
        throw TVJourneyFailure.unavailableControl("fresh foreground pause state")
    }

    private func waitForPlaybackStarts(_ count: Int, user: String = "tv-ui") async throws {
        for _ in 0..<100 {
            let reports = try await fixtureReports()
            if reports.filter({ $0["path"] as? String == "/Sessions/Playing" && $0["user"] as? String == user }).count >= count { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The synthetic server did not receive the expected native playback start.")
        throw TVJourneyFailure.playbackDidNotStart
    }

    private func captureHierarchy(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(string: app.debugDescription)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func capture(_ name: String, app: XCUIApplication) {
        guard app.state == .runningForeground else {
            captureHierarchy(name + " (application not in foreground)", app: app)
            return
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func select(_ element: XCUIElement, in app: XCUIApplication, activate: Bool = true) throws {
        guard app.state == .runningForeground, element.waitForExistence(timeout: 10) else {
            captureHierarchy("Missing control", app: app)
            XCTFail("The requested native control was unavailable in the foreground application.")
            throw TVJourneyFailure.unavailableControl("requested control")
        }
        var previous = "", stationary = 0, unreported = 0
        for _ in 0..<45 {
            if element.hasFocus { if activate { XCUIRemote.shared.press(.select) }; return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else {
                // tvOS can keep focus without reporting it: on the tab bar when a screen first appears, or on a
                // button after the focused one left (Cancel once sign-in ends). A press makes it report again. A tab
                // target walks along the tab bar; otherwise Down, then Up and Down in turn, so a control at the
                // bottom edge still moves.
                unreported += 1
                let tabBar = app.tabBars.firstMatch
                let onTabBar = tabBar.exists && tabBar.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
                XCUIRemote.shared.press(onTabBar ? .right : (unreported <= 2 || unreported % 2 == 1) ? .down : .up)
                continue
            }
            let target = element.frame, wrapper = focused.frame
            if element.elementType == .cell, wrapper.height >= app.frame.height * 0.8 {
                // AVKit's full-frame scrubber owns focus; Up enters its transport buttons.
                // Down opens Info, irrespective of the scrubber's accessibility frame.
                XCUIRemote.shared.press(.up)
                continue
            }
            let wrapsOneControl = wrapper.width <= max(target.width * 1.2, target.width + 20) && wrapper.height <= max(target.height * 1.2, target.height + 20)
            let compactWrapper = wrapper.height <= 180 && wrapper.width <= app.frame.width * 0.8
            if element.isHittable, !target.isEmpty,
               wrapper.insetBy(dx: -2, dy: -2).contains(target), compactWrapper || wrapsOneControl {
                if activate { XCUIRemote.shared.press(.select) }
                return
            }
            let deltaX = element.frame.midX - focused.frame.midX
            let deltaY = element.frame.midY - focused.frame.midY
            let identity = focused.identifier + focused.label + focused.frame.debugDescription
            stationary = identity == previous ? stationary + 1 : 0
            previous = identity
            if stationary >= 2, abs(deltaX) > 30 {
                XCUIRemote.shared.press(deltaX > 0 ? .right : .left)
                stationary = 0
            } else if abs(deltaY) > 30 { XCUIRemote.shared.press(deltaY > 0 ? .down : .up) }
            else { XCUIRemote.shared.press(deltaX > 0 ? .right : .left) }
        }
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
        XCTFail("Remote focus could not reach \(element.identifier)")
        throw TVJourneyFailure.unavailableControl(element.identifier)
    }
}
