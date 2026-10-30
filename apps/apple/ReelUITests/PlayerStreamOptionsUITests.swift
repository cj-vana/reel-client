import XCTest
import UIKit
import AVKit

@MainActor final class PlayerStreamOptionsUITests: XCTestCase {
    private let app = XCUIApplication()
    private var didLaunchOwnedApp = false
    private var port = 18966
    private var user = "tv-track-output"
    private var owner: String { ProcessInfo.processInfo.environment["REEL_TV_QA_OWNER"] ?? "" }

    override func tearDown() { if didLaunchOwnedApp { app.terminate(); XCUIDevice.shared.orientation = .portrait }; super.tearDown() }

    private func launch(tracks: Bool = false, largeText: Bool = false, metadata: Bool = false, episode: Bool = false, options: Bool = true, noSegments: Bool = false, group: Bool = false, emptySeriesMetadata: Bool = false, missingSeasonIndex: Bool = false) async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("Reel QA Improvements Player ") == true,
              environment["SIMULATOR_UDID"] == environment["REEL_PLAYER_QA_DEVICE_UDID"], !owner.isEmpty else {
            throw XCTSkip("Requires the exact owned Reel player simulator and synthetic fixture identity.")
        }
        continueAfterFailure = false
        port = group ? 18974 : metadata ? 18968 : tracks ? 18969 : Int(environment["REEL_PLAYER_QA_BASE_PORT"] ?? "") ?? 18966
        user = group ? "player-group-" + UUID().uuidString : episode ? "tv-episode-player-" + UUID().uuidString : tracks ? "tv-multiaudio" : "tv-track-output"
        let identity = try await request("/qa/tv-identity")
        XCTAssertEqual(identity["owner"] as? String, owner)
        XCTAssertEqual(identity["port"] as? Int, port)
        app.launchArguments = ["-reel-qa-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:\(port)"
        if episode { _ = try await request("/qa/episode-control", body: ["seasonsFail": false, "seasonsEmpty": false, "episodesFail": false, "episodesEmpty": false, "episodesDelay": false, "noSegments": noSegments, "autoIntro": false, "hideIntro": false, "emptySeriesMetadata": emptySeriesMetadata, "seasonsDelay": false, "missingEpisodeArtwork": false, "delayStream": false, "missingSeasonIndex": missingSeasonIndex]) }
        if tracks { _ = try await request("/qa/audio-control", body: ["unresolvableAudio": false, "failNextMaster": false, "failNextVideo": false]) }
        if metadata { _ = try await request("/qa/tv-control", body: ["subtitleCatalogUnavailable": false, "subtitleCatalogDelay": false]) }
        didLaunchOwnedApp = true
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        let name = app.textFields["username"]
        try await visible(name); name.tap(); name.typeText(user); name.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        try await visible(password); password.tap(); password.typeText("demo"); password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        if group {
            app.tabBars.buttons["More"].tap(); try await tap(app.buttons["Devices"])
            try await visible(app.buttons["syncJoin-fixture-group"])
            let before = try await reports().count
            app.buttons["syncJoin-fixture-group"].tap()
            try await waitStart(after: before)
            return
        }
        if episode { try await tap(app.buttons["home-Series"]) }
        try await tap(app.buttons["heroDetails"])
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 10))
        if tracks {
            let deadline = Date().addingTimeInterval(8)
            while app.buttons["versionPicker"].exists && Date() < deadline { try await Task.sleep(for: .milliseconds(150)) }
        }
        let before = try await reports().count
        if episode { try await tap(app.buttons["episodePlay-episode-1-1"]) }
        else if app.buttons["detailStartOver"].exists { try await tap(app.buttons["detailStartOver"]) }
        else { try await tap(app.buttons["detailPlay"]) }
        try await waitStart(after: before)
        if !options { return }
        app.revealReelPlayerChrome(); try await tap(app.buttons["playbackOptions"])
        let grabber = app.buttons["Sheet Grabber"]
        if grabber.exists && (grabber.value as? String) == "Half screen" {
            grabber.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
                .press(forDuration: 0.2, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)))
        }
        try await visible(app.buttons["transportPlayPause"])
        if app.buttons["transportPlayPause"].label == "Pause" { app.buttons["transportPlayPause"].tap() }
        // Expand the native sheet using its drag affordance before browsing its controls.
        app.swipeUp()
        if episode { try await setAutoplay(true) }
        if app.buttons["playerQuality"].exists {
            try await visible(app.buttons["playerQuality"])
            app.scrollViews["playerOptionsScroll"].swipeDown()
        }
    }

    func testOptionsVisualSnapshot() async throws {
        try await launch()
        snapshot("player-options-current")
        XCTAssertTrue(app.navigationBars["Playback options"].exists)
    }

    func testNativePictureInPictureReturnsToSamePlayback() async throws {
        try await launch(tracks: true, options: false)
        guard AVPictureInPictureController.isPictureInPictureSupported() else {
            snapshot("player-pip-unavailable-on-simulator")
            throw XCTSkip("AVKit reports Picture in Picture unsupported on this owned simulator; native system restoration requires a supporting runtime.")
        }
        let initialReports = try await reports()
        let start = try XCTUnwrap(initialReports.last { $0["path"] as? String == "/Sessions/Playing" })
        let sessionID = try XCTUnwrap((start["body"] as? [String: Any])?["PlaySessionId"] as? String)
        let cursor = try await reports().count
        let native = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        // Picture in picture is the player's own button beside AirPlay in its header.
        let pip = app.buttons.matching(identifier: "playerPictureInPicture")
        app.revealReelPlayerChrome()
        let deadline = Date().addingTimeInterval(8)
        while !pip.allElementsBoundByIndex.contains(where: { $0.isHittable }), Date() < deadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        snapshot("player-pip-control")
        let button = try XCTUnwrap(pip.allElementsBoundByIndex.first { $0.isHittable })
        button.tap(); XCUIDevice.shared.press(.home)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let floating = springboard.otherElements.matching(NSPredicate(format: "label == %@", "Picture in Picture")).firstMatch
        if floating.exists && floating.isHittable { floating.tap() }
        let restore = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Return to Full Screen", "Return to full screen", "Restore", "Stop Picture in Picture"]))
        let restoreDeadline = Date().addingTimeInterval(8)
        while !restore.allElementsBoundByIndex.contains(where: { $0.isHittable }), Date() < restoreDeadline {
            try await Task.sleep(for: .milliseconds(200))
        }
        let restoreButton = try XCTUnwrap(restore.allElementsBoundByIndex.first { $0.isHittable })
        let attachment = XCTAttachment(screenshot: springboard.screenshot()); attachment.name = "player-native-pip"; attachment.lifetime = .keepAlways; add(attachment)
        try await Task.sleep(for: .seconds(11))
        let reportsAfter = try await reports().dropFirst(cursor)
        XCTAssertTrue(reportsAfter.contains { report in
            let body = report["body"] as? [String: Any]
            return report["path"] as? String == "/Sessions/Playing/Progress" && body?["PlaySessionId"] as? String == sessionID && body?["IsPaused"] as? Bool == false
        })
        restoreButton.tap()
        XCTAssertTrue(native.waitForExistence(timeout: 8))
        app.revealReelPlayerChrome(); try await tap(app.buttons["playbackOptions"])
        try await visible(app.buttons["transportPlayPause"])
        app.buttons["transportPlayPause"].tap()
        let final = try await reports().dropFirst(cursor)
        XCTAssertFalse(final.contains { $0["path"] as? String == "/Sessions/Playing" })
        snapshot("player-native-pip-restored")
    }

    func testGroupRestrictsLocalChoicesAndLeavingRecovers() async throws {
        try await launch(group: true)
        app.revealReelPlayerChrome(); try await tap(app.buttons["playbackOptions"])
        try await visible(app.staticTexts["Managed by your watch group"])
        XCTAssertFalse(app.buttons["playerQuality"].exists)
        XCTAssertFalse(app.buttons["playerAudio"].exists)
        XCTAssertFalse(app.buttons["playerSubtitles"].exists)
        XCTAssertFalse(app.switches["autoplayNextEpisode"].exists)
        for id in ["playbackSpeed", "sleepTimer", "playerChapters"] {
            try await visible(app.buttons[id]); XCTAssertFalse(app.buttons[id].isEnabled)
        }
        snapshot("player-group-restrictions")
        app.navigationBars["Playback options"].buttons["Done"].tap()
        app.revealReelPlayerChrome()
        XCTAssertFalse(app.buttons["playerEpisodes"].exists)
        try await tap(app.buttons["groupControls"])
        let leave = try XCTUnwrap(app.buttons.matching(identifier: "syncLeave").allElementsBoundByIndex.first { $0.isHittable })
        leave.tap()
        XCTAssertTrue(app.buttons.matching(identifier: "syncJoin-fixture-group").firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists)
        app.tabBars.buttons["Home"].tap()
        try await tap(app.buttons["heroDetails"])
        let cursor = try await reports().count
        try await tap(app.buttons["detailPlay"]); try await waitStart(after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["playerQuality"])
        XCTAssertTrue(app.buttons["playerQuality"].isEnabled)
        snapshot("player-after-leaving-group")
    }

    func testServerQualityLockAndLocalRecovery() async throws {
        try await launch()
        app.navigationBars["Playback options"].buttons["Done"].tap()
        app.revealReelPlayerChrome(); app.buttons["closePlayer"].tap()
        app.tabBars.buttons["More"].tap(); try await tap(app.buttons["Settings"])
        let control = app.switches["useServerPreferences"]
        try await visible(control)
        if control.value as? String != "1" {
            let nested = control.switches.firstMatch
            if nested.exists { nested.tap() } else { control.tap() }
        }
        try await visible(app.staticTexts["4 Mbps"])
        app.tabBars.buttons["Home"].tap()
        let cursor = try await reports().count
        try await tap(app.buttons["detailPlay"])
        try await waitStart(after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["playerQuality"])
        XCTAssertFalse(app.buttons["playerQuality"].isEnabled)
        XCTAssertTrue(app.buttons["playerQuality"].label.contains("4.0 Mbps"))
        snapshot("player-server-quality-locked")
        app.navigationBars["Playback options"].buttons["Done"].tap()
        app.revealReelPlayerChrome(); app.buttons["closePlayer"].tap()
        app.tabBars.buttons["More"].tap()
        if !control.exists { try await tap(app.buttons["Settings"]) }
        try await visible(control)
        let nested = control.switches.firstMatch
        if nested.exists { nested.tap() } else { control.tap() }
        let disabled = expectation(for: NSPredicate(format: "value == %@", "0"), evaluatedWith: control)
        await fulfillment(of: [disabled], timeout: 4)
        app.tabBars.buttons["Home"].tap()
        let nextCursor = try await reports().count
        try await tap(app.buttons["detailPlay"]); try await waitStart(after: nextCursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["playerQuality"])
        XCTAssertTrue(app.buttons["playerQuality"].isEnabled)
        app.buttons["playerQuality"].tap(); try await tap(app.buttons["Balanced · 8 Mbps"])
        snapshot("player-local-quality-recovered")
    }

    func testQualityAndVersionKeepPausedPlaybackInTheSheet() async throws {
        try await launch()
        var before = try await reports().count
        try await tap(app.buttons["playerQuality"])
        try await tap(app.buttons["Balanced · 8 Mbps"])
        try await waitStart(after: before)
        XCTAssertTrue(app.navigationBars["Playback options"].exists)
        try await visible(app.buttons["playerVersion"])
        before = try await reports().count
        app.buttons["playerVersion"].tap()
        try await tap(app.buttons["Alternate version"])
        try await waitStart(after: before, source: "movie-1-alternate")
        try await visible(app.buttons["playerVersion"])
        XCTAssertTrue(app.buttons["playerVersion"].label.contains("Alternate version"))
        snapshot("player-options-version-and-quality")
        try await tap(app.navigationBars["Playback options"].buttons["Done"])
        app.revealReelPlayerChrome(); try await tap(app.buttons["closePlayer"])
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
    }

    func testAudioSubtitlesAndOffUseActualStreamChoices() async throws {
        try await launch(tracks: true)
        var before = try await reports().count
        try await tap(app.buttons["playerAudio"])
        try await tap(app.buttons["Español sintético 880 Hz"])
        try await waitStart(after: before, audio: 3)
        before = try await reports().count
        try await tap(app.buttons["playerSubtitles"])
        try await tap(app.buttons["Synthetic multi-audio captions"])
        try await waitStart(after: before, audio: 3, subtitle: 2)
        before = try await reports().count
        try await tap(app.buttons["playerSubtitles"])
        try await tap(app.buttons["Off"])
        try await waitStart(after: before, audio: 3, subtitle: -1)
        try await visible(app.buttons["playerSubtitles"])
        XCTAssertTrue(app.buttons["playerSubtitles"].label.contains("Off"))
        snapshot("player-options-audio-and-subtitles-off")
    }

    func testFailedStreamCanRetryWithoutClosingOptions() async throws {
        try await launch(tracks: true)
        _ = try await request("/qa/audio-control", body: ["unresolvableAudio": true])
        try await tap(app.buttons["playerQuality"])
        try await tap(app.buttons["High · 20 Mbps"])
        try await visible(app.buttons["retryPlayerStream"], timeout: 40)
        XCTAssertTrue(app.staticTexts["playerStreamError"].exists)
        snapshot("player-options-stream-error")
        _ = try await request("/qa/audio-control", body: ["unresolvableAudio": false])
        let before = try await reports().count
        app.buttons["retryPlayerStream"].tap()
        try await waitStart(after: before)
        try await visible(app.buttons["playerQuality"])
        XCTAssertTrue(app.buttons["playerQuality"].isEnabled)
        snapshot("player-options-stream-recovered")
    }

    func testFullscreenRetryAndOriginalRecoveryUseExplicitQuality() async throws {
        try await launch(tracks: true)
        for original in [false, true] {
            _ = try await request("/qa/audio-control", body: ["unresolvableAudio": true])
            try await tap(app.buttons["playerQuality"]); try await tap(app.buttons["Balanced · 8 Mbps"])
            try await visible(app.buttons["retryPlayerStream"], timeout: 40)
            app.navigationBars["Playback options"].buttons["Done"].tap()
            try await visible(app.buttons[original ? "originalQualityRecovery" : "retry"])
            _ = try await request("/qa/audio-control", body: ["unresolvableAudio": false])
            let cursor = try await reports().count
            app.buttons[original ? "originalQualityRecovery" : "retry"].tap()
            try await waitStart(after: cursor)
            let recent = try await reports().dropFirst(cursor)
            let request = try XCTUnwrap(recent.first { ($0["path"] as? String)?.hasSuffix("/PlaybackInfo") == true })
            XCTAssertEqual(((request["body"] as? [String: Any])?["MaxStreamingBitrate"] as? NSNumber)?.intValue, original ? 120_000_000 : 8_000_000)
            app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
            try await visible(app.buttons["playerQuality"])
            XCTAssertTrue(app.buttons["playerQuality"].label.contains(original ? "Original / auto" : "Balanced · 8 Mbps"))
        }
        snapshot("player-fullscreen-retry-and-original")
    }

    func testEveryQualityChoicePersistsAcrossRelaunch() async throws {
        try await launch(tracks: true)
        for (label, bitrate) in [("Original / auto", 120_000_000), ("High · 20 Mbps", 20_000_000), ("Balanced · 8 Mbps", 8_000_000), ("Data saver · 2 Mbps", 2_000_000)] {
            let cursor = try await reports().count
            try await tap(app.buttons["playerQuality"]); try await tap(app.buttons[label])
            try await waitStart(after: cursor)
            let recent = try await reports().dropFirst(cursor)
            let request = try XCTUnwrap(recent.first { ($0["path"] as? String)?.hasSuffix("/PlaybackInfo") == true })
            XCTAssertEqual(((request["body"] as? [String: Any])?["MaxStreamingBitrate"] as? NSNumber)?.intValue, bitrate)
        }
        app.navigationBars["Playback options"].buttons["Done"].tap()
        app.revealReelPlayerChrome(); app.buttons["closePlayer"].tap()
        app.terminate(); app.launchArguments.removeAll { $0 == "-reel-qa-reset" }; app.launch()
        try await tap(app.buttons["heroDetails"])
        let cursor = try await reports().count
        try await tap(app.buttons["detailPlay"]); try await waitStart(after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["playerQuality"])
        XCTAssertTrue(app.buttons["playerQuality"].label.contains("Data saver · 2 Mbps"))
        app.buttons["playerQuality"].tap(); try await tap(app.buttons["Original / auto"])
        snapshot("player-quality-persisted")
    }

    func testLargestTextKeepsStreamControlsReachable() async throws {
        try await launch(largeText: true)
        for id in ["playerQuality", "playerAudio", "playerSubtitles", "playerVersion"] {
            try await visible(app.buttons[id]); XCTAssertTrue(app.buttons[id].isHittable)
        }
        snapshot("player-options-largest-text")
    }

    func testMetadataFailureReloadAndClosingWhileLoading() async throws {
        try await launch(metadata: true)
        app.navigationBars["Playback options"].buttons["Done"].tap()
        _ = try await request("/qa/tv-control", body: ["subtitleCatalogUnavailable": true])
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["reloadPlayerStreams"])
        XCTAssertFalse(app.buttons["playerAudio"].isEnabled)
        snapshot("player-options-metadata-error")
        _ = try await request("/qa/tv-control", body: ["subtitleCatalogUnavailable": false])
        app.buttons["reloadPlayerStreams"].tap()
        try await visible(app.buttons["playerAudio"])
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playerAudio"])
        await fulfillment(of: [enabled], timeout: 8)
        app.navigationBars["Playback options"].buttons["Done"].tap()
        _ = try await request("/qa/tv-control", body: ["subtitleCatalogDelay": true])
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        XCTAssertFalse(app.buttons["playerQuality"].isEnabled)
        snapshot("player-options-metadata-loading")
        app.navigationBars["Playback options"].buttons["Done"].tap()
        _ = try await request("/qa/tv-control", body: ["subtitleCatalogDelay": false])
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["playerAudio"])
        let recovered = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["playerAudio"])
        await fulfillment(of: [recovered], timeout: 8)
        snapshot("player-options-metadata-recovered")
    }

    func testTimelineDragCommitsAndDismissesPreview() async throws {
        try await launch(episode: true)
        let slider = app.sliders["scrubTimeline"]
        try await visible(slider)
        let frame = slider.frame
        let position = slider.normalizedSliderPosition
        let cursor = try await reports().count
        let origin = slider.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0.5))
        let width = max(1, frame.width - 28)
        let start = origin.withOffset(CGVector(dx: 14 + width * CGFloat(position), dy: 0))
        let end = origin.withOffset(CGVector(dx: 14 + width * 0.75, dy: 0))
        start.press(forDuration: 0.1, thenDragTo: end)
        try await waitPosition(16...20, after: cursor)
        XCTAssertEqual(slider.frame.minY, frame.minY, accuracy: 1)
        let dismissed = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.images["trickplayThumbnail"])
        await fulfillment(of: [dismissed], timeout: 3)
        let adjustmentCursor = try await reports().count
        slider.adjust(toNormalizedSliderPosition: 0.25)
        try await waitPosition(4...8, after: adjustmentCursor)
        XCTAssertFalse(app.images["trickplayThumbnail"].exists)
        snapshot("player-timeline-drag-and-adjustment-committed")
    }

    func testPlaybackToolsAndStreamInformationRemainReachable() async throws {
        try await launch()
        var cursor = try await reports().count
        try await tap(app.buttons["playerChapters"]); try await tap(app.buttons["A new chapter"])
        try await waitPosition(7.8...8.5, after: cursor)
        cursor = try await reports().count
        try await tap(app.buttons["Back 10 seconds"]); try await waitPosition(0...0.5, after: cursor)
        cursor = try await reports().count
        try await tap(app.buttons["Forward 10 seconds"]); try await waitPosition(9.5...10.5, after: cursor)
        for rate in ["0.5×", "0.75×", "1×", "1.25×", "1.5×", "2×"] {
            try await tap(app.buttons["playbackSpeed"]); try await tap(app.buttons[rate])
            XCTAssertTrue(app.buttons["playbackSpeed"].label.contains(rate))
        }
        try await tap(app.buttons["playbackSpeed"]); try await tap(app.buttons["1×"])
        for minutes in [15, 30, 45, 60] {
            try await tap(app.buttons["sleepTimer"]); try await tap(app.buttons["\(minutes) minutes"])
            XCTAssertTrue(app.buttons["sleepTimer"].label.contains("Timer on"))
            try await tap(app.buttons["sleepTimer"]); try await tap(app.buttons["Off"])
            XCTAssertTrue(app.buttons["sleepTimer"].label.contains("Sleep timer"))
        }
        cursor = try await reports().count
        try await tap(app.buttons["playerChapters"]); try await tap(app.buttons["Opening"])
        try await waitPosition(0...0.5, after: cursor)
        try await visible(app.buttons["transportPlayPause"])
        app.buttons["transportPlayPause"].tap()
        try await Task.sleep(for: .seconds(2))
        cursor = try await reports().count
        app.buttons["transportPlayPause"].tap()
        try await waitPosition(1...5, after: cursor)
        XCTAssertEqual(app.buttons["transportPlayPause"].label, "Play")
        try await tap(app.buttons["streamInformation"])
        try await visible(app.descendants(matching: .any)["playbackFormat"])
        snapshot("player-options-tools-and-stream-information")
    }

    func testPreviousNextAndAnySeasonSelectionKeepPlayerAvailable() async throws {
        try await launch(episode: true)
        try await visible(app.buttons["previousEpisode"])
        XCTAssertFalse(app.buttons["previousEpisode"].isEnabled)
        var cursor = try await reports().count
        app.buttons["nextEpisode"].tap()
        try await waitEpisode("episode-1-2", after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["previousEpisode"])
        cursor = try await reports().count
        app.buttons["previousEpisode"].tap()
        try await waitEpisode("episode-1-1", after: cursor, startsAtBeginning: true)
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.buttons["playerEpisode-episode-1-1"])
        XCTAssertFalse(app.buttons["playerEpisode-episode-1-1"].isEnabled)
        cursor = try await reports().count
        try await tap(app.buttons["playerSeasonPicker"])
        try await tap(app.buttons["Season 2"])
        try await visible(app.buttons["playerEpisode-episode-2-2"])
        let browsingReports = try await reports().dropFirst(cursor)
        XCTAssertFalse(browsingReports.contains { $0["path"] as? String == "/Sessions/Playing/Stopped" })
        snapshot("player-episode-picker-season-two")
        app.buttons["playerEpisode-episode-2-2"].tap()
        try await waitEpisode("episode-2-2", after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.buttons["playerSeasonPicker"])
        XCTAssertEqual(app.buttons["playerSeasonPicker"].value as? String, "Season 2")
        app.buttons["closePlayerEpisodes"].tap()
        XCTAssertTrue(app.buttons["playbackOptions"].exists)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["nextEpisode"])
        cursor = try await reports().count
        app.buttons["nextEpisode"].tap()
        try await waitEpisode("episode-2-3", after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["nextEpisode"])
        XCTAssertFalse(app.buttons["nextEpisode"].isEnabled)
        XCTAssertTrue(app.buttons["previousEpisode"].isEnabled)
    }

    func testSkipIntroUsesActualServerSegment() async throws {
        try await launch(episode: true, options: false)
        let skip = app.buttons["skipSegment"]
        XCTAssertTrue(skip.waitForExistence(timeout: 4))
        let cursor = try await reports().count
        skip.tap()
        let deadline = Date().addingTimeInterval(8)
        var didSeek = false
        repeat {
            didSeek = try await reports().dropFirst(cursor).contains { report in
                let body = report["body"] as? [String: Any]
                return report["path"] as? String == "/Sessions/Playing/Progress" && ((body?["PositionTicks"] as? NSNumber)?.int64Value ?? 0) >= 80_000_000
            }
            if didSeek { break }; try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        XCTAssertTrue(didSeek)
        let renderDeadline = Date().addingTimeInterval(3)
        while skip.exists && Date() < renderDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(skip.exists)
        snapshot("player-intro-skipped")
    }

    func testImportedIntroPreferencesAutomaticallySkipAndCanHidePrompt() async throws {
        try await launch(episode: true)
        app.navigationBars["Playback options"].buttons["Done"].tap()
        app.revealReelPlayerChrome(); app.buttons["closePlayer"].tap()
        for hide in [false, true] {
            _ = try await request("/qa/episode-control", body: ["autoIntro": !hide, "hideIntro": hide])
            app.tabBars.buttons["More"].tap()
            let control = app.switches["useServerPreferences"]
            if !control.exists { try await tap(app.buttons["Settings"]) }
            try await visible(control)
            if control.value as? String != "1" {
                let nested = control.switches.firstMatch
                if nested.exists { nested.tap() } else { control.tap() }
            } else { try await tap(app.buttons["refreshServerPreferences"]) }
            try await visible(app.buttons["refreshServerPreferences"])
            let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["refreshServerPreferences"])
            await fulfillment(of: [ready], timeout: 8)
            app.tabBars.buttons["Home"].tap()
            let cursor = try await reports().count
            let episodeID = hide ? "episode-1-3" : "episode-1-2"
            try await tap(app.buttons["episodePlay-\(episodeID)"])
            try await waitEpisode(episodeID, after: cursor)
            XCTAssertFalse(app.buttons["skipSegment"].exists)
            if !hide { try await waitPosition(8...12, after: cursor) }
            else {
                try await Task.sleep(for: .seconds(2))
                let recent = try await reports().dropFirst(cursor)
                XCTAssertFalse(recent.contains { report in
                    let body = report["body"] as? [String: Any]
                    return ((body?["PositionTicks"] as? NSNumber)?.int64Value ?? 0) >= 80_000_000
                })
            }
            app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
            try await visible(app.buttons["transportPlayPause"])
            if app.buttons["transportPlayPause"].label == "Pause" { app.buttons["transportPlayPause"].tap() }
            snapshot(hide ? "player-intro-prompt-hidden" : "player-intro-skipped-automatically")
            app.navigationBars["Playback options"].buttons["Done"].tap()
            app.revealReelPlayerChrome(); app.buttons["closePlayer"].tap()
        }
        _ = try await request("/qa/episode-control", body: ["autoIntro": false, "hideIntro": false])
    }

    func testStreamPreparationDisablesDuplicateChoicesAndCanClose() async throws {
        try await launch(episode: true)
        _ = try await request("/qa/episode-control", body: ["delayStream": true])
        let cursor = try await reports().count
        try await tap(app.buttons["playerQuality"]); try await tap(app.buttons["High · 20 Mbps"])
        XCTAssertFalse(app.buttons["playerQuality"].isEnabled)
        XCTAssertFalse(app.buttons["playerAudio"].isEnabled)
        snapshot("player-stream-preparation-controls-disabled")
        app.navigationBars["Playback options"].buttons["Done"].tap()
        _ = try await request("/qa/episode-control", body: ["delayStream": false])
        try await waitStart(after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["playerQuality"])
        XCTAssertTrue(app.buttons["playerQuality"].isEnabled)
    }

    func testAutomaticNextCanBeCancelledThenPlayedManually() async throws {
        try await launch(episode: true)
        try await playEpisodeToEnd()
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 10))
        let cursor = try await reports().count
        app.buttons["cancelNextEpisode"].tap()
        try await Task.sleep(for: .seconds(11))
        let cancelledReports = try await reports().dropFirst(cursor)
        XCTAssertFalse(cancelledReports.contains { $0["path"] as? String == "/Sessions/Playing" })
        XCTAssertTrue(app.buttons["playNext"].isHittable)
        snapshot("player-autoplay-cancelled")
        app.buttons["playNext"].tap()
        try await waitEpisode("episode-1-2", after: cursor)
    }

    func testSleepTimerSuppressesAutomaticNext() async throws {
        try await launch(episode: true)
        try await tap(app.buttons["sleepTimer"]); try await tap(app.buttons["15 minutes"])
        let cursor = try await reports().count
        try await playEpisodeToEnd()
        XCTAssertTrue(app.buttons["playNext"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["nextEpisodeCountdown"].exists)
        try await Task.sleep(for: .seconds(11))
        let recent = try await reports().dropFirst(cursor)
        XCTAssertFalse(recent.contains { $0["path"] as? String == "/Sessions/Playing" })
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["sleepTimer"])
        XCTAssertTrue(app.buttons["sleepTimer"].label.contains("Timer on"))
        app.buttons["sleepTimer"].tap(); try await tap(app.buttons["Off"])
        snapshot("player-sleep-suppresses-autoplay")
    }

    func testMissingIntroMetadataOffersNoInventedSkip() async throws {
        try await launch(episode: true, options: false, noSegments: true)
        try await Task.sleep(for: .seconds(2))
        XCTAssertFalse(app.buttons["skipSegment"].exists)
        app.revealReelPlayerChrome()
        XCTAssertTrue(app.buttons["playerEpisodes"].isEnabled)
        snapshot("player-no-intro-metadata")
    }

    func testEpisodeNavigationFailureReloadsWithoutStoppingCurrentVideo() async throws {
        try await launch(episode: true)
        app.navigationBars["Playback options"].buttons["Done"].tap()
        app.revealReelPlayerChrome(); app.buttons["closePlayer"].tap()
        _ = try await request("/qa/episode-control", body: ["episodesFail": true])
        let cursor = try await reports().count
        try await tap(app.buttons["episodePlay-episode-1-1"]); try await waitEpisode("episode-1-1", after: cursor)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["reloadEpisodeNavigation"])
        XCTAssertFalse(app.buttons["nextEpisode"].isEnabled)
        _ = try await request("/qa/episode-control", body: ["episodesFail": false])
        app.buttons["reloadEpisodeNavigation"].tap()
        let enabled = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["nextEpisode"])
        await fulfillment(of: [enabled], timeout: 8)
        let recent = try await reports().dropFirst(cursor)
        XCTAssertFalse(recent.contains { $0["path"] as? String == "/Sessions/Playing/Stopped" })
        snapshot("player-episode-navigation-recovered")
    }

    func testLargestTextEpisodePickerPreservesPausedPlayback() async throws {
        try await launch(largeText: true, episode: true)
        try await tap(app.navigationBars["Playback options"].buttons["Done"])
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.buttons["playerSeasonPicker"])
        app.buttons["playerSeasonPicker"].tap(); try await tap(app.buttons["Season 2"])
        let episode = app.buttons["playerEpisode-episode-2-1"]
        try await visible(episode)
        let window = app.windows.allElementsBoundByIndex.map(\.frame).first { $0.width > 0 && $0.height > 0 } ?? .zero
        XCTAssertGreaterThanOrEqual(episode.frame.minX, window.minX)
        XCTAssertLessThanOrEqual(episode.frame.maxX, window.maxX)
        XCTAssertTrue(episode.label.contains("S2"))
        snapshot("player-episodes-largest-text")
        app.buttons["closePlayerEpisodes"].tap()
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["transportPlayPause"])
        XCTAssertEqual(app.buttons["transportPlayPause"].label, "Play")
    }

    func testClosingEndedPlayerCancelsAutomaticNext() async throws {
        try await launch(episode: true)
        try await playEpisodeToEnd()
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 10))
        let cursor = try await reports().count
        app.buttons["closePlayer"].tap()
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists)
        try await Task.sleep(for: .seconds(11))
        let recent = try await reports().dropFirst(cursor)
        XCTAssertFalse(recent.contains { $0["path"] as? String == "/Sessions/Playing" })
    }

    func testFullscreenOptionsAndEpisodesFitBothOrientations() async throws {
        try await launch(episode: true)
        app.navigationBars["Playback options"].buttons["Done"].tap()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            app.revealReelPlayerChrome()
            let native = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
            XCTAssertTrue(native.waitForExistence(timeout: 6))
            let window = app.windows.firstMatch.frame
            XCTAssertEqual(native.frame.width, window.width, accuracy: 2)
            XCTAssertEqual(native.frame.height, window.height, accuracy: 2)
            for id in ["closePlayer", "playbackOptions", "playerEpisodes"] {
                let button = app.buttons[id]
                XCTAssertTrue(button.isHittable)
                XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(button.frame))
            }
            snapshot("player-fullscreen-\(orientation.rawValue)")
            app.buttons["playbackOptions"].tap()
            try await visible(app.buttons["playerQuality"])
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(app.buttons["playerQuality"].frame))
            app.buttons["playerQuality"].tap(); try await tap(app.buttons["Original / auto"])
            try await tap(app.navigationBars["Playback options"].buttons["Done"])
            app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
            try await visible(app.buttons["playerSeasonPicker"])
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(app.buttons["playerSeasonPicker"].frame))
            app.buttons["playerSeasonPicker"].tap(); try await tap(app.buttons["Season 2"])
            try await visible(app.buttons["playerEpisode-episode-2-1"])
            XCTAssertTrue(window.insetBy(dx: -1, dy: -1).contains(app.buttons["playerEpisode-episode-2-1"].frame))
            snapshot("player-episodes-\(orientation.rawValue)")
            app.buttons["closePlayerEpisodes"].tap()
        }
    }

    func testAutomaticNextStartsTheNextEpisodeAfterCountdown() async throws {
        try await launch(episode: true)
        let cursor = try await reports().count
        try await playEpisodeToEnd()
        XCTAssertTrue(app.staticTexts["nextEpisodeCountdown"].waitForExistence(timeout: 10))
        snapshot("player-autoplay-countdown")
        try await waitEpisode("episode-1-2", after: cursor)
        app.revealReelPlayerChrome()
        XCTAssertTrue(app.buttons["playerEpisodes"].isHittable)
    }

    func testEpisodePickerLoadingEmptyErrorsAndRecovery() async throws {
        try await launch(episode: true, options: false)
        _ = try await request("/qa/episode-control", body: ["seasonsFail": true])
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.buttons["playerSeasonsErrorRetry"])
        snapshot("player-seasons-error")
        _ = try await request("/qa/episode-control", body: ["seasonsFail": false])
        app.buttons["playerSeasonsErrorRetry"].tap()
        try await visible(app.buttons["playerSeasonPicker"])
        _ = try await request("/qa/episode-control", body: ["episodesFail": true])
        app.buttons["playerSeasonPicker"].tap(); try await tap(app.buttons["Season 2"])
        try await visible(app.buttons["playerEpisodesErrorRetry"])
        snapshot("player-episodes-error")
        _ = try await request("/qa/episode-control", body: ["episodesFail": false])
        app.buttons["playerEpisodesErrorRetry"].tap()
        try await visible(app.buttons["playerEpisode-episode-2-2"])
        _ = try await request("/qa/episode-control", body: ["episodesEmpty": true])
        app.buttons["playerSeasonPicker"].tap(); try await tap(app.buttons["Season 1"])
        try await visible(app.descendants(matching: .any)["playerEpisodesEmpty"])
        snapshot("player-episodes-empty")
        _ = try await request("/qa/episode-control", body: ["episodesEmpty": false, "episodesDelay": true])
        app.buttons["playerSeasonPicker"].tap(); try await tap(app.buttons["Season 2"])
        XCTAssertTrue(app.activityIndicators["playerEpisodesLoading"].exists || app.descendants(matching: .any)["playerEpisodesLoading"].exists)
        snapshot("player-episodes-loading")
        app.buttons["closePlayerEpisodes"].tap()
        _ = try await request("/qa/episode-control", body: ["episodesDelay": false, "seasonsEmpty": true])
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.descendants(matching: .any)["playerSeasonsEmpty"])
        snapshot("player-seasons-empty")
        app.buttons["closePlayerEpisodes"].tap()
        _ = try await request("/qa/episode-control", body: ["seasonsEmpty": false])
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.buttons["playerEpisode-episode-1-1"])
        snapshot("player-episodes-recovered")
    }

    func testEpisodeBrowserKeepsVideoAdvancingWithoutANewSession() async throws {
        try await launch(episode: true, options: false)
        let cursor = try await reports().count
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.buttons["playerSeasonPicker"])
        try await Task.sleep(for: .seconds(11))
        let recent = try await reports().dropFirst(cursor)
        XCTAssertTrue(recent.contains { report in
            let body = report["body"] as? [String: Any]
            return report["path"] as? String == "/Sessions/Playing/Progress" && body?["IsPaused"] as? Bool == false
                && ((body?["PositionTicks"] as? NSNumber)?.int64Value ?? 0) >= 80_000_000
        })
        XCTAssertFalse(recent.contains { ["/Sessions/Playing", "/Sessions/Playing/Stopped"].contains($0["path"] as? String ?? "") })
        snapshot("player-episode-browser-advancing-video")
        app.buttons["closePlayerEpisodes"].tap()
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["transportPlayPause"])
        XCTAssertEqual(app.buttons["transportPlayPause"].label, "Pause")
        app.buttons["transportPlayPause"].tap()
    }

    func testBackgroundAndEpisodeBrowserPauseAutomaticNext() async throws {
        try await launch(episode: true)
        try await playEpisodeToEnd()
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 10))
        let cursor = try await reports().count
        XCUIDevice.shared.press(.home)
        try await Task.sleep(for: .seconds(11))
        let backgroundReports = try await reports().dropFirst(cursor)
        XCTAssertFalse(backgroundReports.contains { $0["path"] as? String == "/Sessions/Playing" })
        app.activate()
        app.revealReelPlayerChrome(); try await tap(app.buttons["playerEpisodes"])
        try await visible(app.buttons["playerSeasonPicker"])
        try await Task.sleep(for: .seconds(11))
        let browserReports = try await reports().dropFirst(cursor)
        XCTAssertFalse(browserReports.contains { $0["path"] as? String == "/Sessions/Playing" })
        snapshot("player-ended-episode-browser-keeps-countdown-paused")
        app.buttons["closePlayerEpisodes"].tap()
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 4))
        app.buttons["cancelNextEpisode"].tap()
        XCTAssertTrue(app.buttons["playNext"].exists)
    }

    func testMissingSeasonIndexUsesFirstAvailableSeason() async throws {
        try await launch(episode: true, options: false, missingSeasonIndex: true)
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.buttons["playerSeasonPicker"])
        XCTAssertEqual(app.buttons["playerSeasonPicker"].value as? String, "Season 1")
        try await visible(app.buttons["playerEpisode-episode-1-1"])
        XCTAssertFalse(app.buttons["playerEpisode-episode-1-1"].isEnabled)
        snapshot("player-missing-season-index-fallback")
        app.buttons["closePlayerEpisodes"].tap()
        _ = try await request("/qa/episode-control", body: ["missingSeasonIndex": false])
    }

    func testEmptySeriesMetadataExplainsUnavailablePicker() async throws {
        try await launch(episode: true, options: false, emptySeriesMetadata: true)
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        try await visible(app.staticTexts["Season information isn’t available for this video."])
        XCTAssertFalse(app.buttons["playerSeasonPicker"].exists)
        snapshot("player-episode-unavailable-metadata")
        try await tap(app.buttons["playerSeasonsErrorRetry"])
        try await visible(app.staticTexts["Season information isn’t available for this video."])
        app.buttons["closePlayerEpisodes"].tap()
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists)
        _ = try await request("/qa/episode-control", body: ["emptySeriesMetadata": false])
    }

    func testDelayedSeasonReplacementAndMissingArtworkKeepSelectionSafe() async throws {
        try await launch(episode: true)
        try await tap(app.buttons["sleepTimer"]); try await tap(app.buttons["15 minutes"])
        app.navigationBars["Playback options"].buttons["Done"].tap()
        _ = try await request("/qa/episode-control", body: ["seasonsDelay": true, "missingEpisodeArtwork": true])
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        XCTAssertTrue(app.descendants(matching: .any)["playerSeasonsLoading"].waitForExistence(timeout: 4))
        XCTAssertFalse(app.buttons["playerEpisode-episode-1-1"].exists)
        snapshot("player-seasons-loading")
        _ = try await request("/qa/episode-control", body: ["seasonsDelay": false])
        try await visible(app.buttons["playerSeasonPicker"])
        XCTAssertEqual(app.buttons["playerSeasonPicker"].value as? String, "Season 1")
        let current = app.buttons["playerEpisode-episode-1-1"]
        try await visible(current)
        XCTAssertFalse(current.isEnabled)
        XCTAssertEqual(current.value as? String, "Playing")
        XCTAssertTrue(current.label.contains("A new beginning"))
        _ = try await request("/qa/episode-control", body: ["episodesDelay": true])
        app.buttons["playerSeasonPicker"].tap(); try await tap(app.buttons["Season 2"])
        XCTAssertTrue(app.descendants(matching: .any)["playerEpisodesLoading"].exists)
        XCTAssertFalse(current.exists)
        app.buttons["playerSeasonPicker"].tap(); try await tap(app.buttons["Season 1"])
        _ = try await request("/qa/episode-control", body: ["episodesDelay": false])
        try await visible(app.buttons["playerEpisode-episode-1-3"])
        XCTAssertFalse(app.buttons["playerEpisode-episode-2-1"].exists)
        snapshot("player-episode-artwork-fallback-and-current-season")
        app.buttons["closePlayerEpisodes"].tap()
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["transportPlayPause"])
        XCTAssertEqual(app.buttons["transportPlayPause"].label, "Play")
        try await visible(app.buttons["sleepTimer"])
        XCTAssertTrue(app.buttons["sleepTimer"].label.contains("Timer on"))
        app.navigationBars["Playback options"].buttons["Done"].tap()
        app.revealReelPlayerChrome(); app.buttons["playerEpisodes"].tap()
        let cursor = try await reports().count
        try await tap(app.buttons["playerEpisode-episode-1-3"])
        try await waitEpisode("episode-1-3", after: cursor, startsAtBeginning: true)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["nextEpisode"])
        let nextCursor = try await reports().count
        app.buttons["nextEpisode"].tap()
        try await waitEpisode("episode-2-1", after: nextCursor, startsAtBeginning: true)
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.buttons["previousEpisode"])
        let previousCursor = try await reports().count
        app.buttons["previousEpisode"].tap()
        try await waitEpisode("episode-1-3", after: previousCursor, startsAtBeginning: true)
        _ = try await request("/qa/episode-control", body: ["missingEpisodeArtwork": false])
    }

    func testAutoplayPreferencePersistsAcrossRelaunchAndPreventsNext() async throws {
        try await launch(episode: true)
        try await setAutoplay(false)
        let cursor = try await reports().count
        try await playEpisodeToEnd()
        XCTAssertTrue(app.buttons["playNext"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["nextEpisodeCountdown"].exists)
        try await Task.sleep(for: .seconds(11))
        let recent = try await reports().dropFirst(cursor)
        XCTAssertFalse(recent.contains { $0["path"] as? String == "/Sessions/Playing" })
        app.terminate(); app.launchArguments.removeAll { $0 == "-reel-qa-reset" }; app.launch()
        try await tap(app.buttons["home-Series"]); try await tap(app.buttons["heroDetails"])
        try await tap(app.buttons["episodePlay-episode-1-1"])
        app.revealReelPlayerChrome(); app.buttons["playbackOptions"].tap()
        try await visible(app.switches["autoplayNextEpisode"])
        let control = app.switches["autoplayNextEpisode"]
        XCTAssertEqual(control.value as? String, "0")
        snapshot("player-autoplay-off-persisted")
        try await setAutoplay(true)
    }

    func testReplayCancelsPendingAutomaticNext() async throws {
        try await launch(episode: true)
        try await playEpisodeToEnd()
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 10))
        let cursor = try await reports().count
        snapshot("player-before-replay")
        app.buttons["replayPlayer"].tap()
        try await Task.sleep(for: .seconds(2))
        snapshot("player-after-replay")
        try await waitEpisode("episode-1-1", after: cursor)
        try await Task.sleep(for: .seconds(11))
        let recent = try await reports().dropFirst(cursor)
        XCTAssertFalse(recent.contains { report in
            report["path"] as? String == "/Sessions/Playing" && (report["body"] as? [String: Any])?["ItemId"] as? String == "episode-1-2"
        })
    }

    private func setAutoplay(_ enabled: Bool) async throws {
        let control = app.switches["autoplayNextEpisode"]
        try await visible(control)
        let expected = enabled ? "1" : "0"
        if control.value as? String != expected {
            let nested = control.switches.firstMatch
            if nested.exists { nested.tap() } else { control.tap() }
            let changed = expectation(for: NSPredicate(format: "value == %@", expected), evaluatedWith: control)
            await fulfillment(of: [changed], timeout: 4)
        }
    }

    private func playEpisodeToEnd() async throws {
        try await visible(app.buttons["transportPlayPause"])
        if app.buttons["transportPlayPause"].label == "Play" { app.buttons["transportPlayPause"].tap() }
        app.navigationBars["Playback options"].buttons["Done"].tap()
        // Let this owned24-second video reach genuine EOF; a synthetic seek is
        // unnecessary for episode-ending checks and obscures their actual trigger.
        XCTAssertTrue(app.buttons["replayPlayer"].waitForExistence(timeout: 32))
    }
    private func waitPosition(_ seconds: ClosedRange<Double>, after cursor: Int) async throws {
        let deadline = Date().addingTimeInterval(6)
        repeat {
            let reached = try await reports().dropFirst(cursor).contains { report in
                guard report["path"] as? String == "/Sessions/Playing/Progress",
                      let body = report["body"] as? [String: Any], let ticks = body["PositionTicks"] as? NSNumber else { return false }
                return seconds.contains(ticks.doubleValue / 10_000_000)
            }
            if reached { return }; try await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        snapshot("player-position-did-not-change")
        XCTFail("Native playback did not reach \(seconds) after a user control interaction.")
    }

    private func waitEpisode(_ itemID: String, after cursor: Int, startsAtBeginning: Bool = false) async throws {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            if let report = try await reports().dropFirst(cursor).first(where: { report in
                report["path"] as? String == "/Sessions/Playing" && (report["body"] as? [String: Any])?["ItemId"] as? String == itemID
            }) {
                if startsAtBeginning {
                    let ticks = try XCTUnwrap((report["body"] as? [String: Any])?["PositionTicks"] as? NSNumber)
                    XCTAssertLessThan(ticks.int64Value, 10_000_000)
                }
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        snapshot("episode-start-missing")
        XCTFail("Selected episode did not begin: \(itemID)")
        throw NSError(domain: "ReelPlayerUI", code: 3)
    }

    private func visible(_ element: XCUIElement, timeout: TimeInterval = 12) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            let passwordPrompt = app.sheets["Save Password?"]
            if passwordPrompt.exists {
                if passwordPrompt.buttons["Not Now"].isHittable { passwordPrompt.buttons["Not Now"].tap() }
                else { passwordPrompt.swipeUp(); try await Task.sleep(for: .milliseconds(150)); continue }
            }
            let window = app.windows.allElementsBoundByIndex.map(\.frame).first { $0.width > 0 && $0.height > 0 } ?? .zero
            let home = app.scrollViews["homeScroll"]
            let refresh = app.buttons["homeRefresh"]
            // The accessibility-size refresh action is a pinned inset. A control
            // underneath it can be reported hittable even though Refresh receives the tap.
            let homeVisible = home.exists && home.isHittable
            let contentTop = homeVisible && element.identifier != "homeRefresh" && refresh.exists
                && refresh.frame.intersects(window) ? max(window.minY, refresh.frame.maxY) : window.minY
            let tabs = app.tabBars.firstMatch
            let contentBottom = homeVisible && tabs.exists ? min(window.maxY, tabs.frame.minY) : window.maxY
            let visibleBounds = CGRect(x: window.minX, y: contentTop, width: window.width,
                                       height: max(0, contentBottom - contentTop))
            if element.exists && element.isHittable,
               element.frame.height > visibleBounds.height || visibleBounds.insetBy(dx: -1, dy: -1).contains(element.frame) { return }
            if app.navigationBars["Playback options"].exists {
                let scroll = app.scrollViews["playerOptionsScroll"]
                if scroll.exists {
                    if window.height > window.width {
                        if element.exists && element.frame.maxY < scroll.frame.minY + 100 { scroll.swipeDown() }
                        else { scroll.swipeUp() }
                        try await Task.sleep(for: .milliseconds(150))
                        continue
                    }
                    let bounds = scroll.frame.intersection(window).insetBy(dx: 6, dy: 16)
                    let distance = element.exists ? min(140, max(-140, element.frame.midY - bounds.midY)) : 140
                    let origin = app.coordinate(withNormalizedOffset: .zero)
                    let start = origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.midY))
                    let target = origin.withOffset(CGVector(dx: bounds.midX, dy: min(bounds.maxY, max(bounds.minY, bounds.midY - distance))))
                    start.press(forDuration: 0.08, thenDragTo: target)
                } else { app.swipeUp() }
            }
            else if !app.keyboards.firstMatch.exists {
                if home.exists {
                    if element.identifier.hasPrefix("home-"), element.exists,
                       element.frame.maxX > window.maxX || element.frame.minX < window.minX,
                       let categories = app.scrollViews.containing(.button, identifier: element.identifier).allElementsBoundByIndex
                            .filter({ $0.frame.height < window.height / 2 }).min(by: { $0.frame.height < $1.frame.height }) {
                        if element.frame.maxX > window.maxX { categories.swipeLeft() } else { categories.swipeRight() }
                    } else if element.exists {
                        let bounds = visibleBounds.insetBy(dx: 8, dy: 16)
                        let distance = min(160, max(-160, element.frame.midY - bounds.midY))
                        let origin = app.coordinate(withNormalizedOffset: .zero)
                        let start = origin.withOffset(CGVector(dx: bounds.midX, dy: bounds.midY))
                        let target = origin.withOffset(CGVector(dx: bounds.midX, dy: min(bounds.maxY, max(bounds.minY, bounds.midY - distance))))
                        start.press(forDuration: 0.08, thenDragTo: target)
                    } else { home.swipeUp() }
                } else if element.exists && element.frame.maxY < 120 { app.swipeDown() }
                else { app.swipeUp() }
            }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        snapshot("missing-control")
        XCTFail("Control not reachable: \(element.identifier) \(element.label)\n\(app.debugDescription)")
        throw NSError(domain: "ReelPlayerUI", code: 1)
    }
    private func tap(_ element: XCUIElement) async throws { try await visible(element); element.tap() }
    private func snapshot(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    private func request(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue(owner, forHTTPHeaderField: "X-Reel-TV-Owner")
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        if data.isEmpty { return [:] }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func reports() async throws -> [[String: Any]] {
        let state = try await request("/qa/state")
        return try XCTUnwrap(state["reports"] as? [[String: Any]]).filter { $0["user"] as? String == user }
    }
    private func waitStart(after cursor: Int, source: String? = nil, audio: Int? = nil, subtitle: Int? = nil) async throws {
        let deadline = Date().addingTimeInterval(30)
        repeat {
            let recent = Array(try await reports().dropFirst(cursor))
            let starts = Set(recent.filter { $0["path"] as? String == "/Sessions/Playing" }.compactMap {
                ($0["body"] as? [String: Any])?["PlaySessionId"] as? String
            })
            for report in recent where ["/Sessions/Playing", "/Sessions/Playing/Progress"].contains(report["path"] as? String ?? "") {
                guard let body = report["body"] as? [String: Any],
                      let sessionID = body["PlaySessionId"] as? String, starts.contains(sessionID) else { continue }
                if let source, body["MediaSourceId"] as? String != source { continue }
                if let audio, body["AudioStreamIndex"] as? Int != audio { continue }
                if let subtitle, body["SubtitleStreamIndex"] as? Int != subtitle { continue }
                return
            }
            try await Task.sleep(for: .milliseconds(150))
        } while Date() < deadline
        snapshot("missing-stream-start")
        XCTFail("No new native session matched the selected stream choices"); throw NSError(domain: "ReelPlayerUI", code: 2)
    }
}
