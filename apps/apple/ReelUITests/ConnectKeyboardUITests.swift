import XCTest

@MainActor final class ConnectKeyboardUITests: XCTestCase {
    override func tearDown() {
        #if targetEnvironment(simulator)
        XCUIDevice.shared.orientation = .portrait
        #endif
        super.tearDown()
    }

    private func assertAboveKeyboard(_ element: XCUIElement, in app: XCUIApplication, name: String) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            let keyboard = app.keyboards.firstMatch
            return element.exists && keyboard.exists && element.isHittable
                && element.frame.minY >= app.windows.firstMatch.frame.minY
                && element.frame.maxY < keyboard.frame.minY
        }, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 8)
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        XCTAssertEqual(result, .completed, "The focused field must remain fully above the keyboard.")
        XCTAssertTrue(app.keyboards.firstMatch.exists, "The keyboard must still be visible after the layout settles.")
        XCTAssertLessThan(element.frame.maxY, app.keyboards.firstMatch.frame.minY)
    }

    private func signInThroughNextAndGo(largeText: Bool = false, rotate: Bool = false, dismissKeyboard: Bool = false) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This reset workflow is only for disposable simulators and loopback fixtures.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launch()
        defer { app.terminate() }
        let server = app.textFields["server"]
        XCTAssertTrue(server.waitForExistence(timeout: 8))
        for _ in 0..<12 {
            let window = app.windows.firstMatch.frame
            if server.isHittable && server.frame.minY > window.minY + 24
                && server.frame.maxY < window.maxY - 24 { break }
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let below = server.frame.maxY >= window.maxY - 24
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.07,
                                                  dy: app.frame.height * (below ? 0.85 : 0.3)))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.07,
                                                dy: app.frame.height * (below ? 0.5 : 0.65)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
        XCTAssertGreaterThan(server.frame.minY, app.windows.firstMatch.frame.minY + 24)
        XCTAssertLessThan(server.frame.maxY, app.windows.firstMatch.frame.maxY - 24,
                          "The entire field must be visible before tapping it.")
        server.tap()
        assertAboveKeyboard(server, in: app, name: "server-above-keyboard")
        server.typeText(XCUIKeyboardKey.return.rawValue)
        let username = app.textFields["username"]
        assertAboveKeyboard(username, in: app, name: "username-after-next")
        if dismissKeyboard {
            let keyboard = app.keyboards.firstMatch
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let start = origin.withOffset(CGVector(dx: app.frame.width * 0.07,
                                                  dy: username.frame.midY - app.frame.minY))
            let end = origin.withOffset(CGVector(dx: app.frame.width * 0.07, dy: app.frame.height - 40))
            start.press(forDuration: 0.1, thenDragTo: end)
            XCTAssertTrue(keyboard.waitForNonExistence(timeout: 8), "Dismissing the keyboard must not trigger focus scrolling that brings it back.")
            for _ in 0..<8 {
                if username.isHittable { break }
                app.swipeUp()
            }
            username.tap()
            assertAboveKeyboard(username, in: app, name: "username-after-refocus")
        }
        if rotate {
            XCUIDevice.shared.orientation = .landscapeLeft
            let landscape = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
                let frame = app.windows.firstMatch.frame
                return frame.width > frame.height
            }, object: nil)
            XCTAssertEqual(XCTWaiter.wait(for: [landscape], timeout: 8), .completed,
                           "This case must exercise an actual landscape window.")
            assertAboveKeyboard(username, in: app, name: "username-after-rotation")
        }
        username.typeText("keyboard-" + UUID().uuidString)
        username.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        assertAboveKeyboard(password, in: app, name: "password-after-next")
        password.typeText("demo")
        password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15), "Native Go must complete sign-in.")
        #endif
    }

    func testNextKeepsFieldsAboveKeyboardAndGoSignsIn() throws {
        try signInThroughNextAndGo()
    }

    func testLargestTextKeepsFocusedFieldsVisible() throws {
        try signInThroughNextAndGo(largeText: true)
    }

    func testRotationKeepsFocusedFieldsVisible() throws {
        try signInThroughNextAndGo(rotate: true)
    }

    func testInteractiveKeyboardDismissalAndRefocus() throws {
        try signInThroughNextAndGo(dismissKeyboard: true)
    }
}
