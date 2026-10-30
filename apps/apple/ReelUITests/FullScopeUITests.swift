import XCTest
import CoreGraphics
import Synchronization

@MainActor final class FullScopeUITests: XCTestCase {
    var app: XCUIApplication!
    private var createdFixtureGateway = false
    override func setUp() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Fixture account-reset journeys run only on disposable simulators.")
        #endif
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launch()
    }
    override func tearDown() async throws {
        #if targetEnvironment(simulator)
        if createdFixtureGateway { removeOwnedFixtureGateway() }
        #endif
        try await super.tearDown()
    }

    private func removeOwnedFixtureGateway() {
        app.terminate()
        app.launchArguments = []
        app.launch()
        if !app.textFields["username"].waitForExistence(timeout: 2) {
            guard app.buttons["heroDetails"].waitForExistence(timeout: 15) else {
                XCTFail("Fixture gateway cleanup could not identify its signed-in state.")
                app.terminate(); return
            }
            tap("servers"); tap("serverOptions-quickconnect"); tap("Sign in again")
        }
        guard app.textFields["server"].value as? String == "http://127.0.0.1:18766" else {
            XCTFail("Cleanup refused to edit another server's gateway settings.")
            app.terminate(); return
        }
        tap("advancedConnection")
        guard app.textFields["advancedServer"].value as? String == "http://127.0.0.1:18766" else {
            XCTFail("Cleanup refused an unexpected gateway origin.")
            app.terminate(); return
        }
        let name = app.textFields["gatewayName"].firstMatch
        reveal(name)
        guard name.waitForExistence(timeout: 8), name.value as? String == "X-Reel-Fixture-Gateway",
              app.textFields.matching(identifier: "gatewayName").count == 1 else {
            XCTFail("Cleanup preserved unexpected gateway credentials rather than clearing them.")
            app.terminate(); return
        }
        tap("Remove gateway header"); tap("saveGatewayHeaders")
        XCTAssertTrue(app.buttons["saveGatewayHeaders"].label.contains("Headers saved"))
        XCTAssertFalse(app.textFields["gatewayName"].exists)
        createdFixtureGateway = false
        app.terminate()
    }

    private func openPristineFixtureGateway() throws {
        XCTAssertEqual(app.textFields["server"].value as? String, "http://127.0.0.1:18766")
        tap("advancedConnection")
        XCTAssertEqual(app.textFields["advancedServer"].value as? String, "http://127.0.0.1:18766")
        let add = app.buttons["addGatewayHeader"]
        reveal(add)
        XCTAssertTrue(add.waitForExistence(timeout: 8))
        guard !app.textFields["gatewayName"].exists else {
            throw XCTSkip("This synthetic fixture case requires no saved gateway headers; unexpected credentials are preserved.")
        }
    }

    private func tapFixtureQuickConnect() {
        let target = app.buttons["quickConnect"]
        for attempt in 0...10 {
            let window = app.windows.firstMatch.frame
            let bar = app.navigationBars["Connection options"]
            guard bar.exists,
                  let form = app.collectionViews.allElementsBoundByIndex.last(where: {
                      $0.frame.intersects(window) && $0.frame.height > 100 && $0.frame.width > 40
                  }) else {
                XCTFail("Quick Connect requires the foreground connection-options Form.")
                return
            }
            var visible = form.frame.intersection(window)
            let bottom = visible.maxY
            visible.origin.y = max(visible.minY, bar.frame.maxY + 8)
            visible.size.height = max(0, bottom - visible.minY - 24)
            for input in app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex {
                let frame = input.frame
                if frame.height > 60 && frame.minY > visible.minY && frame.minY < visible.maxY {
                    visible.size.height = frame.minY - visible.minY - 8
                }
            }
            guard visible.height > 80 else { XCTFail("No usable Form area above the keyboard."); return }
            var fingerDown = true
            if target.exists {
                let frame = target.frame
                if frame.width > 0 && frame.height > 0 && visible.insetBy(dx: 8, dy: 8).contains(frame)
                    && target.isEnabled && target.isHittable {
                    target.tap()
                    return
                }
                if frame.maxY > visible.maxY { fingerDown = false }
            }
            if attempt == 10 { break }
            let origin = form.coordinate(withNormalizedOffset: .zero)
            let x = visible.minX + 18 - form.frame.minX
            let upper = visible.minY + visible.height * 0.25 - form.frame.minY
            let lower = visible.minY + visible.height * 0.7 - form.frame.minY
            origin.withOffset(CGVector(dx: x, dy: fingerDown ? upper : lower))
                .press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: x, dy: fingerDown ? lower : upper)))
        }
        XCTFail("Quick Connect did not become fully reachable in its Form.\n\(app.debugDescription)")
    }

    private func approveFixtureQuickConnect(_ code: String) throws {
        let completion = XCTestExpectation(description: "Owned loopback Quick Connect approval")
        let result = Mutex<(Int?, (any Error)?)>((nil, nil))
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18766/qa/quick-connect/approve")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 8
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["code": code])
        let task = URLSession.shared.dataTask(with: request) { _, response, error in
            result.withLock { $0 = ((response as? HTTPURLResponse)?.statusCode, error) }
            completion.fulfill()
        }
        task.resume()
        defer { task.cancel() }
        XCTAssertEqual(XCTWaiter.wait(for: [completion], timeout: 10), .completed)
        let (status, error) = result.withLock { $0 }
        if let error { throw error }
        XCTAssertEqual(status, 200)
    }

    private func tapConnectAfterLayoutSettles() {
        let connect = app.buttons["connect"]
        var previousFrames: [CGRect] = []
        var stableSince = ProcessInfo.processInfo.systemUptime
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            guard connect.exists, connect.isEnabled, connect.isHittable else {
                previousFrames = []
                stableSince = ProcessInfo.processInfo.systemUptime
                return false
            }
            let window = self.app.windows.firstMatch.frame
            let frame = connect.frame
            let inputs = self.app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex
                .map(\.frame).filter { $0.height > 60 && $0.intersects(window) }
            let frames = [window, frame] + inputs
            if frames != previousFrames {
                previousFrames = frames
                stableSince = ProcessInfo.processInfo.systemUptime
                return false
            }
            guard frame.minY > window.minY + 8, frame.maxY < window.maxY - 24,
                  inputs.allSatisfy({ frame.maxY < $0.minY - 8 }) else { return false }
            for bar in self.app.navigationBars.allElementsBoundByIndex where bar.frame.intersects(window)
                && (bar.isHittable || bar.buttons.allElementsBoundByIndex.contains { $0.isHittable }) {
                if frame.intersects(bar.frame) { return false }
            }
            return ProcessInfo.processInfo.systemUptime - stableSince >= 0.4
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 8), .completed,
                       "Connect and the software keyboard must finish moving before the native tap.\n\(app.debugDescription)")
        XCTAssertTrue(connect.isHittable)
        connect.tap()
    }

    private func login(server: String = "http://127.0.0.1:18766", user: String = "full-ui-" + UUID().uuidString) {
        if server != "http://127.0.0.1:18766" { replace(app.textFields["server"], with: server) }
        let username = app.textFields["username"]
        reveal(username); username.tap(); username.typeText(user)
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("demo")
        tapConnectAfterLayoutSettles()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        // The system may offer to save the fixture password over Home.
        let decline = app.buttons["Not Now"].firstMatch
        if decline.waitForExistence(timeout: 4), decline.isHittable { decline.tap() }
    }
    private func replace(_ field: XCUIElement, with text: String) {
        reveal(field); field.tap()
        field.press(forDuration: 1)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) { app.menuItems["Select All"].tap() }
        else if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
        else { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 180)) }
        field.typeText(text)
    }
    private func reveal(_ element: XCUIElement, scrollingDown: Bool = false) {
        for _ in 0..<10 {
            if element.exists && element.isHittable { return }
            if scrollingDown { app.swipeDown() } else { app.swipeUp() }
        }
    }
    private func playerAwareButton(_ id: String) -> XCUIElement {
        app.prepareReelPlayerControl(id)
        if app.navigationBars["Playback options"].exists,
           let scroll = app.scrollViews.containing(.button, identifier: "playbackSpeed")
            .allElementsBoundByIndex.first(where: { $0.frame.intersects(app.windows.firstMatch.frame) }),
           scroll.buttons.matching(identifier: id).count > 0 {
            let query = scroll.buttons.matching(identifier: id)
            return query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? query.firstMatch
        }
        return app.buttons[id].firstMatch
    }
    private func tap(_ id: String) {
        let button = playerAwareButton(id)
        if ["Done", "hubCloseReader", "hubClosePlayer", "hubClosePhoto"].contains(id) {
            for _ in 0..<4 { if button.exists && button.isHittable { break }; app.swipeDown() }
        } else { reveal(button) }
        XCTAssertTrue(button.waitForExistence(timeout: 8), "\(id)\n\(app.debugDescription)")
        button.tap()
    }
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
        XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing tab \(name)\n\(app.debugDescription)")
        button.tap()
    }
    private func playable(_ id: String = "transportPlayPause") {
        if id == "transportPlayPause" {
            XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.waitForExistence(timeout: 10))
        }
        let transport = playerAwareButton(id)
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transport)
        waitForExpectations(timeout: 20)
    }
    private func back() {
        let button = app.buttons["BackButton"].firstMatch
        if button.exists { button.tap(); return }
        let navigationBack = app.navigationBars.buttons.firstMatch
        for _ in 0..<4 { if navigationBack.exists && navigationBack.isHittable { break }; app.swipeDown() }
        XCTAssertTrue(navigationBack.waitForExistence(timeout: 5), app.debugDescription)
        navigationBack.tap()
    }
    private func toggle(_ element: XCUIElement) {
        let previous = element.value as? String
        let control = element.switches.firstMatch
        if control.exists { control.tap() } else { element.tap() }
        if let previous {
            expectation(for: NSPredicate(format: "value != %@", previous), evaluatedWith: element)
            waitForExpectations(timeout: 5)
        }
    }
    private func attach(_ name: String) { let a = XCTAttachment(screenshot: app.screenshot()); a.name = name; a.lifetime = .keepAlways; add(a) }
    private func post(_ url: String, _ body: [String: String] = [:], fixtureToken: String? = nil) async throws {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let fixtureToken { request.setValue("MediaBrowser Token=\"fixture-\(fixtureToken)\"", forHTTPHeaderField: "Authorization") }
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as! HTTPURLResponse).statusCode))
    }

    func testMusicQueueTransportAndRestoredMiniPlayer() {
        login(); tab("Media"); tap("hub-MusicAlbum"); tap("hub-item-hub-album-1"); tap("hubPlayAll")
        playable("hubToggle")
        XCTAssertEqual(app.staticTexts["hubCurrentTitle"].label, "First signal")
        tap("hubNext")
        expectation(for: NSPredicate(format: "label == %@", "Second signal"), evaluatedWith: app.staticTexts["hubCurrentTitle"])
        waitForExpectations(timeout: 10)
        playable("hubToggle"); tap("hubToggle"); XCTAssertEqual(app.buttons["hubToggle"].label, "Play music")
        tap("hubRepeat"); tap("hubSpeed"); tap("1.5×"); attach("native-audio-queue")
        tap("hubClosePlayer")
        XCTAssertTrue(app.buttons["hubNowPlaying"].waitForExistence(timeout: 5))
        app.terminate(); app.launchArguments = []; app.launch(); tab("Media")
        XCTAssertTrue(app.buttons["hubNowPlaying"].waitForExistence(timeout: 8))
        tap("hubNowPlaying"); XCTAssertEqual(app.staticTexts["hubCurrentTitle"].label, "Second signal")
    }

    func testPhotoAlbumPagingAndDismissal() {
        login(); tab("Media"); tap("hub-PhotoAlbum"); tap("hub-item-hub-photo-album-1"); tap("hub-photo-hub-photo-1")
        XCTAssertTrue(app.images["hubFullPhoto-hub-photo-1"].waitForExistence(timeout: 10))
        app.swipeLeft()
        XCTAssertTrue(app.images["hubFullPhoto-hub-photo-2"].waitForExistence(timeout: 8))
        attach("native-photo-viewer"); tap("hubClosePhoto")
        XCTAssertTrue(app.buttons["hub-photo-hub-photo-1"].waitForExistence(timeout: 5))
    }

    func testBookDownloadReaderExportAndRelaunch() {
        login(); tab("Media"); tap("hub-Book"); tap("hub-book-hub-book-1"); tap("hubSaveBook")
        XCTAssertTrue(app.buttons["hubOpenBook"].waitForExistence(timeout: 15)); tap("hubOpenBook")
        XCTAssertTrue(app.otherElements["hubPDFReader"].waitForExistence(timeout: 10))
        app.swipeUp(); attach("native-book-reader"); tap("hubCloseReader"); tap("hubExportBook")
        let shareSheet = app.otherElements["ActivityListView"]
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 8), app.debugDescription)
        attach("native-book-export")
        let dismissPopover = app.otherElements["PopoverDismissRegion"]
        if dismissPopover.exists { dismissPopover.tap() }
        else if app.buttons["Close"].exists { app.buttons["Close"].tap() }
        else { XCTAssertTrue(app.buttons["Cancel"].exists, app.debugDescription); app.buttons["Cancel"].tap() }
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: shareSheet)
        waitForExpectations(timeout: 8)
        app.terminate(); app.launchArguments = []; app.launch(); tab("Media"); tap("hub-saved")
        XCTAssertTrue(app.buttons["hub-saved-hub-book-1"].waitForExistence(timeout: 8)); tap("hub-saved-hub-book-1")
        XCTAssertTrue(app.otherElements["hubPDFReader"].waitForExistence(timeout: 8)); tap("hubCloseReader")
        tap("hub-saved-options-hub-book-1"); tap("Remove saved file"); tap("hubConfirmRemoveSaved")
        XCTAssertTrue(app.staticTexts["Take it with you"].waitForExistence(timeout: 8))
    }

    func testGuideRecordingAndSeriesLifecycleAndRecordedPlayback() {
        login(); tab("Live TV"); tap("tv-Guide"); tap("program-program-2"); tap("recordProgram"); tap("Schedule recording"); tap("Done")
        tap("tv-Scheduled"); tap("cancelTimer-timer-1"); tap("Cancel recording")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["cancelTimer-timer-1"])
        waitForExpectations(timeout: 8)
        tap("tv-Guide"); tap("program-program-2"); tap("recordSeries"); tap("Schedule series"); tap("Done")
        tap("tv-Series rules"); tap("cancelSeries-series-1"); tap("Cancel series rule")
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons["cancelSeries-series-1"])
        waitForExpectations(timeout: 8)
        tap("tv-Recordings"); tap("recording-recording-1"); playable(); attach("recorded-broadcast-native-playback"); tap("closePlayer")
        tap("Recording details")
        XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 8))
    }

    func testQuickConnectApprovalAndGatewayValidation() throws {
        try openPristineFixtureGateway(); tap("addGatewayHeader")
        let name = app.textFields["gatewayName"].firstMatch
        reveal(name); name.tap(); name.typeText("Authorization")
        let value = app.secureTextFields["gatewayValue"].firstMatch
        value.tap(); value.typeText("fixture-only"); tap("saveGatewayHeaders")
        XCTAssertTrue(app.staticTexts["gatewayError"].waitForExistence(timeout: 5))
        replace(name, with: "X-Reel-Fixture-Gateway")
        createdFixtureGateway = true
        tap("saveGatewayHeaders")
        XCTAssertTrue(app.buttons["saveGatewayHeaders"].label.contains("Headers saved"))
        tapFixtureQuickConnect()
        let code = app.staticTexts["quickConnectCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 8))
        try approveFixtureQuickConnect(code.label)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        tab("Settings"); XCTAssertTrue(app.staticTexts["Quick Connect Test"].waitForExistence(timeout: 5))
    }

    func testGatewayFixtureCancellationAlsoRestoresDirectConnection() throws {
        try openPristineFixtureGateway(); tap("addGatewayHeader")
        let name = app.textFields["gatewayName"].firstMatch
        reveal(name); name.tap(); name.typeText("X-Reel-Fixture-Gateway")
        let value = app.secureTextFields["gatewayValue"].firstMatch
        value.tap(); value.typeText("fixture-only")
        createdFixtureGateway = true
        tap("saveGatewayHeaders")
        XCTAssertTrue(app.buttons["saveGatewayHeaders"].label.contains("Headers saved"))
        tapFixtureQuickConnect()
        XCTAssertTrue(app.staticTexts["quickConnectCode"].waitForExistence(timeout: 8))
        tap("Cancel")
        XCTAssertTrue(app.staticTexts["quickConnectCode"].waitForNonExistence(timeout: 8))
    }

    func testGatewayFixtureSetupPreservesExistingHeaders() throws {
        try openPristineFixtureGateway(); tap("addGatewayHeader")
        let name = app.textFields["gatewayName"].firstMatch
        reveal(name); name.tap(); name.typeText("X-Reel-Fixture-Gateway")
        let value = app.secureTextFields["gatewayValue"].firstMatch
        value.tap(); value.typeText("fixture-only")
        createdFixtureGateway = true
        tap("saveGatewayHeaders")
        XCTAssertTrue(app.buttons["saveGatewayHeaders"].label.contains("Headers saved"))
        tap("Done")
        do {
            try openPristineFixtureGateway()
            XCTFail("Setup must preserve and refuse an existing gateway entry.")
        } catch is XCTSkip {
            XCTAssertEqual(app.textFields["gatewayName"].firstMatch.value as? String, "X-Reel-Fixture-Gateway")
            XCTAssertEqual(app.textFields.matching(identifier: "gatewayName").count, 1)
            XCTAssertTrue(app.secureTextFields["gatewayValue"].firstMatch.exists)
        }
    }

    func testSeerrMovieAndSeasonRequestsAndCancel() async throws {
        try await post("http://127.0.0.1:18768/api/v1/qa/reset")
        login(); tab("Requests")
        replace(app.textFields["seerrServer"], with: "http://127.0.0.1:18768")
        app.segmentedControls["seerrAuthMethod"].buttons["Jellyfin"].tap()
        replace(app.textFields["seerrUsername"], with: "viewer")
        app.secureTextFields["seerrPassword"].tap(); app.secureTextFields["seerrPassword"].typeText("demo"); tap("seerrConnect")
        tap("seerrTitle-movie-101"); tap("seerrSubmitRequest"); tap("Send request")
        XCTAssertTrue(app.staticTexts["seerrRequestSuccess"].waitForExistence(timeout: 10)); attach("native-seerr-request")
        back()
        tap("seerrTitle-tv-201"); tap("seerrSeason-2"); tap("seerrSubmitRequest"); tap("Send request")
        XCTAssertTrue(app.staticTexts["seerrRequestSuccess"].waitForExistence(timeout: 10))
        back()
        app.segmentedControls["seerrSection"].buttons["My requests"].tap()
        let cancel = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "seerrCancel-")).firstMatch
        reveal(cancel); XCTAssertTrue(cancel.waitForExistence(timeout: 8)); let cancelID = cancel.identifier
        cancel.tap(); tap("Cancel request")
        let cancelled = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: app.buttons[cancelID])
        await fulfillment(of: [cancelled], timeout: 8)
    }

    func testRemoteCommandsAndSyncPlayWebSocketPlayback() async throws {
        let setupUser = "remote-ui-setup-" + UUID().uuidString
        try await post("http://127.0.0.1:18769/Sessions/qa-living-room/Playing?playCommand=PlayNow&itemIds=movie-1", fixtureToken: setupUser)
        try await post("http://127.0.0.1:18769/Sessions/qa-living-room/Playing/Unpause", fixtureToken: setupUser)
        login(server: "http://127.0.0.1:18769"); tab("Devices")
        tap("remote-pause-qa-living-room"); XCTAssertTrue(app.buttons["remote-unpause-qa-living-room"].waitForExistence(timeout: 8))
        tap("remote-seek-forward-qa-living-room"); tap("remote-unpause-qa-living-room")
        let name = app.textFields["syncGroupName"]; reveal(name); name.tap(); name.typeText("Duo QA party"); tap("syncCreate")
        let activeGroup = app.descendants(matching: .any).matching(identifier: "activeSyncGroup").firstMatch
        reveal(activeGroup, scrollingDown: true)
        XCTAssertTrue(activeGroup.waitForExistence(timeout: 8), app.debugDescription); tap("syncLeave")
        tap("syncJoin-fixture-group"); playable(); tap("transportPlayPause"); tap("Forward 10 seconds"); attach("native-syncplay-player")
        tap("closePlayer")
        XCTAssertTrue(app.buttons["syncJoin-fixture-group"].waitForExistence(timeout: 10))
    }

    func testTrickplayTimelineSeeksNativeMovie() {
        login(); tap("heroPlay"); playable()
        app.prepareReelPlayerControl("scrubTimeline")
        let slider = app.sliders["scrubTimeline"]
        reveal(slider); XCTAssertTrue(slider.waitForExistence(timeout: 8))
        slider.adjust(toNormalizedSliderPosition: 0.45)
        tap("transportPlayPause"); attach("native-trickplay-scrubber"); tap("closePlayer")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 8))
    }
    func testOptimizedHLSDownloadAndNativeOfflinePlayback() {
        login(); tap("heroDetails"); tap("downloadMenu")
        XCTAssertTrue(app.buttons["downloadOptimized"].waitForExistence(timeout: 5))
        tap("downloadOptimized"); tab("Downloads")
        let saved = app.buttons["offline-movie-1"]
        XCTAssertTrue(saved.waitForExistence(timeout: 55), "Optimized download did not become playable offline: \(app.debugDescription)")
        saved.tap(); playable(); attach("optimized-native-offline"); tap("closePlayer")
    }

    func testServerPreferencesAreAppliedAndPersisted() {
        login(); tab("Settings")
        let serverPreferences = app.switches["useServerPreferences"]; reveal(serverPreferences); toggle(serverPreferences)
        reveal(app.staticTexts["4 Mbps"])
        XCTAssertTrue(app.staticTexts["4 Mbps"].waitForExistence(timeout: 8))
        reveal(app.buttons["qualityPicker"], scrollingDown: true)
        XCTAssertFalse(app.buttons["qualityPicker"].isEnabled)
        tab("Home"); tap("heroPlay"); playable()
        XCTAssertTrue(app.reelPlaybackButton("Forward 30 seconds").waitForExistence(timeout: 8))
        let speed = app.reelPlaybackButton("playbackSpeed")
        XCTAssertTrue(speed.waitForExistence(timeout: 8))
        XCTAssertFalse(speed.isEnabled)
        tap("closePlayer"); app.terminate(); app.launchArguments = []; app.launch(); tab("Settings")
        reveal(app.staticTexts["4 Mbps"])
        XCTAssertTrue(app.staticTexts["4 Mbps"].waitForExistence(timeout: 8))
        let restored = app.switches["useServerPreferences"]; reveal(restored, scrollingDown: true); toggle(restored)
        reveal(app.buttons["qualityPicker"], scrollingDown: true)
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: app.buttons["qualityPicker"])
        waitForExpectations(timeout: 5)
    }

}
