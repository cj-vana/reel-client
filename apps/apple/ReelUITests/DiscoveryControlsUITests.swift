import XCTest
import UIKit

@MainActor final class DiscoveryControlsUITests: XCTestCase {
    private enum Mode: String {
        case reply = "-reel-qa-discovery-loopback"
        case empty = "-reel-qa-discovery-empty"
        case unavailable = "-reel-qa-discovery-unavailable"
    }
    private var app: XCUIApplication!
    private let primary = "http://127.0.0.1:18766"
    private let secondary = "http://127.0.0.1:18767"

    override func tearDown() async throws {
        #if targetEnvironment(simulator)
        if app != nil {
            if app.buttons["heroPlay"].exists || app.navigationBars["Settings"].exists {
                settings()
                let privacy = app.switches["privateViewing"].firstMatch
                reveal(privacy)
                if privacy.value as? String == "1" { setSwitch("privateViewing", false) }
            }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        #endif
    }

    private func launch(_ mode: Mode = .reply, initialServer: String? = nil, accessibilityText: Bool = false, requiresDeniedLocalNetwork: Bool = false) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Discovery QA resets and fixture accounts run only on disposable simulators.")
        #else
        if requiresDeniedLocalNetwork {
            guard ProcessInfo.processInfo.environment["REEL_QA_LOCAL_NETWORK_DENIED"] == "1" else {
                throw XCTSkip("The QA owner must verify denied Local Network access before enabling native receiver-picker tests; these tests never select a receiver.")
            }
        }
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset", mode.rawValue]
        if accessibilityText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = initialServer ?? primary
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
        #endif
    }

    private func reveal(_ element: XCUIElement, down: Bool = false) {
        for direction in [down, !down] {
            for _ in 0..<7 {
                if element.exists && element.isHittable { return }
                if direction { app.swipeDown() } else { app.swipeUp() }
            }
        }
    }

    private func button(_ id: String) -> XCUIElement {
        app.prepareReelPlayerControl(id)
        if id == "groupControls" { app.revealReelPlayerChrome() }
        return app.buttons.matching(identifier: id).allElementsBoundByIndex.first(where: { $0.isHittable }) ?? app.buttons[id].firstMatch
    }

    private func revealCompleteDiscoveryButton() {
        for _ in 0..<12 {
            let target = button("discoverServers")
            guard target.exists else { reveal(target); return }
            let window = app.windows.firstMatch.frame
            let containers = app.collectionViews.allElementsBoundByIndex.filter {
                $0.buttons.matching(identifier: "discoverServers").count > 0
            }
            guard let container = containers.last else { reveal(target); return }
            var visible = container.frame.intersection(window)
            for bar in app.navigationBars.allElementsBoundByIndex where bar.frame.intersects(visible)
                && (bar.isHittable || bar.buttons.allElementsBoundByIndex.contains { $0.isHittable }) {
                let bottom = visible.maxY
                visible.origin.y = max(visible.minY, bar.frame.maxY + 8)
                visible.size.height = max(0, bottom - visible.minY)
            }
            visible.size.height = max(0, min(visible.maxY, window.maxY - 24) - visible.minY)
            for input in app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex
                where input.frame.height > 60 && input.frame.minY > visible.minY && input.frame.minY < visible.maxY {
                visible.size.height = input.frame.minY - visible.minY - 8
            }
            guard visible.width > 40 && visible.height > 80 else { return }
            let frame = target.frame
            if frame.minY > visible.minY + 8 && frame.maxY < visible.maxY - 8 && target.isHittable { return }
            let fingerDown = frame.minY <= visible.minY + 8
            let origin = app.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * (fingerDown ? 0.25 : 0.8)))
            let end = origin.withOffset(CGVector(dx: visible.midX, dy: visible.minY + visible.height * (fingerDown ? 0.65 : 0.4)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    private func tap(_ id: String, down: Bool = false) {
        if id == "discoverServers" { revealCompleteDiscoveryButton() }
        else { reveal(button(id), down: down) }
        let target = button(id)
        XCTAssertTrue(target.waitForExistence(timeout: 8), "Missing \(id)")
        XCTAssertTrue(target.isHittable, "Unreachable \(id)")
        if id == "discoverServers" {
            let window = app.windows.firstMatch.frame
            XCTAssertGreaterThan(target.frame.minY, window.minY + 8)
            XCTAssertLessThan(target.frame.maxY, window.maxY - 24, "The complete Find caption must be above the home indicator")
            for bar in app.navigationBars.allElementsBoundByIndex where bar.frame.intersects(window)
                && (bar.isHittable || bar.buttons.allElementsBoundByIndex.contains { $0.isHittable }) {
                XCTAssertFalse(target.frame.intersects(bar.frame), "Find must be clear of the active navigation bar")
            }
            for input in app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex where input.frame.height > 60 {
                XCTAssertLessThan(target.frame.maxY, input.frame.minY - 8, "The complete Find caption must be above the active keyboard")
            }
        }
        target.tap()
    }

    private func replace(_ field: XCUIElement, _ value: String) {
        reveal(field); XCTAssertTrue(field.waitForExistence(timeout: 8)); field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty, existing != field.placeholderValue {
            field.press(forDuration: 1)
            if app.menuItems["Select All"].waitForExistence(timeout: 1) { app.menuItems["Select All"].tap() }
            else if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
            else { field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 180)) }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        if !value.isEmpty { field.typeText(value) }
    }

    private func wait(_ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval = 8) {
        expectation(for: predicate, evaluatedWith: element)
        waitForExpectations(timeout: timeout)
    }

    private func advanced() throws {
        tap("advancedConnection")
        XCTAssertTrue(app.navigationBars["Connection options"].waitForExistence(timeout: 8))
        let marker = app.staticTexts["discoveryLoopbackOnly"]
        reveal(marker)
        // Assert the compiled routing scope before Find can send any packet.
        _ = try XCTUnwrap(marker.waitForExistence(timeout: 8) ? marker : nil, "This build lacks the required loopback-only discovery configuration")
    }

    private func login(_ user: String) {
        replace(app.textFields["username"], user)
        let password = app.secureTextFields["password"]
        replace(password, "demo")
        password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
    }

    private func settings() {
        if app.navigationBars["Settings"].exists { return }
        destination("Settings", title: "Settings")
    }

    private func destination(_ name: String, title: String) {
        let more = app.buttons["ellipsis.circle"].firstMatch
        if !more.exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        if !app.navigationBars["More"].waitForExistence(timeout: 2) { more.tap() }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 8)); tap(name)
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
    }

    private func setSwitch(_ id: String, _ enabled: Bool) {
        let element = app.switches[id].firstMatch
        reveal(element); XCTAssertTrue(element.waitForExistence(timeout: 8))
        if (element.value as? String == "1") != enabled {
            if element.switches.firstMatch.exists { element.switches.firstMatch.tap() } else { element.tap() }
        }
        wait(element, NSPredicate(format: "value == %@", enabled ? "1" : "0"))
    }

    private func prepareLocalPlayer(_ user: String) throws {
        try advanced()
        for _ in 0..<20 {
            let remove = app.buttons["Remove gateway header"].firstMatch
            if !remove.exists { break }
            reveal(remove); remove.tap()
        }
        tap("saveGatewayHeaders"); tap("Done", down: true)
        login(user); settings(); setSwitch("privateViewing", false); setSwitch("useServerPreferences", false)
        tap("qualityPicker", down: true); tap("Original / auto"); tap("Home"); tap("heroPlay")
        openPlayerOptions()
        if button("transportPlayPause").label == "Pause" { tap("transportPlayPause", down: true) }
        wait(button("transportPlayPause"), NSPredicate(format: "label == %@", "Play"))
    }

    private func openPlayerOptions() {
        if !app.navigationBars["Playback options"].exists { tap("playbackOptions", down: true) }
        XCTAssertTrue(app.navigationBars["Playback options"].waitForExistence(timeout: 8))
        let transport = button("transportPlayPause")
        reveal(transport, down: true); XCTAssertTrue(transport.waitForExistence(timeout: 12))
        wait(transport, NSPredicate(format: "enabled == true"), timeout: 25)
    }

    private func closePlayer() {
        if app.navigationBars["Playback options"].exists { tap("Done", down: true) }
        tap("closePlayer", down: true)
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 10))
    }

    private func stopCount(_ user: String) async throws -> Int {
        let (data, response) = try await URLSession.shared.data(from: URL(string: primary + "/qa/state")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (state["reports"] as? [[String: Any]] ?? []).filter { $0["user"] as? String == user && $0["path"] as? String == "/Sessions/Playing/Stopped" }.count
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    func testFindLoopbackServerSelectAndSignIn() throws {
        try launch(.reply, initialServer: secondary); try advanced(); tap("discoverServers")
        let server = app.buttons["discovered-fixture-discovery"]
        XCTAssertTrue(server.waitForExistence(timeout: 8)); tap("discovered-fixture-discovery")
        XCTAssertEqual(app.textFields["advancedServer"].value as? String, primary)
        XCTAssertFalse(app.buttons["stopDiscovery"].exists)
        tap("Done", down: true)
        XCTAssertEqual(app.textFields["server"].value as? String, primary)
        login("discovered-login-" + UUID().uuidString)
        XCTAssertEqual(app.buttons["servers"].label, "Servers")
        XCTAssertTrue((app.buttons["servers"].value as? String ?? "").contains("Reel Test Library"))
    }

    func testStopClearsSearchingAndFindCanRestart() throws {
        try launch(); try advanced(); tap("discoverServers")
        XCTAssertTrue(app.staticTexts["discoverySearching"].waitForExistence(timeout: 3))
        let stop = app.buttons["stopDiscovery"]
        XCTAssertTrue(stop.waitForExistence(timeout: 3)); XCTAssertTrue(stop.isHittable); stop.tap()
        wait(app.staticTexts["discoverySearching"], NSPredicate(format: "exists == false"))
        XCTAssertTrue(app.buttons["discoverServers"].exists)
        tap("discoverServers")
        XCTAssertTrue(app.buttons["discovered-fixture-discovery"].waitForExistence(timeout: 8))
        tap("discovered-fixture-discovery")
        XCTAssertEqual(app.textFields["advancedServer"].value as? String, primary)
        attach("native-discovery-stop-and-restart")
    }

    func testEmptyDiscoveryReachesManualAddressRecovery() throws {
        try launch(.empty); try advanced(); tap("discoverServers")
        XCTAssertTrue(app.staticTexts["discoveryEmpty"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["discovered-fixture-discovery"].exists)
        XCTAssertTrue(app.buttons["discoverServers"].exists)
        replace(app.textFields["advancedServer"], primary); tap("Done", down: true)
        login("discovery-empty-recovery-" + UUID().uuidString)
    }

    func testUnavailableDiscoveryRemainsRecoverableByManualSignIn() throws {
        try launch(.unavailable); try advanced(); tap("discoverServers")
        XCTAssertTrue(app.staticTexts["discoveryError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["discoveryError"].label.contains("Discovery couldn’t use the local network"))
        XCTAssertFalse(app.buttons["stopDiscovery"].exists)
        tap("discoverServers")
        XCTAssertTrue(app.staticTexts["discoveryError"].exists)
        XCTAssertFalse(app.buttons["discovered-fixture-discovery"].exists)
        tap("Done", down: true)
        app.terminate(); app.launchArguments = [Mode.reply.rawValue]; app.launch()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10)); try advanced(); tap("discoverServers")
        XCTAssertTrue(app.buttons["discovered-fixture-discovery"].waitForExistence(timeout: 8))
        tap("discovered-fixture-discovery"); tap("Done", down: true)
        login("discovery-error-recovery-" + UUID().uuidString)
    }

    func testDismissAndRelaunchDiscardDiscoveryState() throws {
        try launch(); try advanced(); tap("discoverServers"); tap("Done", down: true)
        try advanced()
        XCTAssertFalse(app.buttons["stopDiscovery"].exists)
        XCTAssertFalse(app.buttons["discovered-fixture-discovery"].exists)
        tap("discoverServers")
        XCTAssertTrue(app.buttons["discovered-fixture-discovery"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments = [Mode.reply.rawValue]; app.launch()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10)); try advanced()
        XCTAssertFalse(app.buttons["stopDiscovery"].exists)
        XCTAssertFalse(app.buttons["discovered-fixture-discovery"].exists)
        tap("discoverServers")
        XCTAssertTrue(app.buttons["discovered-fixture-discovery"].waitForExistence(timeout: 8))
        tap("discovered-fixture-discovery"); tap("Done", down: true)
    }

    func testDiscoveryLargeTextAndRotationControlsRemainActionable() throws {
        try launch(.reply, accessibilityText: true); try advanced()
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            revealCompleteDiscoveryButton()
            attach("native-discovery-complete-large-find")
            tap("discoverServers")
            XCTAssertTrue(app.buttons["discovered-fixture-discovery"].waitForExistence(timeout: 8))
            tap("discovered-fixture-discovery")
            XCTAssertEqual(app.textFields["advancedServer"].value as? String, primary)
            XCTAssertFalse(app.buttons["stopDiscovery"].exists)
        }
        attach("native-discovery-large-text-rotation"); tap("Done", down: true)
        login("discovery-large-text-" + UUID().uuidString)
    }

    func testAirPlayPickerOpensAndCancelsWithoutChangingPlayback() async throws {
        try launch(requiresDeniedLocalNetwork: true)
        let user = "airplay-picker-" + UUID().uuidString
        try prepareLocalPlayer(user)
        let before = try await stopCount(user)
        let route = app.descendants(matching: .any).matching(identifier: "airPlayRoute").firstMatch
        XCTAssertFalse(app.buttons["castCurrentTitle"].exists)
        XCTAssertFalse(app.buttons["stopCasting"].exists)
        reveal(route); XCTAssertTrue(route.waitForExistence(timeout: 8)); route.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let title = NSPredicate(format: "label == 'AirPlay' OR label == 'Speakers & TVs' OR label == 'Audio Output'")
        let appTitle = app.staticTexts.matching(title).firstMatch
        let systemTitle = springboard.staticTexts.matching(title).firstMatch
        XCTAssertTrue(appTitle.waitForExistence(timeout: 5) || systemTitle.waitForExistence(timeout: 5), "Native AirPlay picker did not open")
        attach("native-airplay-picker-denied-network")
        dismissNativePicker(springboard: springboard)
        XCTAssertTrue(app.navigationBars["Playback options"].waitForExistence(timeout: 8))
        XCTAssertEqual(button("transportPlayPause").label, "Play")
        let after = try await stopCount(user)
        XCTAssertEqual(after, before, "Opening/cancelling AirPlay must preserve local playback")
        XCTAssertFalse(app.buttons["stopCasting"].exists); closePlayer()
    }

    func testCastPickerOpensAndCancelsWithNoReceiver() async throws {
        try launch(requiresDeniedLocalNetwork: true)
        let user = "cast-picker-" + UUID().uuidString
        try prepareLocalPlayer(user)
        let before = try await stopCount(user)
        let route = app.descendants(matching: .any).matching(identifier: "googleCastRoute").firstMatch
        XCTAssertFalse(app.buttons["castCurrentTitle"].exists)
        XCTAssertFalse(app.buttons["stopCasting"].exists)
        reveal(route); XCTAssertTrue(route.waitForExistence(timeout: 8)); route.tap()
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let heading = NSPredicate(format: "label == 'Cast to' OR label == 'Connect to a device' OR label == 'Connect to device' OR label == 'No devices found' OR label == 'No Cast devices found'")
        XCTAssertTrue(app.staticTexts.matching(heading).firstMatch.waitForExistence(timeout: 8), "Native Google Cast dialog did not open")
        XCTAssertFalse(app.buttons["castCurrentTitle"].exists)
        XCTAssertFalse(app.buttons["stopCasting"].exists)
        attach("native-cast-picker-no-receiver-denied-network")
        dismissNativePicker(springboard: springboard)
        XCTAssertTrue(app.navigationBars["Playback options"].waitForExistence(timeout: 8))
        XCTAssertEqual(button("transportPlayPause").label, "Play")
        let after = try await stopCount(user)
        XCTAssertEqual(after, before, "Opening/cancelling Cast must preserve local playback")
        closePlayer()
    }

    private func dismissNativePicker(springboard: XCUIApplication) {
        let candidates = [app.buttons["Close"], springboard.buttons["Close"], app.buttons["Cancel"], springboard.buttons["Cancel"], springboard.buttons["Done"]]
        if let close = candidates.first(where: { $0.exists && $0.isHittable }) { close.tap(); return }
        let popover = app.otherElements["PopoverDismissRegion"]
        if popover.exists && popover.isHittable { popover.tap(); return }
        XCTFail("Native picker exposes no safe close/cancel control; no receiver was selected")
    }

    func testGroupPlaybackHidesIndependentReceiverControls() throws {
        try launch(initialServer: "http://127.0.0.1:18769")
        login("group-receiver-lock-" + UUID().uuidString)
        settings(); setSwitch("privateViewing", false)
        destination("Devices", title: "Players & watch together"); tap("syncJoin-fixture-group")
        XCTAssertTrue(app.buttons["groupControls"].waitForExistence(timeout: 15)); openPlayerOptions()
        reveal(button("sleepTimer"))
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "airPlayRoute").firstMatch.exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "googleCastRoute").firstMatch.exists)
        XCTAssertFalse(app.buttons["castCurrentTitle"].exists)
        tap("Done", down: true); tap("groupControls", down: true)
        XCTAssertTrue(app.navigationBars["Players & watch together"].waitForExistence(timeout: 8)); tap("syncLeave")
        XCTAssertTrue(app.buttons["syncJoin-fixture-group"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["groupControls"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists, "Leaving the group must close local video playback.")
        tap("Home"); XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 10))
    }
}
