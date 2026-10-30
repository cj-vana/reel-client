import XCTest

@MainActor final class TVEpisodePlayerJourneys: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:18967")!
    private enum Failure: Error { case control, focus, playback }

    private func launch(_ user: String, autoplay: Bool = false, initialControl: [String: Bool] = [:], itemID: String = "episode-1-1") async throws -> XCUIApplication {
        guard ProcessInfo.processInfo.environment["REEL_TV_EPISODE_JOURNEYS"] == "1" else {
            throw XCTSkip("Requires the owned silent episode fixture on 18967; no other lane's fixture may be reset.")
        }
        try TVFixtureOwnership.requireHost()
        _ = try await fixture("reset", body: [:])
        if !initialControl.isEmpty { _ = try await fixture("tv-control", body: initialControl) }
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        addTeardownBlock { @MainActor in app.terminate() }
        app.launchArguments = ["-reel-qa-reset", "-privateViewing", "NO", "-streamQuality", "0", "-autoplayNextEpisode", autoplay ? "YES" : "NO"]
        app.launch()
        for (field, value) in [(app.textFields["server"], base.absoluteString), (app.textFields["username"], user), (app.secureTextFields["password"], "demo")] {
            try select(field, app: app); field.typeText(value); XCUIRemote.shared.press(.menu)
        }
        try select(app.buttons["connect"], app: app)
        if user == "tv-episode-controls" {
            XCTAssertTrue(app.buttons["item-episode-1-1"].firstMatch.waitForExistence(timeout: 12))
            capture("Native TV Home before player", app: app)
        }
        try select(app.buttons["item-" + itemID].firstMatch, app: app)
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 12))
        if user == "tv-episode-controls" { capture("Native TV episode detail before player", app: app) }
        try select(app.buttons["startOver"].exists ? app.buttons["startOver"] : app.buttons["detailPlay"], app: app)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 15))
        return app
    }

    func testRemoteSeasonSelectionPreviousNextAndCrossSeasonBoundary() async throws {
        let app = try await launch("tv-episode-controls")
        defer { app.terminate() }
        XCTAssertTrue(app.cells["Previous episode"].exists)
        try choose("Episodes", app: app)
        XCTAssertTrue(app.buttons["closeEpisodeBrowser"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playerEpisode-episode-1-1"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["playerEpisode-episode-1-1"].isEnabled)
        capture("Native TV episode browser artwork and metadata", app: app)
        try select(app.segmentedControls["playerSeason"].buttons["Season 2"], app: app)
        try select(app.buttons["playerEpisode-episode-2-1"], app: app)
        try await started("episode-2-1")
        try choose("Next episode", app: app); try await started("episode-2-2")
        try choose("Previous episode", app: app); try await started("episode-2-1", count: 2)
        try choose("Previous episode", app: app); try await started("episode-1-3")
        try choose("Next episode", app: app); try await started("episode-2-1", count: 3)
        capture("Native TV episode transport and cross-season replacement", app: app)
    }

    func testRemoteMetadataIntroSkipChangesActualTimeline() async throws {
        let app = try await launch("tv-episode-intro")
        defer { app.terminate() }
        capture("Available native Skip intro", app: app)
        XCUIRemote.shared.press(.select)
        var seeked = false
        for _ in 0..<30 {
            let rows = try await reports()
            seeked = rows.contains { $0["path"] as? String == "/Sessions/Playing/Progress" && (((($0["body"] as? [String: Any])?["PositionTicks"] as? NSNumber)?.int64Value) ?? 0) >= 100_000_000 }
            if seeked { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(seeked, "The actual native Skip intro action must seek to metadata EndTicks")
        XCTAssertFalse(app.cells["Skip intro"].exists)
        capture("Native metadata-backed Intro skip", app: app)
    }

    func testRemotePausedTransportIntroActionPreservesPause() async throws {
        let app = try await launch("tv-intro-transport")
        defer { app.terminate() }
        XCUIRemote.shared.press(.playPause)
        try select(app.cells["Skip intro"], app: app)
        var seek: [String: Any]?
        for _ in 0..<30 {
            seek = try await reports().compactMap { $0["body"] as? [String: Any] }.last { (($0["PositionTicks"] as? NSNumber)?.int64Value ?? 0) >= 100_000_000 }
            if seek != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(seek)
        XCTAssertEqual(seek?["IsPaused"] as? Bool, true)
        let beforeSubtitle = try await reports().count
        try choose("Subtitles", app: app)
        try choose("Off", app: app)
        var restored: [String: Any]?
        for _ in 0..<60 {
            let fresh = try await reports().dropFirst(beforeSubtitle)
            restored = fresh.filter { $0["path"] as? String == "/Sessions/Playing/Progress" }.compactMap { $0["body"] as? [String: Any] }.last { (($0["PositionTicks"] as? NSNumber)?.int64Value ?? 0) >= 100_000_000 }
            if restored != nil { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotNil(restored, "Subtitle Off must restore the existing nonzero native position")
        XCTAssertEqual(restored?["IsPaused"] as? Bool, true)
        let negotiations = try await reports().filter { $0["path"] as? String == "/Items/episode-1-1/PlaybackInfo" }
        XCTAssertGreaterThanOrEqual(((negotiations.last?["body"] as? [String: Any])?["StartTimeTicks"] as? NSNumber)?.int64Value ?? 0, 100_000_000)
        capture("Native transport intro skip preserves pause", app: app)
    }

    func testRemoteNearbyRetryAndMissingArtworkFallback() async throws {
        let app = try await launch("tv-episode-nearby", initialControl: ["failAdjacent": true, "noArtwork": true])
        defer { app.terminate() }
        try choose("Episodes", app: app)
        XCTAssertTrue(app.buttons["retryNearbyEpisodes"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playerEpisode-episode-1-2"].waitForExistence(timeout: 10))
        capture("Episode browser missing-artwork fallback and nearby recovery", app: app)
        _ = try await fixture("tv-control", body: ["failAdjacent": false])
        try select(app.buttons["retryNearbyEpisodes"], app: app)
        for _ in 0..<20 {
            if !app.buttons["retryNearbyEpisodes"].exists { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(app.buttons["retryNearbyEpisodes"].exists)
        try select(app.buttons["closeEpisodeBrowser"], app: app)
        try choose("Next episode", app: app)
        try await started("episode-1-2")
    }

    func testRemoteNearbyAndEpisodeListLoadingStates() async throws {
        let app = try await launch("tv-episode-delays", initialControl: ["noIntro": true, "slowAdjacent": true, "slowEpisodes": true])
        defer { app.terminate() }
        try choose("Episodes", app: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Finding nearby episodes")).firstMatch.waitForExistence(timeout: 5))
        capture("Nearby episode loading state", app: app)
        XCTAssertTrue(app.buttons["playerEpisode-episode-1-2"].waitForExistence(timeout: 15))
        try select(app.segmentedControls["playerSeason"].buttons["Season 2"], app: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", "Loading episodes")).firstMatch.waitForExistence(timeout: 5))
        capture("Episode list loading after season selection", app: app)
        XCTAssertTrue(app.buttons["playerEpisode-episode-2-1"].waitForExistence(timeout: 15))
        try select(app.buttons["closeEpisodeBrowser"], app: app)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 10))
    }

    func testRemoteEOFCancelPlayNowAndAutomaticNext() async throws {
        let app = try await launch("tv-episode-autoplay", autoplay: true)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 35))
        try select(app.buttons["cancelNextEpisode"], app: app)
        try await Task.sleep(for: .seconds(11))
        let cancelledStarts = try await starts("episode-1-2")
        XCTAssertEqual(cancelledStarts, 0)
        XCTAssertTrue(app.buttons["playNextEpisode"].exists)
        try select(app.buttons["playNextEpisode"], app: app)
        try await started("episode-1-2")
        XCTAssertTrue(app.staticTexts["nextEpisodeCountdown"].waitForExistence(timeout: 35))
        try await started("episode-1-3", timeout: 15)
        capture("Native TV automatic next after cancellable countdown", app: app)
    }

    func testRemoteBrowserReturnsToPlaybackAndDisablesAutoplay() async throws {
        let app = try await launch("tv-episode-preference", autoplay: true)
        defer { app.terminate() }
        try choose("Episodes", app: app)
        try select(app.switches["autoplayNextEpisode"], app: app)
        try select(app.buttons["closeEpisodeBrowser"], app: app)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["playNextEpisode"].waitForExistence(timeout: 35))
        XCTAssertFalse(app.buttons["cancelNextEpisode"].exists)
        try await Task.sleep(for: .seconds(11))
        let disabledStarts = try await starts("episode-1-2")
        XCTAssertEqual(disabledStarts, 0)
        capture("Autoplay disabled and manual next retained", app: app)
        app.terminate()
        app.launchArguments = ["-privateViewing", "NO", "-streamQuality", "0"]
        app.launch()
        try select(app.buttons["item-episode-1-1"].firstMatch, app: app)
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 12))
        try select(app.buttons["startOver"].exists ? app.buttons["startOver"] : app.buttons["detailPlay"], app: app)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 15))
        try choose("Episodes", app: app)
        XCTAssertTrue(app.switches["autoplayNextEpisode"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.switches["autoplayNextEpisode"].value as? String, "0")
        capture("Autoplay choice survives normal relaunch", app: app)
    }

    func testRemoteBrowserErrorRetryAndEmptySeasonStates() async throws {
        let app = try await launch("tv-episode-recovery")
        defer { app.terminate() }
        _ = try await fixture("tv-control", body: ["failSeasons": true])
        try choose("Episodes", app: app)
        XCTAssertTrue(app.buttons["retryPlayerSeasons"].waitForExistence(timeout: 10))
        _ = try await fixture("tv-control", body: ["failSeasons": false, "emptySeasons": true])
        try select(app.buttons["retryPlayerSeasons"], app: app)
        XCTAssertTrue(app.staticTexts["emptyPlayerSeasons"].waitForExistence(timeout: 10))
        try select(app.buttons["closeEpisodeBrowser"], app: app)
        _ = try await fixture("tv-control", body: ["emptySeasons": false])
        try choose("Episodes", app: app)
        XCTAssertTrue(app.buttons["playerEpisode-episode-1-2"].waitForExistence(timeout: 10))
        _ = try await fixture("tv-control", body: ["emptyEpisodes": true])
        try select(app.segmentedControls["playerSeason"].buttons["Season 2"], app: app)
        XCTAssertTrue(app.staticTexts["emptyPlayerEpisodes"].waitForExistence(timeout: 10))
        _ = try await fixture("tv-control", body: ["emptyEpisodes": false, "failEpisodes": true])
        try select(app.segmentedControls["playerSeason"].buttons["Season 1"], app: app)
        XCTAssertTrue(app.buttons["retryPlayerEpisodes"].waitForExistence(timeout: 10))
        _ = try await fixture("tv-control", body: ["failEpisodes": false])
        try select(app.buttons["retryPlayerEpisodes"], app: app)
        XCTAssertTrue(app.buttons["playerEpisode-episode-1-2"].waitForExistence(timeout: 10))
        try select(app.buttons["closeEpisodeBrowser"], app: app)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 10))
        capture("Episode browser recovered without losing playback", app: app)
    }

    func testRemoteReopenedSlowBrowserKeepsLoadingUntilItsOwnRequestCompletes() async throws {
        let app = try await launch("tv-episode-loading")
        defer { app.terminate() }
        _ = try await fixture("tv-control", body: ["slowSeasons": true])
        try choose("Episodes", app: app)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "episodeBrowserLoading").firstMatch.waitForExistence(timeout: 5))
        XCUIRemote.shared.press(.menu)
        try choose("Episodes", app: app)
        for _ in 0..<10 {
            XCTAssertFalse(app.staticTexts["emptyPlayerSeasons"].exists)
            try await Task.sleep(for: .milliseconds(200))
        }
        XCTAssertTrue(app.buttons["playerEpisode-episode-1-2"].waitForExistence(timeout: 12))
        capture("Reopened season request retains loading ownership", app: app)
    }

    func testRemoteMissingAndInvalidIntroMetadataNeverOffersSkip() async throws {
        for mode in ["noIntro", "badIntro"] {
            let app = try await launch("tv-episode-" + mode, initialControl: [mode: true])
            XCUIRemote.shared.press(.menu)
            try await Task.sleep(for: .seconds(2))
            XCTAssertFalse(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Skip intro")).firstMatch.exists)
            capture("No fabricated intro action for " + mode, app: app)
            app.terminate()
        }
    }

    func testRemoteBackgroundAndCloseFencePendingAutomaticNext() async throws {
        let app = try await launch("tv-episode-background", autoplay: true)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 35))
        XCUIRemote.shared.press(.home)
        for _ in 0..<30 {
            if app.state != .runningForeground { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNotEqual(app.state, .runningForeground)
        try await Task.sleep(for: .seconds(11))
        let backgroundStarts = try await starts("episode-1-2")
        XCTAssertEqual(backgroundStarts, 0)
        app.activate()
        XCTAssertTrue(app.buttons["cancelNextEpisode"].waitForExistence(timeout: 8))
        try await Task.sleep(for: .seconds(2))
        let foregroundStarts = try await starts("episode-1-2")
        XCTAssertEqual(foregroundStarts, 0, "Returning to Reel must restart the visible countdown")
        try select(app.buttons["closePlayer"], app: app)
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 10))
        try await Task.sleep(for: .seconds(11))
        let closedStarts = try await starts("episode-1-2")
        XCTAssertEqual(closedStarts, 0)
        capture("Background and close preserve episode ownership", app: app)
    }

    func testRemoteFinaleReplayAndExistingNativeMenus() async throws {
        let app = try await launch("tv-episode-finale", autoplay: true)
        defer { app.terminate() }
        XCUIRemote.shared.press(.playPause)
        try choose("Speed", app: app)
        try choose("1.25×", app: app)
        try choose("Quality", app: app)
        try choose("Original / auto", app: app)
        try choose("Subtitles", app: app)
        try choose("Off", app: app)
        try choose("Episodes", app: app)
        try select(app.segmentedControls["playerSeason"].buttons["Season 2"], app: app)
        try select(app.buttons["playerEpisode-episode-2-3"], app: app)
        try await started("episode-2-3")
        XCTAssertTrue(app.cells["Next episode"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["replay"].waitForExistence(timeout: 35))
        XCTAssertFalse(app.buttons["cancelNextEpisode"].exists)
        XCTAssertFalse(app.buttons["playNextEpisode"].exists)
        try select(app.buttons["replay"], app: app)
        try await started("episode-2-3", count: 2)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 10))
        capture("Series finale replays with native controls", app: app)
    }

    func testRemoteMovieEOFReplayHasNoEpisodeActions() async throws {
        let app = try await launch("tv-movie-replay", autoplay: true, itemID: "movie-1")
        defer { app.terminate() }
        XCTAssertFalse(app.cells["Episodes"].exists)
        XCTAssertFalse(app.cells["Next episode"].exists)
        XCTAssertTrue(app.buttons["replay"].waitForExistence(timeout: 35))
        XCTAssertFalse(app.buttons["playNextEpisode"].exists)
        XCTAssertFalse(app.buttons["cancelNextEpisode"].exists)
        try select(app.buttons["replay"], app: app)
        try await started("movie-1", count: 2)
        XCTAssertTrue(app.cells["Quality"].waitForExistence(timeout: 10))
        capture("Movie replay keeps native playback without episode actions", app: app)
    }

    private func fixture(_ action: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = try await TVFixtureOwnership.request(base.appendingPathComponent("qa/" + action))
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.control }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func reports() async throws -> [[String: Any]] { try await fixture("state")["reports"] as? [[String: Any]] ?? [] }
    private func starts(_ id: String) async throws -> Int { try await reports().filter { $0["path"] as? String == "/Items/\(id)/PlaybackInfo" }.count }
    private func started(_ id: String, count: Int = 1, timeout: Int = 10) async throws {
        for _ in 0..<(timeout * 10) {
            if try await starts(id) >= count { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Expected a fresh playback negotiation for \(id)")
        throw Failure.playback
    }

    private func choose(_ title: String, app: XCUIApplication) throws {
        let cell = app.cells.matching(NSPredicate(format: "label == %@ OR label == %@", title, "selected, " + title)).firstMatch
        try select(cell.exists ? cell : app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch, app: app)
    }

    private func select(_ element: XCUIElement, app: XCUIApplication) throws {
        guard element.waitForExistence(timeout: 12) else { capture("Missing requested control", app: app); throw Failure.control }
        var previous = "", stationary = 0
        for _ in 0..<50 {
            if element.hasFocus { XCUIRemote.shared.press(.select); return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            guard focused.exists else { XCUIRemote.shared.press(element.elementType == .cell ? .up : .down); continue }
            let target = element.frame, frame = focused.frame
            if element.elementType == .cell && frame.height >= app.frame.height * 0.8 { XCUIRemote.shared.press(.up); continue }
            let wrapsOneControl = frame.width <= max(target.width * 1.2, target.width + 20) && frame.height <= max(target.height * 1.2, target.height + 20)
            let compactWrapper = frame.height <= 180 && frame.width <= app.frame.width * 0.8
            if element.isHittable, !target.isEmpty, frame.insetBy(dx: -2, dy: -2).contains(target), compactWrapper || wrapsOneControl {
                XCUIRemote.shared.press(.select); return
            }
            let x = target.midX - frame.midX, y = target.midY - frame.midY
            let identity = focused.identifier + focused.label + frame.debugDescription
            stationary = identity == previous ? stationary + 1 : 0
            previous = identity
            if stationary >= 2, abs(x) > 30 {
                XCUIRemote.shared.press(x > 0 ? .right : .left); stationary = 0
            } else { XCUIRemote.shared.press(abs(y) > 30 ? (y > 0 ? .down : .up) : (x > 0 ? .right : .left)) }
        }
        capture("Unreachable control " + element.identifier, app: app)
        throw Failure.focus
    }

    private func capture(_ name: String, app: XCUIApplication) {
        let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + " hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
}
