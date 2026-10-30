import XCTest
import CoreGraphics

@MainActor final class ReelUITests: XCTestCase {
    var app: XCUIApplication!
    override func setUp() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Fixture account-reset journeys run only on disposable simulators.")
        #endif
        try await super.setUp()
        await MainActor.run {
            continueAfterFailure = false
            app = XCUIApplication()
            app.launchArguments = ["-reel-qa-reset"]
            app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
            // A test that stops early can leave the simulator turned; every journey starts upright.
            XCUIDevice.shared.orientation = .portrait
            app.launch()
        }
    }
    private func tapConnectAfterLayoutSettles() {
        let connect = app.buttons["connect"]
        for attempt in 0...6 {
            var previousFrames: [CGRect] = []
            var stableSince = ProcessInfo.processInfo.systemUptime
            let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                guard connect.exists, connect.isEnabled else { return false }
                let window = self.app.windows.firstMatch.frame
                let inputs = self.app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex
                    .map(\.frame).filter { $0.height > 60 && $0.intersects(window) }
                let frames = [window, connect.frame] + inputs
                if frames != previousFrames {
                    previousFrames = frames
                    stableSince = ProcessInfo.processInfo.systemUptime
                    return false
                }
                return ProcessInfo.processInfo.systemUptime - stableSince >= 0.4
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                           "Connect and the software keyboard must finish moving before scrolling or tapping.\n\(app.debugDescription)")
            let window = app.windows.firstMatch.frame
            let inputs = app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex
                .map(\.frame).filter { $0.height > 60 && $0.intersects(window) }
            let bars = app.navigationBars.allElementsBoundByIndex.filter {
                $0.frame.intersects(window) && ($0.isHittable || $0.buttons.allElementsBoundByIndex.contains { $0.isHittable })
            }.map(\.frame)
            let frame = connect.frame
            let fullyVisible = frame.minX > window.minX + 8 && frame.maxX < window.maxX - 8
                && frame.minY > window.minY + 8 && frame.maxY < window.maxY - 24
                && inputs.allSatisfy { frame.maxY < $0.minY - 8 }
                && bars.allSatisfy { !frame.intersects($0) }
            if fullyVisible && connect.isHittable {
                connect.tap()
                return
            }
            if attempt == 6 { break }
            let owners = app.scrollViews.containing(.button, identifier: "connect").allElementsBoundByIndex
                .filter { $0.frame.intersects(window) }
            guard let scroll = owners.min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                XCTFail("Connect has no foreground owning scroll view.\n\(app.debugDescription)")
                return
            }
            let bounds = scroll.frame.intersection(window)
            let top = max(bounds.minY, bars.map(\.maxY).max() ?? bounds.minY) + 8
            let bottom = min(bounds.maxY - 24, inputs.map(\.minY).min() ?? bounds.maxY) - 8
            guard bottom - top > 80 else {
                XCTFail("Connect's owning scroll view has no usable area above the keyboard.\n\(app.debugDescription)")
                return
            }
            let x = bounds.minX + 18
            let upper = top + (bottom - top) * 0.3
            let lower = top + (bottom - top) * 0.85
            let origin = scroll.coordinate(withNormalizedOffset: .zero)
            let from = origin.withOffset(CGVector(dx: x - scroll.frame.minX, dy: (frame.minY < top ? upper : lower) - scroll.frame.minY))
            let to = origin.withOffset(CGVector(dx: x - scroll.frame.minX, dy: (frame.minY < top ? lower : upper) - scroll.frame.minY))
            from.press(forDuration: 0.1, thenDragTo: to)
        }
        screenshot("connect-not-reachable-after-foreground-scroll")
        XCTFail("The complete Connect button must be reachable above the keyboard before a native tap.\n\(app.debugDescription)")
    }

    private func login(_ username: String = "demo", password: String = "demo") {
        let field = app.textFields["username"]
        if !field.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap(); field.typeText(username)
        let pw = app.secureTextFields["password"]
        pw.tap(); pw.typeText(password)
        tapConnectAfterLayoutSettles()
        if password == "demo" { app.dismissReelPasswordPrompt(timeout: 8) }
    }
    private func home() { XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15)) }
    private func tab(_ name: String) {
        if app.navigationBars[name].exists { return }
        if ["Media", "Live TV", "Requests", "Devices", "Settings"].contains(name) {
            let more = app.buttons["ellipsis.circle"].firstMatch
            if !more.exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
            XCTAssertTrue(more.waitForExistence(timeout: 5), "Missing More tab")
            more.tap()
            if !app.navigationBars["More"].waitForExistence(timeout: 2) { more.tap() }
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5), "More did not return to its root")
            let destination = app.buttons[name].firstMatch
            for _ in 0..<6 { if destination.exists && destination.isHittable { break }; app.scrollViews.firstMatch.swipeUp() }
            XCTAssertTrue(destination.waitForExistence(timeout: 5), "Missing More destination: \(name)\n\(app.debugDescription)")
            destination.tap()
            return
        }
        let button = app.buttons[name].firstMatch
        if !button.exists, app.buttons["More"].exists { app.buttons["More"].tap() }
        if !button.exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        if !button.exists {
            let row = app.tables.cells.containing(.staticText, identifier: name).firstMatch
            if row.exists { row.tap(); return }
        }
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing tab: \(name)\n\(app.debugDescription)")
        button.tap()
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways
        add(attachment)
    }
    /// Library's category pills scroll sideways; an off-screen pill has no hit point yet. On a
    /// foldable's outer screen the status bar sits in a strip over the right edge, so a pill there
    /// is moved left too.
    private func revealPill(_ pill: XCUIElement) {
        XCTAssertTrue(pill.waitForExistence(timeout: 8))
        let window = app.windows.firstMatch.frame
        let clear = CGRect(x: window.minX, y: window.minY, width: window.width - 90, height: window.height)
        if !clear.contains(pill.frame) { app.buttons["filter-Series"].swipeLeft() }
    }
    private func reveal(_ element: XCUIElement, in scroll: XCUIElement? = nil) {
        for _ in 0..<12 {
            if element.isHittable { return }
            (scroll ?? app).swipeUp()
        }
        // The element can sit above the current position, as Details' actions do after Chapters.
        for _ in 0..<12 {
            if element.isHittable { return }
            (scroll ?? app).swipeDown()
        }
    }

    /// Details offers download quality in the Download menu.
    private func chooseDownload(_ identifier: String) {
        let menu = app.buttons["downloadMenu"]
        reveal(menu, in: app.scrollViews["detailScroll"])
        XCTAssertTrue(menu.isHittable, "The Download menu must be reachable on Details.")
        menu.tap()
        let choice = app.buttons[identifier]
        XCTAssertTrue(choice.waitForExistence(timeout: 5))
        choice.tap()
    }

    func testLoginFailureRecoveryAndRelaunchPersistence() {
        screenshot("01-connect-closed")
        login(password: "wrong")
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 8))
        let pw = app.secureTextFields["password"]
        pw.tap(); pw.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5)); pw.typeText("demo")
        tapConnectAfterLayoutSettles()
        app.dismissReelPasswordPrompt(timeout: 8)
        home(); screenshot("02-home-closed")
        app.terminate()
        app.launchArguments = []
        app.launch()
        home()
        XCTAssertFalse(app.textFields["username"].exists)
    }

    func testDetailsFavoritesSearchAndSeries() {
        login("favorites-\(UUID().uuidString)"); home()
        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
        let favorite = app.buttons["favorite"]
        XCTAssertTrue(favorite.waitForExistence(timeout: 8))
        if favorite.label == "Remove favorite" { favorite.tap() }
        favorite.tap()
        XCTAssertTrue(app.buttons["Remove favorite"].waitForExistence(timeout: 5))
        screenshot("03-film-detail")
        tab("Library")
        let favorites = app.buttons["filter-Favorites"]
        revealPill(favorites); favorites.tap()
        XCTAssertTrue(app.buttons["item-movie-1"].waitForExistence(timeout: 10))
        tab("Search")
        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.tap(); search.typeText("Out of the Blue")
        XCTAssertTrue(app.buttons["item-series-7"].waitForExistence(timeout: 10))
        app.buttons["item-series-7"].tap()
        reveal(app.buttons["episode-episode-1-1"], in: app.scrollViews["detailScroll"])
        XCTAssertTrue(app.buttons["episode-episode-1-1"].waitForExistence(timeout: 8))
        // On a phone, revealing the first episode can scroll the season chip up under the navigation bar.
        let seasonPicker = app.buttons["seasonPicker"], bar = app.navigationBars.firstMatch.frame
        for _ in 0..<3 where seasonPicker.frame.minY < bar.maxY { app.scrollViews["detailScroll"].swipeDown() }
        seasonPicker.tap()
        app.buttons["Season 2"].tap()
        XCTAssertTrue(app.buttons["episode-episode-2-1"].waitForExistence(timeout: 8))
        screenshot("04-series-and-seasons")
        app.buttons["episode-episode-2-1"].tap()
        reveal(app.buttons["detailPlay"], in: app.scrollViews["detailScroll"])
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 8))
        reveal(app.buttons["detailTracks"], in: app.scrollViews["detailScroll"])
        app.buttons["detailTracks"].tap()
        app.reelMenuItem("Audio").tap()
        app.buttons["English · AAC stereo"].tap()
        app.buttons["detailTracks"].tap()
        app.reelMenuItem("Subtitles").tap()
        app.buttons["Off"].tap()
        if !app.buttons["detailPlay"].isHittable { app.scrollViews["detailScroll"].swipeDown() }
        app.buttons["detailPlay"].tap()
        let transport = app.reelPlaybackButton("transportPlayPause")
        XCTAssertTrue(transport.waitForExistence(timeout: 12))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transport)
        waitForExpectations(timeout: 15)
        app.reelPlaybackButton("Forward 10 seconds").tap()
        app.prepareReelPlayerControl("closePlayer")
        XCTAssertTrue(app.buttons["playNext"].waitForExistence(timeout: 25), app.debugDescription)
        app.buttons["playNext"].tap()
        // The player's title names the next episode once it starts.
        XCTAssertTrue(app.buttons["playNext"].waitForNonExistence(timeout: 10))
        app.revealReelPlayerChrome()
        let nowPlaying = app.descendants(matching: .any)["playerTitle"]
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 10))
        XCTAssertTrue(nowPlaying.label.contains("Below the surface"), nowPlaying.label)
        app.reelPlaybackButton("closePlayer").tap()
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 8))
    }

    func testNativePlaybackPauseSeekCloseAndResume() {
        login("playback-\(UUID().uuidString)"); home()
        app.buttons["heroPlay"].tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 10))
        let transport = app.reelPlaybackButton("transportPlayPause")
        XCTAssertTrue(transport.waitForExistence(timeout: 15))
        let playable = NSPredicate(format: "enabled == true")
        expectation(for: playable, evaluatedWith: transport)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(transport.label, "Pause")
        transport.tap()
        XCTAssertEqual(transport.label, "Play")
        app.reelPlaybackButton("Forward 10 seconds").tap()
        transport.tap()
        app.prepareReelPlayerControl("closePlayer")
        screenshot("05-native-video")
        app.reelPlaybackButton("closePlayer").tap()
        home()
        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["detailPlay"].label.contains("Resume"))
    }

    func testFiltersPaginationQualityAndSignOut() {
        login("browse"); home()
        tab("Library")
        XCTAssertTrue(app.staticTexts["75 titles"].waitForExistence(timeout: 8))
        app.buttons["filter-Series"].tap()
        XCTAssertTrue(app.buttons["item-series-7"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["item-movie-2"].exists)
        app.buttons["filter-All"].tap()
        let more = app.buttons["loadMore"]
        for _ in 0..<24 {
            if more.isHittable { break }
            app.scrollViews["libraryScroll"].swipeUp(velocity: .fast)
        }
        XCTAssertTrue(more.isHittable)
        more.tap()
        screenshot("06-library-pagination")
        tab("Settings")
        app.buttons["qualityPicker"].tap()
        app.buttons["Data saver · 2 Mbps"].tap()
        screenshot("07-settings")
        reveal(app.buttons["signOut"])
        app.buttons["signOut"].tap()
        app.buttons["Sign out"].tap()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 8))
    }

    func testEmptyAndPermissionStates() {
        login("empty")
        XCTAssertTrue(app.staticTexts["A little quiet in here"].waitForExistence(timeout: 10))
        tab("Library")
        let favorites = app.buttons["filter-Favorites"]
        revealPill(favorites); favorites.tap()
        XCTAssertTrue(app.staticTexts["Keep the good ones close"].waitForExistence(timeout: 8), app.debugDescription)
        screenshot("08-empty-library")
        app.terminate(); app.launchArguments = ["-reel-qa-reset"]; app.launch()
        login("expired")
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 10))
        screenshot("09-expired-session")
        tab("Settings")
        reveal(app.buttons["signOut"])
        XCTAssertTrue(app.buttons["signOut"].exists)
    }

    func testServerErrorRecoveryAndMissingArtwork() {
        login("flaky")
        if app.buttons["retry"].waitForExistence(timeout: 5) { app.buttons["retry"].tap() }
        home()
        app.terminate(); app.launchArguments = ["-reel-qa-reset"]; app.launch()
        login("missingart"); home()
        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 8))
        screenshot("10-missing-artwork")
    }


    func testSavedServersAddSwitchCancelRemoveAndPersist() {
        login("server-one"); home()
        app.buttons["servers"].tap()
        app.buttons["addServer"].tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["server-server-one"].exists)
        app.buttons["addServer"].tap()
        let server = app.textFields["server"]
        server.tap(); server.press(forDuration: 1)
        if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
        else if app.menuItems["Select All"].exists { app.menuItems["Select All"].tap() }
        else { server.tap(withNumberOfTaps: 3, numberOfTouches: 1) }
        server.typeText("http://127.0.0.1:18767")
        XCTAssertEqual(server.value as? String, "http://127.0.0.1:18767")
        login("server-two")
        let connectionClosed = app.textFields["username"].waitForNonExistence(timeout: 15)
        let serverSheetClosed = app.navigationBars["Servers"].waitForNonExistence(timeout: 10)
        if !connectionClosed || !serverSheetClosed {
            screenshot("saved-server-connection-did-not-close")
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "saved-server-connection-foreground"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        }
        XCTAssertTrue(connectionClosed, "The new server must finish signing in before using Home")
        XCTAssertTrue(serverSheetClosed, "The old server sheet must disappear after the active account changes")
        home()
        XCTAssertTrue(app.buttons["servers"].isHittable, "The current Home server switcher must be reachable")
        app.buttons["servers"].tap()
        XCTAssertTrue(app.buttons["server-server-one"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["server-server-two"].waitForExistence(timeout: 5), app.debugDescription)
        app.buttons["serverOptions-server-two"].tap()
        app.buttons["Sign in again"].tap()
        XCTAssertEqual(app.textFields["server"].value as? String, "http://127.0.0.1:18767")
        XCTAssertEqual(app.textFields["username"].value as? String, "Alex")
        app.buttons["Cancel"].tap()
        app.buttons["server-server-one"].tap(); home()
        app.terminate(); app.launchArguments = []; app.launch(); home()
        app.buttons["servers"].tap()
        XCTAssertTrue(app.buttons["server-server-two"].exists)
        app.buttons["serverOptions-server-two"].tap()
        app.buttons["Remove from device"].tap()
        app.buttons.matching(identifier: "confirmRemoveServer").firstMatch.tap()
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["server-server-two"])
        waitForExpectations(timeout: 8)
        XCTAssertTrue(app.buttons["server-server-one"].exists)
        app.buttons["Done"].tap(); home()
    }

    /// Opening or closing a foldable iPhone changes the window's size class inside one scene.
    /// Turning a large iPhone does the same (compact in portrait, regular in landscape), so this
    /// checks that the change keeps the selected tab, the reader's place on Details, and the same
    /// play session.
    func testSizeClassChangeKeepsTabDetailsPlaceAndPlayback() async throws {
        let user = "fold-\(UUID().uuidString)"
        let window = app.windows.firstMatch
        XCUIDevice.shared.orientation = .portrait
        login(user); home()
        XCUIDevice.shared.orientation = .landscapeLeft
        try await Task.sleep(for: .seconds(2))
        let turnsRegular = window.horizontalSizeClass == .regular
        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(for: .seconds(2))
        guard turnsRegular, window.horizontalSizeClass == .compact else {
            throw XCTSkip("Needs a simulator whose window turns regular width in landscape, such as an iPhone Pro Max.")
        }

        tab("Library")
        XCTAssertTrue(app.scrollViews["libraryScroll"].waitForExistence(timeout: 10))
        XCUIDevice.shared.orientation = .landscapeLeft
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.scrollViews["libraryScroll"].exists, "The selected tab must survive the size class change.")
        XCUIDevice.shared.orientation = .portrait
        try await Task.sleep(for: .seconds(2))
        XCTAssertTrue(app.scrollViews["libraryScroll"].exists, "The selected tab must survive the size class change back.")

        tab("Home"); home()
        app.buttons["home-Series"].tap()
        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 10))
        // Read down the page past the header. The first episode or section at least half on
        // screen is the reader's place, and it must still be on screen after each change.
        XCTAssertTrue(app.staticTexts["Cast & crew"].waitForExistence(timeout: 10))
        let scroll = app.scrollViews["detailScroll"]
        scroll.swipeUp(velocity: .slow); scroll.swipeUp(velocity: .slow)
        try await Task.sleep(for: .seconds(2))
        func shownFraction(_ element: XCUIElement) -> CGFloat {
            let shown = window.frame.intersection(element.frame)
            return shown.isNull || element.frame.height == 0 ? 0 : shown.height / element.frame.height
        }
        let marks = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "episodePlay-")).allElementsBoundByIndex
            .map { app.buttons[$0.identifier] } + [app.staticTexts["Cast & crew"]]
        let place = try XCTUnwrap(marks.filter { shownFraction($0) >= 0.5 }.min { $0.frame.minY < $1.frame.minY },
                                  "An episode or the cast must be on screen after scrolling.")
        XCTAssertFalse(app.staticTexts["detailTitle"].isHittable && shownFraction(app.staticTexts["detailTitle"]) == 1,
                       "Scrolling must move past the header first.")
        let placeName = place.identifier.isEmpty ? place.label : place.identifier
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            try await Task.sleep(for: .seconds(3))
            XCTAssertTrue(app.staticTexts["detailTitle"].exists, "Details must stay open.")
            XCTAssertGreaterThan(shownFraction(place), 0.3, "Details must keep the reader's place, \(placeName): \(place.frame) in \(window.frame).")
        }

        // Playback: a movie, which has no automatic next episode, paused as soon as it starts so a
        // slow run can't reach the end of the short fixture clip during the changes.
        let back = app.buttons["BackButton"].firstMatch
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        home()
        app.buttons["home-Movies"].tap()
        app.buttons["heroPlay"].tap()
        let playPause = app.buttons["playerPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 15))
        var session: String?
        for _ in 0..<60 where session == nil {
            session = (try await playbackReports(user).last { $0["path"] as? String == "/Sessions/Playing" }?["body"] as? [String: Any])?["PlaySessionId"] as? String
            if session == nil { try await Task.sleep(for: .milliseconds(250)) }
        }
        let started = try XCTUnwrap(session, "Playback must start.")
        app.revealReelPlayerChrome()
        if playPause.label == "Pause" { playPause.tap() }
        let cursor = try await playbackReports(user).count
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            try await Task.sleep(for: .seconds(2))
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists,
                          "The player must stay open through the size class change.")
        }
        var after = Array(try await playbackReports(user).dropFirst(cursor))
        XCTAssertFalse(after.contains { $0["path"] as? String == "/Sessions/Playing" }, "A size class change must not start a new play session.")
        XCTAssertFalse(after.contains { ($0["path"] as? String)?.hasSuffix("/PlaybackInfo") == true }, "A size class change must not negotiate a new stream.")
        XCTAssertFalse(after.contains { $0["path"] as? String == "/Sessions/Playing/Stopped" }, "A size class change must not stop playback.")
        // The same session carries on when resumed.
        app.revealReelPlayerChrome()
        if playPause.label == "Play" { playPause.tap() }
        var resumed = false
        for _ in 0..<60 where !resumed {
            after = Array(try await playbackReports(user).dropFirst(cursor))
            resumed = after.contains { report in
                let body = report["body"] as? [String: Any]
                return report["path"] as? String == "/Sessions/Playing/Progress" && body?["PlaySessionId"] as? String == started
                    && body?["IsPaused"] as? Bool == false
            }
            if !resumed { try await Task.sleep(for: .milliseconds(250)) }
        }
        XCTAssertTrue(resumed, "Resuming after the changes must continue the same play session.")
        app.reelPlaybackButton("closePlayer").tap()
    }

    private func playbackReports(_ user: String) async throws -> [[String: Any]] {
        let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18766/qa/state")!)
        let state = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return (state["reports"] as? [[String: Any]] ?? []).filter { $0["user"] as? String == user }
    }

    func testNewHomeChaptersSpeedTimerDownloadsAndTV() {
        login("expanded-\(UUID().uuidString)"); home()
        // This class is simulator-only and signs into its fixed disposable
        // loopback fixture. Manual history changes require Private viewing off.
        tab("Settings")
        let privacy = app.switches["privateViewing"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        if privacy.value as? String == "1" { privacy.tap() }
        XCTAssertEqual(privacy.value as? String, "0")
        tab("Home"); home()
        app.buttons["home-Series"].tap()
        XCTAssertTrue(app.buttons["feature-series-7"].exists)
        app.buttons["home-Movies"].tap()
        app.buttons["feature-movie-2"].tap()
        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
        let versions = app.buttons["versionPicker"]
        reveal(versions, in: app.scrollViews["detailScroll"])
        versions.tap(); app.buttons["Alternate version"].tap()
        app.buttons["detailTracks"].tap(); app.reelMenuItem("Audio").tap(); app.buttons["Alternate English"].tap()
        versions.tap(); app.buttons["Original"].tap()
        app.scrollViews["detailScroll"].swipeDown()
        let watched = app.buttons["watchStatus"]
        reveal(watched, in: app.scrollViews["detailScroll"])
        XCTAssertTrue(watched.isEnabled)
        XCTAssertNotEqual(watched.value as? String, "Watched", "The toggle's first tap must mark the movie watched.")
        watched.tap()
        let marked = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Watched"), object: watched)
        let markedResult = XCTWaiter.wait(for: [marked], timeout: 8)
        guard markedResult == .completed else {
            screenshot("watch-status-failure")
            continueAfterFailure = true
            XCTFail("Watched state did not update: \(app.debugDescription)")
            return
        }
        // A movie's watched control is a toggle: a second tap marks it unwatched.
        XCTAssertTrue(watched.isHittable)
        watched.tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Unwatched"), object: watched)], timeout: 8), .completed)
        let chapters = app.buttons["detailChapters"]
        reveal(chapters, in: app.scrollViews["detailScroll"])
        chapters.tap(); app.buttons["A new chapter"].tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 10))
        app.reelPlaybackButton("closePlayer").tap()
        chooseDownload("download")
        XCTAssertTrue(app.buttons["playDownload"].waitForExistence(timeout: 15))
        app.buttons["playDownload"].tap()
        let transport = app.reelPlaybackButton("transportPlayPause")
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transport)
        waitForExpectations(timeout: 15)
        app.reelPlaybackButton("playbackSpeed").tap(); app.buttons["1.5×"].tap()
        app.reelPlaybackButton("sleepTimer").tap(); app.buttons["15 minutes"].tap()
        XCTAssertTrue(app.reelPlaybackButton("sleepTimer").label.contains("Timer on"))
        app.reelPlaybackButton("sleepTimer").tap(); app.buttons["Off"].tap()
        app.reelPlaybackButton("closePlayer").tap()
        tab("Downloads")
        XCTAssertTrue(app.buttons["offline-movie-2"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch(); home()
        tab("Downloads")
        app.buttons["offline-movie-2"].tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 8))
        app.reelPlaybackButton("closePlayer").tap()
        app.buttons["removeDownload-movie-2"].tap(); app.buttons.matching(identifier: "confirmRemoveDownload").firstMatch.tap()
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 5))
        tab("Live TV")
        XCTAssertTrue(app.buttons["channel-channel-1"].waitForExistence(timeout: 8))
        app.buttons["channel-channel-1"].tap()
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 8))
        app.buttons["detailPlay"].tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 8))
        app.reelPlaybackButton("closePlayer").tap()
        tab("Library")
        let collections = app.buttons["filter-Collections"]
        revealPill(collections)
        collections.tap()
        XCTAssertTrue(app.buttons["item-collection-1"].waitForExistence(timeout: 8))
        app.buttons["item-collection-1"].tap()
        XCTAssertTrue(app.buttons["item-movie-1"].waitForExistence(timeout: 8))
    }


    func testSeededNativeChaosOnDisposableLibrary() {
        login("chaos-\(UUID().uuidString)"); home()
        var seed: UInt64 = 20261023
        for _ in 0..<18 {
            seed = seed &* 6364136223846793005 &+ 1
            switch (seed >> 32) % 5 {
            case 0:
                tab("Home")
                app.buttons[["home-For you", "home-Movies", "home-Series"][Int(seed % 3)]].tap()
                XCTAssertTrue(app.buttons["heroDetails"].exists)
            case 1:
                tab("Library")
                app.buttons[["filter-All", "filter-Movies", "filter-Series", "filter-Favorites"][Int(seed % 4)]].tap()
            case 2:
                tab("Settings")
                app.buttons["qualityPicker"].tap()
                app.buttons[["Original / auto", "High · 20 Mbps", "Balanced · 8 Mbps", "Data saver · 2 Mbps"][Int(seed % 4)]].tap()
            case 3:
                tab("Home")
                app.buttons["servers"].tap(); app.buttons["Done"].tap()
            default:
                tab("Live TV")
                XCTAssertTrue(app.buttons["channel-channel-1"].waitForExistence(timeout: 8))
            }
            XCTAssertEqual(app.state, .runningForeground)
        }
        screenshot("seeded-native-chaos")
    }


    func testBrowseOptionsAndDuplicatePlaylistEntries() {
        login("options-\(UUID().uuidString)"); home(); tab("Library")
        let options = app.buttons["libraryFilters"]
        options.tap(); app.buttons["Adventure"].tap()
        XCTAssertTrue(app.staticTexts["37 titles"].waitForExistence(timeout: 8))
        app.buttons["librarySort"].tap(); app.buttons["Release year"].tap()
        XCTAssertTrue(app.buttons["item-movie-10"].waitForExistence(timeout: 8))
        options.tap(); app.buttons["Watched"].tap()
        XCTAssertTrue(app.staticTexts["No titles found"].waitForExistence(timeout: 8))
        options.tap(); app.buttons["Any"].tap()
        options.tap(); app.buttons["All genres"].tap()
        options.tap(); app.buttons["Films"].tap()
        XCTAssertTrue(app.staticTexts["72 titles"].waitForExistence(timeout: 8))
        options.tap(); app.buttons["All libraries"].tap()
        let playlists = app.buttons["filter-Playlists"]
        revealPill(playlists)
        playlists.tap()
        XCTAssertTrue(app.buttons["item-playlist-1"].waitForExistence(timeout: 8))
        app.buttons["item-playlist-1"].tap()
        XCTAssertTrue(app.staticTexts["3 titles"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["libraryFilters"].exists)
        XCTAssertFalse(app.buttons["librarySort"].exists)
        XCTAssertGreaterThanOrEqual(app.buttons.matching(identifier: "item-movie-1").count, 2)
        app.buttons.matching(identifier: "item-movie-1").firstMatch.tap()
        let play = app.buttons["detailPlay"]
        reveal(play, in: app.scrollViews["detailScroll"])
        play.tap()
        XCTAssertTrue(app.buttons["skipSegment"].waitForExistence(timeout: 6))
        app.buttons["skipSegment"].tap()
        XCTAssertTrue(app.reelPlaybackButton("playerChapters").exists)
        app.reelPlaybackButton("playerChapters").tap(); app.buttons["A new chapter"].tap()
        app.reelPlaybackButton("closePlayer").tap()
    }

    func testDownloadErrorAndCancellationRemainManageable() {
        login("nodownload"); home(); app.buttons["heroDetails"].tap()
        chooseDownload("download")
        tab("Downloads")
        XCTAssertTrue(app.buttons["retryDownload"].waitForExistence(timeout: 8))
        app.buttons["retryDownload"].tap()
        XCTAssertTrue(app.buttons["retryDownload"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments = ["-reel-qa-reset"]; app.launch()
        login("slowdownload"); home(); app.buttons["heroDetails"].tap()
        chooseDownload("download"); tab("Downloads")
        XCTAssertTrue(app.buttons["cancelDownload"].waitForExistence(timeout: 6))
        app.buttons["cancelDownload"].tap()
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 6))
        XCTAssertFalse(app.buttons["offline-movie-1"].exists)
    }

    func testZVisualPreview() {
        login("demo"); home()
        screenshot("11-home-final")
    }
}


@MainActor final class LivePreviewUITests: XCTestCase {
    func testProtectedTranscodeFailureRecoversAtOriginalQuality() throws {
        guard ProcessInfo.processInfo.environment["REEL_LIVE_PREVIEW_TESTS"] == "1" else { throw XCTSkip("Explicit opt-in required for signed-in home-server preview tests.") }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch() // Deliberately no QA reset or fixture override: preserve the user's signed-in preview.
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["servers"].label.isEmpty)
        let more = app.buttons["ellipsis.circle"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5))
        more.tap()
        if !app.navigationBars["More"].waitForExistence(timeout: 2) { more.tap() }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
        app.buttons["Settings"].tap()
        app.buttons["qualityPicker"].tap(); app.buttons["Data saver · 2 Mbps"].tap()
        app.buttons["Home"].tap(); app.buttons["heroPlay"].tap()
        let recovery = app.buttons["originalQualityRecovery"]
        XCTAssertTrue(recovery.waitForExistence(timeout: 45))
        recovery.tap()
        let transport = app.reelPlaybackButton("transportPlayPause")
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transport)
        waitForExpectations(timeout: 20)
        XCTAssertEqual(transport.label, "Pause")
        transport.tap()
        app.reelPlaybackButton("Forward 10 seconds").tap()
        app.reelPlaybackButton("closePlayer").tap()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 10))
    }
}
