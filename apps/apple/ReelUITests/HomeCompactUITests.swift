import XCTest

@MainActor final class HomeCompactUITests: XCTestCase {
    private func dismissPasswordSavePrompt(in app: XCUIApplication) {
        let prompt = app.sheets["Save Password?"]
        if prompt.waitForExistence(timeout: 3) {
            let decline = prompt.buttons["Not Now"]
            XCTAssertTrue(decline.isHittable)
            decline.tap()
            XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        }
    }

    private func launchHome(accessibilityText: Bool = false) throws -> XCUIApplication {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This account-reset workflow uses disposable simulators and loopback fixtures.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        if accessibilityText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launch()
        try XCTSkipUnless(app.windows.firstMatch.frame.width < 800, "Compact Home requires a phone-width window.")
        let username = app.textFields["username"]
        XCTAssertTrue(username.waitForExistence(timeout: 8))
        for _ in 0..<12 {
            let window = app.windows.firstMatch.frame
            if username.isHittable && username.frame.minY > window.minY + 24
                && username.frame.maxY < window.maxY - 24 { break }
            app.swipeUp()
        }
        XCTAssertGreaterThan(username.frame.minY, app.windows.firstMatch.frame.minY + 24)
        XCTAssertLessThan(username.frame.maxY, app.windows.firstMatch.frame.maxY - 24)
        username.tap()
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        username.typeText("compact-" + UUID().uuidString)
        username.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        password.typeText("demo")
        password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        dismissPasswordSavePrompt(in: app)
        return app
        #endif
    }

    func testCompactFeatureSelectionDetailsAndContinueWatching() throws {
        let app = try launchHome()
        defer { app.terminate() }
        let scroll = app.scrollViews["homeScroll"]
        let selectors = app.scrollViews["homeFeatureSelector"]
        XCTAssertTrue(selectors.exists)
        XCTAssertLessThanOrEqual(selectors.frame.height, 48, "Compact features use controls rather than a thumbnail rail.")
        let second = app.buttons["feature-movie-2"]
        XCTAssertTrue(second.isHittable)
        XCTAssertGreaterThanOrEqual(second.frame.width, 44)
        XCTAssertGreaterThanOrEqual(second.frame.height, 44)
        let originalTitle = app.staticTexts["homeHeroTitle"].label
        second.tap()
        XCTAssertNotEqual(app.staticTexts["homeHeroTitle"].label, originalTitle)
        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
        let back = app.buttons["BackButton"].firstMatch
        if back.exists { back.tap() }
        else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 8))
        app.buttons["home-Series"].tap()
        XCTAssertTrue(app.buttons["feature-series-7"].exists)
        app.buttons["home-For you"].tap()
        let scrollStart = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.72))
        let scrollEnd = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.46))
        scrollStart.press(forDuration: 0.1, thenDragTo: scrollEnd)
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'resume-'")).firstMatch
        XCTAssertTrue(resume.isHittable, "Continue Watching should be reachable on the first scroll.")
        XCTAssertGreaterThanOrEqual(resume.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        // iOS 27's floating tab bar is not always reported as a tab bar; isHittable above covers it then.
        if app.tabBars.firstMatch.exists { XCTAssertLessThanOrEqual(resume.frame.maxY, app.tabBars.firstMatch.frame.minY) }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "compact-home-continue"; attachment.lifetime = .keepAlways
        add(attachment)
        resume.tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 10))
        app.reelPlaybackButton("closePlayer").tap()
        XCTAssertTrue(app.scrollViews["homeScroll"].waitForExistence(timeout: 8))
    }

    func testCompactHomeLargestTextKeepsCategoriesAndActionsReachable() throws {
        let app = try launchHome(accessibilityText: true)
        defer { app.terminate() }
        let scroll = app.scrollViews["homeScroll"]
        XCTAssertTrue(app.buttons["home-For you"].isHittable)
        let details = app.buttons["heroDetails"]
        // Short drags, so the button stops fully on screen; a swipe can carry it under the status bar.
        let window = app.windows.firstMatch.frame
        for _ in 0..<12 {
            if details.isHittable && details.frame.minY >= window.minY + 80 && details.frame.maxY <= window.maxY - 100 { break }
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.7))
                .press(forDuration: 0.1, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.3, dy: 0.5)))
        }
        XCTAssertTrue(details.isHittable)
        XCTAssertTrue(app.buttons["heroPlay"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "compact-home-largest-text"; attachment.lifetime = .keepAlways
        add(attachment)
        details.tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
    }
}
