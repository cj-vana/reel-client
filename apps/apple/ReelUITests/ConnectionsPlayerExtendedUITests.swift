import XCTest
import UIKit

@MainActor final class ConnectionsPlayerExtendedUITests: XCTestCase {
    private var app: XCUIApplication!
    private let primary = "http://127.0.0.1:18766"
    private let secondary = "http://127.0.0.1:18767"
    private var optionsOwner: XCUIElement?
    private var optionsScroll: XCUIElement?

    override func tearDown() async throws {
        #if targetEnvironment(simulator)
        if app != nil {
            try? await post("/qa/quick-connect/enabled", ["enabled": true])
            try? await post("/qa/control", ["failReports": false, "reportDelay": 0, "recoveryAllowed": false])
            app.terminate()
            app.launchArguments = []
            app.launch()
            if app.textFields["username"].waitForExistence(timeout: 2) {
                signIn("cleanup-" + String(UUID().uuidString.prefix(8)), server: primary)
            }
            if app.buttons["heroPlay"].waitForExistence(timeout: 10) {
                settings()
                setSwitch("privateViewing", false)
            } else {
                XCTFail("Disposable QA cleanup could not reach Settings to restore private viewing.")
            }
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        #endif
    }

    private func launch(largeText: Bool = false) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Account reset and fixture mutations are restricted to disposable simulators and loopback servers.")
        #else
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        if largeText { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = primary
        XCUIDevice.shared.orientation = .portrait
        app.launch()
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
        #endif
    }

    private func relaunch(largeText: Bool = false) {
        app.terminate()
        app.launchArguments = largeText ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : []
        app.launch()
    }

    private func foregroundOptionsScroll() -> XCUIElement? {
        let bar = app.navigationBars["Playback options"]
        guard bar.exists else {
            optionsOwner = nil
            optionsScroll = nil
            return nil
        }
        if let owner = optionsOwner, let scroll = optionsScroll,
           owner.exists, scroll.exists, owner.navigationBars["Playback options"].exists {
            return scroll
        }
        let window = app.windows.firstMatch.frame
        let owners = app.otherElements.containing(.navigationBar, identifier: "Playback options")
            .allElementsBoundByAccessibilityElement.filter { owner in
                let visible = owner.frame.intersection(window)
                return visible.width > 40 && visible.height > 80 && visible.contains(bar.frame)
                    && owner.scrollViews.containing(.button, identifier: "transportPlayPause")
                        .containing(.button, identifier: "playbackSpeed").count > 0
            }.sorted { first, second in
                let firstFrame = first.frame.intersection(window), secondFrame = second.frame.intersection(window)
                let firstArea = firstFrame.width * firstFrame.height, secondArea = secondFrame.width * secondFrame.height
                return firstArea == secondArea ? first.scrollViews.count < second.scrollViews.count : firstArea < secondArea
            }
        guard let owner = owners.first else { return nil }
        let scroll = owner.scrollViews.allElementsBoundByAccessibilityElement.first { scroll in
            scroll.buttons.matching(identifier: "transportPlayPause").count > 0
                && scroll.buttons.matching(identifier: "playbackSpeed").count > 0
        }
        optionsOwner = owner
        optionsScroll = scroll
        return scroll
    }

    private func foregroundOptionsMenu() -> XCUIElement? {
        guard app.navigationBars["Playback options"].exists else { return nil }
        let window = app.windows.firstMatch.frame
        return app.collectionViews.allElementsBoundByIndex.first { collection in
            let visible = collection.frame.intersection(window)
            return visible.width > 40 && visible.height > 80 && collection.isHittable
                && collection.buttons.count > 0
        }
    }

    private func reveal(_ element: XCUIElement, down: Bool = false) {
        for attempt in 0..<24 {
            let window = app.windows.firstMatch.frame
            let navigationBars = app.navigationBars.allElementsBoundByIndex.filter { bar in
                bar.frame.intersects(window) && (bar.isHittable || bar.buttons.allElementsBoundByIndex.contains { $0.isHittable })
            }
            var fingerDown = attempt < 12 ? down : !down
            let exists = element.exists
            let identifier = exists ? element.identifier : ""
            let isField = exists && (element.elementType == .textField || element.elementType == .secureTextField)
            if exists {
                let frame = element.frame
                let coveredByNavigation = navigationBars.contains { bar in
                    bar.frame.intersects(frame) && !bar.descendants(matching: element.elementType)
                        .allElementsBoundByIndex.contains { child in
                            child.frame == frame && child.identifier == identifier && child.label == element.label
                        }
                }
                let needsWholeFrame = ["playbackSpeed", "sleepTimer", "playerChapters"].contains(identifier)
                let top = needsWholeFrame ? frame.minY : frame.midY
                let bottom = needsWholeFrame ? frame.maxY : frame.midY
                if !isField && !coveredByNavigation && frame.minX >= window.minX && frame.maxX <= window.maxX
                    && top > window.minY + 8 && bottom < window.maxY - 8
                    && (element.isHittable || !element.isEnabled) { return }
            }
            let menu = foregroundOptionsMenu()
            let options = menu == nil ? foregroundOptionsScroll() : nil
            let containers: [XCUIElement]
            if let menu {
                containers = [menu]
            } else if let options {
                containers = [options]
            } else if app.navigationBars["Playback options"].exists {
                continue
            } else {
                containers = app.collectionViews.allElementsBoundByIndex
                    + app.tables.allElementsBoundByIndex + app.scrollViews.allElementsBoundByIndex
            }
            let candidates = containers
                .filter { container in
                    let visible = container.frame.intersection(window)
                    guard visible.height > 80 && visible.width > 40 else { return false }
                    return container.isHittable || container.descendants(matching: .any)
                        .allElementsBoundByIndex.contains { child in
                            child.frame.width > 0 && child.frame.height > 0 && visible.contains(child.frame) && child.isHittable
                        }
                }
            let containing = identifier.isEmpty ? [] : candidates.filter {
                $0.descendants(matching: .any).matching(identifier: identifier).count > 0
            }
            let foregroundCollection = candidates.first { container in
                container.elementType == .collectionView && container.isHittable
                    && container.frame.width < window.width - 8
            }
            guard let container = containing.last ?? foregroundCollection ?? candidates.last else {
                if options != nil || menu != nil { continue }
                return
            }
            var visible = container.frame.intersection(window)
            if let bar = navigationBars.last, bar.frame.intersects(visible) {
                let bottom = visible.maxY
                visible.origin.y = max(visible.minY, bar.frame.maxY + 8)
                visible.size.height = max(0, bottom - visible.minY)
            }
            for input in app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex {
                if input.frame.height > 60 && input.frame.minY > visible.minY && input.frame.minY < visible.maxY {
                    visible.size.height = input.frame.minY - visible.minY - 8
                }
            }
            guard visible.height > 80 && visible.width > 40 else {
                if options != nil || menu != nil { continue }
                return
            }
            if element.exists {
                let frame = element.frame
                let needsWholeFrame = isField || ["playbackSpeed", "sleepTimer", "playerChapters"].contains(identifier)
                let top = needsWholeFrame ? frame.minY : frame.midY
                let bottom = needsWholeFrame ? frame.maxY : frame.midY
                if frame.minX >= visible.minX && frame.maxX <= visible.maxX
                    && top > visible.minY + 8 && bottom < visible.maxY - 8
                    && (element.isHittable || !element.isEnabled) { return }
                if bottom >= visible.maxY - 8 { fingerDown = false }
                else if top <= visible.minY + 8 { fingerDown = true }
            }
            let origin = app.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 0))
            let startY = visible.minY + visible.height * (fingerDown ? 0.25 : 0.85)
            var x = window.width > window.height
                ? visible.midX
                : visible.minX + min(20, visible.width * 0.07)
            if options != nil && container.elementType == .scrollView
                && container.buttons.matching(identifier: "transportPlayPause").count > 0 {
                let controls = (container.buttons.allElementsBoundByIndex + container.sliders.allElementsBoundByIndex)
                    .map { $0.frame.insetBy(dx: -4, dy: -4) }
                let inset = min(132, visible.width * 0.18)
                let lanes = [visible.maxX - inset, visible.minX + inset, visible.midX]
                guard let blankX = lanes.first(where: { candidate in
                    !controls.contains { $0.contains(CGPoint(x: candidate, y: startY)) }
                }) else {
                    attach("no-blank-options-pan-start")
                    return
                }
                x = blankX
            }
            let start = origin.withOffset(CGVector(dx: x,
                                                  dy: startY))
            let end = origin.withOffset(CGVector(dx: x,
                                                dy: visible.minY + visible.height * (fingerDown ? 0.7 : 0.35)))
            start.press(forDuration: 0.1, thenDragTo: end)
        }
    }

    private func button(_ id: String) -> XCUIElement {
        app.prepareReelPlayerControl(id)
        if id == "groupControls" { app.revealReelPlayerChrome() }
        let window = app.windows.firstMatch.frame
        let query: XCUIElementQuery
        if let menu = foregroundOptionsMenu() {
            query = menu.buttons.matching(identifier: id)
        } else if app.navigationBars["Playback options"].exists {
            let bar = app.navigationBars["Playback options"]
            if bar.buttons.matching(identifier: id).count > 0 {
                query = bar.buttons.matching(identifier: id)
            } else if let options = foregroundOptionsScroll() {
                query = options.buttons.matching(identifier: id)
            } else {
                query = bar.buttons.matching(identifier: id)
            }
        } else {
            optionsOwner = nil
            optionsScroll = nil
            query = app.buttons.matching(identifier: id)
        }
        return query.allElementsBoundByIndex.first { candidate in
            let frame = candidate.frame
            return frame.width > 0 && frame.height > 0 && window.contains(frame) && candidate.isHittable
        } ?? query.firstMatch
    }

    private func tap(_ id: String, down: Bool = false) {
        if ["closePlayer", "playbackOptions", "groupControls"].contains(id) {
            if id == "closePlayer" { app.prepareReelPlayerControl(id) }
            let surface = app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch
            XCTAssertTrue(surface.waitForExistence(timeout: 12))
            let target = app.buttons[id].firstMatch
            // Wake the real overlay immediately before the action. Deep ownership
            // snapshots can outlast the four-second idle timer while video plays.
            // A tap on the picture toggles the controls, so tap only while they are hidden.
            if !(target.exists && target.isHittable) {
                surface.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.22)).tap()
            }
            XCTAssertTrue(target.waitForExistence(timeout: 5))
            XCTAssertTrue(target.isHittable)
            target.tap()
            return
        }
        var target = button(id)
        reveal(target, down: down)
        target = button(id)
        if !target.exists { attach("missing-\(id)") }
        XCTAssertTrue(target.waitForExistence(timeout: 8), "Missing control: \(id)")
        if !target.isHittable { reveal(target, down: down); target = button(id) }
        if !target.isHittable { attach("unreachable-\(id)") }
        wait(target, NSPredicate(format: "hittable == true"), timeout: 3)
        XCTAssertTrue(target.isHittable, "Unreachable control: \(id)")
        let dismissingOptions = id == "Done" && app.navigationBars["Playback options"].exists
        target.tap()
        if dismissingOptions {
            wait(app.navigationBars["Playback options"], NSPredicate(format: "exists == false"))
            optionsOwner = nil
            optionsScroll = nil
        }
    }

    private func replace(_ field: XCUIElement, _ text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        reveal(field)
        XCTAssertTrue(field.isHittable, "The field must be reachable before editing")
        XCTAssertGreaterThan(field.frame.minY, app.windows.firstMatch.frame.minY + 24)
        XCTAssertLessThan(field.frame.maxY, app.windows.firstMatch.frame.maxY - 24)
        for input in app.otherElements.matching(identifier: "inputView").allElementsBoundByIndex where input.frame.height > 60 {
            XCTAssertLessThan(field.frame.maxY, input.frame.minY, "The entire field must be above the active keyboard")
        }
        field.tap()
        let existing = field.value as? String ?? ""
        if !existing.isEmpty, existing != field.placeholderValue {
            field.press(forDuration: 1)
            if app.menuItems["Select All"].waitForExistence(timeout: 1) { app.menuItems["Select All"].tap() }
            else if app.buttons["Select All"].exists { app.buttons["Select All"].tap() }
            else { field.tap(); field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 180)) }
            field.typeText(XCUIKeyboardKey.delete.rawValue)
        }
        if !text.isEmpty { field.typeText(text) }
    }

    private func wait(_ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval = 8) {
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed,
                       "Timed out waiting for \(predicate) on \(element)")
    }

    private func setSwitch(_ id: String, _ enabled: Bool) {
        let element = app.switches[id].firstMatch
        reveal(element)
        if !element.exists { attach("missing-switch-" + id) }
        XCTAssertTrue(element.waitForExistence(timeout: 8))
        XCTAssertTrue(element.isHittable, "The switch must be reachable before editing")
        if (element.value as? String == "1") != enabled {
            let nested = element.switches.firstMatch
            if nested.exists { nested.tap() } else { element.tap() }
        }
        wait(element, NSPredicate(format: "value == %@", enabled ? "1" : "0"))
    }

    private func home() {
        tap("Home")
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
    }

    private func settings() {
        destination("Settings", title: "Settings")
    }

    private func destination(_ name: String, title: String) {
        if app.navigationBars[title].exists { return }
        let more = app.buttons["ellipsis.circle"].firstMatch
        if !more.exists, app.buttons["Show Sidebar"].exists { app.buttons["Show Sidebar"].tap() }
        XCTAssertTrue(more.waitForExistence(timeout: 8))
        more.tap()
        if !app.navigationBars["More"].waitForExistence(timeout: 2) { more.tap() }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 8))
        tap(name)
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8))
    }

    private func signIn(_ user: String, server: String? = nil, password: String = "demo") {
        if let server { replace(app.textFields["server"], server) }
        replace(app.textFields["username"], user)
        let passwordField = app.secureTextFields["password"]
        replace(passwordField, password)
        passwordField.typeText(XCUIKeyboardKey.return.rawValue)
    }

    private func login(_ user: String) {
        signIn(user)
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
    }

    private func configureLocalPlayback(quality: String = "Original / auto", privateViewing: Bool = false) {
        settings()
        setSwitch("useServerPreferences", false)
        setSwitch("privateViewing", privateViewing)
        tap("qualityPicker", down: true); tap(quality)
        XCTAssertTrue(button("qualityPicker").label.contains(quality))
    }

    private func openPlayerOptions() {
        if !app.navigationBars["Playback options"].exists { tap("playbackOptions", down: true) }
        XCTAssertTrue(app.navigationBars["Playback options"].waitForExistence(timeout: 8))
        let transport = button("transportPlayPause")
        reveal(transport, down: true)
        XCTAssertTrue(transport.waitForExistence(timeout: 12))
        wait(transport, NSPredicate(format: "enabled == true"), timeout: 25)
    }

    private func pause() {
        let transport = button("transportPlayPause")
        wait(transport, NSPredicate(format: "exists == true AND enabled == true"))
        if transport.label == "Pause" { tap("transportPlayPause", down: true) }
        wait(button("transportPlayPause"), NSPredicate(format: "exists == true AND enabled == true AND label == %@", "Play"))
    }

    private func play() {
        if button("transportPlayPause").label == "Play" { tap("transportPlayPause", down: true) }
        wait(button("transportPlayPause"), NSPredicate(format: "label == %@", "Pause"))
    }

    private func timeline() -> XCUIElement {
        app.prepareReelPlayerControl("scrubTimeline")
        let query: XCUIElementQuery
        if app.navigationBars["Playback options"].exists {
            query = foregroundOptionsScroll()?.sliders.matching(identifier: "scrubTimeline")
                ?? app.navigationBars["Playback options"].sliders.matching(identifier: "scrubTimeline")
        } else {
            query = app.sliders.matching(identifier: "scrubTimeline")
        }
        let slider = query.allElementsBoundByIndex.first(where: { $0.isHittable }) ?? query.firstMatch
        reveal(slider)
        XCTAssertTrue(slider.waitForExistence(timeout: 8))
        return slider
    }

    private func seconds(_ value: XCUIElement) -> Double {
        let components = (value.value as? String ?? "").split(separator: ":").compactMap { Double($0) }
        XCTAssertTrue((2...3).contains(components.count), "Expected native timeline timestamp; got \(value.value ?? "nil")")
        return components.reduce(0) { $0 * 60 + $1 }
    }

    private func waitPosition(_ range: ClosedRange<Double>, timeout: TimeInterval = 8) {
        let slider = timeline()
        let predicate = NSPredicate { element, _ in
            guard let value = (element as? XCUIElement)?.value as? String else { return false }
            let fields = value.split(separator: ":").compactMap { Double($0) }
            return (2...3).contains(fields.count) && range.contains(fields.reduce(0) { $0 * 60 + $1 })
        }
        wait(slider, predicate, timeout: timeout)
    }

    private func chooseChapter(_ name: String) {
        tap("playerChapters"); tap(name)
    }

    private func closePlayer() {
        if app.navigationBars["Playback options"].exists { tap("Done", down: true) }
        tap("closePlayer", down: true)
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 10))
    }

    private func cancelConfirmation() {
        let cancel = app.buttons["Cancel"].firstMatch
        if cancel.exists { cancel.tap() }
        else {
            let outside = app.otherElements.matching(identifier: "PopoverDismissRegion").allElementsBoundByIndex.last ?? app.otherElements["PopoverDismissRegion"]
            XCTAssertTrue(outside.waitForExistence(timeout: 3), app.debugDescription)
            let bar = app.navigationBars.allElementsBoundByIndex.last ?? app.navigationBars.firstMatch
            bar.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5)).tap()
            wait(outside, NSPredicate(format: "exists == false"))
        }
    }

    private func post(_ path: String, _ body: [String: Any] = [:]) async throws {
        let url = URL(string: primary + path)!
        XCTAssertEqual(url.host, "127.0.0.1")
        XCTAssertTrue(path.hasPrefix("/qa/"))
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as! HTTPURLResponse).statusCode), "Fixture control failed: \(path)")
    }

    private func state() async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: primary + "/qa/state")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func reports(_ user: String) async throws -> [[String: Any]] {
        let snapshot = try await state()
        return (snapshot["reports"] as? [[String: Any]] ?? []).filter { $0["user"] as? String == user }
    }

    private func waitReport(_ user: String, path: String, after: Int = 0, bodyMatches: ([String: Any]) -> Bool = { _ in true }) async throws {
        let deadline = Date().addingTimeInterval(12)
        repeat {
            let receipts = try await reports(user)
            if receipts.dropFirst(after).contains(where: { $0["path"] as? String == path && bodyMatches($0["body"] as? [String: Any] ?? [:]) }) { return }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        XCTFail("Missing fixture receipt \(path) for isolated test account")
    }

    private func attach(_ name: String) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    func testSignInValidationAndAdvancedAddressRecoverAtLargeText() throws {
        try launch(largeText: true)
        reveal(app.buttons["connect"])
        XCTAssertFalse(app.buttons["connect"].isEnabled)
        replace(app.textFields["username"], "   ")
        XCTAssertFalse(app.buttons["connect"].isEnabled)
        replace(app.textFields["username"], "connect-validation-" + UUID().uuidString)
        replace(app.textFields["server"], "ftp://127.0.0.1:18766")
        tap("connect")
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["connectionError"].label.contains("complete server address"))
        XCUIDevice.shared.orientation = .landscapeLeft
        tap("advancedConnection")
        replace(app.textFields["advancedServer"], secondary)
        tap("Done", down: true)
        XCTAssertEqual(app.textFields["server"].value as? String, secondary)
        let reachable = app.descendants(matching: .any).matching(identifier: "serverReachable").firstMatch
        XCTAssertTrue(reachable.waitForExistence(timeout: 8))
        XCTAssertTrue(reachable.label.contains("Reel Second Server"))
        XCUIDevice.shared.orientation = .portrait
        signIn("connect-recovery-" + UUID().uuidString, password: "wrong-fixture-password")
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["connectionError"].label.contains("not accepted"))
        replace(app.secureTextFields["password"], "demo"); tap("connect")
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
        attach("extended-sign-in-large-text-recovery")
    }

    func testQuickConnectDisabledExpiredRetryAndCancellation() async throws {
        try launch()
        try await post("/qa/quick-connect/enabled", ["enabled": false])
        tap("advancedConnection"); tap("quickConnect")
        XCTAssertTrue(app.staticTexts["quickConnectError"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["quickConnectError"].label.contains("disabled"))
        try await post("/qa/quick-connect/enabled", ["enabled": true])
        tap("quickConnect")
        let code = app.staticTexts["quickConnectCode"]
        XCTAssertTrue(code.waitForExistence(timeout: 8))
        let expiredCode = code.label
        XCTAssertNotNil(expiredCode.range(of: "^[0-9]{6}$", options: .regularExpression))
        XCTAssertTrue(app.staticTexts["Waiting for approval…"].exists)
        try await post("/qa/quick-connect/expire", ["code": expiredCode])
        XCTAssertTrue(app.staticTexts["quickConnectError"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["quickConnectError"].label.contains("expired"))
        tap("quickConnect")
        XCTAssertTrue(code.waitForExistence(timeout: 8)); let cancelledCode = code.label
        XCTAssertNotEqual(cancelledCode, expiredCode)
        tap("Cancel")
        wait(code, NSPredicate(format: "exists == false"))
        try await post("/qa/quick-connect/approve", ["code": cancelledCode])
        try await Task.sleep(for: .seconds(3))
        XCTAssertFalse(app.buttons["heroPlay"].exists)
        XCTAssertTrue(app.navigationBars["Connection options"].exists)
        tap("quickConnect")
        XCTAssertTrue(code.waitForExistence(timeout: 8)); let dismissedCode = code.label
        tap("Done", down: true)
        try await post("/qa/quick-connect/approve", ["code": dismissedCode])
        try await Task.sleep(for: .seconds(3))
        XCTAssertTrue(app.textFields["username"].exists)
        XCTAssertFalse(app.buttons["heroPlay"].exists)
        login("quick-cancel-password-recovery-" + UUID().uuidString)
    }

    func testGatewayValidationRowLimitAndSecurePersistence() throws {
        try launch(); tap("advancedConnection")
        func removeRows() {
            for _ in 0..<20 {
                let remove = app.buttons["Remove gateway header"].firstMatch
                if !remove.exists { break }
                reveal(remove, down: true); remove.tap()
            }
        }
        func addRow(_ name: String, _ value: String) {
            tap("addGatewayHeader")
            let names = app.textFields.matching(identifier: "gatewayName")
            replace(names.element(boundBy: names.count - 1), name)
            let values = app.secureTextFields.matching(identifier: "gatewayValue")
            replace(values.element(boundBy: values.count - 1), value)
        }
        removeRows(); tap("saveGatewayHeaders")
        addRow("Invalid Header", "fixture-value"); tap("saveGatewayHeaders")
        XCTAssertTrue(app.staticTexts["gatewayError"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["gatewayError"].label.contains("valid HTTP header"))
        replace(app.textFields["gatewayName"].firstMatch, "Authorization"); tap("saveGatewayHeaders")
        XCTAssertTrue(app.staticTexts["gatewayError"].label.contains("managed by Reel"))
        replace(app.textFields["gatewayName"].firstMatch, "X-Reel-Fixture-Gateway")
        replace(app.secureTextFields["gatewayValue"].firstMatch, "fixture-gateway-secret")
        addRow("x-reel-fixture-gateway", "duplicate-fixture-value"); tap("saveGatewayHeaders")
        XCTAssertTrue(app.staticTexts["gatewayError"].label.contains("different name"))
        let remove = app.buttons.matching(identifier: "Remove gateway header")
        reveal(remove.element(boundBy: remove.count - 1)); remove.element(boundBy: remove.count - 1).tap()
        tap("saveGatewayHeaders")
        XCTAssertTrue(button("saveGatewayHeaders").label.contains("Headers saved"))
        tap("Done", down: true); relaunch(); tap("advancedConnection")
        XCTAssertEqual(app.textFields["gatewayName"].firstMatch.value as? String, "X-Reel-Fixture-Gateway")
        let storedValue = app.secureTextFields["gatewayValue"].firstMatch
        XCTAssertTrue(storedValue.exists)
        XCTAssertNotEqual(storedValue.value as? String, "Header value")
        removeRows(); tap("saveGatewayHeaders"); tap("Done", down: true); tap("advancedConnection")
        XCTAssertFalse(app.textFields["gatewayName"].exists)
        for _ in 0..<16 { tap("addGatewayHeader") }
        XCTAssertFalse(button("addGatewayHeader").isEnabled)
        let lastRemove = app.buttons.matching(identifier: "Remove gateway header").allElementsBoundByIndex.last!
        reveal(lastRemove); lastRemove.tap()
        reveal(button("addGatewayHeader"))
        XCTAssertTrue(button("addGatewayHeader").isEnabled)
        removeRows(); tap("saveGatewayHeaders"); tap("Done", down: true)
    }

    func testActiveServerRemovalCancelFallbackAndLastAccountSignOut() throws {
        try launch()
        let first = "active-first-" + UUID().uuidString, second = "active-second-" + UUID().uuidString
        login(first); settings(); tap("manageServers"); tap("addServer")
        signIn(second, server: secondary)
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.buttons["servers"].label, "Servers")
        XCTAssertTrue((app.buttons["servers"].value as? String ?? "").contains("Reel Second Server"))
        tap("servers"); XCTAssertTrue(app.buttons["server-" + first].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["server-" + second].exists)
        tap("serverOptions-" + second); tap("Remove from device"); cancelConfirmation()
        XCTAssertTrue(app.buttons["server-" + second].exists)
        tap("serverOptions-" + second); tap("Remove from device"); tap("confirmRemoveServer")
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
        relaunch(); XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15)); tap("servers")
        XCTAssertTrue(app.buttons["server-" + first].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["server-" + first].label.contains("Current server"))
        XCTAssertFalse(app.buttons["server-" + second].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-' ")).count, 1)
        tap("Done", down: true); settings(); tap("signOut"); cancelConfirmation()
        XCTAssertTrue(app.navigationBars["Settings"].exists)
        tap("signOut"); tap("Sign out")
        XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 12))
        relaunch(); XCTAssertTrue(app.textFields["username"].waitForExistence(timeout: 10))
    }

    func testSavedConnectionReauthenticationFailureRecoveryAndNoDuplicate() throws {
        try launch()
        let user = "reauth-" + UUID().uuidString
        login(user); tap("servers"); tap("serverOptions-" + user); tap("Sign in again")
        XCTAssertEqual(app.textFields["server"].value as? String, primary)
        XCTAssertEqual(app.textFields["username"].value as? String, "Alex")
        let emptyPassword = app.secureTextFields["password"].value as? String ?? ""
        XCTAssertTrue(emptyPassword.isEmpty || emptyPassword == "Your Jellyfin password")
        signIn(user, password: "wrong-fixture-password")
        XCTAssertTrue(app.staticTexts["connectionError"].waitForExistence(timeout: 8))
        replace(app.secureTextFields["password"], "demo"); tap("connect")
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
        relaunch(); XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15)); tap("servers")
        XCTAssertTrue(app.buttons["server-" + user].waitForExistence(timeout: 8))
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-' ")).count, 1)
        tap("addServer"); tap("Cancel", down: true)
        XCTAssertTrue(app.buttons["server-" + user].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-' ")).count, 1)
    }

    func testPrivateViewingPersistsSuppressesReportsAndCanRecover() async throws {
        try launch()
        let user = "privacy-" + UUID().uuidString
        login(user); configureLocalPlayback(privateViewing: true)
        relaunch(); XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15)); settings()
        reveal(app.switches["privateViewing"]); XCTAssertEqual(app.switches["privateViewing"].value as? String, "1")
        home(); tap("heroPlay")
        openPlayerOptions()
        XCTAssertTrue(app.staticTexts["History off"].waitForExistence(timeout: 12))
        pause(); chooseChapter("A new chapter"); waitPosition(7...9)
        play(); try await Task.sleep(for: .seconds(2)); pause(); closePlayer()
        try await waitReport(user, path: "/Items/movie-1/PlaybackInfo")
        try await Task.sleep(for: .seconds(2))
        let privateReceipts = try await reports(user)
        XCTAssertFalse(privateReceipts.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        settings(); setSwitch("privateViewing", false); home(); tap("heroPlay"); openPlayerOptions(); pause()
        try await waitReport(user, path: "/Sessions/Playing")
        try await waitReport(user, path: "/Sessions/Playing/Progress") { $0["IsPaused"] as? Bool == true }
        closePlayer(); try await waitReport(user, path: "/Sessions/Playing/Stopped")
    }

    func testEveryQualitySettingPersistsAndControlsNegotiation() async throws {
        try launch()
        let user = "quality-" + UUID().uuidString
        login(user)
        for (label, bitrate) in [("Original / auto", 120_000_000), ("High · 20 Mbps", 20_000_000), ("Balanced · 8 Mbps", 8_000_000), ("Data saver · 2 Mbps", 2_000_000)] {
            configureLocalPlayback(quality: label)
            relaunch(); XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15)); settings()
            reveal(button("qualityPicker")); XCTAssertTrue(button("qualityPicker").label.contains(label))
            let before = try await reports(user).count
            home(); tap("heroDetails")
            XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
            if app.buttons["detailStartOver"].waitForExistence(timeout: 2) { tap("detailStartOver") }
            else { tap("detailPlay") }
            openPlayerOptions()
            try await waitReport(user, path: "/Items/movie-1/PlaybackInfo", after: before) {
                ($0["MaxStreamingBitrate"] as? NSNumber)?.intValue == bitrate && ($0["StartTimeTicks"] as? NSNumber)?.int64Value == 0
            }
            tap("Done", down: true); tap("closePlayer", down: true); tap("BackButton", down: true)
            XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 10))
        }
        configureLocalPlayback()
    }

    func testServerPreferenceRefreshLocksThenLocalControlsRecover() async throws {
        try launch()
        let user = "preference-refresh-" + UUID().uuidString
        login(user); configureLocalPlayback(); setSwitch("useServerPreferences", true)
        reveal(app.staticTexts["4 Mbps"]); XCTAssertTrue(app.staticTexts["4 Mbps"].waitForExistence(timeout: 8))
        reveal(button("qualityPicker"), down: true); XCTAssertFalse(button("qualityPicker").isEnabled)
        let beforeState = try await state()
        let before = (beforeState["requests"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/streamyfin/config" }.count
        tap("refreshServerPreferences")
        let deadline = Date().addingTimeInterval(8)
        var refreshed = false
        repeat {
            let snapshot = try await state()
            let count = (snapshot["requests"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/streamyfin/config" }.count
            if count > before { refreshed = true; break }
            try await Task.sleep(for: .milliseconds(250))
        } while Date() < deadline
        XCTAssertTrue(refreshed, "Refresh must make a real config request")
        XCTAssertTrue(app.staticTexts["4 Mbps"].exists)
        home(); tap("heroPlay"); openPlayerOptions()
        XCTAssertFalse(button("playbackSpeed").isEnabled)
        XCTAssertTrue(button("Forward 30 seconds").exists)
        closePlayer(); settings(); setSwitch("useServerPreferences", false)
        reveal(button("qualityPicker"), down: true); XCTAssertTrue(button("qualityPicker").isEnabled)
        relaunch(); XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15)); settings()
        reveal(app.switches["useServerPreferences"]); XCTAssertEqual(app.switches["useServerPreferences"].value as? String, "0")
        home(); tap("heroPlay"); openPlayerOptions()
        XCTAssertTrue(button("playbackSpeed").isEnabled)
        tap("playbackSpeed"); tap("1×"); closePlayer()
    }

    func testPlayerTransportChapterSkipAndEverySpeedHaveNativeEffects() async throws {
        try launch()
        let user = "player-controls-" + UUID().uuidString
        login(user); configureLocalPlayback(); home(); tap("heroPlay"); openPlayerOptions(); pause()
        chooseChapter("A new chapter"); waitPosition(8...9)
        let reportStart = try await reports(user).count
        play(); pause()
        try await waitReport(user, path: "/Sessions/Playing/Progress", after: reportStart) {
            $0["IsPaused"] as? Bool == true && (70_000_000...110_000_000).contains(($0["PositionTicks"] as? NSNumber)?.int64Value ?? -1)
        }
        let pausedAt = seconds(timeline())
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(seconds(timeline()), pausedAt, accuracy: 1)
        tap("Back 10 seconds", down: true); waitPosition(0...0)
        tap("Forward 10 seconds", down: true); waitPosition(10...11)
        tap("Back 10 seconds", down: true); waitPosition(0...1)
        for rate in [0.5, 0.75, 1.0, 1.25, 1.5, 2.0] {
            chooseChapter("Opening"); waitPosition(0...1)
            let label = String(format: "%g×", rate)
            tap("playbackSpeed"); tap(label)
            XCTAssertTrue(button("playbackSpeed").label.contains(label))
            let start = seconds(timeline()), began = Date()
            play(); try await Task.sleep(for: .seconds(4)); pause()
            let elapsed = Date().timeIntervalSince(began), advanced = seconds(timeline()) - start
            XCTAssertGreaterThanOrEqual(advanced, max(1, elapsed * rate - 3), "Native playback did not advance at \(label)")
            XCTAssertLessThanOrEqual(advanced, elapsed * rate + 3, "Native playback advanced too far at \(label)")
        }
        tap("playbackSpeed"); tap("1×"); chooseChapter("Opening"); waitPosition(0...1)
        tap("Done", down: true)
        XCTAssertTrue(app.buttons["skipSegment"].waitForExistence(timeout: 8)); tap("skipSegment")
        openPlayerOptions(); waitPosition(3...5)
        let beforeUnpause = try await reports(user).count
        play()
        try await waitReport(user, path: "/Sessions/Playing/Progress", after: beforeUnpause) { $0["IsPaused"] as? Bool == false }
        pause(); attach("extended-native-player-controls"); closePlayer()
    }

    func testSleepTimerChoicesCancelAndResetOnNewPlayback() throws {
        try launch()
        login("sleep-controls-" + UUID().uuidString); configureLocalPlayback(); home(); tap("heroPlay"); openPlayerOptions(); pause()
        for minutes in [15, 30, 45, 60] {
            tap("sleepTimer"); tap("\(minutes) minutes")
            XCTAssertTrue(button("sleepTimer").label.contains("Timer on"))
            XCTAssertEqual(button("transportPlayPause").label, "Play")
            tap("sleepTimer"); tap("Off")
            XCTAssertTrue(button("sleepTimer").label.contains("Sleep timer"))
        }
        play(); tap("sleepTimer"); tap("60 minutes")
        XCTAssertEqual(button("transportPlayPause").label, "Pause")
        closePlayer(); tap("heroPlay"); openPlayerOptions()
        XCTAssertTrue(button("sleepTimer").label.contains("Sleep timer"))
        closePlayer()
    }

    func testPlayerSeekUpperBoundaryEndsAndReturnsToLibrary() async throws {
        try launch()
        let user = "player-boundaries-" + UUID().uuidString
        login(user); configureLocalPlayback(); home(); tap("heroPlay"); openPlayerOptions(); pause()
        chooseChapter("A new chapter"); waitPosition(8...9)
        tap("Forward 10 seconds", down: true); waitPosition(18...19)
        tap("Back 10 seconds", down: true); waitPosition(8...9)
        let scrubber = timeline()
        scrubber.adjust(toNormalizedSliderPosition: 0.5)
        waitPosition(11...13)
        play()
        // Two ten-second skips from the middle of the 24-second clip pass its end.
        tap("Forward 10 seconds", down: true); tap("Forward 10 seconds", down: true); waitPosition(23...24)
        tap("Done", down: true)
        XCTAssertTrue(app.staticTexts["Finished watching"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["playNext"].exists)
        try await waitReport(user, path: "/Sessions/Playing/Stopped") {
            (230_000_000...250_000_000).contains(($0["PositionTicks"] as? NSNumber)?.int64Value ?? -1)
        }
        tap("Back to your library")
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 10))
    }

    func testWatchReportFailurePersistsAndRetriesAfterRelaunch() async throws {
        try launch()
        let user = "report-recovery-" + UUID().uuidString
        login(user); configureLocalPlayback()
        try await post("/qa/control", ["failReports": true])
        home(); tap("heroPlay"); openPlayerOptions(); pause()
        chooseChapter("A new chapter"); waitPosition(8...9)
        play(); pause()
        tap("Done", down: true)
        let warning = app.staticTexts["syncError"]
        XCTAssertTrue(warning.waitForExistence(timeout: 15))
        XCTAssertTrue(warning.label.contains("saved here"))
        let failedReceipts = try await reports(user)
        XCTAssertFalse(failedReceipts.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        closePlayer(); app.terminate()
        try await post("/qa/control", ["failReports": false])
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 20))
        try await waitReport(user, path: "/Sessions/Playing/Stopped") {
            (70_000_000...130_000_000).contains(($0["PositionTicks"] as? NSNumber)?.int64Value ?? -1)
        }
        tap("heroPlay"); openPlayerOptions(); pause()
        waitPosition(7...14)
        tap("Done", down: true)
        XCTAssertFalse(app.staticTexts["syncError"].exists)
        closePlayer()
    }

    func testSyncPlayGroupControlsDisableLocalOptionsAndLeaveRecovers() throws {
        try launch()
        signIn("sync-options-" + UUID().uuidString, server: "http://127.0.0.1:18769")
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15))
        configureLocalPlayback(); destination("Devices", title: "Players & watch together")
        tap("syncJoin-fixture-group")
        XCTAssertTrue(app.buttons["groupControls"].waitForExistence(timeout: 15))
        openPlayerOptions()
        for id in ["playbackSpeed", "sleepTimer", "playerChapters"] {
            reveal(button(id))
            XCTAssertTrue(button(id).exists, "Expected managed option \(id)")
            XCTAssertFalse(button(id).isEnabled, "Group playback must disable independent \(id)")
        }
        tap("Done", down: true); tap("groupControls", down: true)
        XCTAssertTrue(app.navigationBars["Players & watch together"].waitForExistence(timeout: 8))
        let active = app.descendants(matching: .any).matching(identifier: "activeSyncGroup").firstMatch
        reveal(active); XCTAssertTrue(active.exists)
        tap("syncLeave")
        XCTAssertTrue(app.buttons["syncJoin-fixture-group"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["groupControls"].exists)
        XCTAssertFalse(app.descendants(matching: .any).matching(identifier: "nativePlayer").firstMatch.exists, "Leaving the group must close local video playback.")
        home(); tap("heroPlay"); openPlayerOptions()
        for id in ["playbackSpeed", "sleepTimer", "playerChapters"] {
            reveal(button(id)); XCTAssertTrue(button(id).isEnabled, "Leaving must restore local \(id)")
        }
        closePlayer()
    }

    func testPlayerFailureRetryOriginalQualityRecoveryAndPersistence() async throws {
        try launch()
        try await post("/qa/control", ["recoveryAllowed": false])
        login("failed-recovery"); configureLocalPlayback(quality: "Data saver · 2 Mbps"); home(); tap("heroPlay")
        XCTAssertTrue(app.buttons["originalQualityRecovery"].waitForExistence(timeout: 40))
        let before = try await reports("failed-recovery").count
        tap("retry")
        XCTAssertTrue(app.buttons["originalQualityRecovery"].waitForExistence(timeout: 40))
        try await waitReport("failed-recovery", path: "/Items/movie-1/PlaybackInfo", after: before)
        try await post("/qa/control", ["recoveryAllowed": true])
        let beforeRecovery = try await reports("failed-recovery").count
        tap("originalQualityRecovery"); openPlayerOptions()
        try await waitReport("failed-recovery", path: "/Items/movie-1/PlaybackInfo", after: beforeRecovery) { ($0["MaxStreamingBitrate"] as? NSNumber)?.intValue == 120_000_000 }
        XCTAssertFalse(app.buttons["retry"].exists)
        closePlayer(); relaunch(); XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 15)); settings()
        reveal(button("qualityPicker")); XCTAssertTrue(button("qualityPicker").label.contains("Original / auto"))
    }

    private func assertReadableAccessibilityMenu(_ id: String, maximumCaptionLines: CGFloat) {
        let menu = button(id)
        reveal(menu)
        XCTAssertTrue(menu.exists)
        XCTAssertTrue(menu.isHittable, "The complete menu must remain reachable")
        let window = app.windows.firstMatch.frame
        XCTAssertGreaterThan(menu.frame.minY, window.minY + 8)
        XCTAssertLessThan(menu.frame.maxY, window.maxY - 8)
        for bar in app.navigationBars.allElementsBoundByIndex where bar.frame.intersects(window)
            && (bar.isHittable || bar.buttons.allElementsBoundByIndex.contains { $0.isHittable }) {
            XCTAssertFalse(menu.frame.intersects(bar.frame), "Menu captions must be clear of the navigation bar")
        }
        let traits = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
        let lineHeight = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).lineHeight
        XCTAssertLessThanOrEqual(menu.frame.height, max(44, lineHeight * maximumCaptionLines + 24),
                                 "Menu captions must wrap by words rather than into character columns")
        attach("readable-accessibility-" + id)
    }

    private func assertPausedSession(_ user: String, stoppedCount: Int, step: String) async throws {
        let transport = button("transportPlayPause")
        let receipts = try await reports(user)
        let stopped = receipts.filter { $0["path"] as? String == "/Sessions/Playing/Stopped" }.count
        if !transport.exists || !transport.isEnabled || transport.label != "Play" || stopped != stoppedCount {
            attach("paused-session-divergence-" + step)
            let data = try JSONSerialization.data(withJSONObject: receipts, options: [.prettyPrinted, .sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "paused-session-receipts-" + step
            attachment.lifetime = .keepAlways
            add(attachment)
        }
        XCTAssertTrue(transport.exists && transport.isEnabled, "\(step): paused transport must remain available")
        XCTAssertEqual(transport.label, "Play", "\(step): options must retain pause")
        XCTAssertEqual(stopped, stoppedCount, "\(step): options must preserve the playback session")
    }

    func testLargeTextPlayerOptionsRotationPauseSeekAndClose() async throws {
        try launch(largeText: true)
        let user = "large-player-" + UUID().uuidString
        login(user); configureLocalPlayback(); home(); tap("heroPlay"); openPlayerOptions(); pause()
        let before = try await reports(user).filter { $0["path"] as? String == "/Sessions/Playing/Stopped" }.count
        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait, .landscapeRight, .portrait] {
            XCUIDevice.shared.orientation = orientation
            try await assertPausedSession(user, stoppedCount: before, step: "rotated-\(orientation.rawValue)")
            assertReadableAccessibilityMenu("playbackSpeed", maximumCaptionLines: 1)
            try await assertPausedSession(user, stoppedCount: before, step: "speed-revealed-\(orientation.rawValue)")
            tap("playbackSpeed")
            attach("opened-accessibility-speed-menu")
            tap("1.25×")
            XCTAssertTrue(button("playbackSpeed").label.contains("1.25"))
            try await assertPausedSession(user, stoppedCount: before, step: "speed-selected-\(orientation.rawValue)")
            assertReadableAccessibilityMenu("playerChapters", maximumCaptionLines: 1)
            chooseChapter("A new chapter"); waitPosition(7...9)
            try await assertPausedSession(user, stoppedCount: before, step: "chapter-selected-\(orientation.rawValue)")
            assertReadableAccessibilityMenu("sleepTimer", maximumCaptionLines: 2)
            tap("sleepTimer"); tap("15 minutes")
            XCTAssertTrue(button("sleepTimer").label.contains("Timer on"))
            tap("sleepTimer"); tap("Off")
            wait(button("sleepTimer"), NSPredicate(format: "label CONTAINS %@", "Sleep timer"))
            try await assertPausedSession(user, stoppedCount: before, step: "timer-cleared-\(orientation.rawValue)")
            tap("Done", down: true); openPlayerOptions()
            let cycleReports = try await reports(user)
            XCTAssertEqual(cycleReports.filter { $0["path"] as? String == "/Sessions/Playing/Stopped" }.count, before,
                           "Each options cycle must preserve the native playback session")
            let geometry = XCTAttachment(string: "Requested orientation: \(orientation.rawValue); actual window: \(app.windows.firstMatch.frame)")
            geometry.name = "player-options-orientation-window"; geometry.lifetime = .keepAlways; add(geometry)
        }
        let after = try await reports(user).filter { $0["path"] as? String == "/Sessions/Playing/Stopped" }.count
        XCTAssertEqual(after, before, "Options and rotation must retain the native playback session")
        attach("extended-player-accessibility-text-rotation")
        closePlayer(); try await waitReport(user, path: "/Sessions/Playing/Stopped")
    }
}
