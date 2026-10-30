import XCTest

@MainActor extension XCUIApplication {
    /// A menu row by its title. A submenu row that shows its current choice
    /// can read as "Title, Choice".
    func reelMenuItem(_ title: String) -> XCUIElement {
        buttons.matching(NSPredicate(format: "label == %@ OR label BEGINSWITH %@", title, title + ",")).firstMatch
    }

    /// A signed simulator build lets AutoFill offer to save the fixture password
    /// a few seconds after sign-in; its sheet covers the screen until declined.
    func dismissReelPasswordPrompt(timeout: TimeInterval = 6) {
        let decline = buttons["Not Now"].firstMatch
        guard decline.waitForExistence(timeout: timeout) else { return }
        // A tap that lands while the sheet is still animating in is lost, so tap again while it stays.
        for _ in 0..<3 where decline.exists {
            if decline.isHittable { decline.tap() }
            if decline.waitForNonExistence(timeout: 3) { return }
        }
    }

    func revealReelPlayerChrome() {
        let options = buttons["playbackOptions"]
        if options.exists && options.isHittable { return }
        let surface = descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        XCTAssertTrue(surface.waitForExistence(timeout: 12), "The real video surface must be present.")
        surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
        XCTAssertTrue(options.waitForExistence(timeout: 5))
        XCTAssertTrue(options.isHittable, "Tapping the video must reveal its overlay controls.")
    }

    func prepareReelPlayerControl(_ identifier: String) {
        if identifier == "closePlayer" {
            let options = navigationBars["Playback options"]
            if options.exists {
                options.buttons["Done"].tap()
                XCTAssertTrue(options.waitForNonExistence(timeout: 5))
            }
            revealReelPlayerChrome()
            return
        }
        if identifier == "playbackOptions" { revealReelPlayerChrome(); return }
        let optionsControls: Set<String> = ["transportPlayPause", "playbackSpeed", "sleepTimer", "playerChapters", "scrubTimeline"]
        let skipControl = (identifier.hasPrefix("Back ") || identifier.hasPrefix("Forward ")) && identifier.hasSuffix(" seconds")
        guard optionsControls.contains(identifier) || skipControl else { return }
        if navigationBars["Playback options"].exists { return }
        // Managed group transport stays on the picture; regular playback reaches it through the options sheet.
        if identifier == "transportPlayPause", buttons[identifier].exists, buttons[identifier].isHittable { return }
        revealReelPlayerChrome()
        if identifier == "transportPlayPause", buttons[identifier].exists, buttons[identifier].isHittable { return }
        buttons["playbackOptions"].tap()
        XCTAssertTrue(navigationBars["Playback options"].waitForExistence(timeout: 5))
    }

    func reelPlaybackButton(_ identifier: String) -> XCUIElement {
        prepareReelPlayerControl(identifier)
        if navigationBars["Playback options"].exists {
            let owners = scrollViews.containing(.button, identifier: "transportPlayPause")
                .containing(.button, identifier: "playbackSpeed").allElementsBoundByIndex.filter { $0.exists }
            XCTAssertEqual(owners.count, 1, "The foreground options sheet must own its controls.")
            if let owner = owners.first, owners.count == 1 { return owner.buttons[identifier].firstMatch }
        }
        return buttons[identifier].firstMatch
    }
}
