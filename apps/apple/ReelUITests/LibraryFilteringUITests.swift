import XCTest
import UIKit

@MainActor final class LibraryFilteringUITests: XCTestCase {
    private var app = XCUIApplication()
    private var user = ""
    private var observedUsers = Set<String>()

    private func launch(accessibility: Bool = false, userOverride: String? = nil) throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("These account-reset journeys require a disposable simulator and synthetic loopback server.")
        #else
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        user = userOverride ?? "library-" + UUID().uuidString
        observedUsers.insert(user)
        app.launchArguments = ["-reel-qa-reset"]
        if accessibility { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launch()
        let username = app.textFields["username"]
        XCTAssertTrue(username.waitForExistence(timeout: 10))
        for _ in 0..<10 {
            let frame = username.frame
            if username.isHittable && frame.minY > app.windows.firstMatch.frame.minY + 24 && frame.maxY < app.windows.firstMatch.frame.maxY - 24 { break }
            app.swipeUp()
        }
        username.tap(); username.typeText(user); username.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        XCTAssertTrue(password.isHittable)
        password.typeText("demo"); password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15), app.debugDescription)
        dismissPasswordSavePrompt()
        #endif
    }

    private func dismissPasswordSavePrompt() {
        let decline = app.buttons["Not Now"]
        if decline.waitForExistence(timeout: 3) {
            let promptTitle = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Save Password?")).firstMatch
            XCTAssertTrue(promptTitle.exists, "Only dismiss the system password-save prompt.\n\(app.debugDescription)")
            XCTAssertTrue(decline.isHittable)
            decline.tap()
            XCTAssertTrue(decline.waitForNonExistence(timeout: 5))
        }
    }

    private func tab(_ title: String) {
        let value = app.buttons[title].firstMatch
        XCTAssertTrue(value.waitForExistence(timeout: 5))
        XCTAssertTrue(value.isHittable)
        let frame = value.frame, window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(frame))
        // Native glass tabs can expose an invalid automatic hit point while
        // their full, visible control bounds remain stable.
        value.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.navigationBars[title].waitForExistence(timeout: 8), app.debugDescription)
    }

    private func initialSearchField() -> XCUIElement {
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 8), "Dedicated Search must expose its input immediately, before any reveal gesture.")
        let window = app.windows.firstMatch.frame
        let bottom = app.tabBars.firstMatch.exists ? min(window.maxY, app.tabBars.firstMatch.frame.minY) : window.maxY
        XCTAssertGreaterThan(field.frame.width, 0)
        XCTAssertGreaterThan(field.frame.height, 0)
        XCTAssertTrue(window.contains(field.frame))
        XCTAssertLessThanOrEqual(field.frame.maxY, bottom)
        XCTAssertTrue(field.isHittable)
        attach("library-search-initial-field-visible")
        return field
    }

    private func visibleSearchField(in scroll: XCUIElement) -> XCUIElement {
        let field = app.searchFields.firstMatch
        for attempt in 0...4 {
            let window = app.windows.firstMatch.frame
            let keyboard = app.keyboards.firstMatch
            let bottom = keyboard.exists ? min(window.maxY, keyboard.frame.minY) : window.maxY
            if field.exists && field.frame.height > 0 && window.contains(field.frame) && field.frame.maxY <= bottom && field.isHittable {
                return field
            }
            guard attempt < 4 else { break }
            XCTAssertTrue(scroll.exists)
            // Native searchable can start collapsed. Reveal it through its
            // real vertical scroll before locating or tapping the field.
            scroll.swipeDown()
        }
        attach("library-search-field-not-reachable")
        XCTFail("The native Search field must become fully visible and hittable through ordinary scrolling.")
        return field
    }

    private func back() {
        let navigationBack = app.navigationBars.buttons.firstMatch
        let control: XCUIElement
        if navigationBack.exists { control = navigationBack }
        else {
            attach("library-native-side-back-control")
            control = app.buttons["BackButton"]
        }
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(control.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame))
        control.tap()
    }

    private func select(_ menu: String, _ label: String) {
        let control = app.buttons[menu]
        XCTAssertTrue(control.waitForExistence(timeout: 8), app.debugDescription)
        XCTAssertTrue(control.isHittable)
        control.tap()
        let option = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@ AND NOT (identifier BEGINSWITH 'filter-')", label, menu)).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5), app.debugDescription)
        option.tap()
    }

    private func selectScrollableMenu(_ menu: String, _ label: String, in scroll: XCUIElement) {
        reveal(app.buttons[menu], in: scroll, up: false)
        app.buttons[menu].tap()
        let option = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@ AND NOT (identifier BEGINSWITH 'filter-')", label, menu)).firstMatch
        for attempt in 0...12 {
            let window = app.windows.firstMatch.frame
            let popups = app.collectionViews.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.buttons.count > 0 && $0.frame.intersects(window) }
            XCTAssertEqual(popups.count, 1, "Only the foreground native menu should own these options.")
            guard let popup = popups.first,
                  let visibleOption = popup.buttons.allElementsBoundByAccessibilityElement.first(where: { $0.exists && popup.frame.intersection(window).contains($0.frame) && $0.isHittable }) else {
                XCTFail("The native menu has no reachable option.\n\(app.debugDescription)"); return
            }
            let owners = app.otherElements.containing(.button, identifier: visibleOption.label).allElementsBoundByAccessibilityElement
            guard let owner = owners.filter({ $0.frame.width >= popup.frame.width - 1 && $0.frame.height > 80 }).min(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) else {
                XCTFail("The native menu's visible clipping container is missing.\n\(app.debugDescription)"); return
            }
            let visible = popup.frame.intersection(owner.frame).intersection(window)
            XCTAssertGreaterThan(visible.height, 80)
            if option.exists && visible.contains(option.frame) && option.isHittable { option.tap(); return }
            guard attempt < 12 else { break }
            let fingerDown = option.exists && option.frame.minY < visible.minY
            let needed = option.exists ? (fingerDown ? visible.minY - option.frame.minY : option.frame.maxY - visible.maxY) : visible.height
            let distance = min(max(needed + 12, 44), visible.height * 0.6)
            let origin = popup.coordinate(withNormalizedOffset: .zero)
            let x = visible.midX - popup.frame.minX
            let startY = (fingerDown ? visible.minY + 16 : visible.maxY - 16) - popup.frame.minY
            let endY = startY + (fingerDown ? distance : -distance)
            let start = origin.withOffset(CGVector(dx: x, dy: startY))
            let end = origin.withOffset(CGVector(dx: x, dy: endY))
            start.press(forDuration: 0.05, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        XCTFail("Menu option did not become fully reachable: \(label)\n\(app.debugDescription)")
    }

    private func category(_ name: String) {
        let identifier = "filter-" + name
        let button = app.buttons[identifier]
        let rail = app.scrollViews.containing(.button, identifier: identifier).firstMatch
        for _ in 0..<8 {
            let window = app.windows.firstMatch.frame
            if button.isHittable && button.frame.minX >= window.minX && button.frame.maxX <= window.maxX { break }
            if name == "All" { rail.swipeRight() } else { rail.swipeLeft() }
        }
        XCTAssertTrue(button.isHittable)
        button.tap()
    }

    private func first(_ suffix: String, timeout: TimeInterval = 10) async {
        let expected = "item-library-title-" + suffix
        let query = app.scrollViews["libraryScroll"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-library-title-'"))
        let predicate = NSPredicate { _, _ in query.firstMatch.exists && query.firstMatch.identifier == expected }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
        XCTAssertTrue(query.firstMatch.isHittable)
    }

    private func firstEpisode(_ suffix: String) async {
        let expected = "item-library-episode-" + suffix
        let rows = app.scrollViews["libraryScroll"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-library-episode-'"))
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in rows.firstMatch.exists && rows.firstMatch.identifier == expected }, object: nil)], timeout: 10)
        XCTAssertTrue(rows.firstMatch.isHittable)
    }

    private func assertNoWatchReports() async throws {
        let state = try await json("/qa/state")
        let reports = try XCTUnwrap(state["reports"] as? [[String: Any]])
        XCTAssertFalse(reports.contains {
            guard let reportedUser = $0["user"] as? String else { return false }
            return observedUsers.contains(reportedUser) || reportedUser == user
        }, "Browsing and filters must not generate watch reports for either saved account.")
    }

    private func count(_ total: Int) {
        XCTAssertTrue(app.staticTexts["\(total) titles"].waitForExistence(timeout: 10), app.debugDescription)
    }

    @discardableResult
    private func refreshAccessibleLibrary(in scroll: XCUIElement, label: String = "Refresh library", centered: Bool = false) -> XCUIElement {
        let control = scroll.buttons["libraryRefresh"]
        reveal(control, in: scroll, centered: centered)
        XCTAssertTrue(control.isHittable)
        XCTAssertTrue(control.isEnabled)
        XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        XCTAssertEqual(control.label, label)
        XCTAssertEqual(control.value as? String, "Ready")
        control.tap()
        return control
    }

    @discardableResult
    private func refreshLibraryFromToolbar(label: String = "Refresh library") -> XCUIElement {
        let control = app.navigationBars.buttons["libraryRefresh"]
        XCTAssertTrue(control.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(control.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(control.frame))
        XCTAssertGreaterThanOrEqual(control.frame.height, 44)
        XCTAssertTrue(control.isEnabled)
        XCTAssertEqual(control.label, label)
        XCTAssertEqual(control.value as? String, "Ready")
        control.tap()
        return control
    }

    private func json(_ path: String, body: [String: Any]? = nil, forUser: String? = nil) async throws -> [String: Any] {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic fixture controls require a disposable simulator.")
        #else
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18766" + path)!)
        request.setValue("MediaBrowser Token=\"fixture-\(forUser ?? user)\"", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
        #endif
    }

    private func itemQueries() async throws -> [[String: String]] {
        let receipts = try await json("/qa/library-state")["requests"] as? [[String: Any]] ?? []
        return receipts.filter { $0["path"] as? String == "/Items" }.compactMap { $0["query"] as? [String: String] }
    }

    private func recordedReads(path: String = "/Items", query: [String: String]) async throws -> [[String: Any]] {
        let state = try await json("/qa/library-state")
        return (state["requests"] as? [[String: Any]] ?? []).filter { entry in
            guard entry["path"] as? String == path, let actual = entry["query"] as? [String: String] else { return false }
            return query.allSatisfy { actual[$0.key] == $0.value }
        }
    }

    private func waitForCompletedRead(after previousCount: Int, path: String = "/Items", query: [String: String]) async throws {
        for _ in 0..<50 {
            let reads = try await recordedReads(path: path, query: query)
            if reads.count > previousCount, reads.last?["status"] as? Int == 200 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The actual Refresh action must complete a fresh request for its current results.")
    }

    private func keyboardContainerBottom(_ bottom: CGFloat, viewport: CGRect, containers: [CGRect]) -> CGFloat {
        var result = bottom
        for frame in containers where frame.width > 0 && frame.height > 0 && frame.intersects(viewport) {
            result = min(result, max(viewport.minY, frame.minY))
        }
        return result
    }

    private func reveal(_ element: XCUIElement, in scroll: XCUIElement, up: Bool = true, centered: Bool = false) {
        for _ in 0..<30 {
            let window = app.windows.firstMatch.frame
            XCTAssertTrue(scroll.exists)
            let scrollFrame = scroll.frame
            let navigation = app.navigationBars.firstMatch
            let top = max(scrollFrame.minY, navigation.exists ? navigation.frame.maxY : window.minY)
            var bottom = app.tabBars.firstMatch.exists ? min(scrollFrame.maxY, app.tabBars.firstMatch.frame.minY) : min(scrollFrame.maxY, window.maxY)
            let keyboard = app.keyboards.firstMatch
            if keyboard.exists { bottom = min(bottom, keyboard.frame.minY) }
            var keyboardContainers: [CGRect] = []
            for identifier in ["inputView", "SystemInputAssistantView"] {
                for container in app.otherElements.matching(identifier: identifier).allElementsBoundByAccessibilityElement where container.exists {
                    keyboardContainers.append(container.frame)
                }
            }
            bottom = keyboardContainerBottom(bottom, viewport: scrollFrame.intersection(window), containers: keyboardContainers)
            let visible = CGRect(x: max(window.minX, scrollFrame.minX), y: top,
                                 width: min(window.maxX, scrollFrame.maxX) - max(window.minX, scrollFrame.minX), height: bottom - top)
            guard visible.width > 24, visible.height > 80 else {
                attach("library-no-usable-scroll-viewport")
                XCTFail("The owning scroll has no usable viewport."); return
            }
            if element.exists {
                let frame = element.frame
                if element.isHittable && frame.minY >= top && frame.maxY <= bottom { return }
                let fingerDown = frame.minY < top
                let needed = fingerDown ? top - frame.minY : frame.maxY - bottom
                if centered {
                    if needed > 0, needed < visible.height * 2 {
                        let distance = min(max(needed + 12, 44), visible.height * 0.5)
                        let x = visible.midX
                        let startY = visible.minY + visible.height * (fingerDown ? 0.25 : 0.75)
                        let endY = startY + (fingerDown ? distance : -distance)
                        let origin = scroll.coordinate(withNormalizedOffset: .zero)
                        let start = origin.withOffset(CGVector(dx: x - scrollFrame.minX, dy: startY - scrollFrame.minY))
                        let end = origin.withOffset(CGVector(dx: x - scrollFrame.minX, dy: endY - scrollFrame.minY))
                        start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .fast, thenHoldForDuration: 0.1)
                    } else if fingerDown { scroll.swipeDown() } else { scroll.swipeUp() }
                    continue
                }
                if needed > 0, needed < visible.height * 2 {
                    // A full swipe can jump across the narrow band where a
                    // whole poster fits. Use the grid's blank leading gutter
                    // for a small native pan, wholly inside its viewport.
                    let distance = min(max(needed + 12, 44), visible.height * 0.65)
                    let x = visible.minX + 10
                    let startY = fingerDown ? visible.minY + 12 : visible.maxY - 12
                    let endY = startY + (fingerDown ? distance : -distance)
                    let origin = scroll.coordinate(withNormalizedOffset: .zero)
                    let start = origin.withOffset(CGVector(dx: x - scrollFrame.minX, dy: startY - scrollFrame.minY))
                    let end = origin.withOffset(CGVector(dx: x - scrollFrame.minX, dy: endY - scrollFrame.minY))
                    start.press(forDuration: 0.1, thenDragTo: end, withVelocity: .slow, thenHoldForDuration: 0.1)
                    continue
                }
                if fingerDown { scroll.swipeDown(); continue }
            }
            if up { scroll.swipeUp() } else { scroll.swipeDown(velocity: .fast) }
        }
        XCTFail("Control not fully reachable in its owning scroll: \(element)\n\(app.debugDescription)")
    }

    private func attach(_ name: String) {
        let capture = XCTAttachment(screenshot: app.screenshot()); capture.name = name; capture.lifetime = .keepAlways; add(capture)
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + "-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
    }

    private func tapLibraryItem(_ identifier: String) {
        let scroll = app.scrollViews["libraryScroll"]
        let rows = scroll.buttons.matching(identifier: identifier)
        XCTAssertEqual(rows.count, 1, "The foreground library must have exactly one matching listing.")
        let row = rows.firstMatch
        reveal(row, in: scroll)
        let window = app.windows.firstMatch.frame
        let top = max(scroll.frame.minY, app.navigationBars.firstMatch.frame.maxY)
        let bottom = app.tabBars.firstMatch.exists ? min(scroll.frame.maxY, app.tabBars.firstMatch.frame.minY) : min(scroll.frame.maxY, window.maxY)
        let usable = CGRect(x: max(window.minX, scroll.frame.minX), y: top,
                            width: min(window.maxX, scroll.frame.maxX) - max(window.minX, scroll.frame.minX), height: bottom - top)
        let receipt = XCTAttachment(string: "identifier=\(identifier); globalMatches=\(app.buttons.matching(identifier: identifier).count); foregroundMatches=\(rows.count); frame=\(row.frame); usable=\(usable); hittable=\(row.isHittable)")
        receipt.name = "library-listing-tap-bounds"; receipt.lifetime = .keepAlways; add(receipt)
        XCTAssertTrue(usable.contains(row.frame), "The whole listing must be visible before tapping it.")
        XCTAssertTrue(row.isHittable)
        row.tap()
    }

    private func addSavedAccount(_ username: String) {
        app.buttons["servers"].tap()
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 8))
        app.buttons["addServer"].tap()
        let field = app.textFields["username"]
        XCTAssertTrue(field.waitForExistence(timeout: 8))
        let form = app.scrollViews.containing(.textField, identifier: "username").firstMatch
        reveal(field, in: form)
        field.tap(); field.typeText(username); field.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        XCTAssertTrue(password.isHittable)
        password.typeText("demo"); password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        dismissPasswordSavePrompt()
        observedUsers.insert(username)
        user = username
    }

    private func switchSavedAccount(_ username: String) {
        app.buttons["servers"].tap()
        let servers = app.navigationBars["Servers"]
        XCTAssertTrue(servers.waitForExistence(timeout: 8))
        let account = app.buttons["server-" + username]
        XCTAssertTrue(account.isHittable)
        account.tap()
        XCTAssertTrue(servers.waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["heroDetails"].isHittable)
        user = username
    }

    private func episodeFeeds(forUser: String) async throws -> [[String: Any]] {
        let receipts = try await json("/qa/library-state", forUser: forUser)["requests"] as? [[String: Any]] ?? []
        return receipts.filter { entry in
            let query = entry["query"] as? [String: String]
            return entry["path"] as? String == "/Items" && query?["includeitemtypes"] == "Episode" && query?["limit"] == "18"
        }
    }

    func testRecentlyAddedShelvesSeeAllPreservesOrder() async throws {
        try launch()
        let home = app.scrollViews["homeScroll"]
        let movieLink = app.buttons["recent-Movies-seeAll"].exists ? app.buttons["recent-Movies-seeAll"] : app.buttons["See all"].firstMatch
        reveal(movieLink, in: home); movieLink.tap()
        count(96)
        let queries = try await itemQueries()
        XCTAssertEqual(queries.last?["sortby"]?.components(separatedBy: ",").first, "DateCreated", "A Recently added shelf must continue into Recently added, not Title.")
        await first("007")
        let movieQuery = ["includeitemtypes": "Movie", "sortby": "DateCreated,SortName", "startindex": "0"]
        let movieReads = try await recordedReads(query: movieQuery)
        refreshLibraryFromToolbar()
        try await waitForCompletedRead(after: movieReads.count, query: movieQuery)
        count(96); await first("007")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        attach("library-recent-movies")
        back()
        let seriesLink = app.buttons["recent-Series-seeAll"]
        reveal(seriesLink, in: home); seriesLink.tap()
        count(48); await first("087")
        let seriesQueries = try await itemQueries()
        XCTAssertEqual(seriesQueries.last?["includeitemtypes"], "Series")
        XCTAssertEqual(seriesQueries.last?["sortby"], "DateCreated,SortName")
    }

    func testVisibleSortsAndIndividualFilters() async throws {
        try launch(); tab("Library"); count(144); await first("048")
        select("librarySort", "Recently added"); await first("007")
        let recentRows = app.scrollViews["libraryScroll"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-library-title-'"))
        XCTAssertEqual(recentRows.element(boundBy: 0).identifier, "item-library-title-007")
        XCTAssertEqual(recentRows.element(boundBy: 1).identifier, "item-library-title-127", "Titles sharing an added date must retain the server's secondary title order.")
        XCTAssertTrue(recentRows.element(boundBy: 1).isHittable)
        attach("library-recent-secondary-title-order")
        select("librarySort", "Release year"); await first("017")
        select("librarySort", "Title"); await first("048")
        category("Movies"); count(96); await first("013")
        category("Series"); count(48); await first("048")
        category("Favorites"); count(41)
        category("All"); count(144)
        select("libraryFilters", "Films"); count(96)
        select("libraryFilters", "All libraries"); count(144)
        select("libraryFilters", "Shows"); count(48)
        select("libraryFilters", "All libraries"); count(144)
        select("libraryFilters", "Adventure"); count(72)
        select("libraryFilters", "All genres"); count(144)
        select("libraryFilters", "Drama"); count(108)
        select("libraryFilters", "All genres"); count(144)
        select("libraryFilters", "Watched"); count(57)
        select("libraryFilters", "Unwatched"); count(87)
        select("libraryFilters", "Any"); count(144)
        let queries = try await itemQueries()
        XCTAssertTrue(queries.contains { $0["sortby"] == "DateCreated,SortName" && $0["sortorder"] == "Descending,Ascending" })
        attach("library-controls-default")
    }

    func testCombinedFiltersClearAndNavigation() async throws {
        try launch(); tab("Library"); count(144)
        select("libraryFilters", "Films")
        select("librarySort", "Recently added")
        select("libraryFilters", "Adventure")
        select("libraryFilters", "Unwatched")
        count(28); await first("134")
        let queries = try await itemQueries()
        let last = queries.last
        XCTAssertEqual(last?["parentid"], "library-films")
        XCTAssertEqual(last?["genreids"], "library-adventure")
        XCTAssertEqual(last?["isplayed"], "false")
        XCTAssertEqual(last?["sortby"], "DateCreated,SortName")
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].label.contains("Films"))
        attach("library-combined-filters")
        select("libraryFilters", "Clear filters"); count(144); await first("007")
        XCTAssertFalse(app.staticTexts["libraryFilterSummary"].exists)
        tapLibraryItem("item-library-title-007")
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 8))
        back()
        XCTAssertTrue(app.buttons["librarySort"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        await first("007")
    }

    func testPaginationErrorRetryAndRefresh() async throws {
        try launch()
        _ = try await json("/qa/library-control", body: ["failLater": 1])
        tab("Library"); count(144)
        select("librarySort", "Recently added"); await first("007")
        let scroll = app.scrollViews["libraryScroll"]
        let more = app.buttons["loadMore"]
        let firstTail = app.buttons["item-library-title-039"]
        reveal(firstTail, in: scroll)
        XCTAssertTrue(firstTail.isHittable)
        reveal(more, in: scroll); more.tap()
        let retry = app.buttons["libraryRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        reveal(retry, in: scroll); retry.tap()
        XCTAssertTrue(more.waitForExistence(timeout: 10))
        let secondTail = app.buttons["item-library-title-071"]
        reveal(secondTail, in: scroll)
        XCTAssertTrue(secondTail.isHittable)
        reveal(more, in: scroll); more.tap()
        XCTAssertTrue(more.waitForNonExistence(timeout: 10))
        let finalTail = app.buttons["item-library-title-040"]
        reveal(finalTail, in: scroll)
        XCTAssertTrue(finalTail.isHittable)
        let queries = try await itemQueries()
        let starts = queries.filter { $0["sortby"] == "DateCreated,SortName" && $0["includeitemtypes"] == "Movie,Series" }.compactMap { $0["startindex"] }
        XCTAssertEqual(starts, ["0", "60", "60", "120"])
        let backToTop = app.buttons["libraryBackToTop"]
        reveal(backToTop, in: scroll); backToTop.tap()
        await first("007")
        let refreshQuery = ["includeitemtypes": "Movie,Series", "sortby": "DateCreated,SortName", "startindex": "0"]
        let beforeRefresh = try await recordedReads(query: refreshQuery).count
        XCTAssertFalse(more.exists)
        refreshLibraryFromToolbar()
        try await waitForCompletedRead(after: beforeRefresh, query: refreshQuery)
        XCTAssertTrue(more.waitForExistence(timeout: 8), "A committed refresh must replace all144 loaded rows with the first60 and expose Load more again.")
        await first("007")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        attach("library-pagination-recovered")
    }

    func testInitialErrorEmptyRecoveryAndFastSortChanges() async throws {
        try launch()
        _ = try await json("/qa/library-control", body: ["failFirst": 1])
        tab("Library")
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 10))
        app.buttons["retry"].tap(); count(144); await first("048")
        _ = try await json("/qa/library-control", body: ["empty": true])
        select("librarySort", "Recently added")
        XCTAssertTrue(app.staticTexts["No titles found"].waitForExistence(timeout: 10))
        _ = try await json("/qa/library-control", body: ["empty": false, "delayFirstMs": 2000])
        select("librarySort", "Release year")
        select("librarySort", "Title")
        await first("048", timeout: 15)
        try await Task.sleep(for: .seconds(3))
        await first("048")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Title")
    }

    func testEmptyLaterPageRetainsLoadedTitlesAndStopsPagination() async throws {
        try launch()
        _ = try await json("/qa/library-control", body: ["emptyLater": 1])
        tab("Library"); count(144)
        select("librarySort", "Recently added"); await first("007")
        let scroll = app.scrollViews["libraryScroll"]
        let tail = scroll.buttons["item-library-title-039"]
        reveal(tail, in: scroll)
        XCTAssertTrue(tail.isHittable)
        let more = app.buttons["loadMore"]
        reveal(more, in: scroll); more.tap()
        XCTAssertTrue(more.waitForNonExistence(timeout: 10))
        XCTAssertFalse(app.buttons["libraryRetry"].exists)
        XCTAssertTrue(tail.isHittable, "An empty later page must retain the already loaded page.")
        count(144)
        scroll.swipeUp(); scroll.swipeUp()
        let state = try await json("/qa/library-state")
        let receipts = try XCTUnwrap(state["requests"] as? [[String: Any]])
        let pages = receipts.filter { entry in
            let query = entry["query"] as? [String: String]
            return entry["path"] as? String == "/Items" && query?["sortby"] == "DateCreated,SortName" && query?["includeitemtypes"] == "Movie,Series"
        }
        XCTAssertEqual(pages.compactMap { ($0["query"] as? [String: String])?["startindex"] }, ["0", "60"])
        let terminal = try XCTUnwrap(pages.last)
        XCTAssertEqual(terminal["status"] as? Int, 200)
        XCTAssertEqual(terminal["count"] as? Int, 0)
        XCTAssertEqual(terminal["total"] as? Int, 144)
        XCTAssertFalse(more.exists, "Scrolling the terminal page must not request another page.")
        attach("library-terminal-empty-page-retains-content")
    }

    func testOverlappingLaterPageDeduplicatesBoundaryAndUsesRawOffsets() async throws {
        try launch()
        _ = try await json("/qa/library-control", body: ["overlapLater": 1])
        tab("Library"); count(144)
        select("librarySort", "Recently added"); await first("007")
        let scroll = app.scrollViews["libraryScroll"]
        let boundary = scroll.buttons.matching(identifier: "item-library-title-039")
        reveal(boundary.firstMatch, in: scroll)
        let more = app.buttons["loadMore"]
        reveal(more, in: scroll); more.tap()
        let secondTail = scroll.buttons["item-library-title-071"]
        reveal(secondTail, in: scroll)
        XCTAssertTrue(secondTail.isHittable, "The new second page must render before checking its overlapping boundary.")
        reveal(boundary.firstMatch, in: scroll, up: false)
        XCTAssertTrue(boundary.firstMatch.isHittable)
        XCTAssertEqual(boundary.count, 1, "The repeated server boundary must render only one listing.")
        attach("library-overlap-boundary-deduplicated")
        reveal(secondTail, in: scroll)
        XCTAssertTrue(secondTail.isHittable)
        reveal(more, in: scroll); more.tap()
        XCTAssertTrue(more.waitForNonExistence(timeout: 10))
        let finalTail = scroll.buttons["item-library-title-040"]
        reveal(finalTail, in: scroll)
        XCTAssertTrue(finalTail.isHittable)
        XCTAssertFalse(app.buttons["libraryRetry"].exists)
        scroll.swipeUp(); scroll.swipeUp()
        let state = try await json("/qa/library-state")
        let receipts = try XCTUnwrap(state["requests"] as? [[String: Any]])
        let pages = receipts.filter { entry in
            let query = entry["query"] as? [String: String]
            return entry["path"] as? String == "/Items" && query?["sortby"] == "DateCreated,SortName" && query?["includeitemtypes"] == "Movie,Series"
        }
        XCTAssertEqual(pages.compactMap { ($0["query"] as? [String: String])?["startindex"] }, ["0", "60", "120"], "The next offset must use 60 raw records, not 59 deduplicated listings.")
        XCTAssertEqual(pages.compactMap { $0["count"] as? Int }, [60, 60, 24])
        XCTAssertTrue(pages.allSatisfy { $0["status"] as? Int == 200 && $0["total"] as? Int == 144 })
        XCTAssertEqual(pages.filter { $0["overlapLater"] as? Bool == true }.count, 1)
        let repeatedPage = try XCTUnwrap(pages.dropFirst().first)
        XCTAssertTrue(repeatedPage["overlapLater"] as? Bool == true)
        XCTAssertFalse(more.exists)
        attach("library-overlap-final-raw-page-stops")
    }

    func testLargestTextControlsAndSelectedSortRemainReachable() async throws {
        try launch(accessibility: true); tab("Library"); count(144)
        select("librarySort", "Recently added"); await first("007")
        let sort = app.buttons["librarySort"], filters = app.buttons["libraryFilters"]
        for control in [sort, filters] {
            XCTAssertTrue(control.isHittable)
            XCTAssertGreaterThanOrEqual(control.frame.height, 44)
            XCTAssertGreaterThanOrEqual(control.frame.minX, app.windows.firstMatch.frame.minX)
            XCTAssertLessThanOrEqual(control.frame.maxX, app.windows.firstMatch.frame.maxX)
            XCTAssertGreaterThanOrEqual(control.frame.minY, app.navigationBars.firstMatch.frame.maxY)
            XCTAssertLessThanOrEqual(control.frame.maxY, app.windows.firstMatch.frame.maxY)
            if app.tabBars.firstMatch.exists { XCTAssertLessThanOrEqual(control.frame.maxY, app.tabBars.firstMatch.frame.minY) }
        }
        XCTAssertFalse(sort.frame.intersects(filters.frame))
        attach("library-largest-text")
        let scroll = app.scrollViews["libraryScroll"]
        let title = app.staticTexts["libraryRowTitle-library-title-007"]
        let subtitle = app.staticTexts["libraryRowSubtitle-library-title-007"]
        XCTAssertTrue(title.waitForExistence(timeout: 5), app.debugDescription)
        XCTAssertTrue(subtitle.exists)
        reveal(title, in: scroll)
        XCTAssertEqual(title.label, "Cedar Story 19")
        attach("library-largest-text-title-readable")
        reveal(subtitle, in: scroll)
        XCTAssertEqual(subtitle.label, "1991 · 24s")
        attach("library-largest-text-subtitle-readable")
        reveal(title, in: scroll)
        XCTAssertTrue(title.isHittable)
        title.tap()
        XCTAssertTrue(app.scrollViews["detailScroll"].waitForExistence(timeout: 8))
        let detailTitle = app.staticTexts["detailTitle"]
        reveal(detailTitle, in: app.scrollViews["detailScroll"])
        XCTAssertEqual(detailTitle.label, "Cedar Story 19")
        back()
        await first("007")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
    }

    func testLargestTextCombinedEpisodeFiltersStayReadableAndSurviveDetail() async throws {
        try launch(accessibility: true); tab("Library"); count(144)
        let scroll = app.scrollViews["libraryScroll"]
        XCTAssertTrue(scroll.waitForExistence(timeout: 5))
        category("Episodes"); count(12)
        func choose(_ menu: String, _ label: String) {
            selectScrollableMenu(menu, label, in: scroll)
        }
        choose("libraryFilters", "Shows")
        choose("librarySort", "Recently added")
        choose("libraryFilters", "Adventure")
        choose("libraryFilters", "Unwatched"); count(2)

        func assertReadableHeader(_ phase: String) {
            let countText = app.staticTexts["libraryCount"]
            let sort = app.buttons["librarySort"], filters = app.buttons["libraryFilters"]
            let sortText = sort.staticTexts.matching(NSPredicate(format: "label == %@", "Recently added")).firstMatch
            let filterText = filters.staticTexts.matching(NSPredicate(format: "label == %@", "Filters · 3")).firstMatch
            let refresh = scroll.buttons["libraryRefresh"]
            let refreshText = refresh.staticTexts["Refresh library"]
            let summary = app.staticTexts["libraryFilterSummary"]
            XCTAssertTrue(sortText.waitForExistence(timeout: 5), app.debugDescription)
            XCTAssertTrue(filterText.exists, app.debugDescription)
            XCTAssertEqual(summary.label, "Shows · Adventure · Unwatched")
            reveal(countText, in: scroll, up: false)
            XCTAssertEqual(countText.label, "2 titles")
            reveal(sort, in: scroll)
            XCTAssertEqual(sort.value as? String, "Recently added")
            XCTAssertTrue(sort.frame.insetBy(dx: -3, dy: -3).contains(sortText.frame), "The visible sort text must fit its menu, including both lines.")
            XCTAssertLessThanOrEqual(countText.frame.maxY, sortText.frame.minY + 2, "Count and sort glyphs must not overlap.")
            attach("library-combined-largest-\(phase)-sort")
            reveal(filters, in: scroll)
            XCTAssertTrue(filters.frame.insetBy(dx: -3, dy: -3).contains(filterText.frame), "The visible filter text must fit its menu.")
            XCTAssertLessThanOrEqual(sortText.frame.maxY, filterText.frame.minY + 2, "Sort and filter glyphs must not overlap.")
            attach("library-combined-largest-\(phase)-filters")
            reveal(refresh, in: scroll)
            XCTAssertTrue(refresh.isEnabled)
            XCTAssertGreaterThanOrEqual(refresh.frame.height, 44)
            XCTAssertEqual(refresh.value as? String, "Ready")
            XCTAssertTrue(refreshText.exists)
            XCTAssertTrue(refresh.frame.insetBy(dx: -3, dy: -3).contains(refreshText.frame), "The full Refresh label must fit its control.")
            XCTAssertLessThanOrEqual(filterText.frame.maxY, refreshText.frame.minY + 2, "Filters and Refresh glyphs must not overlap.")
            let refreshTrait = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
            let refreshFont = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: refreshTrait)
            let refreshRequired = (refreshText.label as NSString).boundingRect(with: CGSize(width: refreshText.frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: refreshFont], context: nil)
            XCTAssertGreaterThanOrEqual(refreshText.frame.height, ceil(refreshRequired.height) - 2, "Refresh library must wrap in full at the largest text size.")
            attach("library-combined-largest-\(phase)-refresh")
            reveal(summary, in: scroll)
            XCTAssertLessThanOrEqual(refreshText.frame.maxY, summary.frame.minY + 2, "Refresh and the filter summary must not overlap.")
            let trait = UITraitCollection(preferredContentSizeCategory: .accessibilityExtraExtraExtraLarge)
            let font = UIFont.preferredFont(forTextStyle: .caption1, compatibleWith: trait)
            let required = (summary.label as NSString).boundingRect(with: CGSize(width: summary.frame.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font], context: nil)
            XCTAssertGreaterThanOrEqual(summary.frame.height, ceil(required.height) - 2, "The full selected-filter summary must wrap instead of showing an ellipsis.")
            attach("library-combined-largest-\(phase)-summary")
        }
        assertReadableHeader("before-detail")
        let title = app.staticTexts["libraryRowTitle-library-episode-05"]
        let subtitle = app.staticTexts["libraryRowSubtitle-library-episode-05"]
        reveal(title, in: scroll)
        XCTAssertEqual(title.label, "Amber Story 30")
        attach("library-combined-largest-episode-title")
        reveal(subtitle, in: scroll)
        XCTAssertEqual(subtitle.label, "S1 E1 North Episode 05")
        attach("library-combined-largest-episode-subtitle")
        XCTAssertTrue(subtitle.isHittable)
        subtitle.tap()
        let detailScroll = app.scrollViews["detailScroll"]
        XCTAssertTrue(detailScroll.waitForExistence(timeout: 8))
        let detailTitle = app.staticTexts["detailTitle"]
        reveal(detailTitle, in: detailScroll)
        XCTAssertEqual(detailTitle.label, "North Episode 05")
        back()
        assertReadableHeader("after-back")
        let queries = try await itemQueries()
        XCTAssertTrue(queries.contains { $0["includeitemtypes"] == "Episode" && $0["parentid"] == "library-shows" && $0["genreids"] == "library-adventure" && $0["isplayed"] == "false" && $0["sortby"] == "DateCreated,SortName" })
        try await assertNoWatchReports()
    }

    func testLargestTextLoadingEmptyAndFirstErrorRemainReachable() async throws {
        try launch(accessibility: true)
        _ = try await json("/qa/library-control", body: ["delayMs": 2000, "delayFirstMs": 2000, "failFirst": 1])
        tab("Library")
        let scroll = app.scrollViews["libraryScroll"]
        let loading = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", "Finding your titles…")).firstMatch
        XCTAssertTrue(loading.exists, "The actual pending first-page request must expose its loading state.")
        reveal(loading, in: scroll)
        let pendingState = try await json("/qa/library-state")
        let pending = try XCTUnwrap(pendingState["requests"] as? [[String: Any]])
        XCTAssertTrue(pending.contains { $0["path"] as? String == "/Items" && $0["plannedStatus"] as? Int == 503 && $0["status"] == nil })
        attach("library-largest-loading-pending")
        let retry = app.buttons["retry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        reveal(retry, in: scroll)
        attach("library-largest-first-error-retry")
        retry.tap(); count(144)
        let recovered = app.staticTexts["libraryRowTitle-library-title-048"]
        reveal(recovered, in: scroll)
        XCTAssertEqual(recovered.label, "Amber Story 00")
        _ = try await json("/qa/library-control", body: ["delayMs": 0, "delayFirstMs": 0, "empty": true])
        selectScrollableMenu("librarySort", "Recently added", in: scroll)
        let empty = app.staticTexts["No titles found"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        reveal(empty, in: scroll)
        let explanation = app.staticTexts["Try another search or library."]
        reveal(explanation, in: scroll)
        attach("library-largest-empty-state-readable")
        _ = try await json("/qa/library-control", body: ["empty": false])
        selectScrollableMenu("libraryFilters", "Adventure", in: scroll); count(72)
        let filtered = app.staticTexts["libraryRowTitle-library-title-054"]
        reveal(filtered, in: scroll)
        XCTAssertEqual(filtered.label, "Amber Story 30")
        selectScrollableMenu("libraryFilters", "Clear filters", in: scroll); count(144)
        let summary = app.staticTexts["libraryFilterSummary"]
        XCTAssertFalse(summary.exists)
        let firstTitle = app.staticTexts["libraryRowTitle-library-title-007"]
        reveal(firstTitle, in: scroll)
        XCTAssertEqual(firstTitle.label, "Cedar Story 19")
        let state = try await json("/qa/library-state")
        let receipts = try XCTUnwrap(state["requests"] as? [[String: Any]])
        XCTAssertTrue(receipts.contains { $0["path"] as? String == "/Items" && $0["status"] as? Int == 503 })
        XCTAssertTrue(receipts.contains { $0["path"] as? String == "/Items" && $0["status"] as? Int == 200 && $0["count"] as? Int == 0 })
        try await assertNoWatchReports()
    }

    func testLargestTextPagingRetryBackToTopAndRefreshRemainReachable() async throws {
        try launch(accessibility: true); tab("Library"); count(144)
        let scroll = app.scrollViews["libraryScroll"]
        selectScrollableMenu("librarySort", "Recently added", in: scroll)
        selectScrollableMenu("libraryFilters", "Adventure", in: scroll); count(72)
        _ = try await json("/qa/library-control", body: ["failLater": 1])
        let firstTail = scroll.buttons["item-library-title-078"]
        reveal(firstTail, in: scroll)
        let more = app.buttons["loadMore"]
        reveal(more, in: scroll); more.tap()
        let retry = app.buttons["libraryRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        reveal(retry, in: scroll)
        XCTAssertTrue(firstTail.exists, "The failed later page must retain its loaded first page.")
        attach("library-largest-later-error-retry")
        retry.tap()
        XCTAssertTrue(more.waitForNonExistence(timeout: 10))
        let finalTail = scroll.buttons["item-library-title-040"]
        reveal(finalTail, in: scroll)
        XCTAssertTrue(finalTail.isHittable)
        XCTAssertFalse(retry.exists)
        let state = try await json("/qa/library-state")
        let receipts = try XCTUnwrap(state["requests"] as? [[String: Any]])
        let pages = receipts.filter { entry in
            let query = entry["query"] as? [String: String]
            return entry["path"] as? String == "/Items" && query?["genreids"] == "library-adventure" && query?["sortby"] == "DateCreated,SortName"
        }
        XCTAssertEqual(pages.compactMap { ($0["query"] as? [String: String])?["startindex"] }, ["0", "60", "60"])
        XCTAssertEqual(pages.compactMap { $0["status"] as? Int }, [200, 503, 200])
        XCTAssertEqual(pages.filter { $0["status"] as? Int == 200 }.compactMap { $0["count"] as? Int }, [60, 12])
        let backToTop = app.buttons["libraryBackToTop"]
        reveal(backToTop, in: scroll); backToTop.tap()
        let topCount = app.staticTexts["libraryCount"], topSort = app.buttons["librarySort"]
        let topReady = NSPredicate { _, _ in
            guard topCount.exists && topSort.exists && topCount.isHittable && topSort.isHittable else { return false }
            let window = self.app.windows.firstMatch.frame
            let top = max(scroll.frame.minY, self.app.navigationBars.firstMatch.frame.maxY)
            let bottom = self.app.tabBars.firstMatch.exists ? min(scroll.frame.maxY, self.app.tabBars.firstMatch.frame.minY) : min(scroll.frame.maxY, window.maxY)
            return topCount.frame.minY >= top && topSort.frame.maxY <= bottom
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: topReady, object: nil)], timeout: 8)
        XCTAssertTrue(app.staticTexts["libraryCount"].isHittable)
        XCTAssertTrue(app.buttons["librarySort"].isHittable)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        XCTAssertEqual(app.staticTexts["libraryFilterSummary"].label, "Adventure")
        attach("library-largest-back-to-top-controls")
        let refreshQuery = ["genreids": "library-adventure", "sortby": "DateCreated,SortName", "startindex": "0"]
        let beforeRefresh = try await recordedReads(query: refreshQuery).count
        XCTAssertFalse(more.exists)
        refreshAccessibleLibrary(in: scroll)
        try await waitForCompletedRead(after: beforeRefresh, query: refreshQuery)
        XCTAssertTrue(more.waitForExistence(timeout: 8), "A committed refresh must replace all72 loaded rows with the first60 and expose Load more again.")
        count(72)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        XCTAssertEqual(app.staticTexts["libraryFilterSummary"].label, "Adventure")
        let title = app.staticTexts["libraryRowTitle-library-title-054"]
        reveal(title, in: scroll)
        XCTAssertEqual(title.label, "Amber Story 30")
        try await assertNoWatchReports()
    }

    func testLargestTextRefreshCommitsChangedResultsAndRecoversRetainedPage() async throws {
        try launch(accessibility: true); tab("Library"); count(144)
        let scroll = app.scrollViews["libraryScroll"]
        func catalog(_ state: [String: Any]) -> [[String: Any]] {
            (state["requests"] as? [[String: Any]] ?? []).filter {
                let query = $0["query"] as? [String: String]
                return $0["path"] as? String == "/Items" && query?["includeitemtypes"] == "Movie,Series" && query?["sortby"] == "SortName"
            }
        }
        let before = try await json("/qa/library-state")
        _ = try await json("/qa/library-control", body: ["empty": true])
        refreshAccessibleLibrary(in: scroll); count(0)
        let empty = app.staticTexts["No titles found"]
        reveal(empty, in: scroll)
        XCTAssertTrue(empty.isHittable)
        attach("library-largest-refresh-committed-empty")
        _ = try await json("/qa/library-control", body: ["empty": false])
        refreshAccessibleLibrary(in: scroll); count(144)
        _ = try await json("/qa/library-control", body: ["failFirst": 1, "delayFirstMs": 2000])
        let refresh = refreshAccessibleLibrary(in: scroll)
        XCTAssertFalse(refresh.isEnabled)
        XCTAssertEqual(refresh.value as? String, "Loading")
        let pending = try await json("/qa/library-state")
        XCTAssertTrue(catalog(pending).contains { $0["plannedStatus"] as? Int == 503 && $0["status"] == nil })
        XCTAssertTrue(app.staticTexts["144 titles"].exists)
        attach("library-largest-refresh-loading-retains-page")
        let retry = scroll.buttons["libraryRefreshRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10))
        count(144)
        XCTAssertFalse(scroll.buttons["libraryRetry"].exists)
        let retainedTitle = app.staticTexts["libraryRowTitle-library-title-048"]
        reveal(retainedTitle, in: scroll)
        XCTAssertEqual(retainedTitle.label, "Amber Story 00")
        attach("library-largest-refresh-error-retains-readable-title")
        _ = try await json("/qa/library-control", body: ["empty": true, "delayFirstMs": 0])
        reveal(retry, in: scroll)
        XCTAssertTrue(retry.isHittable)
        retry.tap(); count(0)
        XCTAssertFalse(retry.exists)
        _ = try await json("/qa/library-control", body: ["empty": false])
        refreshAccessibleLibrary(in: scroll); count(144)
        let ready = scroll.buttons["libraryRefresh"]
        reveal(ready, in: scroll)
        XCTAssertTrue(ready.isEnabled)
        XCTAssertEqual(ready.value as? String, "Ready")
        let after = try await json("/qa/library-state")
        let reads = Array(catalog(after).dropFirst(catalog(before).count))
        XCTAssertEqual(reads.compactMap { $0["status"] as? Int }, [200, 200, 503, 200, 200])
        XCTAssertEqual(reads.compactMap { ($0["query"] as? [String: String])?["startindex"] }, ["0", "0", "0", "0", "0"])
        XCTAssertEqual(reads.filter { $0["status"] as? Int == 200 }.compactMap { $0["count"] as? Int }, [0, 60, 0, 60])
        attach("library-largest-refresh-retry-recovered")
        try await assertNoWatchReports()
    }

    func testLargestTextSearchRefreshHonorsQueryAndHidesWhenBlank() async throws {
        try launch(accessibility: true); tab("Search")
        let field = initialSearchField()
        let scroll = app.scrollViews["libraryScroll"]
        let refresh = scroll.buttons["libraryRefresh"]
        XCTAssertFalse(refresh.exists, "A blank search has nothing to refresh.")
        XCTAssertFalse(scroll.buttons["librarySort"].exists)
        XCTAssertFalse(scroll.buttons["libraryFilters"].exists)
        field.tap(); field.typeText("  North  "); field.typeText(XCUIKeyboardKey.return.rawValue)
        let episode = scroll.buttons["item-library-episode-01"]
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        var queryReady = false
        for _ in 0..<50 {
            let state = try await json("/qa/library-state")
            let reads = state["requests"] as? [[String: Any]] ?? []
            if reads.contains(where: { ($0["query"] as? [String: String])?["searchterm"] == "North" && $0["status"] as? Int == 200 }), refresh.isEnabled, refresh.value as? String == "Ready" {
                queryReady = true; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(queryReady, "Refresh must begin from the completed North query, not a partial typed term.")
        let before = try await itemQueries()
        _ = try await json("/qa/library-control", body: ["empty": true])
        refreshAccessibleLibrary(in: scroll, label: "Refresh results", centered: true)
        let empty = app.staticTexts["No titles found"]
        XCTAssertTrue(empty.waitForExistence(timeout: 10))
        reveal(empty, in: scroll, centered: true)
        attach("library-largest-search-refreshed-empty")
        _ = try await json("/qa/library-control", body: ["empty": false])
        refreshAccessibleLibrary(in: scroll, label: "Refresh results", centered: true)
        XCTAssertTrue(episode.waitForExistence(timeout: 10))
        let subtitle = app.staticTexts["libraryRowSubtitle-library-episode-01"]
        reveal(subtitle, in: scroll, centered: true)
        XCTAssertTrue(subtitle.label.contains("North Episode 01"))
        let after = try await itemQueries()
        XCTAssertEqual(after.count, before.count + 2)
        XCTAssertEqual(after.suffix(2).map { $0["searchterm"] }, ["North", "North"])
        XCTAssertTrue(after.suffix(2).allSatisfy { $0["includeitemtypes"] == "Movie,Series,Episode" && $0["startindex"] == "0" })
        let clearField = visibleSearchField(in: app.scrollViews["libraryScroll"])
        let clear = clearField.buttons["Clear text"]
        XCTAssertTrue(clear.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(clear.frame))
        clear.tap()
        let inputView = app.otherElements["inputView"].firstMatch
        let assistant = app.otherElements["SystemInputAssistantView"].firstMatch
        XCTAssertTrue(inputView.waitForExistence(timeout: 5))
        let close = app.navigationBars["Search"].buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertTrue(app.windows.firstMatch.frame.contains(close.frame))
        XCTAssertLessThanOrEqual(close.frame.maxY, inputView.frame.minY)
        XCTAssertTrue(close.isHittable)
        close.tap()
        let editingSurfaces = [app.keyboards.firstMatch, inputView, assistant]
        let editingGone = NSPredicate { _, _ in
            let window = self.app.windows.firstMatch.frame
            return editingSurfaces.allSatisfy { surface in
                guard surface.exists else { return true }
                let frame = surface.frame
                return frame.width <= 0 || frame.height <= 0 || !frame.intersects(window)
            }
        }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: editingGone, object: nil)], timeout: 5)
        attach("library-largest-search-Clear-nativeClose-editing-surfaces-gone")
        let invitation = app.staticTexts["A title in mind?"]
        XCTAssertTrue(invitation.waitForExistence(timeout: 8))
        XCTAssertTrue(refresh.waitForNonExistence(timeout: 5), "A blank search has nothing to refresh.")
        XCTAssertFalse(episode.exists)
        let cleared = try await itemQueries()
        XCTAssertEqual(cleared.count, after.count, "A blank search must not issue a catalog request.")
        attach("library-largest-search-blank-refresh-disabled")
        try await assertNoWatchReports()
    }

    func testCollectionsAndPlaylistsKeepServerSequenceAndDuplicates() async throws {
        try launch(); tab("Library"); count(144)
        category("Collections"); count(2)
        app.buttons["item-library-collection-1"].tap(); count(8)
        let collectionQuery = ["parentid": "library-collection-1", "startindex": "0"]
        let collectionReads = try await recordedReads(query: collectionQuery)
        refreshLibraryFromToolbar()
        try await waitForCompletedRead(after: collectionReads.count, query: collectionQuery)
        count(8)
        XCTAssertTrue(app.buttons["librarySort"].exists)
        tapLibraryItem("item-library-title-054")
        XCTAssertTrue(app.scrollViews["detailScroll"].waitForExistence(timeout: 8))
        let detailTitle = app.staticTexts["detailTitle"]
        reveal(detailTitle, in: app.scrollViews["detailScroll"])
        XCTAssertEqual(detailTitle.label, "Amber Story 30")
        back(); count(8)
        back()
        category("Playlists"); count(1)
        app.buttons["item-library-playlist-1"].tap(); count(8)
        let playlistPath = "/Playlists/library-playlist-1/Items"
        let playlistReads = try await recordedReads(path: playlistPath, query: ["startindex": "0"])
        refreshLibraryFromToolbar()
        try await waitForCompletedRead(after: playlistReads.count, path: playlistPath, query: ["startindex": "0"])
        count(8)
        XCTAssertFalse(app.buttons["librarySort"].exists)
        XCTAssertFalse(app.buttons["libraryFilters"].exists)
        let rows = app.scrollViews["libraryScroll"].buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-library-title-'"))
        XCTAssertEqual(rows.element(boundBy: 0).identifier, "item-library-title-071")
        XCTAssertEqual(rows.element(boundBy: 1).identifier, "item-library-title-002")
        XCTAssertEqual(rows.element(boundBy: 2).identifier, "item-library-title-071")
        attach("library-playlist-duplicates")
    }

    func testSearchTrimsTermIncludesEpisodesAndClears() async throws {
        try launch(); tab("Search")
        let field = initialSearchField()
        XCTAssertTrue(app.staticTexts["A title in mind?"].waitForExistence(timeout: 8))
        let refresh = app.navigationBars.buttons["libraryRefresh"]
        XCTAssertFalse(refresh.exists, "A blank search has nothing to refresh.")
        field.tap(); field.typeText("  North  ")
        field.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["item-library-episode-01"].waitForExistence(timeout: 10))
        let queries = try await itemQueries()
        XCTAssertEqual(queries.last?["searchterm"], "North")
        XCTAssertEqual(queries.last?["includeitemtypes"], "Movie,Series,Episode")
        let ready = NSPredicate { _, _ in refresh.exists && refresh.isEnabled && refresh.value as? String == "Ready" }
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: ready, object: nil)], timeout: 8)
        let searchQuery = ["searchterm": "North", "includeitemtypes": "Movie,Series,Episode", "startindex": "0"]
        let searchReads = try await recordedReads(query: searchQuery)
        refreshLibraryFromToolbar(label: "Refresh results")
        try await waitForCompletedRead(after: searchReads.count, query: searchQuery)
        XCTAssertTrue(app.buttons["item-library-episode-01"].exists)
        tapLibraryItem("item-library-episode-01")
        XCTAssertTrue(app.scrollViews["detailScroll"].waitForExistence(timeout: 8))
        let title = app.staticTexts["detailTitle"]
        reveal(title, in: app.scrollViews["detailScroll"])
        XCTAssertEqual(title.label, "North Episode 01")
        back()
        XCTAssertTrue(app.buttons["item-library-episode-01"].waitForExistence(timeout: 8))
        XCTAssertTrue((field.value as? String ?? "").contains("North"))
        let clearField = visibleSearchField(in: app.scrollViews["libraryScroll"])
        let clear = clearField.buttons["Clear text"]
        XCTAssertTrue(clear.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(clear.frame))
        clear.tap()
        XCTAssertTrue(app.staticTexts["A title in mind?"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["item-library-episode-01"].exists)
        XCTAssertTrue(refresh.waitForNonExistence(timeout: 5), "A blank search has nothing to refresh.")
    }

    func testOptionalFilterFailureHasReachableRecovery() async throws {
        try launch()
        _ = try await json("/qa/library-control", body: ["failOptions": 1])
        tab("Library"); count(144)
        XCTAssertTrue(app.staticTexts["libraryOptionsError"].waitForExistence(timeout: 10))
        let retry = app.buttons["libraryOptionsRetry"]
        XCTAssertTrue(retry.isEnabled); XCTAssertTrue(retry.isHittable); retry.tap()
        XCTAssertTrue(app.staticTexts["libraryOptionsError"].waitForNonExistence(timeout: 10))
        select("libraryFilters", "Adventure"); count(72)
    }

    func testNewestEpisodesAndSeriesLatestEpisodeAddedStayDistinct() async throws {
        try launch(); tab("Library"); count(144)
        category("Episodes"); count(12)
        select("librarySort", "Recently added"); await firstEpisode("05")
        select("libraryFilters", "Adventure")
        select("libraryFilters", "Unwatched"); count(2); await firstEpisode("05")
        XCTAssertTrue(app.buttons["item-library-episode-07"].exists)
        attach("library-newest-episodes-filtered")
        select("libraryFilters", "Clear filters"); count(12)
        category("Series"); count(48); await first("048")
        // Category choices are independent. Explicitly choose recency here.
        select("librarySort", "Series added"); await first("087")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Series added")
        select("librarySort", "Latest episode added"); await first("006")
        attach("library-series-latest-episode-added")
        let queries = try await itemQueries()
        XCTAssertEqual(queries.last?["sortby"], "DateLastContentAdded,SortName")
        XCTAssertEqual(queries.last?["includeitemtypes"], "Series")
        select("librarySort", "Series added"); await first("087")
        select("librarySort", "Latest episode added"); await first("006")
        category("Movies"); count(96); await first("013")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Title")
        app.buttons["librarySort"].tap()
        XCTAssertFalse(app.buttons["Latest episode added"].exists)
        app.buttons.matching(NSPredicate(format: "label == 'Recently added' AND identifier != 'librarySort'")).firstMatch.tap()
        try await assertNoWatchReports()
    }

    func testHomeNewEpisodesSeeAllAndEpisodeDetails() async throws {
        try launch()
        let link = app.buttons["recent-Episodes-seeAll"]
        reveal(link, in: app.scrollViews["homeScroll"]); link.tap()
        count(12); await firstEpisode("05")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        let queries = try await itemQueries()
        XCTAssertEqual(queries.last?["includeitemtypes"], "Episode")
        XCTAssertEqual(queries.last?["sortby"], "DateCreated,SortName")
        for suffix in ["05", "10"] {
            tapLibraryItem("item-library-episode-" + suffix)
            attach("episode-after-navigation-" + suffix)
            XCTAssertTrue(app.scrollViews["detailScroll"].waitForExistence(timeout: 8), app.debugDescription)
            let detailTitle = app.staticTexts["detailTitle"]
            reveal(detailTitle, in: app.scrollViews["detailScroll"])
            XCTAssertEqual(detailTitle.label, "North Episode " + suffix)
            XCTAssertTrue(app.buttons["detailPlay"].exists)
            back()
            await firstEpisode("05")
        }
        try await assertNoWatchReports()
    }

    func testHomeRetainsOtherShelvesWhenNewEpisodeFeedFailsAndRetries() async throws {
        user = "library-" + UUID().uuidString
        _ = try await json("/qa/library-control", body: ["reset": true, "failEpisodeFeed": 1])
        try launch(userOverride: user)
        XCTAssertTrue(app.buttons["heroDetails"].exists, "A failed new-episode request must not blank the rest of Home.")
        let retry = app.buttons["homeRetry"]
        reveal(retry, in: app.scrollViews["homeScroll"]); retry.tap()
        let link = app.buttons["recent-Episodes-seeAll"]
        XCTAssertTrue(link.waitForExistence(timeout: 10))
        reveal(link, in: app.scrollViews["homeScroll"]); link.tap()
        count(12); await firstEpisode("05")
        try await assertNoWatchReports()
    }

    func testSlowEpisodeFeedDoesNotBlockHealthyHome() async throws {
        user = "library-" + UUID().uuidString
        _ = try await json("/qa/library-control", body: ["reset": true, "delayEpisodeFeedMs": 8000])
        try launch(userOverride: user)
        XCTAssertTrue(app.buttons["heroDetails"].isHittable)
        XCTAssertTrue(app.staticTexts["Loading new episodes…"].exists)
        let receipts = try await json("/qa/library-state")["requests"] as? [[String: Any]] ?? []
        let feed = receipts.last { entry in
            let query = entry["query"] as? [String: String]
            return entry["path"] as? String == "/Items" && query?["includeitemtypes"] == "Episode" && query?["limit"] == "18"
        }
        XCTAssertNotNil(feed)
        XCTAssertNil(feed?["status"], "Healthy Home must be usable while the optional episode request is still in flight.")
        XCTAssertTrue(app.buttons["recent-Episodes-seeAll"].waitForExistence(timeout: 12))
        try await assertNoWatchReports()
    }

    func testSwitchingSavedAccountWhileEpisodeFeedFailsKeepsNewHomeHealthy() async throws {
        let first = "library-switch-a-" + UUID().uuidString
        let second = "library-switch-b-" + UUID().uuidString
        try launch(userOverride: first)
        addSavedAccount(second)
        _ = try await json("/qa/library-control", body: ["reset": true, "delayEpisodeFeedMs": 10000, "failEpisodeFeed": 1], forUser: first)
        let previousSecondFeedCount = try await episodeFeeds(forUser: second).count
        switchSavedAccount(first)
        let pendingFirst = try await episodeFeeds(forUser: first)
        XCTAssertTrue(pendingFirst.contains { $0["plannedStatus"] as? Int == 503 && $0["status"] == nil }, "The old account's error request must actually be in flight before switching.")
        switchSavedAccount(second)
        var secondFeeds: [[String: Any]] = []
        for _ in 0..<120 {
            secondFeeds = try await episodeFeeds(forUser: second)
            if secondFeeds.count > previousSecondFeedCount && secondFeeds.dropFirst(previousSecondFeedCount).contains(where: { $0["status"] as? Int == 200 }) { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertGreaterThan(secondFeeds.count, previousSecondFeedCount)
        XCTAssertTrue(secondFeeds.dropFirst(previousSecondFeedCount).contains { $0["status"] as? Int == 200 }, "The newly selected account must complete its own fresh episode feed.")
        var oldFailureCompleted = false
        for _ in 0..<120 {
            if try await episodeFeeds(forUser: first).contains(where: { $0["status"] as? Int == 503 }) {
                oldFailureCompleted = true; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(oldFailureCompleted, "The old account's delayed503 must complete while the new account is active.")
        XCTAssertTrue(app.buttons["heroDetails"].isHittable)
        XCTAssertFalse(app.buttons["homeRetry"].exists)
        XCTAssertFalse(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "New episodes couldn’t load.")).firstMatch.exists)
        app.buttons["servers"].tap()
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 8))
        let selected = app.buttons["server-" + second]
        let old = app.buttons["server-" + first]
        XCTAssertTrue(selected.label.contains("Current server"))
        XCTAssertFalse(old.label.contains("Current server"))
        app.buttons["Done"].tap()
        attach("home-saved-account-late-feed-isolation")
        try await assertNoWatchReports()
    }

    override func tearDown() async throws {
        #if targetEnvironment(simulator)
        defer { app.terminate() }
        await cleanupHeldRefreshes()
        if !user.isEmpty {
            try await assertNoWatchReports()
            for account in observedUsers.sorted() {
                let snapshot = try await json("/qa/library-state", forUser: account)
                let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.prettyPrinted, .sortedKeys])
                let receipts = XCTAttachment(string: String(decoding: data, as: UTF8.self))
                receipts.name = "library-contract-receipts-" + account; receipts.lifetime = .keepAlways; add(receipts)
            }
        }
        #endif
    }
    private func refreshLifecycleReads(forUser account: String? = nil) async throws -> [[String: Any]] {
        let state = try await json("/qa/library-state", forUser: account)
        return (state["requests"] as? [[String: Any]] ?? []).filter { entry in
            let query = entry["query"] as? [String: String]
            return entry["path"] as? String == "/Items" && query?["includeitemtypes"] == "Movie,Series" && query?["sortby"] == "SortName" && query?["startindex"] == "0"
        }
    }

    private func captureRefreshLifecycle(_ phase: String, account: String? = nil) async throws {
        let state = try await json("/qa/library-state", forUser: account)
        let data = try JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys])
        let receipt = XCTAttachment(string: String(decoding: data, as: UTF8.self))
        receipt.name = "refresh-lifecycle-" + phase + "-receipts"; receipt.lifetime = .keepAlways; add(receipt)
        attach("refresh-lifecycle-" + phase)
    }

    private func startDelayedFailedRefresh(accessibility: Bool = false) async throws -> Int {
        let before = try await refreshLifecycleReads().count
        _ = try await json("/qa/library-control", body: ["delayFirstMs": 10000, "failFirst": 1])
        if accessibility { refreshAccessibleLibrary(in: app.scrollViews["libraryScroll"]) }
        else { refreshLibraryFromToolbar() }
        let pending = try await refreshLifecycleReads()
        XCTAssertEqual(pending.count, before + 1)
        let request = try XCTUnwrap(pending.last)
        XCTAssertNil(request["status"])
        XCTAssertEqual(request["plannedStatus"] as? Int, 503)
        XCTAssertEqual(request["delayMs"] as? Int, 10000)
        let control = accessibility ? app.scrollViews["libraryScroll"].buttons["libraryRefresh"] : app.navigationBars.buttons["libraryRefresh"]
        XCTAssertFalse(control.isEnabled)
        XCTAssertEqual(control.value as? String, "Loading")
        try await captureRefreshLifecycle("positive-pending")
        // The existing request retains its captured delay; subsequent loads can finish.
        _ = try await json("/qa/library-control", body: ["delayFirstMs": 0])
        return before
    }

    private func awaitDelayedFailure(_ index: Int, account: String? = nil) async throws {
        for _ in 0..<140 {
            let reads = try await refreshLifecycleReads(forUser: account)
            if reads.count > index, reads[index]["status"] as? Int == 503 {
                try await captureRefreshLifecycle("old-response-completed", account: account)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The old delayed503 must actually complete before testing stale publication suppression.")
    }

    private func assertHealthyRefreshPage(_ total: Int, accessibility: Bool = false) {
        count(total)
        let control = accessibility ? app.scrollViews["libraryScroll"].buttons["libraryRefresh"] : app.navigationBars.buttons["libraryRefresh"]
        if accessibility { reveal(control, in: app.scrollViews["libraryScroll"], up: false) }
        XCTAssertTrue(control.isEnabled)
        XCTAssertEqual(control.value as? String, "Ready")
        XCTAssertFalse(app.buttons["libraryRefreshRetry"].exists)
        XCTAssertFalse(app.buttons["libraryRetry"].exists)
        XCTAssertFalse(app.buttons["retry"].exists)
    }

    private func assertStableHealthyRefreshPage(_ total: Int, accessibility: Bool = false, category: String = "All") async throws {
        // The fixture records status immediately before writing the HTTP response.
        // Observe the active UI repeatedly after that write can be delivered.
        for _ in 0..<6 {
            assertHealthyRefreshPage(total, accessibility: accessibility)
            XCTAssertTrue(app.buttons["filter-" + category].isSelected)
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    private func returnHomeForRefreshLifecycle() {
        let home = app.buttons["Home"].firstMatch
        XCTAssertTrue(home.waitForExistence(timeout: 5))
        XCTAssertTrue(home.isHittable)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(home.frame))
        home.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
        XCTAssertTrue(app.scrollViews["homeScroll"].waitForExistence(timeout: 8))
        let hero = app.buttons["heroDetails"]
        XCTAssertTrue(hero.waitForExistence(timeout: 8))
        XCTAssertTrue(hero.isHittable)
    }

    private struct HeldRefresh {
        let owner: String
        let identifier: String
    }

    private var heldRefreshOwners = Set<String>()

    private func canonicalHoldID(_ value: Any?) throws -> String {
        let identifier = try XCTUnwrap(value as? String)
        let parsed = try XCTUnwrap(UUID(uuidString: identifier))
        let canonical = parsed.uuidString.lowercased()
        XCTAssertEqual(identifier, canonical)
        let characters = Array(canonical)
        XCTAssertEqual(characters[14], "4")
        XCTAssertTrue("89ab".contains(characters[19]))
        return try XCTUnwrap(identifier == canonical && characters[14] == "4" && "89ab".contains(characters[19]) ? identifier : nil)
    }

    private func heldRefreshReceipt(_ hold: HeldRefresh) async throws -> [String: Any] {
        let matches = try await refreshLifecycleReads(forUser: hold.owner).filter { $0["heldRequestID"] as? String == hold.identifier }
        XCTAssertEqual(matches.count, 1, "The exact owned request must have one immutable receipt.")
        return try XCTUnwrap(matches.count == 1 ? matches.first : nil)
    }

    private func assertHeldRefreshWaiting(_ hold: HeldRefresh) async throws {
        let receipt = try await heldRefreshReceipt(hold)
        XCTAssertEqual(receipt["holdState"] as? String, "waiting")
        XCTAssertEqual(receipt["plannedStatus"] as? Int, 503)
        XCTAssertEqual(receipt["holdTimeoutMs"] as? Int, 60000)
        XCTAssertEqual(receipt["delayMs"] as? Int, 0)
        XCTAssertNil(receipt["status"], "The old response must remain unsent until the new UI is healthy and explicitly releases it.")
        _ = try XCTUnwrap(receipt["holdState"] as? String == "waiting" && receipt["plannedStatus"] as? Int == 503 && receipt["status"] == nil ? true : nil)
    }

    private func startHeldFailedRefresh() async throws -> HeldRefresh {
        let owner = user
        // Register ownership before arming so teardown can release a hold even
        // if a failure occurs before the returned request ID is captured.
        heldRefreshOwners.insert(owner)
        _ = try await json("/qa/library-control", body: ["reset": true, "holdFirst": true, "failFirst": 1], forUser: owner)
        refreshLibraryFromToolbar()
        for _ in 0..<40 {
            let held = try await refreshLifecycleReads(forUser: owner).filter { $0["heldRequestID"] != nil }
            if let receipt = held.first {
                XCTAssertEqual(held.count, 1)
                let identifier = try canonicalHoldID(receipt["heldRequestID"])
                let hold = HeldRefresh(owner: owner, identifier: identifier)
                try await assertHeldRefreshWaiting(hold)
                let control = app.navigationBars.buttons["libraryRefresh"]
                XCTAssertFalse(control.isEnabled)
                XCTAssertEqual(control.value as? String, "Loading")
                try await captureRefreshLifecycle("hold-positive-waiting", account: owner)
                return hold
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try XCTUnwrap(nil as HeldRefresh?, "The actual Refresh must create its owned held503 request.")
    }

    private func releaseHeldRefresh(_ hold: HeldRefresh) async throws {
        try await assertHeldRefreshWaiting(hold)
        let response = try await json("/qa/library-control", body: ["releaseFirst": hold.identifier], forUser: hold.owner)
        XCTAssertEqual(response["releasedFirst"] as? String, hold.identifier)
        _ = try XCTUnwrap(response["releasedFirst"] as? String == hold.identifier ? true : nil)
        for _ in 0..<40 {
            let receipt = try await heldRefreshReceipt(hold)
            let state = receipt["holdState"] as? String
            XCTAssertNotEqual(state, "timedOut", "Automatic timeout cannot qualify as explicit release proof.")
            XCTAssertNotEqual(state, "canceled", "Reset cannot qualify as explicit release proof.")
            if state == "released", receipt["status"] as? Int == 503 {
                // status is the selected server response. A canceled HTTP
                // client may separately have responseWriteFailed=true.
                try await captureRefreshLifecycle("hold-explicitly-released503", account: hold.owner)
                heldRefreshOwners.remove(hold.owner)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try XCTUnwrap(nil as Bool?, "The exact owned request must finish as explicitly released503.")
    }

    private func cleanupHeldRefreshes() async {
        for owner in heldRefreshOwners.sorted() {
            do {
                // Disarm an unclaimed request before draining any active hold.
                // This leaves an already captured response unchanged.
                _ = try await json("/qa/library-control", body: ["holdFirst": false], forUser: owner)
                let state = try await json("/qa/library-state", forUser: owner)
                let receipts = state["requests"] as? [[String: Any]] ?? []
                for receipt in receipts where receipt["holdState"] as? String == "waiting" {
                    let identifier = try canonicalHoldID(receipt["heldRequestID"])
                    let response = try await json("/qa/library-control", body: ["releaseFirst": identifier], forUser: owner)
                    XCTAssertEqual(response["releasedFirst"] as? String, identifier, "Failure cleanup must release only this owned user's exact outstanding hold.")
                }
                try await captureRefreshLifecycle("hold-failure-cleanup", account: owner)
            } catch {
                XCTFail("Owned refresh hold cleanup failed: \(error)")
            }
        }
        heldRefreshOwners.removeAll()
    }

    func testPrivateAXCategoryChangeCancelsDelayedRefresh() async throws {
        try launch(accessibility: true); tab("Library"); count(144)
        let old = try await startDelayedFailedRefresh(accessibility: true)
        category("Movies"); count(96)
        let pending = try await refreshLifecycleReads()
        XCTAssertNil(pending[old]["status"], "The new category must load while the old refresh remains in flight.")
        let movies = try await recordedReads(query: ["includeitemtypes": "Movie", "sortby": "SortName", "startindex": "0"])
        XCTAssertTrue(movies.contains { $0["status"] as? Int == 200 && $0["total"] as? Int == 96 })
        try await captureRefreshLifecycle("new-category-healthy-before-old-error")
        try await awaitDelayedFailure(old)
        try await assertStableHealthyRefreshPage(96, accessibility: true, category: "Movies")
        XCTAssertTrue(app.buttons["filter-Movies"].isSelected)
        try await assertNoWatchReports()
    }

    func testPrivateNavigationAwayCancelsDelayedRefresh() async throws {
        try launch(); tab("Library"); count(144)
        let old = try await startHeldFailedRefresh()
        returnHomeForRefreshLifecycle()
        XCTAssertTrue(app.buttons["heroDetails"].isHittable)
        tab("Library"); count(144)
        let current = try await refreshLifecycleReads()
        let oldIndex = try XCTUnwrap(current.firstIndex { $0["heldRequestID"] as? String == old.identifier })
        XCTAssertTrue(current.dropFirst(oldIndex + 1).contains { $0["status"] as? Int == 200 && $0["total"] as? Int == 144 && $0["heldRequestID"] == nil })
        assertHealthyRefreshPage(144)
        try await assertHeldRefreshWaiting(old)
        try await captureRefreshLifecycle("hold-remounted-healthy-before-release")
        try await releaseHeldRefresh(old)
        try await assertStableHealthyRefreshPage(144)
        try await assertNoWatchReports()
    }

    func testPrivateForegroundRevisionCancelsDelayedRefresh() async throws {
        try launch(); tab("Library"); count(144)
        let old = try await startDelayedFailedRefresh()
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.navigationBars["Library"].waitForExistence(timeout: 8))
        var newPage = false
        for _ in 0..<70 {
            let current = try await refreshLifecycleReads()
            if current.count > old + 1 && current.dropFirst(old + 1).contains(where: { $0["status"] as? Int == 200 }) {
                XCTAssertNil(current[old]["status"], "Foreground libraryRevision must replace the pending request before its old response.")
                newPage = true; break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(newPage)
        try await awaitDelayedFailure(old)
        try await assertStableHealthyRefreshPage(144)
        try await assertNoWatchReports()
    }

    func testPrivateSavedAccountSwitchCancelsDelayedRefresh() async throws {
        let first = "library-refresh-account-a-" + UUID().uuidString
        let second = "library-refresh-account-b-" + UUID().uuidString
        try launch(userOverride: first)
        addSavedAccount(second)
        switchSavedAccount(first)
        tab("Library"); count(144)
        let beforeSecond = try await refreshLifecycleReads(forUser: second).count
        let old = try await startHeldFailedRefresh()
        returnHomeForRefreshLifecycle(); switchSavedAccount(second)
        tab("Library"); count(144)
        let newReads = try await refreshLifecycleReads(forUser: second)
        XCTAssertTrue(newReads.dropFirst(beforeSecond).contains { $0["status"] as? Int == 200 && $0["total"] as? Int == 144 && $0["heldRequestID"] == nil })
        assertHealthyRefreshPage(144)
        try await assertHeldRefreshWaiting(old)
        try await captureRefreshLifecycle("hold-new-account-healthy-before-release", account: second)
        try await releaseHeldRefresh(old)
        try await assertStableHealthyRefreshPage(144)
        returnHomeForRefreshLifecycle()
        app.buttons["servers"].tap()
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["server-" + second].label.contains("Current server"))
        XCTAssertFalse(app.buttons["server-" + first].label.contains("Current server"))
        app.buttons["Done"].tap()
        try await assertNoWatchReports()
    }


    private func heldSearchReads(term: String? = nil, owner: String? = nil) async throws -> [[String: Any]] {
        let state = try await json("/qa/library-state", forUser: owner)
        return (state["requests"] as? [[String: Any]] ?? []).filter { entry in
            guard entry["path"] as? String == "/Items", let query = entry["query"] as? [String: String],
                  query["includeitemtypes"] == "Movie,Series,Episode", query["startindex"] == "0" else { return false }
            return term == nil || query["searchterm"] == term
        }
    }

    private func allItemReadCount() async throws -> Int {
        let state = try await json("/qa/library-state")
        return (state["requests"] as? [[String: Any]] ?? []).filter { $0["path"] as? String == "/Items" }.count
    }

    private func heldSearchReceipt(_ hold: HeldRefresh, term: String) async throws -> [String: Any] {
        let matches = try await heldSearchReads(term: term, owner: hold.owner).filter { $0["heldRequestID"] as? String == hold.identifier }
        XCTAssertEqual(matches.count, 1)
        return try XCTUnwrap(matches.count == 1 ? matches.first : nil)
    }

    private func assertSearchHoldWaiting(_ hold: HeldRefresh, term: String) async throws {
        let receipt = try await heldSearchReceipt(hold, term: term)
        XCTAssertEqual(receipt["holdState"] as? String, "waiting")
        XCTAssertEqual(receipt["plannedStatus"] as? Int, 503)
        XCTAssertEqual(receipt["holdTimeoutMs"] as? Int, 60000)
        XCTAssertEqual(receipt["delayMs"] as? Int, 0)
        XCTAssertNil(receipt["status"])
        _ = try XCTUnwrap(receipt["holdState"] as? String == "waiting" && receipt["plannedStatus"] as? Int == 503 && receipt["status"] == nil ? true : nil)
    }

    private func startHeldSearchRefresh(term: String, accessibility: Bool) async throws -> HeldRefresh {
        heldRefreshOwners.insert(user)
        _ = try await json("/qa/library-control", body: ["reset": true, "holdFirst": true, "failFirst": 1])
        let control: XCUIElement
        if accessibility { control = refreshAccessibleLibrary(in: app.scrollViews["libraryScroll"], label: "Refresh results", centered: true) }
        else { control = refreshLibraryFromToolbar(label: "Refresh results") }
        for _ in 0..<40 {
            let held = try await heldSearchReads(term: term).filter { $0["heldRequestID"] != nil }
            if let receipt = held.first {
                XCTAssertEqual(held.count, 1)
                let hold = HeldRefresh(owner: user, identifier: try canonicalHoldID(receipt["heldRequestID"]))
                try await assertSearchHoldWaiting(hold, term: term)
                XCTAssertFalse(control.isEnabled)
                XCTAssertEqual(control.value as? String, "Loading")
                try await captureRefreshLifecycle("search-" + term + "-positive-held")
                return hold
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        return try XCTUnwrap(nil as HeldRefresh?, "The visible Search Refresh must create its exact owned waiting503 request.")
    }

    private func releaseSearchHold(_ hold: HeldRefresh, term: String) async throws {
        try await assertSearchHoldWaiting(hold, term: term)
        let response = try await json("/qa/library-control", body: ["releaseFirst": hold.identifier], forUser: hold.owner)
        XCTAssertEqual(response["releasedFirst"] as? String, hold.identifier)
        _ = try XCTUnwrap(response["releasedFirst"] as? String == hold.identifier ? true : nil)
        for _ in 0..<40 {
            let receipt = try await heldSearchReceipt(hold, term: term)
            XCTAssertNotEqual(receipt["holdState"] as? String, "timedOut")
            XCTAssertNotEqual(receipt["holdState"] as? String, "canceled")
            if receipt["holdState"] as? String == "released", receipt["status"] as? Int == 503 {
                // This records the selected response, not delivery to a canceled client.
                try await captureRefreshLifecycle("search-" + term + "-explicitly-released503", account: hold.owner)
                heldRefreshOwners.remove(hold.owner)
                return
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        _ = try XCTUnwrap(nil as Bool?, "Only an explicit exact-UUID release503 qualifies this late-response check.")
    }

    private func searchRefreshControl(accessibility: Bool) -> XCUIElement {
        accessibility ? app.scrollViews["libraryScroll"].buttons["libraryRefresh"] : app.navigationBars.buttons["libraryRefresh"]
    }

    private func assertNoSearchRetry() {
        XCTAssertFalse(app.buttons["libraryRefreshRetry"].exists)
        XCTAssertFalse(app.buttons["libraryRetry"].exists)
        XCTAssertFalse(app.buttons["retry"].exists)
    }

    private func assertCedarSearchHealthy(accessibility: Bool) {
        let control = searchRefreshControl(accessibility: accessibility)
        XCTAssertTrue(control.isEnabled)
        XCTAssertEqual(control.value as? String, "Ready")
        XCTAssertTrue((app.searchFields.firstMatch.value as? String ?? "").contains("Cedar"))
        XCTAssertTrue(app.scrollViews["libraryScroll"].buttons["item-library-title-013"].exists)
        XCTAssertFalse(app.scrollViews["libraryScroll"].buttons["item-library-episode-01"].exists)
        assertNoSearchRetry()
    }

    private func assertBlankSearchHealthy(accessibility: Bool) {
        XCTAssertTrue(app.staticTexts["A title in mind?"].exists)
        let field = app.searchFields.firstMatch
        let value = field.value as? String ?? ""
        XCTAssertTrue(value.isEmpty || value == field.placeholderValue)
        XCTAssertTrue(searchRefreshControl(accessibility: accessibility).waitForNonExistence(timeout: 5), "A blank search has nothing to refresh.")
        XCTAssertFalse(app.buttons["item-library-title-013"].exists)
        XCTAssertFalse(app.buttons["item-library-episode-01"].exists)
        assertNoSearchRetry()
    }

    private func searchQueryAndClearCancelHeldRefreshes(accessibility: Bool) async throws {
        try launch(accessibility: accessibility); tab("Search")
        let field = initialSearchField()
        field.tap(); field.typeText("North"); field.typeText(XCUIKeyboardKey.return.rawValue)
        let scroll = app.scrollViews["libraryScroll"]
        XCTAssertTrue(scroll.buttons["item-library-episode-01"].waitForExistence(timeout: 10))
        try await waitForCompletedRead(after: 0, query: ["searchterm": "North", "includeitemtypes": "Movie,Series,Episode", "startindex": "0"])
        let refresh = searchRefreshControl(accessibility: accessibility)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in refresh.exists && refresh.isEnabled && refresh.value as? String == "Ready" }, object: nil)], timeout: 8)
        let north = try await startHeldSearchRefresh(term: "North", accessibility: accessibility)
        let edit = visibleSearchField(in: scroll)
        let oldValue = try XCTUnwrap(edit.value as? String)
        XCTAssertEqual(oldValue, "North")
        // Actual text editing is separate from the Clear button path below.
        edit.tap(); edit.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: oldValue.count) + "Cedar")
        edit.typeText(XCUIKeyboardKey.return.rawValue)
        try await waitForCompletedRead(after: 0, query: ["searchterm": "Cedar", "includeitemtypes": "Movie,Series,Episode", "startindex": "0"])
        let cedarReads = try await heldSearchReads(term: "Cedar")
        XCTAssertTrue(cedarReads.contains { $0["status"] as? Int == 200 && $0["total"] as? Int == 24 && $0["heldRequestID"] == nil })
        let cedar = scroll.buttons["item-library-title-013"]
        XCTAssertTrue(cedar.waitForExistence(timeout: 10))
        if accessibility {
            let title = app.staticTexts["libraryRowTitle-library-title-013"]
            reveal(title, in: scroll, centered: true)
            XCTAssertEqual(title.label, "Cedar Story 01")
            reveal(refresh, in: scroll, centered: true)
        } else {
            reveal(cedar, in: scroll)
            XCTAssertTrue(cedar.label.contains("Cedar Story 01"))
        }
        assertCedarSearchHealthy(accessibility: accessibility)
        try await assertSearchHoldWaiting(north, term: "North")
        try await captureRefreshLifecycle("search-query-new-Cedar-healthy-before-old-release")
        try await releaseSearchHold(north, term: "North")
        for _ in 0..<6 {
            assertCedarSearchHealthy(accessibility: accessibility)
            try await Task.sleep(for: .milliseconds(250))
        }
        try await captureRefreshLifecycle("search-query-Cedar-stable-after-old-release")

        let cedarHold = try await startHeldSearchRefresh(term: "Cedar", accessibility: accessibility)
        let readsBeforeClear = try await allItemReadCount()
        let clearField = visibleSearchField(in: scroll)
        let clear = clearField.buttons["Clear text"]
        XCTAssertTrue(clear.exists)
        XCTAssertTrue(app.windows.firstMatch.frame.contains(clear.frame))
        XCTAssertTrue(clear.isHittable)
        clear.tap()
        XCTAssertTrue(app.staticTexts["A title in mind?"].waitForExistence(timeout: 8))
        // Close only the actual native Search editor when Clear opened it.
        if app.keyboards.firstMatch.exists {
            let close = app.navigationBars["Search"].buttons["Close"]
            XCTAssertTrue(close.waitForExistence(timeout: 5))
            XCTAssertTrue(app.windows.firstMatch.frame.contains(close.frame))
            XCTAssertTrue(close.isHittable)
            close.tap()
            XCTAssertTrue(app.keyboards.firstMatch.waitForNonExistence(timeout: 5))
        }
        if accessibility { reveal(refresh, in: scroll, centered: true) }
        assertBlankSearchHealthy(accessibility: accessibility)
        let afterClear = try await allItemReadCount()
        XCTAssertEqual(afterClear, readsBeforeClear, "Blank Search must issue no new catalog request.")
        try await assertSearchHoldWaiting(cedarHold, term: "Cedar")
        try await captureRefreshLifecycle("search-Clear-blank-healthy-before-old-release")
        try await releaseSearchHold(cedarHold, term: "Cedar")
        for _ in 0..<6 {
            assertBlankSearchHealthy(accessibility: accessibility)
            let stableReads = try await allItemReadCount()
            XCTAssertEqual(stableReads, readsBeforeClear)
            try await Task.sleep(for: .milliseconds(250))
        }
        try await captureRefreshLifecycle("search-Clear-blank-stable-after-old-release")
        try await assertNoWatchReports()
    }

    func testPrivateNormalSearchQueryAndClearCancelHeldRefreshes() async throws {
        try await searchQueryAndClearCancelHeldRefreshes(accessibility: false)
    }

    func testPrivateAXSearchQueryAndClearCancelHeldRefreshes() async throws {
        try await searchQueryAndClearCancelHeldRefreshes(accessibility: true)
    }

}
