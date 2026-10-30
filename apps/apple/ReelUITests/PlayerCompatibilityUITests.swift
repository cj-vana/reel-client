import XCTest

@MainActor final class PlayerCompatibilityUITests: XCTestCase {
    private func dismissPasswordSavePrompt(in app: XCUIApplication) {
        let prompt = app.sheets["Save Password?"]
        if prompt.waitForExistence(timeout: 3) {
            let decline = prompt.buttons["Not Now"]
            let ready = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                decline.exists && decline.isHittable
            }, object: nil)
            let result = XCTWaiter.wait(for: [ready], timeout: 5)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "player-password-prompt"; screenshot.lifetime = .keepAlways; add(screenshot)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "player-password-prompt-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            XCTAssertEqual(result, .completed, "The native password prompt must finish presenting before dismissal.")
            XCTAssertTrue(decline.isHittable)
            decline.tap()
            XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        }
    }

    func testPlayerOptionsRemainReachableAfterRotation() async throws {
        try await exerciseFullscreenPlayer(requireLandscapeWindow: true)
    }

    func testFullscreenWindowAndControlsAfterOrientationInput() async throws {
        try await exerciseFullscreenPlayer(requireLandscapeWindow: false)
    }

    private func exerciseFullscreenPlayer(requireLandscapeWindow: Bool) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This account-reset workflow runs only on disposable simulators with loopback fixtures.")
        #else
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        XCUIDevice.shared.orientation = .portrait
        defer { XCUIDevice.shared.orientation = .portrait; app.terminate() }
        app.launch()
        let username = app.textFields["username"]
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        for _ in 0..<6 { if username.isHittable { break }; app.swipeUp() }
        let user = "compatibility-" + UUID().uuidString
        username.tap(); username.typeText(user)
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("demo")
        app.buttons["connect"].tap()
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
        dismissPasswordSavePrompt(in: app)
        app.buttons["heroPlay"].tap()
        assertFullscreenVideo(in: app, name: "player-fullscreen-portrait")
        @MainActor func reports() async throws -> [[String: Any]] {
            let (data, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:18766/qa/state")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            return (state["reports"] as! [[String: Any]]).filter { ($0["user"] as? String) == user }
        }
        @MainActor func stopCount() async throws -> Int {
            try await reports().filter { ($0["path"] as? String) == "/Sessions/Playing/Stopped" }.count
        }
        let startedDeadline = Date().addingTimeInterval(15)
        var started = false
        repeat {
            started = try await reports().contains { ($0["path"] as? String) == "/Sessions/Playing" }
            if started { break }
            try await Task.sleep(for: .milliseconds(200))
        } while Date() < startedDeadline
        XCTAssertTrue(started, "The actual fixture session must start before testing options retention.")
        let stopsBeforeOptions = try await stopCount()
        XCTAssertTrue(app.buttons["playbackOptions"].waitForNonExistence(timeout: 6),
                      "Playing video must hide the idle overlay instead of keeping a permanent header.")
        let unobstructed = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        unobstructed.name = "player-fullscreen-controls-hidden"; unobstructed.lifetime = .keepAlways; add(unobstructed)
        app.revealReelPlayerChrome()
        XCTAssertTrue(app.buttons["playbackOptions"].isHittable)
        app.prepareReelPlayerControl("transportPlayPause")
        let transport = app.buttons["transportPlayPause"]
        XCTAssertTrue(transport.waitForExistence(timeout: 12))
        let ready = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: transport)
        await fulfillment(of: [ready], timeout: 20)
        if transport.label == "Pause" { transport.tap() }
        app.navigationBars["Playback options"].buttons["Done"].tap()
        let stopsAfterFirstOptions = try await stopCount()
        XCTAssertEqual(stopsAfterFirstOptions, stopsBeforeOptions,
                       "The first options open/dismiss cycle must preserve the active player session.")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists)
        try await Task.sleep(for: .seconds(5))
        XCTAssertTrue(app.buttons["closePlayer"].isHittable, "Paused video must keep its overlay controls available.")
        XCUIDevice.shared.orientation = .landscapeLeft
        if requireLandscapeWindow {
            let rotated = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                app.windows.firstMatch.frame.width > app.windows.firstMatch.frame.height
            }, object: nil)
            await fulfillment(of: [rotated], timeout: 8)
        }
        XCTAssertEqual(XCUIDevice.shared.orientation, .landscapeLeft)
        let geometry = XCTAttachment(string: "deviceOrientation=\(XCUIDevice.shared.orientation.rawValue);window=\(app.windows.firstMatch.frame);landscapeRequired=\(requireLandscapeWindow)")
        geometry.name = "player-orientation-input-and-window"; geometry.lifetime = .keepAlways; add(geometry)
        assertFullscreenVideo(in: app, name: requireLandscapeWindow ? "player-fullscreen-landscape" : "player-fullscreen-after-orientation-input")
        app.revealReelPlayerChrome()
        let options = app.buttons["playbackOptions"]
        XCTAssertTrue(options.waitForExistence(timeout: 8))
        options.tap()
        XCTAssertTrue(app.navigationBars["Playback options"].waitForExistence(timeout: 8))
        @MainActor func visibleButton(_ id: String) -> XCUIElement {
            app.buttons.matching(identifier: id).allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.buttons[id].firstMatch
        }
        // Drag the sheet's own scroll view near its leading edge. On iPhone in landscape, app.swipeUp()
        // leaves this sheet where it is, while a drag on the scroll view scrolls it.
        @MainActor func scrollOptions() {
            let scroll = app.scrollViews["playerOptionsScroll"]
            guard scroll.exists else { app.swipeUp(); return }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.06, dy: 0.25)))
        }
        // Now playing and Up next open the sheet, so the transport can sit below its first screen.
        for _ in 0..<4 { if visibleButton("transportPlayPause").isHittable { break }; scrollOptions() }
        XCTAssertTrue(visibleButton("transportPlayPause").isHittable)
        for _ in 0..<4 { if visibleButton("playbackSpeed").isHittable { break }; scrollOptions() }
        visibleButton("playbackSpeed").tap()
        XCTAssertTrue(app.buttons["1.25×"].waitForExistence(timeout: 5))
        app.buttons["1.25×"].tap()
        XCTAssertTrue(visibleButton("playbackSpeed").label.contains("1.25"))
        visibleButton("playbackSpeed").tap(); app.buttons["1×"].tap()
        XCTAssertTrue(app.buttons["1.25×"].waitForNonExistence(timeout: 3), "The speed menu must close after a choice.")
        let stopsAfterOptions = try await stopCount()
        XCTAssertEqual(stopsAfterOptions, stopsBeforeOptions, "Rotating and opening playback options must preserve the active player session.")
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = requireLandscapeWindow ? "player-options-landscape" : "player-options-after-orientation-input"; attachment.lifetime = .keepAlways
        add(attachment)
        app.buttons["Done"].tap()
        app.prepareReelPlayerControl("closePlayer")
        app.buttons["closePlayer"].tap()
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 8))
        #endif
    }

    private func assertFullscreenVideo(in app: XCUIApplication, name: String) {
        let surface = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 12))
        let matches = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let screen = app.windows.firstMatch.frame, video = surface.frame
            return abs(screen.minX - video.minX) < 2 && abs(screen.minY - video.minY) < 2
                && abs(screen.maxX - video.maxX) < 2 && abs(screen.maxY - video.maxY) < 2
        }, object: nil)
        let result = XCTWaiter.wait(for: [matches], timeout: 8)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        XCTAssertEqual(result, .completed,
                       "The video surface must occupy the full window; controls cannot reserve a panel.")
        XCTAssertFalse(app.buttons["playbackSpeed"].exists, "Advanced controls belong in the options sheet.")
    }
}
