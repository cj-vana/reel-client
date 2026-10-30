import XCTest

@MainActor final class NativePresentationUITests: XCTestCase {
    private let app = XCUIApplication()
    private var port: Int { Int(ProcessInfo.processInfo.environment["REEL_NATIVE_PRESENTATION_PORT"] ?? "18966") ?? 18966 }
    private let user = "tv-track-output"
    private var didLaunchOwnedApp = false
    private var owner: String { ProcessInfo.processInfo.environment["REEL_TV_QA_OWNER"] ?? "" }

    override func tearDown() { if didLaunchOwnedApp { app.terminate() }; super.tearDown() }

    private func launch(largeText: Bool = false, authenticate: Bool = true) async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Native visual QA uses only an owned disposable simulator.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard environment["SIMULATOR_DEVICE_NAME"]?.hasPrefix("Reel QA Improvements Player ") == true,
              environment["REEL_PLAYER_QA_DEVICE_UDID"]?.isEmpty == false,
              environment["SIMULATOR_UDID"] == environment["REEL_PLAYER_QA_DEVICE_UDID"], !owner.isEmpty else {
            throw XCTSkip("Requires the exact owned native design simulator and synthetic fixture identity.")
        }
        continueAfterFailure = false
        let identity = try await request("/qa/tv-identity")
        try XCTSkipUnless(identity["owner"] as? String == owner && identity["port"] as? Int == port, "The listener must belong to this test run before account reset.")
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["-reel-qa-reset", "-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:\(port)"
        didLaunchOwnedApp = true
        app.launch()
        if !authenticate { return }
        let username = app.textFields["username"]
        try await visible(username)
        username.tap(); username.typeText(user); username.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        XCTAssertTrue(password.waitForExistence(timeout: 8))
        password.typeText("demo"); password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        dismissPasswordPrompt()
        #endif
    }

    func testHomeFeatureAndMovieDetailPresentation() async throws {
        try await launch()
        let servers = app.buttons["servers"]
        XCTAssertFalse((servers.value as? String ?? "").isEmpty)
        XCTAssertGreaterThanOrEqual(servers.frame.width, 44)
        XCTAssertGreaterThanOrEqual(servers.frame.height, 44)
        try await tap(servers)
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 8))
        app.navigationBars["Servers"].buttons["Done"].tap()
        app.buttons["home-Movies"].tap()
        XCTAssertTrue(app.buttons["home-Movies"].isSelected)
        app.buttons["home-For you"].tap()
        XCTAssertTrue(app.buttons["home-For you"].isSelected)
        snapshot("native-home-cinematic")
        let feature = app.buttons["feature-movie-2"]
        try await visible(feature)
        XCTAssertGreaterThanOrEqual(feature.frame.width, 44)
        XCTAssertGreaterThanOrEqual(feature.frame.height, 44)
        let originalTitle = app.staticTexts["homeHeroTitle"].label
        feature.tap()
        XCTAssertNotEqual(app.staticTexts["homeHeroTitle"].label, originalTitle)
        try await tap(app.buttons["heroDetails"])
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["detailPlay"].isHittable)
        XCTAssertTrue(app.buttons["favorite"].isHittable)
        let favorite = app.buttons["favorite"]
        let originalFavorite = favorite.label
        favorite.tap()
        let changedFavorite = expectation(for: NSPredicate(format: "label != %@", originalFavorite), evaluatedWith: favorite)
        await fulfillment(of: [changedFavorite], timeout: 8)
        favorite.tap()
        let restoredFavorite = expectation(for: NSPredicate(format: "label == %@", originalFavorite), evaluatedWith: favorite)
        await fulfillment(of: [restoredFavorite], timeout: 8)
        for element in [app.staticTexts["detailTitle"], app.buttons["detailPlay"], app.buttons["favorite"], app.staticTexts["detailOverview"]] { assertHorizontalBounds(element) }
        snapshot("native-detail-cinematic")
        // Audio and subtitles share one compact menu with a submenu each.
        try await tap(app.buttons["detailTracks"])
        try await tap(app.reelMenuItem("Audio"))
        XCTAssertTrue(app.buttons["Server default"].waitForExistence(timeout: 4))
        app.buttons["Server default"].tap()
        try await tap(app.buttons["detailTracks"])
        try await tap(app.reelMenuItem("Subtitles"))
        XCTAssertTrue(app.buttons["Off"].waitForExistence(timeout: 4))
        app.buttons["Off"].tap()
        snapshot("native-detail-options")
    }

    func testConnectRecoveryAndDownloadsEntry() async throws {
        try await launch(authenticate: false)
        let username = app.textFields["username"]
        try await visible(username)
        XCTAssertFalse(app.buttons["connect"].isEnabled)
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "serverReachable").firstMatch.waitForExistence(timeout: 8))
        snapshot("native-connect")
        try await tap(app.buttons["advancedConnection"])
        XCTAssertTrue(app.navigationBars["Connection options"].waitForExistence(timeout: 8))
        app.navigationBars["Connection options"].buttons["Done"].tap()
        username.tap(); username.typeText(user); username.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        password.typeText("wrong"); password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 10))
        snapshot("native-connect-error")
        try await visible(password)
        password.tap(); password.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 5))
        password.typeText("demo"); password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        dismissPasswordPrompt()
        try await selectTab("Downloads")
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 8))
        snapshot("native-downloads-empty")
        try await tap(app.buttons["downloadsBrowseLibrary"])
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 8))
    }

    func testSeriesEpisodeDetailsAndDirectPlayback() async throws {
        try await launch()
        try await tap(app.buttons["home-Series"])
        try await tap(app.buttons["heroDetails"])
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
        let details = app.buttons["episode-episode-1-1"]
        try await tap(details)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
        XCTAssertEqual(app.staticTexts["detailTitle"].label, "A new beginning")
        app.navigationBars.buttons.element(boundBy: 0).tap()
        let play = app.buttons["episodePlay-episode-1-1"]
        try await visible(play)
        XCTAssertGreaterThanOrEqual(play.frame.width, 44)
        XCTAssertGreaterThanOrEqual(play.frame.height, 44)
        snapshot("native-series-episodes")
        let cursor = try await reports().count
        play.tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(30)
        var started = false
        repeat {
            started = try await reports().dropFirst(cursor).contains { report in
                report["path"] as? String == "/Sessions/Playing" && (report["body"] as? [String: Any])?["ItemId"] as? String == "episode-1-1"
            }
            if started { break }
            try await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        XCTAssertTrue(started, "Direct episode Play must start that episode, not just open the player.")
        let pause = app.reelPlaybackButton("transportPlayPause")
        try await visible(pause)
        if pause.label == "Pause" { pause.tap() }
        let timeline = app.sliders["scrubTimeline"]
        try await visible(timeline)
        timeline.adjust(toNormalizedSliderPosition: 0.4)
        app.reelPlaybackButton("closePlayer").tap()
        XCTAssertTrue(app.scrollViews["detailScroll"].waitForExistence(timeout: 8))
        try await visible(app.buttons["episodePlay-episode-1-1"])
        let refreshed = NSPredicate(format: "label BEGINSWITH 'Resume '")
        let refresh = expectation(for: refreshed, evaluatedWith: app.buttons["episodePlay-episode-1-1"])
        await fulfillment(of: [refresh], timeout: 10)
    }

    func testSeriesPrimaryActionPlaysAndResumesSelectedSeason() async throws {
        try await launch()
        // Fixture progress assertions need history enabled in this owned app.
        try await selectTab("More")
        try await tap(app.buttons["Settings"])
        let privacy = app.switches["privateViewing"]
        try await visible(privacy)
        if privacy.value as? String == "1" {
            let control = privacy.switches.firstMatch.exists ? privacy.switches.firstMatch : privacy
            control.tap()
            let enabledHistory = expectation(for: NSPredicate(format: "value == '0'"), evaluatedWith: privacy)
            await fulfillment(of: [enabledHistory], timeout: 5)
        }
        try await selectTab("Home")
        try await tap(app.buttons["home-Series"])
        try await tap(app.buttons["heroDetails"])
        let primary = app.buttons["seriesPlay"]
        try await visible(primary)
        let ready = expectation(for: NSPredicate(format: "enabled == true"), evaluatedWith: primary)
        await fulfillment(of: [ready], timeout: 10)
        XCTAssertTrue(primary.label.contains("S1 E1"))
        XCTAssertFalse(app.buttons["detailChapters"].exists)
        snapshot("native-series-primary-action")
        let cursor = try await reports().count
        primary.tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 15))
        let deadline = Date().addingTimeInterval(20)
        var started = false
        repeat {
            started = try await reports().dropFirst(cursor).contains {
                $0["path"] as? String == "/Sessions/Playing" && ($0["body"] as? [String: Any])?["ItemId"] as? String == "episode-1-1"
            }
            if started { break }
            try await Task.sleep(for: .milliseconds(200))
        } while Date() < deadline
        XCTAssertTrue(started)
        let pause = app.reelPlaybackButton("transportPlayPause")
        try await visible(pause)
        if pause.label == "Pause" { pause.tap() }
        let timeline = app.sliders["scrubTimeline"]
        try await visible(timeline)
        timeline.adjust(toNormalizedSliderPosition: 0.35)
        app.reelPlaybackButton("closePlayer").tap()
        try await visible(primary)
        let resumed = expectation(for: NSPredicate(format: "label BEGINSWITH 'Resume S1'"), evaluatedWith: primary)
        await fulfillment(of: [resumed], timeout: 10)
        try await tap(app.buttons["seasonPicker"])
        try await tap(app.buttons["Season 2"])
        try await visible(primary)
        let secondSeason = expectation(for: NSPredicate(format: "label CONTAINS 'S2 E1' AND enabled == true"), evaluatedWith: primary)
        await fulfillment(of: [secondSeason], timeout: 10)
        snapshot("native-series-selected-season-action")
    }

    func testContinueWatchingRefreshAndRecentLibraryRoutes() async throws {
        try await launch()
        try await tap(app.buttons["homeRefresh"])
        let ready = expectation(for: NSPredicate(format: "value == 'Ready'"), evaluatedWith: app.buttons["homeRefresh"])
        await fulfillment(of: [ready], timeout: 10)
        let resume = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'resume-'")).firstMatch
        try await visible(resume)
        snapshot("native-home-continue-watching")
        resume.tap()
        XCTAssertTrue(app.reelPlaybackButton("closePlayer").waitForExistence(timeout: 15))
        app.reelPlaybackButton("closePlayer").tap()
        XCTAssertTrue(app.scrollViews["homeScroll"].waitForExistence(timeout: 8))
        for category in ["Movies", "Episodes", "Series"] {
            try await tap(app.buttons["recent-\(category)-seeAll"])
            XCTAssertTrue(app.staticTexts["libraryCount"].waitForExistence(timeout: 8))
            XCTAssertTrue(app.buttons["librarySort"].label.contains(category == "Series" ? "Series added" : "Recently added"))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
    }

    func testLargestTextHomeAndDetailActionsRemainReachable() async throws {
        try await launch(largeText: true)
        XCTAssertTrue(app.buttons["home-For you"].isHittable)
        try await visible(app.buttons["heroDetails"])
        snapshot("native-home-largest-text")
        app.buttons["heroDetails"].tap()
        try await visible(app.buttons["detailPlay"])
        XCTAssertTrue(app.buttons["favorite"].exists)
        snapshot("native-detail-largest-text")
        try await visible(app.buttons["detailTracks"])
        snapshot("native-detail-options-largest-text")
    }

    func testLibraryControlsAndViewModes() async throws {
        try await launch()
        try await selectTab("Library")
        try await tap(app.buttons["filter-Movies"])
        try await tap(app.buttons["librarySort"])
        snapshot("native-library-sort-menu")
        let recent = app.buttons["Recently added"]
        XCTAssertTrue(recent.waitForExistence(timeout: 5))
        XCTAssertTrue(recent.isHittable)
        recent.tap()
        let sorted = expectation(for: NSPredicate(format: "label CONTAINS 'Recently added'"), evaluatedWith: app.buttons["librarySort"])
        await fulfillment(of: [sorted], timeout: 5)
        let direction = app.buttons["libraryDirection"]
        let previous = direction.value as? String
        try await tap(direction)
        let changedDirection = expectation(for: NSPredicate(format: "value != %@", previous ?? ""), evaluatedWith: direction)
        await fulfillment(of: [changedDirection], timeout: 5)
        let style = app.segmentedControls["libraryViewStyle"]
        XCTAssertTrue(style.waitForExistence(timeout: 5))
        for element in [app.buttons["librarySort"], direction, app.buttons["libraryFilters"], style] { assertHorizontalBounds(element) }
        style.buttons["List"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'libraryRowTitle-'")).firstMatch.waitForExistence(timeout: 8))
        snapshot("native-library-list")
        style.buttons["Grid"].tap()
        try await tap(app.buttons["libraryFilters"])
        try await tap(app.buttons["Drama"])
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].waitForExistence(timeout: 8))
        try await tap(app.buttons["libraryFilters"])
        try await tap(app.buttons["Clear filters"])
        snapshot("native-library-grid")
    }

    func testMoreDestinationsAndSettings() async throws {
        try await launch()
        try await selectTab("More")
        snapshot("native-more")
        let moreServers = app.buttons["servers"]
        XCTAssertFalse((moreServers.value as? String ?? "").isEmpty)
        try await tap(moreServers)
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 8))
        app.navigationBars["Servers"].buttons["Done"].tap()
        for (identifier, title) in [("Media", "Media"), ("Live TV", "Live TV"), ("Requests", "Requests"), ("Devices", "Players & watch together")] {
            try await tap(app.buttons[identifier])
            XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
            app.navigationBars.buttons.element(boundBy: 0).tap()
        }
        try await tap(app.buttons["Settings"])
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        snapshot("native-settings")
        try await tap(app.buttons["manageServers"])
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 8))
        app.navigationBars["Servers"].buttons["Done"].tap()
        let privacy = app.switches["privateViewing"]
        try await visible(privacy)
        let previous = privacy.value as? String
        let privacyControl = privacy.switches.firstMatch.exists ? privacy.switches.firstMatch : privacy
        privacyControl.tap()
        let changedPrivacy = expectation(for: NSPredicate(format: "value != %@", previous ?? "0"), evaluatedWith: privacy)
        await fulfillment(of: [changedPrivacy], timeout: 5)
        privacyControl.tap()
        let restoredPrivacy = expectation(for: NSPredicate(format: "value == %@", previous ?? "0"), evaluatedWith: privacy)
        await fulfillment(of: [restoredPrivacy], timeout: 5)
    }

    func testLandscapeHomeAndDetailBounds() async throws {
        try await launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        let landscape = expectation(for: NSPredicate { _, _ in
            let frame = self.app.windows.firstMatch.frame
            return frame.width > frame.height
        }, evaluatedWith: app)
        await fulfillment(of: [landscape], timeout: 8)
        try await Task.sleep(for: .milliseconds(700))
        defer { XCUIDevice.shared.orientation = .portrait }
        try await visible(app.buttons["heroDetails"])
        snapshot("native-home-landscape")
        app.buttons["heroDetails"].tap()
        try await visible(app.buttons["detailPlay"])
        for element in [app.staticTexts["detailTitle"], app.buttons["detailPlay"], app.buttons["favorite"], app.staticTexts["detailOverview"]] { assertHorizontalBounds(element) }
        snapshot("native-detail-landscape")
    }

    private func assertHorizontalBounds(_ element: XCUIElement) {
        XCTAssertTrue(element.exists)
        let viewport = activeWindow.frame
        XCTAssertGreaterThanOrEqual(element.frame.minX, viewport.minX, element.identifier)
        XCTAssertLessThanOrEqual(element.frame.maxX, viewport.maxX, element.identifier)
    }

    private var activeWindow: XCUIElement {
        app.windows.allElementsBoundByIndex.max { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height } ?? app.windows.firstMatch
    }
    private func selectTab(_ title: String) async throws {
        let tab = app.tabBars.buttons[title]
        if !tab.exists && !app.buttons[title].firstMatch.exists {
            let nextPage = app.buttons["Next Page"]
            if nextPage.exists { nextPage.tap() }
        }
        if !tab.exists && !app.buttons[title].firstMatch.exists {
            let sidebar = app.buttons["ToggleSideBar"]
            if sidebar.exists { sidebar.tap() }
        }
        try await tap(tab.exists ? tab : app.buttons[title].firstMatch)
    }
    private func dismissPasswordPrompt() {
        // iPhone presents a sheet; iPad presents an alert from the system credential UI.
        let dismiss = app.buttons["Not Now"].firstMatch
        guard dismiss.waitForExistence(timeout: 2) else { return }
        for _ in 0..<5 {
            if dismiss.isHittable { dismiss.tap(); XCTAssertTrue(dismiss.waitForNonExistence(timeout: 5)); return }
            let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save Password?")).firstMatch
            guard title.exists else { break }
            if app.sheets.firstMatch.exists { app.sheets.firstMatch.swipeUp() }
            else if app.alerts.firstMatch.exists { app.alerts.firstMatch.swipeUp() }
            else { app.swipeUp() }
        }
        XCTFail("The system Save Password prompt must be dismissed before exercising the app.")
    }
    private func visible(_ element: XCUIElement) async throws {
        for _ in 0..<12 {
            if app.alerts["Save Password?"].exists || app.sheets["Save Password?"].exists { dismissPasswordPrompt() }
            if element.waitForExistence(timeout: 1), element.isHittable { return }
            swipeContentUp()
            try await Task.sleep(for: .milliseconds(150))
        }
        snapshot("native-design-missing-control")
        XCTFail("Control not reachable\n\(app.debugDescription)")
        throw NSError(domain: "ReelNativePresentation", code: 1)
    }
    private func swipeContentUp() {
        let window = activeWindow
        if app.navigationBars["Playback options"].exists {
            let scroll = app.scrollViews.containing(.button, identifier: "transportPlayPause")
                .containing(.button, identifier: "playbackSpeed").firstMatch
            XCTAssertTrue(scroll.exists)
            let bounds = scroll.frame.intersection(window.frame)
            XCTAssertGreaterThan(bounds.width, 40)
            XCTAssertGreaterThan(bounds.height, 80)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.8))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.25)))
            return
        }
        let navigation = app.navigationBars.firstMatch
        let tabBar = app.tabBars.firstMatch
        let top = navigation.exists ? max(window.frame.minY, navigation.frame.maxY) : window.frame.minY
        let bottom = tabBar.exists ? min(window.frame.maxY, tabBar.frame.minY) : window.frame.maxY
        let height = max(44, bottom - top)
        let origin = window.coordinate(withNormalizedOffset: .zero)
        let start = origin.withOffset(CGVector(dx: window.frame.width * 0.6, dy: top - window.frame.minY + height * 0.8))
        let end = origin.withOffset(CGVector(dx: window.frame.width * 0.6, dy: top - window.frame.minY + height * 0.2))
        start.press(forDuration: 0.05, thenDragTo: end)
    }
    private func tap(_ element: XCUIElement) async throws { try await visible(element); element.tap() }
    private func snapshot(_ name: String) {
        let image = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }
    private func request(_ path: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(path)")!)
        request.setValue(owner, forHTTPHeaderField: "X-Reel-TV-Owner")
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func reports() async throws -> [[String: Any]] {
        let state = try await request("/qa/state")
        return try XCTUnwrap(state["reports"] as? [[String: Any]]).filter { $0["user"] as? String == user }
    }
}
