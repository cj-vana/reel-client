import XCTest
import UIKit

@MainActor final class PhoneNavigationUITests: XCTestCase {
    private func dismissPasswordSavePrompt(in app: XCUIApplication) {
        let prompt = app.sheets["Save Password?"]
        if prompt.waitForExistence(timeout: 3) {
            let decline = prompt.buttons["Not Now"]
            XCTAssertTrue(decline.isHittable)
            decline.tap()
            XCTAssertTrue(prompt.waitForNonExistence(timeout: 5))
        }
    }

    func testDownloadsSelectionSurvivesOtherRootsRotationAndRelaunch() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("This account-reset regression runs only on disposable simulators with loopback fixtures.")
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
        username.tap(); username.typeText("phone-navigation-" + UUID().uuidString)
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("demo")
        app.buttons["connect"].tap()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        dismissPasswordSavePrompt(in: app)

        func root(_ title: String) {
            let button = title == "More" && app.buttons["ellipsis.circle"].exists
                ? app.buttons["ellipsis.circle"].firstMatch : app.buttons[title].firstMatch
            if !button.exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
            XCTAssertTrue(button.waitForExistence(timeout: 5), "Missing root: \(title)")
            button.tap()
        }
        func downloads() {
            root("Downloads")
            XCTAssertTrue(app.navigationBars["Downloads"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 5))
            XCTAssertEqual(app.state, .runningForeground)
        }
        func more() {
            root("More")
            if !app.navigationBars["More"].waitForExistence(timeout: 2) { root("More") }
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
            for _ in 0..<5 {
                if app.buttons["Media"].isHittable { break }
                app.swipeDown()
            }
        }

        for title in ["Home", "Library", "Search", "More", "Home"] {
            downloads(); root(title)
        }
        downloads()
        let browseLibrary = app.buttons["downloadsBrowseLibrary"]
        XCTAssertTrue(browseLibrary.waitForExistence(timeout: 5))
        XCTAssertTrue(browseLibrary.isHittable)
        browseLibrary.tap()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.textFields["username"].exists)
        downloads()
        for (title, heading) in [("Media", "Media"), ("Live TV", "Live TV"), ("Requests", "Requests"),
                                 ("Devices", "Players & watch together"), ("Settings", "Settings")] {
            more()
            let destination = app.buttons[title].firstMatch
            for _ in 0..<6 { if destination.isHittable { break }; app.swipeUp() }
            XCTAssertTrue(destination.waitForExistence(timeout: 5)); destination.tap()
            XCTAssertTrue(app.navigationBars[heading].waitForExistence(timeout: 8))
            downloads()
        }
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            downloads(); root("Home"); downloads()
        }
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "downloads-stable-phone-navigation"; attachment.lifetime = .keepAlways
        add(attachment)
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        downloads()
        #endif
    }
}
