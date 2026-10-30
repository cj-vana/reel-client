import XCTest
import UIKit
import Vision

@MainActor final class PlayerPresentationUITests: XCTestCase {
    private enum Fixture {
        case library, remote, tracks, slowMedia

        var port: Int {
            switch self {
            case .library: 18766
            case .remote: 18769
            case .tracks: 18969
            case .slowMedia: 18966
            }
        }
        var origin: URL { URL(string: "http://127.0.0.1:\(port)")! }
        var requiresTVIdentity: Bool { self == .tracks || self == .slowMedia }
        var serverName: String {
            switch self {
            case .library: "Reel Test Library"
            case .remote: "Reel Second Server"
            case .tracks: "Reel Multi Audio QA"
            case .slowMedia: "Reel Cinema"
            }
        }
    }

    private let app = XCUIApplication()
    private var fixture = Fixture.library
    private var user = ""
    private var audioFailureArmed = false
    private var nativeSurface: XCUIElement {
        app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
    }

    override func tearDown() {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        super.tearDown()
    }

    // The reset argument clears saved accounts. Never infer ownership from a model name alone.
    private func requireOwnedSimulator() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Presentation QA requires a separately owned disposable simulator.")
        #else
        let environment = ProcessInfo.processInfo.environment
        let bundles: Set<String> = ["app.reelclient.ios.uitests", "app.reelclient.ios.uitests.xctrunner"]
        guard bundles.contains(Bundle.main.bundleIdentifier ?? ""),
              environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("Reel QA ") == true,
              let expected = environment["REEL_PLAYER_QA_DEVICE_UDID"].flatMap(UUID.init(uuidString:)),
              let actual = environment["SIMULATOR_UDID"].flatMap(UUID.init(uuidString:)), expected == actual else {
            throw XCTSkip("Set REEL_PLAYER_QA_DEVICE_UDID to the exact leased Reel QA simulator before account-reset presentation tests.")
        }
        #endif
    }

    private func tvOwner() throws -> String {
        guard let value = ProcessInfo.processInfo.environment["REEL_TV_QA_OWNER"],
              (24...120).contains(value.count),
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else {
            try fail("The exact owned TV fixture nonce must be supplied privately in REEL_TV_QA_OWNER.")
        }
        return value
    }

    private func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        try requireOwnedSimulator()
        let allowed = ["/System/Info/Public", "/qa/state", "/qa/remote-state", "/qa/remote-control", "/qa/audio-control"]
        guard allowed.contains(path), method == "GET" || method == "POST",
              body == nil || method == "POST" else { try fail("Unrecognized presentation-fixture operation.") }
        var request = URLRequest(url: fixture.origin.appendingPathComponent(String(path.dropFirst())))
        request.timeoutInterval = 8
        request.httpMethod = method
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        if fixture.requiresTVIdentity, path.hasPrefix("/qa/") {
            let owner = try tvOwner()
            let (data, response) = try await URLSession.shared.data(from: fixture.origin.appendingPathComponent("qa/tv-identity"))
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  identity["kind"] as? String == "reel-tv-owned-fixture",
                  identity["owner"] as? String == owner, identity["port"] as? Int == fixture.port else {
                try fail("The TV listener does not match this run's private ownership identity.")
            }
            request.setValue(owner, forHTTPHeaderField: "X-Reel-TV-Owner")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else {
            try fail("The owned fixture rejected \(method) \(path).")
        }
        if data.isEmpty { return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func launch(_ target: Fixture = .library, username: String? = nil, largeText: Bool = false) async throws {
        try requireOwnedSimulator()
        continueAfterFailure = false
        fixture = target
        user = username ?? "presentation-" + UUID().uuidString
        let identity = try await request("/System/Info/Public")
        guard identity["ServerName"] as? String == target.serverName else { try fail("Unexpected loopback fixture identity.") }
        if target.requiresTVIdentity { _ = try await request("/qa/state") }
        app.launchArguments = ["-reel-qa-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = target.origin.absoluteString
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let name = app.textFields["username"]
        try await visible(name, description: "fixture username")
        name.tap(); name.typeText(user)
        let password = app.secureTextFields["password"]
        try await visible(password, description: "fixture password")
        password.tap(); password.typeText("demo")
        try await tap(app.buttons["connect"], description: "Connect")
        guard app.buttons["heroDetails"].waitForExistence(timeout: 20) else { try fail("Sign-in did not reach Home.") }
        // AutoFill can offer to save the fixture password over Home a few seconds after sign-in.
        app.dismissReelPasswordPrompt()
        try await visible(app.buttons["heroDetails"], description: "fixture Home")
    }

    private func startMovie() async throws -> [String: Any] {
        let cursor = try await reports().count
        try await tap(app.buttons["heroDetails"], description: "movie Details")
        try await visible(app.staticTexts["detailTitle"], description: "loaded movie Details")
        if fixture == .tracks {
            try await until("genuine multi-audio source replaces the initial catalogue version") {
                !self.app.buttons["versionPicker"].exists
            }
        }
        if app.buttons["detailStartOver"].exists {
            try await tap(app.buttons["detailStartOver"], description: "start fixture from the beginning")
        } else {
            try await tap(app.buttons["detailPlay"], description: "play fixture movie")
        }
        try await until("actual native player") { self.nativeSurface.exists }
        return try await waitReport(after: cursor, path: "/Sessions/Playing")
    }

    private func reports() async throws -> [[String: Any]] {
        let state = try await request("/qa/state")
        return try XCTUnwrap(state["reports"] as? [[String: Any]]).filter { $0["user"] as? String == user }
    }

    private func waitReport(after cursor: Int, path: String, timeout: TimeInterval = 15,
                            matching: ([String: Any]) -> Bool = { _ in true }) async throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            for report in try await reports().dropFirst(cursor) where report["path"] as? String == path {
                if let body = report["body"] as? [String: Any], matching(body) { return body }
            }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        try fail("No own-session \(path) receipt matched the actual UI action.")
    }

    private func until(_ description: String, timeout: TimeInterval = 8, _ predicate: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        try fail("Timed out: \(description).")
    }

    private func visible(_ element: XCUIElement, description: String) async throws {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            if app.navigationBars["Playback options"].exists,
               let options = app.scrollViews.containing(.button, identifier: "playbackSpeed")
                .allElementsBoundByIndex.first(where: { $0.isHittable }) { options.swipeUp() }
            else if app.scrollViews["detailScroll"].isHittable { app.scrollViews["detailScroll"].swipeUp() }
            else if !app.keyboards.firstMatch.exists { app.swipeUp() }
            try await Task.sleep(for: .milliseconds(100))
        }
        try await until(description) { element.exists && element.isHittable }
    }

    private func tap(_ element: XCUIElement, description: String) async throws {
        try await visible(element, description: description)
        guard element.isEnabled else { try fail("Disabled actual UI control: \(description).") }
        element.tap()
    }

    private func tapVideo() throws {
        guard nativeSurface.exists, !app.navigationBars["Playback options"].exists else {
            try fail("Native control interactions require the video surface with the options sheet closed.")
        }
        nativeSurface.coordinate(withNormalizedOffset: CGVector(dx: 0.08, dy: 0.45)).tap()
    }

    /// One of the player's controls over the picture (the system player's own controls are
    /// gone), revealed with a tap on the video while hidden.
    private func playerButton(_ identifier: String, labels: [String], description: String) async throws -> XCUIElement {
        guard !app.navigationBars["Playback options"].exists else { try fail("The options sheet cannot stand in for the player's \(description).") }
        let query = app.buttons.matching(NSPredicate(format: "identifier == %@ AND label IN %@", identifier, labels))
        func candidates() -> [XCUIElement] {
            query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable && $0.frame.width > 0 && $0.frame.height > 0 }
        }
        if candidates().isEmpty { try tapVideo() }
        try await until("player \(description)", timeout: 5) { !candidates().isEmpty }
        let matches = candidates()
        guard matches.count == 1, let match = matches.first, match.isEnabled else {
            try fail("The player's \(description) must resolve to one enabled visible control; found \(matches.count).")
        }
        return match
    }

    private func menuItem(_ label: String) async throws -> XCUIElement {
        let query = app.buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", label, label + ","))
        try await until("native menu option \(label)") { query.allElementsBoundByIndex.contains { $0.isHittable } }
        let matches = query.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        guard matches.count == 1, let match = matches.first, match.isEnabled else { try fail("Native menu option \(label) is ambiguous or disabled.") }
        return match
    }

    /// Picks a track in Playback options, waits for the stream that carries it, then closes the sheet.
    private func chooseInOptions(_ control: String, _ option: String, matching: @escaping ([String: Any]) -> Bool,
                                 description: String) async throws {
        let options = app.buttons["playbackOptions"]
        if !options.isHittable { try tapVideo() }
        try await tap(options, description: "Playback options")
        let cursor = try await reports().count
        try await tap(app.buttons[control], description: "\(description) menu")
        try await menuItem(option).tap()
        _ = try await waitReport(after: cursor, path: "/Sessions/Playing", timeout: 30, matching: matching)
        try await tap(app.navigationBars["Playback options"].buttons["Done"], description: "close options after \(description)")
    }

    private func ticks(_ body: [String: Any]) -> Int64 { (body["PositionTicks"] as? NSNumber)?.int64Value ?? -1 }

    private func pausePlayer() async throws -> [String: Any] {
        let cursor = try await reports().count
        let pause = try await playerButton("playerPlayPause", labels: ["Pause"], description: "Pause")
        pause.tap()
        _ = try await playerButton("playerPlayPause", labels: ["Play"], description: "Play after pause")
        return try await waitReport(after: cursor, path: "/Sessions/Playing/Progress") { $0["IsPaused"] as? Bool == true }
    }

    func testPlayerPauseResumeAndSeekHaveSessionEffects() async throws {
        try await launch(.tracks, username: "tv-multiaudio")
        let started = try await startMovie()
        let paused = try await pausePlayer()
        XCTAssertEqual(paused["PlaySessionId"] as? String, started["PlaySessionId"] as? String)
        // The timeline over the picture, not the options sheet's copy.
        let timeline = app.sliders["playerTimeline"]
        try await visible(timeline, description: "player timeline")
        let beforeSeek = try await reports().count
        timeline.adjust(toNormalizedSliderPosition: 0.35)
        let sought = try await waitReport(after: beforeSeek, path: "/Sessions/Playing/Progress") {
            (35...50).contains(Double(self.ticks($0)) / 10_000_000) && $0["IsPaused"] as? Bool == true
        }
        let cursor = try await reports().count
        let play = try await playerButton("playerPlayPause", labels: ["Play"], description: "resume")
        play.tap()
        _ = try await waitReport(after: cursor, path: "/Sessions/Playing/Progress") { $0["IsPaused"] as? Bool == false }
        try await Task.sleep(for: .seconds(1.5))
        let advanced = try await pausePlayer()
        XCTAssertGreaterThan(ticks(advanced), ticks(sought) + 5_000_000)
        XCTAssertEqual(advanced["PlaySessionId"] as? String, started["PlaySessionId"] as? String)
        capture("player-pause-resume-seek")
    }

    func testAudioAndSubtitleChoicesAffectGenuineMedia() async throws {
        try await launch(.tracks, username: "tv-multiaudio")
        _ = try await startMovie()
        try await chooseInOptions("playerAudio", "Español sintético 880 Hz",
                                  matching: { ($0["AudioStreamIndex"] as? NSNumber)?.intValue == 3 }, description: "Spanish audible rendition")
        try await chooseInOptions("playerSubtitles", "Synthetic multi-audio captions",
                                  matching: { ($0["SubtitleStreamIndex"] as? NSNumber)?.intValue == 2 }, description: "real WebVTT captions")
        // The cue is drawn by the player's own video layer.
        try await captionVisible(true)
        try await chooseInOptions("playerSubtitles", "Off",
                                  matching: { ($0["SubtitleStreamIndex"] as? NSNumber)?.intValue == -1 }, description: "subtitles Off")
        try await captionVisible(false)
        let effective = try await pausePlayer()
        XCTAssertEqual((effective["AudioStreamIndex"] as? NSNumber)?.intValue, 3,
                       "The audio choice must be reflected by effective selection reporting.")
        capture("player-audio-and-subtitles-off")
    }

    private func captionVisible(_ expected: Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        var consecutive = 0
        repeat {
            let screenshot = XCUIScreen.main.screenshot()
            let recognition = VNRecognizeTextRequest()
            recognition.recognitionLevel = .accurate
            recognition.usesLanguageCorrection = false
            recognition.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(data: screenshot.pngRepresentation, options: [:]).perform([recognition])
            let words = (recognition.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
            let present = words.contains("REEL TV MULTI AUDIO CAPTION")
            consecutive = present == expected ? consecutive + 1 : 0
            if consecutive >= 2 { return }
            try await Task.sleep(for: .milliseconds(400))
        } while Date() < deadline
        try fail(expected ? "The genuinely enabled WebVTT caption did not render on screen." : "The real caption remained visible after native Off selection.")
    }

    func testPictureInPictureRestoresAdvancingSession() async throws {
        try await launch(.tracks, username: "tv-multiaudio")
        let started = try await startMovie()
        let cursor = try await reports().count
        let pip = try await playerButton("playerPictureInPicture", labels: ["Picture in picture"], description: "Picture in Picture")
        pip.tap()
        XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let restore = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Return to Full Screen", "Return to full screen", "Restore", "Stop Picture in Picture"]))
        let floating = springboard.otherElements.matching(NSPredicate(format: "label == %@", "Picture in Picture")).firstMatch
        if floating.exists && floating.isHittable { floating.tap() }
        try await until("actual system PiP restoration control") { restore.allElementsBoundByIndex.contains { $0.isHittable } }
        let matches = restore.allElementsBoundByIndex.filter { $0.exists && $0.isHittable }
        guard matches.count == 1 else { try fail("Expected one system PiP restore action.", other: springboard) }
        capture("native-system-picture-in-picture", other: springboard)
        let advancing = try await waitReport(after: cursor, path: "/Sessions/Playing/Progress", timeout: 15) {
            $0["IsPaused"] as? Bool == false && self.ticks($0) > self.ticks(started) + 10_000_000
        }
        XCTAssertEqual(advancing["PlaySessionId"] as? String, started["PlaySessionId"] as? String)
        matches[0].tap()
        try await until("PiP returns to the same foreground video") { self.app.state == .runningForeground && self.nativeSurface.exists }
        let after = try await pausePlayer()
        XCTAssertEqual(after["PlaySessionId"] as? String, started["PlaySessionId"] as? String)
        XCTAssertGreaterThanOrEqual(ticks(after), ticks(advancing))
        capture("native-picture-in-picture-restored")
    }

    func testVideoTapShowsAndHidesControls() async throws {
        try await launch(.tracks, username: "tv-multiaudio")
        _ = try await startMovie()
        let options = app.buttons["playbackOptions"]
        try await until("initial controls auto-hide") { !options.isHittable }
        try tapVideo()
        try await until("a tap shows the controls") { options.isHittable }
        try tapVideo()
        try await until("a second tap hides them", timeout: 3) { !options.isHittable }
        try tapVideo()
        try await until("a third tap shows them again") { options.isHittable }
        try await Task.sleep(for: .seconds(2.2))
        XCTAssertTrue(options.isHittable, "Shown controls must stay up for four seconds.")
        try await until("controls hide after four idle seconds", timeout: 4) { !options.isHittable }
        try tapVideo()
        try await tap(options, description: "options after a reveal")
        XCTAssertTrue(app.navigationBars["Playback options"].exists)
        capture("player-tap-shows-and-hides-controls")
    }

    func testLoadingKeepsHeaderAndCloseUsable() async throws {
        try await launch(.slowMedia, username: "tv-ui-slow-media")
        let cursor = try await reports().count
        try await tap(app.buttons["heroPlay"], description: "start genuinely delayed media")
        let loading = app.staticTexts["Setting the scene…"]
        try await until("actual loading overlay", timeout: 3) { loading.exists }
        try await Task.sleep(for: .seconds(4.5))
        XCTAssertTrue(loading.exists, "The fixture must still be loading when its pinned header is checked.")
        XCTAssertTrue(app.buttons["playbackOptions"].isHittable)
        try await tap(app.buttons["closePlayer"], description: "close during loading")
        try await until("loading player closes") { !self.nativeSurface.exists && self.app.buttons["heroPlay"].exists }
        try await Task.sleep(for: .seconds(7))
        XCTAssertFalse(nativeSurface.exists, "The delayed media reply must not reopen a closed player.")
        let later = try await reports().dropFirst(cursor)
        XCTAssertFalse(later.contains { $0["path"] as? String == "/Sessions/Playing" }, "Closing preparation must not create a started watch session.")
        capture("native-loading-header-close")
    }

    func testErrorPinsHeaderAndActualRetryRecovers() async throws {
        try await launch(.tracks, username: "tv-multiaudio")
        let cursor = try await reports().count
        try await tap(app.buttons["heroDetails"], description: "failure fixture Details")
        try await visible(app.buttons["detailPlay"], description: "failure fixture Play")
        try await until("failure fixture's genuine multi-audio Details source") { !self.app.buttons["versionPicker"].exists }
        _ = try await request("/qa/audio-control", method: "POST", body: ["failNextMaster": true])
        audioFailureArmed = true
        do {
            if app.buttons["detailStartOver"].exists { try await tap(app.buttons["detailStartOver"], description: "start failing media from beginning") }
            else { try await tap(app.buttons["detailPlay"], description: "start one-shot failing media") }
            try await until("real player error and Retry", timeout: 35) { self.app.buttons["retry"].exists }
            try await Task.sleep(for: .seconds(4.5))
            XCTAssertTrue(app.buttons["playbackOptions"].isHittable)
            XCTAssertTrue(app.buttons["closePlayer"].isHittable)
            try await tap(app.buttons["retry"], description: "Retry failed native playback")
            _ = try await waitReport(after: cursor, path: "/Sessions/Playing")
            _ = try await playerButton("playerPlayPause", labels: ["Pause"], description: "playing after Retry")
            XCTAssertFalse(app.buttons["retry"].exists)
            _ = try await request("/qa/audio-control", method: "POST", body: ["failNextMaster": false])
            audioFailureArmed = false
            capture("native-error-header-retry-recovery")
        } catch {
            if audioFailureArmed {
                do { _ = try await request("/qa/audio-control", method: "POST", body: ["failNextMaster": false]) }
                catch { capture("native-master-failure-cleanup-failed"); XCTFail("The owned one-shot media fault could not be cleared.") }
                audioFailureArmed = false
            }
            throw error
        }
    }

    func testEndedHeaderReplayAndReturnHaveFreshPlaybackEffects() async throws {
        try await launch()
        _ = try await startMovie()
        try await seekToEndThroughSheet()
        let replay = app.buttons["replayPlayer"]
        try await until("real EOF replay action") { replay.exists }
        try await Task.sleep(for: .seconds(4.5))
        XCTAssertTrue(app.buttons["closePlayer"].isHittable)
        XCTAssertTrue(app.buttons["playbackOptions"].isHittable)
        let beforeReplay = try await reports().count
        try await tap(replay, description: "Play again after genuine EOF")
        let restarted = try await waitReport(after: beforeReplay, path: "/Sessions/Playing")
        XCTAssertLessThan(ticks(restarted), 30_000_000)
        let paused = try await pausePlayer()
        let play = try await playerButton("playerPlayPause", labels: ["Play"], description: "resume replay")
        play.tap()
        try await Task.sleep(for: .seconds(1.5))
        let advanced = try await pausePlayer()
        XCTAssertGreaterThan(ticks(advanced), ticks(paused) + 5_000_000)
        try await seekToEndThroughSheet()
        try await tap(app.buttons["Back to your library"], description: "return after replay EOF")
        try await until("ended player returns to library") { !self.nativeSurface.exists && self.app.buttons["heroDetails"].exists }
        capture("native-eof-replay-and-return")
    }

    private func seekToEndThroughSheet() async throws {
        let transport = app.reelPlaybackButton("transportPlayPause")
        try await until("ready custom sheet transport") { transport.exists && transport.isEnabled }
        if transport.label == "Pause" { transport.tap() }
        let timeline = app.sliders["scrubTimeline"]
        try await visible(timeline, description: "owned sheet EOF setup timeline")
        timeline.adjust(toNormalizedSliderPosition: 0.94)
        try await until("paused before advancing to genuine EOF") { transport.label == "Play" }
        transport.tap()
        try await tap(app.navigationBars["Playback options"].buttons["Done"], description: "dismiss EOF setup sheet")
        try await until("genuine playback-finished screen", timeout: 10) { self.app.buttons["Back to your library"].exists }
    }

    func testGroupControlsAtGenuineEndOpenOwnedGroup() async throws {
        try await launch(.remote)
        try await tap(app.buttons["heroDetails"], description: "selected group title")
        try await tap(app.buttons["detailMore"], description: "Details more menu")
        try await tap(app.buttons["remotePlayback"], description: "watch-together presentation")
        let name = app.textFields["syncGroupName"]
        try await visible(name, description: "owned group name")
        name.tap(); name.typeText("Presentation EOF " + String(UUID().uuidString.prefix(8)))
        try await tap(app.buttons["syncCreate"], description: "create own fixture group")
        let cursor = try await reports().count
        try await tap(app.buttons["syncPlaySelected"], description: "play selected title together")
        _ = try await waitReport(after: cursor, path: "/Sessions/Playing")
        app.prepareReelPlayerControl("scrubTimeline")
        let timeline = app.sliders["scrubTimeline"]
        try await visible(timeline, description: "managed seek setup")
        let beforeSeekEvents = (try await request("/qa/remote-state")["events"] as? [[String: Any]] ?? []).count
        timeline.adjust(toNormalizedSliderPosition: 0.75)
        let seekDeadline = Date().addingTimeInterval(8)
        var readyNearEnd = false
        repeat {
            let state = try await request("/qa/remote-state")
            let events = (state["events"] as? [[String: Any]] ?? []).dropFirst(beforeSeekEvents)
            readyNearEnd = events.contains {
                $0["user"] as? String == user && $0["path"] as? String == "/SyncPlay/Ready"
                    && (170_000_000...200_000_000).contains(self.ticks($0["body"] as? [String: Any] ?? [:]))
            }
            if readyNearEnd { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < seekDeadline
        guard readyNearEnd else { try fail("The actual managed UI seek never reached readiness near EOF.") }
        try await tap(app.navigationBars["Playback options"].buttons["Done"], description: "dismiss managed seek setup")
        // Only this newly created user's next command is rejected. EOF still comes from the real media.
        _ = try await request("/qa/remote-control", method: "POST", body: ["failCommand": 1])
        let atEnd = app.buttons["groupControlsAtEnd"]
        try await until("genuine managed EOF controls", timeout: 15) { atEnd.exists && atEnd.isHittable }
        // The end controls appear the moment playback ends; the group monitor asks for the next
        // title on its next half-second tick, so wait for that request instead of reading once.
        var state: [String: Any] = [:]
        let nextDeadline = Date().addingTimeInterval(5)
        repeat {
            state = try await request("/qa/remote-state")
            let requested = (state["events"] as? [[String: Any]] ?? []).contains {
                $0["user"] as? String == user && $0["path"] as? String == "/SyncPlay/NextItem"
            }
            if requested { break }
            try await Task.sleep(for: .milliseconds(100))
        } while Date() < nextDeadline
        let events = try XCTUnwrap(state["events"] as? [[String: Any]])
        XCTAssertTrue(events.contains { $0["user"] as? String == user && $0["path"] as? String == "/SyncPlay/NextItem" })
        let groupID = try XCTUnwrap((state["members"] as? [String: String])?[user])
        try await tap(atEnd, description: "Group controls at genuine EOF")
        // The row's identifier also lands on its decorative icon, which is never hittable; check the group's name.
        try await visible(app.staticTexts.matching(identifier: "activeSyncGroup").firstMatch, description: "owned group after EOF action")
        try await tap(app.buttons["syncLeave"], description: "leave own ended group")
        try await until("ended group closes local player") { !self.nativeSurface.exists }
        let after = try await request("/qa/remote-state")
        XCTAssertNil((after["members"] as? [String: String])?[user])
        XCTAssertNotNil((after["groups"] as? [String: [String: Any]])?[groupID], "Leaving local playback must preserve the existing group object.")
        capture("native-group-controls-at-real-eof")
    }

    func testLargestTextKeepsPlayerHeaderAvailable() async throws {
        try await launch(largeText: true)
        _ = try await startMovie()
        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(app.buttons["playbackOptions"].isHittable)
        XCTAssertTrue(app.buttons["closePlayer"].isHittable)
        try await tap(app.buttons["playbackOptions"], description: "largest-text pinned options")
        try await tap(app.navigationBars["Playback options"].buttons["Done"], description: "largest-text Done")
        capture("native-largest-text-pinned-header")
    }

    func testActualVoiceOverKeepsPlayerHeaderAvailable() async throws {
        try requireOwnedSimulator()
        guard UIAccessibility.isVoiceOverRunning else { try fail("Enable actual system VoiceOver on the leased simulator before this accessibility journey; no app flag substitutes for it.") }
        try await launch()
        _ = try await startMovie()
        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(app.buttons["playbackOptions"].isHittable)
        XCTAssertTrue(app.buttons["closePlayer"].isHittable)
        try await tap(app.buttons["playbackOptions"], description: "VoiceOver pinned options")
        capture("native-actual-voiceover-header")
    }

    func testActualReduceMotionAllowsHeaderRevealAndOptions() async throws {
        try requireOwnedSimulator()
        guard UIAccessibility.isReduceMotionEnabled else { try fail("Enable actual system Reduce Motion on the leased simulator before this journey.") }
        try await launch()
        _ = try await startMovie()
        let options = app.buttons["playbackOptions"]
        try await until("Reduce Motion header auto-hide") { !options.isHittable }
        try tapVideo()
        try await tap(options, description: "Reduce Motion reveal then options")
        try await tap(app.navigationBars["Playback options"].buttons["Done"], description: "Reduce Motion Done")
        capture("native-actual-reduce-motion-controls")
    }

    private func capture(_ name: String, other: XCUIApplication? = nil) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription + (other.map { "\nSystem UI:\n" + $0.debugDescription } ?? ""))
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private func fail(_ message: String, other: XCUIApplication? = nil, file: StaticString = #filePath, line: UInt = #line) throws -> Never {
        capture("player-presentation-failure", other: other)
        XCTFail(message, file: file, line: line)
        throw NSError(domain: "PlayerPresentationUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
