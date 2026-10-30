import XCTest

@MainActor final class PlaybackExtrasUITests: XCTestCase {
    func testTrickplayTimelineSeeksTheNativePlayer() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launch()
        let username = app.textFields["username"]
        if !username.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(username.waitForExistence(timeout: 5))
        username.tap(); username.typeText("trickplay-ui-\(UUID().uuidString)")
        let password = app.secureTextFields["password"]
        password.tap(); password.typeText("demo")
        app.buttons["connect"].tap()
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
        // A signed simulator build offers to save the fixture password over Home.
        app.dismissReelPasswordPrompt()
        app.buttons["heroPlay"].tap()
        let transport = app.reelPlaybackButton("transportPlayPause")
        XCTAssertTrue(transport.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: transport)
        waitForExpectations(timeout: 15)
        if transport.label == "Pause" { transport.tap() }
        app.prepareReelPlayerControl("scrubTimeline")
        let timeline = app.sliders["scrubTimeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5))
        for _ in 0..<4 { if timeline.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(timeline.isHittable)
        timeline.adjust(toNormalizedSliderPosition: 0.5)
        expectation(for: NSPredicate(format: "value MATCHES %@", "0:1[0-4]"), evaluatedWith: timeline)
        waitForExpectations(timeout: 5)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "trickplay-native-timeline-seek"; attachment.lifetime = .keepAlways
        add(attachment)
        app.reelPlaybackButton("closePlayer").tap()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 8))
    }
}
