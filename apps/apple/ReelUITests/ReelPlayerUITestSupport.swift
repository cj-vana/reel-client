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
        guard navigationBars["Playback options"].exists else { return buttons[identifier].firstMatch }
        let button = reelOptionsSheet.buttons[identifier].firstMatch
        revealInReelOptions(button)
        return button
    }

    /// The playback options sheet, found by its own name. SwiftUI drops rows that are scrolled out of
    /// sight from the accessibility tree, so a search by the controls inside it can lose the sheet.
    var reelOptionsSheet: XCUIElement {
        let sheets = scrollViews.matching(identifier: "playerOptionsScroll").allElementsBoundByIndex.filter { $0.exists }
        XCTAssertEqual(sheets.count, 1, "The foreground options sheet must own its controls.")
        return sheets.first ?? scrollViews["playerOptionsScroll"]
    }

    /// One drag in the options sheet's left margin. Its content sits 20 points in from each side, so the
    /// drag that grows the sheet to full height cannot end on a row. `up` shows what is further down.
    func dragReelOptions(up: Bool) {
        let bar = navigationBars["Playback options"]
        var area = reelOptionsSheet.frame.intersection(windows.firstMatch.frame)
        if bar.exists, bar.frame.maxY > area.minY {
            area = CGRect(x: area.minX, y: bar.frame.maxY, width: area.width, height: max(0, area.maxY - bar.frame.maxY))
        }
        guard area.width > 40, area.height > 80 else {
            XCTFail("The options sheet has no room to drag in: \(area)")
            return
        }
        let x = area.minX + 8, near = area.minY + area.height * 0.3, far = area.minY + area.height * 0.8
        let origin = coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: x, dy: up ? far : near))
            .press(forDuration: 0.05, thenDragTo: origin.withOffset(CGVector(dx: x, dy: up ? near : far)))
        XCTAssertTrue(bar.waitForExistence(timeout: 2), "A drag in the options sheet's margin must not open one of its lists.")
    }

    /// Scrolls the options sheet until `element` is wholly inside it, below the bar.
    func revealInReelOptions(_ element: XCUIElement) {
        for attempt in 0..<10 {
            let bar = navigationBars["Playback options"]
            guard bar.exists else { return }
            let area = reelOptionsSheet.frame.intersection(windows.firstMatch.frame)
            let top = max(area.minY, bar.frame.maxY)
            guard element.exists else {
                // Out of the tree, so scrolled away. It is usually further down; after five drags, look above.
                dragReelOptions(up: attempt < 5)
                continue
            }
            let frame = element.frame
            if frame.minY >= top && frame.maxY <= area.maxY && (element.isHittable || !element.isEnabled) { return }
            dragReelOptions(up: frame.minY >= top)
        }
    }
}
