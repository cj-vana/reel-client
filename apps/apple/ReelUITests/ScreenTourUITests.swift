import XCTest
import UIKit

/// Walks the key screens against a local fixture server so a host script can
/// capture each one with `xcrun simctl io <device> screenshot`.
///
/// Runs only when the test runner receives `REEL_TOUR_DIR` (pass
/// `TEST_RUNNER_REEL_TOUR_DIR=<folder>` to xcodebuild). At each screen the test
/// writes `<folder>/<name>.request` and waits for the host to answer with
/// `<folder>/<name>.png`. Optional: `REEL_TOUR_SERVER` (a loopback fixture URL),
/// `REEL_TOUR_ORIENTATION` (`portrait` or `landscape`) and `REEL_TOUR_SEARCH`.
@MainActor final class ScreenTourUITests: XCTestCase {
    private let app = XCUIApplication()
    private var folder: URL!
    private var server = "http://127.0.0.1:18766"
    private var searchText = "Quiet"
    /// Set by `REEL_TOUR_ORIENTATION`; otherwise chosen after launch from the window's size class.
    private var requestedOrientation: UIDeviceOrientation?
    private var orientation = UIDeviceOrientation.portrait
    /// A regular-width window (iPad, an open foldable iPhone) gets the tablet tour. The idiom
    /// can't tell: a foldable iPhone reports the phone idiom on both of its screens.
    private var regularWidth: Bool { app.windows.firstMatch.horizontalSizeClass == .regular }

    override func setUp() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The screen tour resets accounts and runs only on disposable simulators.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["REEL_TOUR_DIR"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_REEL_TOUR_DIR to capture the screen tour.")
        }
        folder = URL(fileURLWithPath: path, isDirectory: true)
        if let value = environment["REEL_TOUR_SERVER"], !value.isEmpty { server = value }
        if let value = environment["REEL_TOUR_SEARCH"], !value.isEmpty { searchText = value }
        switch environment["REEL_TOUR_ORIENTATION"] {
        case "portrait": requestedOrientation = .portrait
        case "landscape": requestedOrientation = .landscapeLeft
        default: requestedOrientation = nil
        }
        continueAfterFailure = false
        #endif
    }

    override func tearDown() async throws {
        app.terminate()
        XCUIDevice.shared.orientation = .portrait
        try await super.tearDown()
    }

    func testCaptureKeyScreens() throws {
        XCUIDevice.shared.orientation = .portrait
        launch(reset: true)
        let username = app.textFields["username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        orientation = requestedOrientation ?? (regularWidth ? .landscapeLeft : .portrait)
        if orientation != .portrait { XCUIDevice.shared.orientation = orientation; settle(2) }
        capture("connect")
        username.tap(); username.typeText("tour-" + UUID().uuidString.prefix(8))
        username.typeText(XCUIKeyboardKey.return.rawValue)
        app.secureTextFields["password"].typeText("demo")
        app.secureTextFields["password"].typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        dismissPasswordPrompt()
        settle(2)
        capture("home")
        app.buttons["home-Series"].tap()
        settle()
        capture("home-series-first")
        XCTAssertTrue(app.buttons["home-Series"].isSelected, "Tapping a Home category must select it.")
        app.buttons["home-For you"].tap()
        settle()
        app.scrollViews["homeScroll"].swipeUp()
        settle()
        capture("home-rows")
        app.scrollViews["homeScroll"].swipeDown()

        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 10))
        settle(2)
        capture("detail-movie")
        let tracks = app.buttons["detailTracks"]
        if tracks.exists && tracks.isHittable {
            tracks.tap(); settle(1)
            capture("detail-movie-tracks")
            app.reelMenuItem("Subtitles").tap(); settle(1)
            capture("detail-movie-subtitles")
            dismissMenu()
        }
        let more = app.buttons["detailMore"]
        if more.waitForExistence(timeout: 3) {
            more.tap(); settle(1)
            capture("detail-movie-more")
            dismissMenu()
        }
        app.scrollViews["detailScroll"].swipeUp()
        settle()
        capture("detail-movie-scrolled")
        goBack()

        let series = app.buttons["home-Series"]
        XCTAssertTrue(series.waitForExistence(timeout: 8))
        settle()
        series.tap()
        settle()
        capture("home-series")
        XCTAssertTrue(series.isSelected, "Series must be the selected Home category.\n\(app.debugDescription)")
        app.buttons["heroDetails"].tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 10))
        settle(2)
        capture("detail-series")
        app.scrollViews["detailScroll"].swipeUp()
        settle()
        capture("detail-series-episodes")

        let play = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "episodePlay-")).firstMatch
        XCTAssertTrue(play.waitForExistence(timeout: 10), "The series must list episodes.")
        for _ in 0..<6 {
            if play.isHittable { break }
            app.scrollViews["detailScroll"].swipeUp()
        }
        // Read before the player covers the tab view; a compact window turns the phone sideways for video.
        let turnForVideo = !regularWidth
        play.tap()
        XCTAssertTrue(app.buttons["closePlayer"].waitForExistence(timeout: 15))
        if turnForVideo { XCUIDevice.shared.orientation = .landscapeLeft }
        settle(3)
        capture("player-skip")
        // Reel draws the player's only controls: one close button, its own transport and timeline.
        app.revealReelPlayerChrome()
        XCTAssertEqual(app.buttons.matching(identifier: "closePlayer").count, 1, "The player must show one close button.")
        let playPause = app.buttons["playerPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5))
        if playPause.label == "Pause" { playPause.tap() }
        settle(1)
        capture("player-controls")
        app.buttons["playbackOptions"].tap()
        XCTAssertTrue(app.navigationBars["Playback options"].waitForExistence(timeout: 5))
        settle(1)
        capture("player-options")
        app.navigationBars["Playback options"].buttons["Done"].tap()
        settle(1)
        // While video plays the controls fade; a tap on the picture shows them and a second tap hides them.
        // Back to the start first: the fixture clips are short enough to end during these checks.
        app.revealReelPlayerChrome()
        app.buttons["playerSkipBack"].tap()
        if playPause.label == "Play" { playPause.tap() }
        let options = app.buttons["playbackOptions"]
        XCTAssertTrue(options.waitForNonExistence(timeout: 8), "Controls must fade while video plays.")
        capture("player")
        let picture = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
        XCTAssertTrue(options.waitForExistence(timeout: 3), "A tap on the picture must show the controls.")
        capture("player-playing-controls")
        picture.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
        XCTAssertTrue(options.waitForNonExistence(timeout: 3), "A second tap on the picture must hide the controls.")
        let episodes = app.buttons["playerEpisodes"]
        app.revealReelPlayerChrome()
        if episodes.exists {
            episodes.tap()
            XCTAssertTrue(app.buttons["closePlayerEpisodes"].waitForExistence(timeout: 8))
            settle(2)
            capture("player-episodes")
            app.buttons["closePlayerEpisodes"].tap()
            settle()
        }
        app.reelPlaybackButton("closePlayer").tap()
        XCUIDevice.shared.orientation = orientation
        settle()

        open("Library")
        XCTAssertTrue(app.scrollViews["libraryScroll"].waitForExistence(timeout: 10))
        settle(2)
        capture("library")
        open("Search")
        let field = app.searchFields.firstMatch
        if field.waitForExistence(timeout: 5) {
            field.tap(); field.typeText(searchText)
            settle(2)
            capture("search")
            field.typeText(XCUIKeyboardKey.return.rawValue)
            settle()
            capture("search-results")
            let close = app.buttons["Close"].firstMatch
            if close.exists { close.tap() }
            settle()
        }
        open("Downloads")
        settle()
        capture("downloads")
        // The iPad sidebar lists More's destinations itself, so only the tab bar has a More screen.
        if !app.otherElements["reelSidebar"].exists {
            open("More")
            settle()
            capture("more")
        }
        let settings = app.buttons["Settings"].firstMatch
        if settings.waitForExistence(timeout: 5) {
            settings.tap(); settle()
            capture("settings")
        }

        app.terminate()
        launch(reset: false, largeText: true)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        settle(2)
        capture("home-large-text")
        let details = app.buttons["heroDetails"]
        for _ in 0..<8 where !details.isHittable { app.scrollViews["homeScroll"].swipeUp() }
        details.tap()
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 10))
        settle(2)
        capture("detail-large-text")
        app.scrollViews["detailScroll"].swipeUp()
        settle()
        capture("detail-large-text-scrolled")
    }

    private func launch(reset: Bool, largeText: Bool = false) {
        app.launchArguments = reset ? ["-reel-qa-reset"] : []
        app.launchArguments += ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = server
        app.launch()
    }

    /// Opens a root section from the tab bar, Reel's iPad sidebar (buttons), or the system sidebar
    /// a narrow iPad or a foldable can still show (cells).
    private func open(_ root: String) {
        var candidates = [app.buttons[root].firstMatch, app.cells.matching(NSPredicate(format: "label == %@", root)).firstMatch]
        if root == "More" { candidates.insert(app.buttons["ellipsis.circle"].firstMatch, at: 0) }
        if !candidates.contains(where: \.exists), app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        guard let button = candidates.first(where: \.exists) else { return XCTFail("Missing root: \(root)\n\(app.debugDescription)") }
        button.tap()
    }

    private func goBack() {
        let back = app.buttons["BackButton"].firstMatch
        if back.exists { back.tap() } else { app.navigationBars.buttons.element(boundBy: 0).tap() }
        settle()
    }

    /// Closes an open menu by tapping the empty band at the top of the screen.
    private func dismissMenu() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.08)).tap()
        settle(1)
    }

    /// The system offers to save the fixture password a few seconds after sign-in.
    private func dismissPasswordPrompt(timeout: TimeInterval = 8) {
        let decline = app.buttons["Not Now"].firstMatch
        guard decline.waitForExistence(timeout: timeout) else { return }
        if decline.isHittable { decline.tap() }
        _ = decline.waitForNonExistence(timeout: 5)
    }

    private func settle(_ seconds: TimeInterval = 1) { Thread.sleep(forTimeInterval: seconds) }

    /// Asks the host for a simulator screenshot and waits until it lands.
    private func capture(_ name: String) {
        if app.buttons["Not Now"].firstMatch.exists { dismissPasswordPrompt(timeout: 1) }
        let request = folder.appendingPathComponent(name + ".request")
        let image = folder.appendingPathComponent(name + ".png")
        try? FileManager.default.removeItem(at: image)
        XCTAssertNoThrow(try Data(name.utf8).write(to: request))
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: image.path) && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "The host did not capture \(name).")
    }
}

/// Opens one screen on a simulator that is already signed in and keeps the app there, so a
/// person can fold or open a foldable simulator in Device Hub and capture both displays.
///
/// Runs only when the test runner receives `REEL_HOLD_SCREEN` (pass
/// `TEST_RUNNER_REEL_HOLD_SCREEN=home|movie|series|player|library|search` to xcodebuild). The
/// hold ends when the file named by `REEL_HOLD_RELEASE` exists, or after 30 minutes. The player is
/// paused a moment after it starts, so a short clip doesn't end while the device is being folded.
/// `REEL_HOLD_TEXT=largest` opens the screen at the largest accessibility text size.
@MainActor final class HoldScreenUITests: XCTestCase {
    func testHoldScreen() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The hold runs only on simulators.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let screen = environment["REEL_HOLD_SCREEN"], !screen.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_REEL_HOLD_SCREEN to hold a screen open.")
        }
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["-AppleLanguages", "(en)", "-AppleLocale", "en_US"]
        if environment["REEL_HOLD_TEXT"] == "largest" {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        // REEL_HOLD_ORIENTATION turns the simulator first, for an iPad's other layout.
        switch environment["REEL_HOLD_ORIENTATION"] {
        case "landscape": XCUIDevice.shared.orientation = .landscapeLeft
        case "portrait": XCUIDevice.shared.orientation = .portrait
        default: break
        }
        app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20), "Sign this simulator in to a library first.")
        switch screen {
        case "home":
            break
        case "movie", "series":
            app.buttons[screen == "movie" ? "home-Movies" : "home-Series"].tap()
            app.buttons["heroDetails"].tap()
            XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 10))
        case "player":
            app.buttons["home-Movies"].tap()
            app.buttons["heroPlay"].tap()
            let playPause = app.buttons["playerPlayPause"]
            XCTAssertTrue(playPause.waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 3)
            app.revealReelPlayerChrome()
            if playPause.label == "Pause" { playPause.tap() }
        case "library", "search":
            // A tab bar button, or a cell in the iPad sidebar.
            let root = screen == "library" ? "Library" : "Search"
            let cell = app.cells.matching(NSPredicate(format: "label == %@", root)).firstMatch
            if cell.exists { cell.tap() } else { app.buttons[root].firstMatch.tap() }
            XCTAssertTrue(app.scrollViews["libraryScroll"].waitForExistence(timeout: 10))
        default:
            XCTFail("Unknown screen \(screen); use home, movie, series, player, library or search.")
        }
        let release = environment["REEL_HOLD_RELEASE"].map { URL(fileURLWithPath: $0) }
        let deadline = Date().addingTimeInterval(30 * 60)
        while Date() < deadline {
            if let release, FileManager.default.fileExists(atPath: release.path) { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        #endif
    }
}
