import XCTest
import UIKit

@MainActor final class RemoteRequestsExtendedUITests: XCTestCase {
    private var app: XCUIApplication!
    private let remoteOrigin = "http://127.0.0.1:18769"
    private let seerrOrigin = "http://127.0.0.1:18768"
    private var remoteModeUsers: Set<String> = []
    private var seerrModeUsers: Set<String> = []

    override func setUp() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Account-reset UI tests use disposable simulators and loopback fixtures only.")
        #else
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launchEnvironment["REEL_QA_SEERR_SERVER"] = seerrOrigin
        app.launch()
        #endif
    }

    override func tearDown() async throws {
        app?.terminate()
        for user in remoteModeUsers { _ = try await fixture(remoteOrigin, "/qa/remote-control", method: "POST", body: ["reset": true], user: user) }
        for user in seerrModeUsers { _ = try await fixture(seerrOrigin, "/api/v1/qa/control", method: "POST", body: ["user": user, "reset": true]) }
    }

    private func foregroundNavigationBar() -> XCUIElement? {
        app.navigationBars.allElementsBoundByIndex.last { $0.exists && $0.isHittable }
    }

    private func clearsNavigation(_ element: XCUIElement) -> Bool {
        guard let navigation = foregroundNavigationBar() else { return true }
        let descendants = navigation.descendants(matching: element.elementType)
            .matching(NSPredicate(format: "identifier == %@ AND label == %@", element.identifier, element.label))
        let belongsToNavigation = descendants.allElementsBoundByIndex.contains { $0.frame == element.frame }
        return belongsToNavigation || element.frame.minY >= navigation.frame.maxY
    }

    private func inputOcclusions() -> [CGRect] {
        let window = app.windows.firstMatch.frame
        let keyboards = app.keyboards.allElementsBoundByIndex.map { $0.frame }
        let assistants = app.otherElements.matching(identifier: "SystemInputAssistantView").allElementsBoundByIndex.map { $0.frame }
        return (keyboards + assistants).filter { !$0.isEmpty && !$0.isNull && $0.intersects(window) }
    }

    private func reachable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable, !element.frame.isEmpty,
              app.windows.firstMatch.frame.contains(element.frame), clearsNavigation(element) else { return false }
        return !inputOcclusions().contains { element.frame.intersects($0) }
    }

    private func reveal(_ element: XCUIElement, down: Bool = false) {
        for _ in 0..<10 {
            if reachable(element) { return }
            let occlusions = inputOcclusions()
            let surface = app.collectionViews.allElementsBoundByIndex.first { $0.isHittable }
                ?? app.scrollViews.allElementsBoundByIndex.first { $0.isHittable }
            if !occlusions.isEmpty, let surface {
                let visible = surface.frame.intersection(app.windows.firstMatch.frame)
                XCTAssertFalse(visible.isNull || visible.isEmpty, app.debugDescription)
                let top = max(visible.minY, foregroundNavigationBar()?.frame.maxY ?? visible.minY) + 24
                let bottom = min(visible.maxY, occlusions.map(\.minY).min() ?? visible.maxY) - 24
                XCTAssertGreaterThan(bottom - top, 80, app.debugDescription)
                let upper = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: top))
                let lower = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: visible.midX, dy: bottom))
                if down { upper.press(forDuration: 0.05, thenDragTo: lower) }
                else { lower.press(forDuration: 0.05, thenDragTo: upper) }
            } else if down { app.swipeDown() } else { app.swipeUp() }
        }
    }

    /// Remote playback lives in the Details "More" menu.
    private func openRemotePlayback() {
        tap("detailMore")
        XCTAssertTrue(app.buttons["remotePlayback"].waitForExistence(timeout: 5))
        tap("remotePlayback")
    }

    private func tap(_ id: String, down: Bool = false) {
        app.prepareReelPlayerControl(id)
        if id == "groupControls" {
            // Player controls hide four seconds after they appear. Let a running reveal finish, then
            // tap the picture so the checks below get a full reveal. Paused or managed-sheet states
            // keep the controls up, so the wait simply ends at its timeout there.
            // They sit on the picture, so the scrolling reveal below never applies to them.
            _ = app.buttons["playbackOptions"].waitForNonExistence(timeout: 6)
            app.revealReelPlayerChrome()
            let control = app.buttons[id].firstMatch
            XCTAssertTrue(control.waitForExistence(timeout: 3), "Missing control: \(id)\n\(app.debugDescription)")
            XCTAssertTrue(control.isEnabled, "Disabled control: \(id)\n\(app.debugDescription)")
            XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame), "Control outside app window: \(id)\n\(app.debugDescription)")
            XCTAssertTrue(clearsNavigation(control), "Navigation bar covers content control: \(id)\n\(app.debugDescription)")
            XCTAssertFalse(inputOcclusions().contains { control.frame.intersects($0) }, "Keyboard or input assistant covers control: \(id)\n\(app.debugDescription)")
            XCTAssertTrue(control.isHittable, "Unreachable control: \(id)\n\(app.debugDescription)")
            control.tap()
            return
        }
        let button = app.buttons[id].firstMatch
        reveal(button, down: down)
        XCTAssertTrue(button.waitForExistence(timeout: 8), "Missing control: \(id)\n\(app.debugDescription)")
        waitFor(button, enabled: true)
        reveal(button, down: down)
        XCTAssertTrue(button.exists, "Missing control after scrolling: \(id)\n\(app.debugDescription)")
        XCTAssertTrue(button.isEnabled, "Disabled control after scrolling: \(id)\n\(app.debugDescription)")
        XCTAssertTrue(app.windows.firstMatch.frame.contains(button.frame), "Control outside app window: \(id)\n\(app.debugDescription)")
        XCTAssertTrue(clearsNavigation(button), "Navigation bar covers content control: \(id)\n\(app.debugDescription)")
        XCTAssertFalse(inputOcclusions().contains { button.frame.intersects($0) }, "Keyboard or input assistant covers control: \(id)\n\(app.debugDescription)")
        XCTAssertTrue(button.isHittable, "Unreachable control: \(id)\n\(app.debugDescription)")
        button.tap()
    }

    private func replace(_ field: XCUIElement, with value: String, down: Bool = false) {
        reveal(field, down: down)
        XCTAssertTrue(field.waitForExistence(timeout: 8), app.debugDescription)
        field.tap()
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

    private func login(server: String = "http://127.0.0.1:18766", user: String = "extended-" + UUID().uuidString) {
        replace(app.textFields["server"], with: server)
        replace(app.textFields["username"], with: user)
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("demo")
        tap("connect")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15), app.debugDescription)
        dismissPasswordSavePrompt()
        let hero = app.buttons["heroDetails"]
        XCTAssertTrue(hero.isHittable, app.debugDescription)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(hero.frame), app.debugDescription)
    }

    private func dismissPasswordSavePrompt() {
        let decline = app.buttons["Not Now"]
        if decline.waitForExistence(timeout: 3) {
            let title = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save Password?")).firstMatch
            XCTAssertTrue(title.exists, "Only dismiss the observed system password-save prompt.\n\(app.debugDescription)")
            XCTAssertTrue(decline.isHittable)
            XCTAssertTrue(app.windows.firstMatch.frame.contains(decline.frame))
            artifact("remote-requests-sign-in-password-prompt")
            decline.tap()
            XCTAssertTrue(decline.waitForNonExistence(timeout: 5))
        }
    }

    private func tab(_ title: String) {
        if ["Devices", "Requests", "Settings"].contains(title) {
            let more = app.buttons["ellipsis.circle"].firstMatch
            if !more.exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
            if !app.navigationBars["More"].waitForExistence(timeout: 2) { more.tap() }
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
            tap(title)
        } else { tap(title) }
    }

    private func back() { tap("BackButton", down: true) }

    private func waitFor(_ element: XCUIElement, enabled: Bool) {
        XCTAssertTrue(element.waitForExistence(timeout: 10))
        expectation(for: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)), evaluatedWith: element)
        waitForExpectations(timeout: 20)
    }

    private func disappears(_ element: XCUIElement) {
        expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        waitForExpectations(timeout: 10)
    }

    private func cancelConfirmation() {
        let outside = app.otherElements.matching(identifier: "PopoverDismissRegion").allElementsBoundByIndex.last ?? app.otherElements["PopoverDismissRegion"]
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        else {
            XCTAssertTrue(outside.waitForExistence(timeout: 3), app.debugDescription)
            let bar = app.navigationBars.allElementsBoundByIndex.last ?? app.navigationBars.firstMatch
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
        }
        disappears(outside)
    }

    private func toggle(_ element: XCUIElement) {
        reveal(element, down: true)
        let before = element.value as? String
        let control = element.switches.firstMatch
        if control.exists { control.tap() } else { element.tap() }
        if let before {
            expectation(for: NSPredicate(format: "value != %@", before), evaluatedWith: element)
            waitForExpectations(timeout: 5)
        }
    }

    private func artifact(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    private func dismissRemoteSheet() {
        let bar = app.navigationBars["Players & watch together"].firstMatch
        if bar.exists {
            let start = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15))
            start.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)))
        }
    }

    private func playable() {
        let player = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
        for _ in 0..<3 {
            if player.exists && player.isHittable { break }
            dismissRemoteSheet()
        }
        XCTAssertTrue(player.waitForExistence(timeout: 12))
        // The transport on the picture hides four seconds after it appears and leaves the
        // accessibility tree, so look it up again (which reveals it) on every check.
        var transport = app.reelPlaybackButton("transportPlayPause")
        let deadline = Date().addingTimeInterval(20)
        while !(transport.exists && transport.isEnabled) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            transport = app.reelPlaybackButton("transportPlayPause")
        }
        XCTAssertTrue(transport.exists && transport.isEnabled, "The group transport never became playable\n\(app.debugDescription)")
    }

    private func fixture(_ origin: String, _ path: String, method: String = "GET", body: [String: Any] = [:], user: String? = nil) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: origin + path))
        guard url.host == "127.0.0.1", [18766, 18767, 18768, 18769].contains(url.port ?? 0) else { throw NSError(domain: "NonLoopbackUITest", code: 1) }
        var request = URLRequest(url: url); request.httpMethod = method; request.timeoutInterval = 8
        if method != "GET" { request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let user {
            if origin == seerrOrigin && ["viewer", "restricted", "quota"].contains(user) { request.setValue("connect.sid=fixture-" + user, forHTTPHeaderField: "Cookie") }
            else { request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization") }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as! HTTPURLResponse).statusCode), "Fixture route failed: \(path)")
        return data.isEmpty ? [:] : (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func remoteState() async throws -> [String: Any] { try await fixture(remoteOrigin, "/qa/remote-state") }
    private func remoteOutcome(_ predicate: ([String: Any]) -> Bool) async throws -> [String: Any] {
        var state: [String: Any] = [:]
        for _ in 0..<100 {
            state = try await remoteState()
            if predicate(state) { return state }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The remote fixture did not observe the control's outcome.")
        return state
    }
    private func remoteEvents(_ user: String) async throws -> [[String: Any]] {
        ((try await remoteState())["events"] as? [[String: Any]] ?? []).filter { $0["user"] as? String == user }
    }
    private func seerrState() async throws -> [String: Any] { try await fixture(seerrOrigin, "/api/v1/qa/state") }
    private func resetSeerr() async throws { _ = try await fixture(seerrOrigin, "/api/v1/qa/reset", method: "POST") }
    private func remoteMode(_ user: String, _ values: [String: Any]) async throws {
        remoteModeUsers.insert(user)
        _ = try await fixture(remoteOrigin, "/qa/remote-control", method: "POST", body: values, user: user)
    }
    private func seerrMode(_ user: String, _ values: [String: Any]) async throws {
        seerrModeUsers.insert(user)
        var body = values; body["user"] = user
        _ = try await fixture(seerrOrigin, "/api/v1/qa/control", method: "POST", body: body)
    }

    private func connectSeerr(key: String? = nil, user: String = "viewer", password: String = "demo") {
        tab("Requests")
        replace(app.textFields["seerrServer"], with: seerrOrigin)
        if let key { replace(app.secureTextFields["seerrAPIKey"], with: key) }
        else {
            app.segmentedControls["seerrAuthMethod"].buttons["Jellyfin"].tap()
            replace(app.textFields["seerrUsername"], with: user)
            replace(app.secureTextFields["seerrPassword"], with: password)
        }
        tap("seerrConnect")
    }

    private func title(_ id: String = "seerrTitle-movie-101") { XCTAssertTrue(app.buttons[id].waitForExistence(timeout: 12), app.debugDescription) }
    private func search(_ text: String) {
        replace(app.searchFields.firstMatch, with: text, down: true)
        if app.keyboards.buttons["Search"].exists { app.keyboards.buttons["Search"].tap() }
    }

    func testRemoteSelectedTitleQueueModesBackSeekStopAndRefresh() async throws {
        let user = "extended-remote-" + UUID().uuidString
        _ = try await fixture(remoteOrigin, "/Sessions/qa-living-room/Playing?playCommand=PlayNow&itemIds=movie-1", method: "POST", user: user)
        _ = try await fixture(remoteOrigin, "/Sessions/qa-living-room/Playing/Seek?seekPositionTicks=120000000", method: "POST", user: user)
        login(server: remoteOrigin, user: user); tap("heroDetails"); openRemotePlayback()
        for id in ["remote-next-qa-living-room", "remote-queue-qa-living-room", "remote-play-qa-living-room"] {
            tap(id)
            XCTAssertTrue(app.staticTexts["remoteNotice"].waitForExistence(timeout: 8))
        }
        tap("remote-seek-back-qa-living-room")
        let state = try await remoteOutcome { ($0["position"] as? NSNumber)?.int64Value == 0 }
        XCTAssertEqual((state["position"] as? NSNumber)?.int64Value, 0, "Back seek must clamp at the start.")
        tap("remote-stop-qa-living-room"); disappears(app.buttons["remote-stop-qa-living-room"])
        let before = try await remoteEvents(user).filter { $0["path"] as? String == "/Sessions" }.count
        tap("refreshRemote")
        for _ in 0..<40 {
            if try await remoteEvents(user).filter({ $0["path"] as? String == "/Sessions" }).count > before { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let events = try await remoteEvents(user)
        for mode in ["PlayNow", "PlayNext", "PlayLast"] {
            XCTAssertTrue(events.contains { ($0["query"] as? [String: Any])?["playCommand"] as? String == mode && ($0["query"] as? [String: Any])?["itemIds"] as? String == "movie-1" })
        }
        XCTAssertTrue(events.contains { $0["path"] as? String == "/Sessions/qa-living-room/Playing/Seek" && ($0["query"] as? [String: Any])?["seekPositionTicks"] as? String == "0" })
        XCTAssertGreaterThan(events.filter { $0["path"] as? String == "/Sessions" }.count, before)
        artifact("remote-queue-stop-refresh-outcomes")
        dismissRemoteSheet(); XCTAssertTrue(app.buttons["detailPlay"].waitForExistence(timeout: 8))
    }

    func testDeniedRemoteAndGroupPermissionsStayVisibleAfterRefresh() async throws {
        login(server: remoteOrigin, user: "remote-denied"); tab("Devices")
        XCTAssertTrue(app.staticTexts["remoteError"].waitForExistence(timeout: 10))
        tap("refreshRemote"); XCTAssertTrue(app.staticTexts["remoteError"].exists)
        tap("refreshSyncGroups")
        XCTAssertTrue(app.staticTexts["syncError"].waitForExistence(timeout: 8))
        reveal(app.buttons["syncCreate"]); XCTAssertFalse(app.buttons["syncCreate"].isEnabled)
        XCTAssertFalse(app.buttons["remote-pause-qa-living-room"].exists)
        let events = try await remoteEvents("remote-denied")
        XCTAssertFalse(events.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/qa-living-room/Playing") == true })
        artifact("remote-and-sync-permission-denied")
    }

    func testJoinOnlyAccountCanJoinButCannotCreate() async throws {
        let user = "join-only"
        _ = try await fixture(remoteOrigin, "/SyncPlay/Join", method: "POST", body: ["GroupId": "fixture-group"], user: user)
        _ = try await fixture(remoteOrigin, "/SyncPlay/SetNewQueue", method: "POST", body: ["PlayingQueue": ["movie-1"], "PlayingItemPosition": 0, "StartPositionTicks": 0], user: user)
        _ = try await fixture(remoteOrigin, "/SyncPlay/Leave", method: "POST", user: user)
        let existingEventCount = try await remoteEvents(user).count
        login(server: remoteOrigin, user: user); tab("Devices")
        let create = app.buttons["syncCreate"]; reveal(create); waitFor(create, enabled: false)
        tap("refreshSyncGroups"); waitFor(create, enabled: false)
        tap("syncJoin-fixture-group", down: true); playable(); tap("closePlayer")
        XCTAssertTrue(app.buttons["syncJoin-fixture-group"].waitForExistence(timeout: 10))
        let state = try await remoteOutcome { ($0["members"] as? [String: String])?[user] == nil }
        XCTAssertNil((state["members"] as? [String: String])?[user])
        let events = Array(try await remoteEvents(user).dropFirst(existingEventCount))
        XCTAssertTrue(events.contains { $0["path"] as? String == "/SyncPlay/Join" })
        XCTAssertFalse(events.contains { $0["path"] as? String == "/SyncPlay/New" })
    }

    func testBlankSyncGroupNameUsesDefaultAndEmptyQueueControlsStayDisabled() async throws {
        let user = "extended-blank-group-" + UUID().uuidString
        login(server: remoteOrigin, user: user); tab("Devices"); tap("syncCreate")
        let active = app.descendants(matching: .any).matching(identifier: "activeSyncGroup").firstMatch
        XCTAssertTrue(active.waitForExistence(timeout: 10)); XCTAssertTrue(app.staticTexts["Watch together"].exists)
        reveal(app.buttons["syncNext"]); XCTAssertFalse(app.buttons["syncNext"].isEnabled); XCTAssertFalse(app.buttons["syncPrevious"].isEnabled)
        tap("refreshSyncGroups"); XCTAssertTrue(active.exists)
        tap("syncLeave"); disappears(active)
        let events = try await remoteEvents(user)
        XCTAssertTrue(events.contains { $0["path"] as? String == "/SyncPlay/New" && ($0["body"] as? [String: Any])?["GroupName"] as? String == "Watch together" })
        let state = try await remoteOutcome { ($0["members"] as? [String: String])?[user] == nil }
        XCTAssertNil((state["members"] as? [String: String])?[user])
        artifact("empty-sync-queue-disabled-controls")
    }

    private func selectedSyncQueue(_ button: String) async throws {
        let user = "extended-selected-group-" + UUID().uuidString
        login(server: remoteOrigin, user: user); tap("heroDetails"); openRemotePlayback()
        replace(app.textFields["syncGroupName"], with: "Selected title group")
        tap("syncCreate"); tap(button)
        playable(); artifact(button + "-native-player"); tap("closePlayer")
        let events = try await remoteEvents(user)
        if button == "syncPlaySelected" {
            XCTAssertTrue(events.contains { $0["path"] as? String == "/SyncPlay/SetNewQueue" && ($0["body"] as? [String: Any])?["PlayingQueue"] as? [String] == ["movie-1"] })
        } else {
            XCTAssertTrue(events.contains { $0["path"] as? String == "/SyncPlay/Queue" && ($0["body"] as? [String: Any])?["ItemIds"] as? [String] == ["movie-1"] })
        }
        let state = try await remoteOutcome { ($0["members"] as? [String: String])?[user] == nil }
        XCTAssertNil((state["members"] as? [String: String])?[user])
    }

    func testSelectedTitleStartsGroupQueueInNativePlayer() async throws { try await selectedSyncQueue("syncPlaySelected") }
    func testSelectedTitleAppendsGroupQueueInNativePlayer() async throws { try await selectedSyncQueue("syncQueueSelected") }

    func testGroupControlsPauseResumeNextPreviousStopAndLeave() async throws {
        let user = "extended-group-controls-" + UUID().uuidString
        let first = try await fixture(remoteOrigin, "/Items/movie-1", user: user)
        let second = try await fixture(remoteOrigin, "/Items/movie-2", user: user)
        let firstTitle = try XCTUnwrap(first["Name"] as? String)
        let secondTitle = try XCTUnwrap(second["Name"] as? String)
        let created = try await fixture(remoteOrigin, "/SyncPlay/New", method: "POST", body: ["GroupName": "Extended controls"], user: user)
        let groupID = try XCTUnwrap(created["GroupId"] as? String)
        _ = try await fixture(remoteOrigin, "/SyncPlay/SetNewQueue", method: "POST", body: ["PlayingQueue": ["movie-1", "movie-2"], "PlayingItemPosition": 0, "StartPositionTicks": 0], user: user)
        login(server: remoteOrigin, user: user); tab("Devices"); tap("syncJoin-" + groupID); playable(); tap("groupControls")
        tap("syncPause")
        _ = try await remoteOutcome { state in
            ((state["groups"] as? [String: [String: Any]])?[groupID])?["State"] as? String == "Paused"
                && (state["events"] as? [[String: Any]] ?? []).contains { $0["user"] as? String == user && $0["path"] as? String == "/SyncPlay/Pause" }
        }
        tap("syncUnpause")
        _ = try await remoteOutcome { (($0["groups"] as? [String: [String: Any]])?[groupID])?["State"] as? String == "Playing" }
        tap("syncNext")
        for _ in 0..<80 {
            if ((try await remoteState())["indices"] as? [String: Int])?[groupID] == 1 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let advanced = try await remoteState()
        XCTAssertEqual((advanced["indices"] as? [String: Int])?[groupID], 1)
        dismissRemoteSheet(); app.revealReelPlayerChrome(); XCTAssertTrue(app.staticTexts[secondTitle].firstMatch.waitForExistence(timeout: 10)); playable(); tap("groupControls"); tap("syncPrevious")
        for _ in 0..<80 {
            if ((try await remoteState())["indices"] as? [String: Int])?[groupID] == 0 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        let previous = try await remoteState()
        XCTAssertEqual((previous["indices"] as? [String: Int])?[groupID], 0)
        dismissRemoteSheet(); app.revealReelPlayerChrome(); XCTAssertTrue(app.staticTexts[firstTitle].firstMatch.waitForExistence(timeout: 10)); playable(); tap("groupControls")
        tap("syncStop"); disappears(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch)
        XCTAssertFalse(app.buttons["groupControls"].exists)
        if app.navigationBars["Players & watch together"].exists { dismissRemoteSheet() }
        tab("Devices"); tap("syncLeave")
        let events = try await remoteEvents(user)
        for command in ["Pause", "Unpause", "NextItem", "PreviousItem", "Stop", "Leave"] { XCTAssertTrue(events.contains { $0["path"] as? String == "/SyncPlay/" + command }, command) }
        let stopped = try await remoteOutcome { ($0["members"] as? [String: String])?[user] == nil }
        XCTAssertNil((stopped["members"] as? [String: String])?[user])
        artifact("group-transport-stop-and-leave")
    }

    func testSeerrAPIKeyValidationPaginationEmptySearchAndDisconnectPersistence() async throws {
        try await resetSeerr(); login(); tab("Requests")
        waitFor(app.buttons["seerrConnect"], enabled: false)
        replace(app.secureTextFields["seerrAPIKey"], with: "invalid-fixture-key")
        replace(app.textFields["seerrServer"], with: "not-a-server-address"); tap("seerrConnect")
        XCTAssertTrue(app.staticTexts["seerrConnectError"].waitForExistence(timeout: 8))
        replace(app.textFields["seerrServer"], with: seerrOrigin); tap("seerrConnect")
        XCTAssertTrue(app.staticTexts["seerrConnectError"].waitForExistence(timeout: 10))
        replace(app.secureTextFields["seerrAPIKey"], with: "fixture-seerr"); tap("seerrConnect"); title()
        tap("seerrLoadMore"); title("seerrTitle-movie-102"); XCTAssertFalse(app.buttons["seerrLoadMore"].exists)
        search("no-matching-fixture-title"); XCTAssertTrue(app.staticTexts["No titles found"].waitForExistence(timeout: 10))
        search(""); title()
        tap("seerrConnectionOptions", down: true); tap("Connection settings")
        XCTAssertEqual(app.textFields["seerrServer"].value as? String, seerrOrigin)
        waitFor(app.buttons["seerrConnect"], enabled: false)
        tap("Cancel", down: true); title()
        tap("seerrConnectionOptions", down: true); tap("Disconnect Seerr"); cancelConfirmation(); title()
        tap("seerrConnectionOptions", down: true); tap("Disconnect Seerr"); tap("Disconnect")
        XCTAssertTrue(app.buttons["seerrConnect"].waitForExistence(timeout: 8))
        app.terminate(); app.launchArguments = []; app.launch(); tab("Requests")
        XCTAssertTrue(app.buttons["seerrConnect"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["seerrConnectionOptions"].exists)
        artifact("seerr-disconnected-after-relaunch")
    }

    func testSeerrJellyfinWrongPasswordRecoveryAndAuthMethodClearsSecrets() async throws {
        login(); tab("Requests")
        replace(app.secureTextFields["seerrAPIKey"], with: "fixture-seerr")
        app.segmentedControls["seerrAuthMethod"].buttons["Jellyfin"].tap()
        XCTAssertFalse(app.secureTextFields["seerrAPIKey"].exists)
        app.segmentedControls["seerrAuthMethod"].buttons["API key"].tap()
        waitFor(app.buttons["seerrConnect"], enabled: false)
        app.segmentedControls["seerrAuthMethod"].buttons["Jellyfin"].tap()
        replace(app.textFields["seerrUsername"], with: "viewer")
        replace(app.secureTextFields["seerrPassword"], with: "wrong"); tap("seerrConnect")
        XCTAssertTrue(app.staticTexts["seerrConnectError"].waitForExistence(timeout: 8))
        replace(app.secureTextFields["seerrPassword"], with: "demo"); tap("seerrConnect"); title()
        artifact("seerr-password-error-recovered")
    }

    func testSeerrAvailableSeasonSelectionConfirmationCancelAndRequestDetailCancellation() async throws {
        try await resetSeerr(); login(); connectSeerr(); title("seerrTitle-tv-201"); tap("seerrTitle-tv-201")
        reveal(app.buttons["seerrSubmitRequest"]); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        reveal(app.buttons["seerrSeason-1"], down: true); XCTAssertFalse(app.buttons["seerrSeason-1"].isEnabled)
        tap("seerrAllSeasons", down: true); waitFor(app.buttons["seerrSubmitRequest"], enabled: true)
        tap("seerrSeason-2", down: true); tap("seerrSeason-3"); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        tap("seerrAllSeasons", down: true); tap("seerrSubmitRequest"); cancelConfirmation()
        let cancelledConfirmation = try await seerrState()
        XCTAssertEqual((cancelledConfirmation["requests"] as? [[String: Any]])?.count, 0)
        tap("seerrSubmitRequest"); tap("Send request")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "seerrRequestSuccess").firstMatch.waitForExistence(timeout: 10))
        let rows = (try await seerrState())["requests"] as? [[String: Any]] ?? []
        let request = try XCTUnwrap(rows.first); let requestID = try XCTUnwrap(request["id"] as? Int)
        XCTAssertEqual((request["seasons"] as? [[String: Int]])?.compactMap { $0["seasonNumber"] }, [2, 3])
        XCTAssertEqual(request["is4k"] as? Bool, false)
        back(); app.segmentedControls["seerrSection"].buttons["My requests"].tap(); tap("seerrRequest-\(requestID)")
        tap("seerrDetailCancel-\(requestID)"); cancelConfirmation()
        let kept = try await seerrState()
        XCTAssertEqual((kept["requests"] as? [[String: Any]])?.count, 1)
        tap("seerrDetailCancel-\(requestID)"); tap("Cancel request")
        XCTAssertTrue(app.staticTexts["Request cancelled"].waitForExistence(timeout: 10))
        let cancelled = try await seerrState()
        XCTAssertEqual((cancelled["requests"] as? [[String: Any]])?.count, 0)
        back(); XCTAssertTrue(app.staticTexts["Your next request starts here"].waitForExistence(timeout: 8))
        artifact("seerr-request-detail-cancelled")
    }

    func testSeerrAvailableMovieCanRequestSeparate4KVariant() async throws {
        try await resetSeerr(); login(); connectSeerr(key: "fixture-seerr"); title(); tap("seerrLoadMore"); tap("seerrTitle-movie-102")
        reveal(app.buttons["seerrSubmitRequest"]); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        toggle(app.switches["seerr4K"])
        waitFor(app.buttons["seerrSubmitRequest"], enabled: true); tap("seerrSubmitRequest"); tap("Send request")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "seerrRequestSuccess").firstMatch.waitForExistence(timeout: 10))
        let state = try await seerrState()
        let request = try XCTUnwrap((state["requests"] as? [[String: Any]])?.first)
        XCTAssertEqual(request["is4k"] as? Bool, true); XCTAssertEqual((request["media"] as? [String: Any])?["tmdbId"] as? Int, 102)
        waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        artifact("seerr-4k-variant-request")
    }

    func testSeerrRestrictedAccountCanBrowseButCannotRequest() async throws {
        try await resetSeerr(); login(); connectSeerr(user: "restricted"); title(); tap("seerrTitle-movie-101")
        reveal(app.buttons["seerrSubmitRequest"]); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        XCTAssertTrue(app.staticTexts["Your Seerr account cannot request this media type."].exists)
        XCTAssertFalse(app.switches["seerr4K"].exists)
        let state = try await seerrState()
        XCTAssertEqual((state["requests"] as? [[String: Any]])?.count, 0)
        artifact("seerr-restricted-request-controls")
    }

    func testSeerrQuotaDenialRefreshesWithoutFalseSuccess() async throws {
        try await resetSeerr(); login(); connectSeerr(user: "quota"); title(); tap("seerrTitle-movie-101")
        tap("seerrSubmitRequest"); tap("Send request")
        let failure = app.descendants(matching: .any).matching(identifier: "seerrRequestError").firstMatch
        XCTAssertTrue(failure.waitForExistence(timeout: 10)); XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "seerrRequestSuccess").firstMatch.exists)
        tap("Refresh status"); disappears(failure); waitFor(app.buttons["seerrSubmitRequest"], enabled: true)
        let state = try await seerrState()
        XCTAssertEqual((state["requests"] as? [[String: Any]])?.count, 0)
        artifact("seerr-quota-denial-refreshed")
    }

    func testSeerrConnectionRelaunchAndJellyfinAccountIsolation() {
        let first = "extended-seerr-first-" + UUID().uuidString
        let second = "extended-seerr-second-" + UUID().uuidString
        login(user: first); connectSeerr(key: "fixture-seerr"); title()
        app.terminate(); app.launchArguments = []; app.launch(); tab("Requests"); title()
        tab("Home"); tap("servers"); tap("addServer"); login(server: "http://127.0.0.1:18767", user: second)
        tab("Requests"); XCTAssertTrue(app.buttons["seerrConnect"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["seerrConnectionOptions"].exists)
        tab("Home"); tap("servers"); tap("server-" + first)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 10)); tab("Requests"); title()
        artifact("seerr-account-isolation-restored")
    }

    func testRemoteLoadingEmptyErrorAndRefreshRecovery() async throws {
        let user = "extended-remote-states-" + UUID().uuidString
        try await remoteMode(user, ["reset": true, "sessionsDelayMs": 2000])
        login(server: remoteOrigin, user: user); tab("Devices")
        XCTAssertTrue(app.staticTexts["Finding players…"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "remote-session-qa-living-room").firstMatch.waitForExistence(timeout: 10))
        try await remoteMode(user, ["sessionsDelayMs": 0, "sessionsEmpty": true]); tap("refreshRemote")
        let empty = app.staticTexts["No controllable players are online. Open Jellyfin on a TV or another device with remote control enabled for your account."]
        XCTAssertTrue(empty.waitForExistence(timeout: 8))
        try await remoteMode(user, ["sessionsEmpty": false, "failSessions": 1]); tap("refreshRemote")
        XCTAssertTrue(app.staticTexts["remoteError"].waitForExistence(timeout: 8))
        tap("refreshRemote")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "remote-session-qa-living-room").firstMatch.waitForExistence(timeout: 8))
        disappears(app.staticTexts["remoteError"]); artifact("remote-empty-error-recovered")
    }

    func testRemoteReceiverCapabilitiesDisableOnlyUnsupportedControls() async throws {
        let user = "extended-remote-capabilities-" + UUID().uuidString
        try await remoteMode(user, ["reset": true, "mediaControl": false, "canSeek": false, "acceptsVideo": false])
        _ = try await fixture(remoteOrigin, "/Sessions/qa-living-room/Playing?playCommand=PlayNow&itemIds=movie-1", method: "POST", user: user)
        login(server: remoteOrigin, user: user); tap("heroDetails"); openRemotePlayback()
        for id in ["remote-play-qa-living-room", "remote-next-qa-living-room", "remote-queue-qa-living-room", "remote-stop-qa-living-room", "remote-seek-back-qa-living-room", "remote-seek-forward-qa-living-room"] {
            let control = app.buttons[id]; reveal(control, down: true); XCTAssertTrue(control.exists); XCTAssertFalse(control.isEnabled, id)
        }
        try await remoteMode(user, ["mediaControl": true, "canSeek": true, "acceptsVideo": true]); tap("refreshRemote")
        let play = app.buttons["remote-play-qa-living-room"]; reveal(play, down: true); waitFor(play, enabled: true)
        artifact("remote-capabilities-restored")
    }

    func testSyncGroupListLoadingEmptyAndTransientFailureRecovery() async throws {
        let user = "extended-sync-list-" + UUID().uuidString
        try await remoteMode(user, ["reset": true, "groupsDelayMs": 2000, "groupsEmpty": true])
        login(server: remoteOrigin, user: user); tab("Devices")
        let loading = app.staticTexts["Loading groups…"]; reveal(loading); XCTAssertTrue(loading.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No groups are available."].waitForExistence(timeout: 8))
        try await remoteMode(user, ["groupsDelayMs": 0, "groupsEmpty": false, "failGroups": 1]); tap("refreshSyncGroups")
        XCTAssertTrue(app.staticTexts["syncError"].waitForExistence(timeout: 8)); tap("refreshSyncGroups")
        let join = app.buttons["syncJoin-fixture-group"]; reveal(join, down: true); waitFor(join, enabled: true)
        disappears(app.staticTexts["syncError"]); artifact("sync-list-empty-error-recovered")
    }

    func testSyncSocketLossStopsLocalPlaybackAndAllowsRejoin() async throws {
        let user = "extended-sync-socket-" + UUID().uuidString
        let created = try await fixture(remoteOrigin, "/SyncPlay/New", method: "POST", body: ["GroupName": "Socket recovery"], user: user)
        let groupID = try XCTUnwrap(created["GroupId"] as? String)
        _ = try await fixture(remoteOrigin, "/SyncPlay/SetNewQueue", method: "POST", body: ["PlayingQueue": ["movie-1"], "PlayingItemPosition": 0, "StartPositionTicks": 0], user: user)
        login(server: remoteOrigin, user: user); tab("Devices"); tap("syncJoin-" + groupID); playable()
        try await remoteMode(user, ["disconnectSockets": true])
        disappears(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch)
        XCTAssertTrue(app.staticTexts["syncError"].waitForExistence(timeout: 8))
        let state = try await remoteOutcome { ($0["members"] as? [String: String])?[user] == nil }
        XCTAssertNil((state["members"] as? [String: String])?[user])
        tap("syncJoin-" + groupID); playable(); tap("closePlayer")
        artifact("sync-socket-rejoin-recovered")
    }

    func testSeerrAuthDiscoveryAndDetailLoadingDisableAffectedControls() async throws {
        try await resetSeerr(); try await seerrMode("viewer", ["reset": true, "authDelayMs": 2000, "browseDelayMs": 2000, "detailDelayMs": 2000])
        login(); connectSeerr()
        XCTAssertFalse(app.buttons["seerrConnect"].isEnabled)
        XCTAssertTrue(app.buttons["seerrConnect"].label.contains("Connecting"))
        XCTAssertTrue(app.staticTexts["Opening Seerr…"].waitForExistence(timeout: 8)); title(); tap("seerrTitle-movie-101")
        XCTAssertTrue(app.staticTexts["Checking availability…"].waitForExistence(timeout: 5))
        reveal(app.buttons["seerrSubmitRequest"]); waitFor(app.buttons["seerrSubmitRequest"], enabled: true)
        artifact("seerr-loading-controls-ready")
    }

    func testSeerrDiscoveryAndDetailFailuresHaveReachableRecovery() async throws {
        try await resetSeerr(); try await seerrMode("admin", ["reset": true, "failBrowse": 1])
        login(); connectSeerr(key: "fixture-seerr"); tap("retry"); title()
        try await seerrMode("admin", ["failDetail": 1]); tap("seerrTitle-movie-101")
        let error = app.descendants(matching: .any).matching(identifier: "seerrRequestError").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 8)); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        tap("Refresh status"); disappears(error); waitFor(app.buttons["seerrSubmitRequest"], enabled: true)
        artifact("seerr-provider-errors-recovered")
    }

    func testSeerrRequestsPaginationAppendsWithoutDuplicates() async throws {
        try await resetSeerr(); try await seerrMode("viewer", ["reset": true, "requestPageSize": 1])
        login(); connectSeerr(); title(); tap("seerrTitle-movie-101"); tap("seerrSubmitRequest"); tap("Send request")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "seerrRequestSuccess").firstMatch.waitForExistence(timeout: 10)); back()
        tap("seerrTitle-tv-201"); tap("seerrSeason-2"); tap("seerrSubmitRequest"); tap("Send request")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "seerrRequestSuccess").firstMatch.waitForExistence(timeout: 10)); back()
        app.segmentedControls["seerrSection"].buttons["My requests"].tap(); tap("seerrMoreRequests")
        let state = try await seerrState(); let requests = state["requests"] as? [[String: Any]] ?? []
        XCTAssertEqual(requests.count, 2)
        for request in requests {
            let id = try XCTUnwrap(request["id"] as? Int)
            XCTAssertTrue(app.buttons["seerrRequest-\(id)"].waitForExistence(timeout: 8))
            XCTAssertEqual(app.buttons.matching(identifier: "seerrRequest-\(id)").count, 1)
        }
        XCTAssertFalse(app.buttons["seerrMoreRequests"].exists)
        search("Signal"); title(); XCTAssertTrue(app.segmentedControls["seerrSection"].buttons["Discover"].isSelected)
        artifact("seerr-request-pagination-search-navigation")
    }

    func testSeerrRemainingSeasonQuotaPreventsOversizedSelection() async throws {
        try await resetSeerr(); try await seerrMode("viewer", ["reset": true, "tvQuotaRemaining": 1])
        login(); connectSeerr(); title(); tap("seerrTitle-tv-201"); tap("seerrAllSeasons")
        waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        tap("seerrSeason-3"); waitFor(app.buttons["seerrSubmitRequest"], enabled: true)
        artifact("seerr-season-quota-enforced")
    }

    func testSeerrDelayedSignInCannotInstallConnectionAfterAccountSwitch() async throws {
        let first = "extended-auth-first-" + UUID().uuidString
        let second = "extended-auth-second-" + UUID().uuidString
        login(user: first); tap("servers"); tap("addServer"); login(server: "http://127.0.0.1:18767", user: second)
        tap("servers"); tap("server-" + first); XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 10))
        try await seerrMode("viewer", ["reset": true, "authDelayMs": 10000]); connectSeerr()
        XCTAssertFalse(app.buttons["seerrConnect"].isEnabled)
        tab("Home"); tap("servers"); tap("server-" + second); XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 10))
        tab("Requests"); XCTAssertTrue(app.buttons["seerrConnect"].waitForExistence(timeout: 8))
        try await Task.sleep(for: .seconds(10.5))
        XCTAssertTrue(app.buttons["seerrConnect"].exists); XCTAssertFalse(app.buttons["seerrConnectionOptions"].exists)
        tab("Home"); tap("servers"); tap("server-" + first); tab("Requests")
        XCTAssertTrue(app.buttons["seerrConnect"].waitForExistence(timeout: 8)); artifact("seerr-delayed-auth-account-fence")
    }

    func testRemoteCommandFailureCanBeRetriedWithoutLosingReceiver() async throws {
        let user = "extended-remote-command-" + UUID().uuidString
        _ = try await fixture(remoteOrigin, "/Sessions/qa-living-room/Playing?playCommand=PlayNow&itemIds=movie-1", method: "POST", user: user)
        _ = try await fixture(remoteOrigin, "/Sessions/qa-living-room/Playing/Unpause", method: "POST", user: user)
        try await remoteMode(user, ["reset": true, "failCommand": 1])
        login(server: remoteOrigin, user: user); tab("Devices"); tap("remote-pause-qa-living-room")
        XCTAssertTrue(app.staticTexts["remoteError"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.staticTexts["remoteNotice"].exists)
        tap("remote-pause-qa-living-room")
        XCTAssertTrue(app.buttons["remote-unpause-qa-living-room"].waitForExistence(timeout: 8)); disappears(app.staticTexts["remoteError"])
        let events = try await remoteEvents(user)
        XCTAssertEqual(events.filter { $0["path"] as? String == "/Sessions/qa-living-room/Playing/Pause" }.count, 2)
        artifact("remote-command-failure-retried")
    }

    func testSyncAccessNoneDisablesMembershipWithoutBreakingRemoteDiscovery() async throws {
        let user = "extended-sync-none-" + UUID().uuidString
        try await remoteMode(user, ["reset": true, "syncAccess": "None"])
        login(server: remoteOrigin, user: user); tab("Devices")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "remote-session-qa-living-room").firstMatch.waitForExistence(timeout: 10))
        reveal(app.buttons["syncCreate"]); waitFor(app.buttons["syncCreate"], enabled: false)
        let join = app.buttons["syncJoin-fixture-group"]; reveal(join, down: true); waitFor(join, enabled: false)
        XCTAssertFalse(app.staticTexts["remoteError"].exists); XCTAssertFalse(app.staticTexts["syncError"].exists)
        artifact("sync-policy-none-remote-still-available")
    }

    func testSeerrDuplicateRaceShowsCurrentStatusAndSafeRetryState() async throws {
        try await resetSeerr(); login(); connectSeerr(); title(); tap("seerrTitle-movie-101")
        reveal(app.buttons["seerrSubmitRequest"]); waitFor(app.buttons["seerrSubmitRequest"], enabled: true)
        _ = try await fixture(seerrOrigin, "/api/v1/request", method: "POST", body: ["mediaType": "movie", "mediaId": 101, "is4k": false], user: "viewer")
        tap("seerrSubmitRequest"); tap("Send request")
        let error = app.descendants(matching: .any).matching(identifier: "seerrRequestError").firstMatch
        XCTAssertTrue(error.waitForExistence(timeout: 10)); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        let state = try await seerrState(); XCTAssertEqual((state["requests"] as? [[String: Any]])?.count, 1)
        tap("Refresh status"); disappears(error); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        artifact("seerr-duplicate-race-refreshed")
    }

    func testSeerrZeroMovieQuotaDisablesRequestBeforeSubmission() async throws {
        try await resetSeerr(); try await seerrMode("viewer", ["reset": true, "movieQuotaRemaining": 0])
        login(); connectSeerr(); title(); tap("seerrTitle-movie-101")
        reveal(app.buttons["seerrSubmitRequest"]); waitFor(app.buttons["seerrSubmitRequest"], enabled: false)
        XCTAssertTrue(app.staticTexts["0 of 10 movie requests remaining in your quota."].exists)
        let state = try await seerrState(); XCTAssertEqual((state["requests"] as? [[String: Any]])?.count, 0)
        artifact("seerr-zero-movie-quota")
    }

    func testSeerr4KSeriesSeasonAvailabilityIsIndependentOfRegularLibrary() async throws {
        try await resetSeerr(); login(); connectSeerr(key: "fixture-seerr"); title(); tap("seerrTitle-tv-201")
        reveal(app.buttons["seerrSeason-1"]); XCTAssertFalse(app.buttons["seerrSeason-1"].isEnabled)
        toggle(app.switches["seerr4K"])
        waitFor(app.buttons["seerrSeason-1"], enabled: true)
        tap("seerrAllSeasons"); tap("seerrSubmitRequest"); tap("Send request")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "seerrRequestSuccess").firstMatch.waitForExistence(timeout: 10))
        let state = try await seerrState()
        let request = try XCTUnwrap((state["requests"] as? [[String: Any]])?.first)
        XCTAssertEqual(request["is4k"] as? Bool, true)
        XCTAssertEqual((request["seasons"] as? [[String: Int]])?.compactMap { $0["seasonNumber"] }, [1, 2, 3])
        for id in ["seerrSeason-1", "seerrSeason-2", "seerrSeason-3"] { reveal(app.buttons[id]); XCTAssertFalse(app.buttons[id].isEnabled) }
        artifact("seerr-4k-series-independent-seasons")
    }
}
