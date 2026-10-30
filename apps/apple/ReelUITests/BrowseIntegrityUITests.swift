import XCTest
import UIKit

private final class BrowseNoRedirect: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor final class BrowseIntegrityUITests: XCTestCase {
    private let app = XCUIApplication()
    private var user = ""
    private var observedUsers = Set<String>()
    private var nonce = ""
    private var sourceSHA = ""
    private let origin = "http://127.0.0.1:19140"
    private let redirectDelegate = BrowseNoRedirect()
    private lazy var http = URLSession(configuration: .ephemeral, delegate: redirectDelegate, delegateQueue: nil)

    override func setUp() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Browse integrity QA requires a fresh owned simulator and disposable loopback accounts.")
        #else
        try await super.setUp()
        continueAfterFailure = false
        executionTimeAllowance = 240
        nonce = try XCTUnwrap(ProcessInfo.processInfo.environment["REEL_NATIVE_BROWSE_QA_NONCE"])
        sourceSHA = try XCTUnwrap(ProcessInfo.processInfo.environment["REEL_NATIVE_BROWSE_SOURCE_SHA256"])
        XCTAssertNotNil(nonce.range(of: "^[0-9a-f]{32}$", options: .regularExpression))
        XCTAssertNotNil(sourceSHA.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        user = "browse-" + UUID().uuidString
        observedUsers.insert(user)
        let status = try await json("/qa/status", authenticated: false)
        XCTAssertEqual(status["kind"] as? String, "reel-native-browse-fixture")
        XCTAssertEqual(status["nonce"] as? String, nonce)
        XCTAssertEqual(status["sourceSHA256"] as? String, sourceSHA)
        XCTAssertEqual(status["port"] as? Int, 19140)
        #endif
    }

    override func tearDown() async throws {
        defer {
            http.invalidateAndCancel()
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }
        if !user.isEmpty, !nonce.isEmpty {
            for identity in observedUsers.sorted() {
            let state = try await json("/qa/browse-state", forUser: identity)
            let requests = try XCTUnwrap(state["requests"] as? [[String: Any]])
            XCTAssertFalse(requests.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true }, "Browse QA must never issue playback history reports.")
            XCTAssertFalse(requests.contains { $0["holdOutcome"] as? String == "timedOut" }, "A timed-out hold cannot qualify cancellation/recovery.")
            let receipt = XCTAttachment(data: try JSONSerialization.data(withJSONObject: state, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
            receipt.name = "browse-integrity-final-" + identity; receipt.lifetime = .keepAlways; add(receipt)
            _ = try await json("/qa/browse-control", body: ["reset": true], forUser: identity)
            }
        }
        try await super.tearDown()
    }

    private func json(_ path: String, body: [String: Any]? = nil, authenticated: Bool = true, forUser: String? = nil) async throws -> [String: Any] {
        let url = try XCTUnwrap(URL(string: origin + path))
        var request = URLRequest(url: url); request.timeoutInterval = 4
        request.setValue(nonce, forHTTPHeaderField: "X-Reel-QA-Nonce")
        if authenticated { request.setValue("MediaBrowser Token=\"fixture-\(forUser ?? user)\"", forHTTPHeaderField: "Authorization") }
        if let body {
            request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await http.data(for: request)
        let actual = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(actual.url, url); XCTAssertEqual(actual.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func launch(accessibility: Bool = false, saved: Bool = false) {
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = saved ? [] : ["-reel-qa-reset"]
        if accessibility { app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] }
        app.launchEnvironment["REEL_QA_SERVER"] = origin
        app.launch()
        if !saved {
            let name = app.textFields["username"]
            XCTAssertTrue(name.waitForExistence(timeout: 10)); tap(name, in: app.scrollViews.firstMatch)
            name.typeText(user); name.typeText(XCUIKeyboardKey.return.rawValue)
            let password = app.secureTextFields["password"]
            XCTAssertTrue(password.isHittable); password.typeText("demo"); password.typeText(XCUIKeyboardKey.return.rawValue)
        }
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 18), app.debugDescription)
        let decline = app.buttons["Not Now"]
        if decline.waitForExistence(timeout: 1) {
            XCTAssertTrue(app.staticTexts["Save Password?"].exists); tap(decline)
        }
        // Only the source-bound disposable loopback fixture was admitted above.
        // Set the real policy control explicitly before mutable happy paths.
        tab("Settings")
        let privacy = app.switches["privateViewing"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5))
        if privacy.value as? String == "1" { tap(privacy, in: app.scrollViews.firstMatch) }
        XCTAssertEqual(privacy.value as? String, "0")
        tab("Home")
    }

    private func tab(_ title: String) {
        if app.navigationBars[title].exists { return }
        if title == "Settings" {
            let more = app.buttons["ellipsis.circle"].firstMatch
            if !more.exists, app.buttons["Show Sidebar"].exists { tap(app.buttons["Show Sidebar"]) }
            // Tab bar items sit in the bar itself, outside the content the tap helper checks.
            XCTAssertTrue(more.waitForExistence(timeout: 5)); more.tap()
            // A second tap returns More to its root, as in ReelUITests.
            if !app.navigationBars["More"].waitForExistence(timeout: 2) { more.tap() }
            XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5))
            // More is a List, which current iOS exposes as a collection view.
            let list = app.collectionViews.firstMatch
            tap(app.buttons["Settings"].firstMatch, in: list.exists ? list : app.scrollViews.firstMatch)
        } else {
            let item = app.buttons[title].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
        }
        // Home shows the Reel mark instead of a titled navigation bar.
        let landed = title == "Home" ? app.scrollViews["homeScroll"] : app.navigationBars[title]
        XCTAssertTrue(landed.waitForExistence(timeout: 8), app.debugDescription)
    }

    private func tap(_ element: XCUIElement, in scroll: XCUIElement? = nil) {
        for attempt in 0...16 {
            let window = app.windows.firstMatch.frame
            var visible = window.insetBy(dx: 2, dy: 2)
            let owner = scroll.flatMap { candidate -> XCUIElement? in
                guard element.exists else { return candidate }
                // XCUIElement proxies have no reliable object-identity membership
                // contract. Match the actual descendant's semantic/frame identity.
                return candidate.descendants(matching: .any).allElementsBoundByAccessibilityElement.contains {
                    $0.identifier == element.identifier && $0.label == element.label && $0.frame == element.frame
                } ? candidate : nil
            }
            if let scroll = owner {
                XCTAssertTrue(scroll.exists)
                // Connect has no navigation bar; reading a missing bar's frame fails the test.
                let navigationBar = app.navigationBars.firstMatch
                let top = max(scroll.frame.minY, navigationBar.exists ? navigationBar.frame.maxY : window.minY)
                var bottom = min(scroll.frame.maxY, window.maxY)
                if app.tabBars.firstMatch.exists { bottom = min(bottom, app.tabBars.firstMatch.frame.minY) }
                if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY) }
                for identifier in ["inputView", "SystemInputAssistantView"] {
                    for value in app.otherElements.matching(identifier: identifier).allElementsBoundByAccessibilityElement where value.exists && value.frame.intersects(window) && value.frame.height > 0 {
                        bottom = min(bottom, value.frame.minY)
                    }
                }
                visible = CGRect(x: max(window.minX, scroll.frame.minX), y: top,
                                 width: min(window.maxX, scroll.frame.maxX) - max(window.minX, scroll.frame.minX), height: bottom - top)
            }
            if element.exists && element.isHittable && visible.contains(element.frame) {
                XCTAssertGreaterThan(element.frame.width, 0); XCTAssertGreaterThan(element.frame.height, 0)
                element.tap(); return
            }
            guard attempt < 16, let scroll = owner else { break }
            XCTAssertGreaterThan(visible.height, 60)
            if element.exists && element.frame.minY < visible.minY { scroll.swipeDown() } else { scroll.swipeUp() }
        }
        attach("unreachable-control")
        XCTFail("Control must be fully visible and hittable in its foreground owner: \(element)")
    }

    private func menu(_ identifier: String, _ option: String) {
        tap(app.buttons[identifier], in: app.scrollViews["libraryScroll"].exists ? app.scrollViews["libraryScroll"] : nil)
        let exact = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@ AND NOT (identifier BEGINSWITH 'filter-')", option, identifier)).firstMatch
        XCTAssertTrue(exact.waitForExistence(timeout: 5), app.debugDescription)
        tap(exact)
    }

    private func category(_ value: String) {
        let button = app.buttons["filter-" + value]
        let rail = app.scrollViews.containing(.button, identifier: "filter-" + value).firstMatch
        for _ in 0..<8 {
            if button.exists && button.isHittable && app.windows.firstMatch.frame.contains(button.frame) { break }
            if value == "All" { rail.swipeRight() } else { rail.swipeLeft() }
        }
        tap(button)
        XCTAssertTrue(button.isSelected)
    }

    private func count(_ value: Int) {
        XCTAssertTrue(app.staticTexts["\(value) titles"].waitForExistence(timeout: 12), app.debugDescription)
    }

    private func back() {
        let bars = app.navigationBars.allElementsBoundByAccessibilityElement.filter { $0.exists && $0.frame.intersects(app.windows.firstMatch.frame) && $0.buttons.firstMatch.isHittable }
        if let bar = bars.last { tap(bar.buttons.firstMatch) }
        else {
            let sideBack = app.buttons["BackButton"]
            XCTAssertTrue(sideBack.waitForExistence(timeout: 5)); tap(sideBack)
        }
    }

    private func open(_ identifier: String) {
        tap(app.buttons["item-" + identifier], in: app.scrollViews["libraryScroll"])
        XCTAssertTrue(app.scrollViews["detailScroll"].waitForExistence(timeout: 8))
    }

    private func status(_ value: String) async {
        let element = app.buttons["watchStatus"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)], timeout: 10)
    }

    /// Opens the Audio or Subtitles submenu of the "Audio and subtitles" control.
    private func openTracks(_ submenu: String) {
        tap(app.buttons["detailTracks"], in: app.scrollViews["detailScroll"])
        let row = app.reelMenuItem(submenu)
        XCTAssertTrue(row.waitForExistence(timeout: 5)); tap(row)
    }

    private func chooseTrack(_ submenu: String, _ option: String) {
        openTracks(submenu)
        let choice = app.buttons[option]
        XCTAssertTrue(choice.waitForExistence(timeout: 5)); tap(choice)
    }

    /// A series or season offers scoped choices in a menu; a movie or episode
    /// toggles, so its control is tapped only when it shows the other state.
    private func chooseWatched(_ desired: Bool, identifier: String = "watchStatus") {
        let control = app.buttons[identifier]
        let option = app.buttons[identifier + (desired ? "MarkWatched" : "MarkUnwatched")]
        let before = control.value as? String
        tap(control, in: app.scrollViews["detailScroll"])
        if option.waitForExistence(timeout: 2) { tap(option); return }
        XCTAssertNotEqual(before, desired ? "Watched" : "Unwatched", "A toggle tap must move toward the desired state.")
    }

    private func mutations() async throws -> [[String: Any]] {
        let state = try await json("/qa/browse-state")
        return try XCTUnwrap(state["requests"] as? [[String: Any]]).filter { ($0["path"] as? String)?.hasPrefix("/UserPlayedItems/") == true }
    }

    private func assertMutationCount(_ expected: Int, file: StaticString = #filePath, line: UInt = #line) async throws {
        let values = try await mutations()
        XCTAssertEqual(values.count, expected, file: file, line: line)
    }

    private func requests(_ path: String) async throws -> [[String: Any]] {
        let state = try await json("/qa/browse-state")
        return try XCTUnwrap(state["requests"] as? [[String: Any]]).filter { $0["path"] as? String == path }
    }

    private func waitRead(_ path: String, after: Int, query: [String: String] = [:]) async throws -> [String: Any] {
        for _ in 0..<100 {
            let rows = try await requests(path)
            if let row = rows.dropFirst(after).last(where: { row in
                guard row["completed"] as? Bool == true, row["status"] as? Int == 200, let actual = row["query"] as? [String: String] else { return false }
                return query.allSatisfy { actual[$0.key] == $0.value }
            }) { return row }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("A fresh completed matching native API request was required for \(path)")
        throw URLError(.timedOut)
    }

    private func waitHold(path: String, method: String, role: String) async throws -> String {
        for _ in 0..<80 {
            let values = try await requests(path)
            let matches = values.filter { $0["method"] as? String == method && $0["holdRole"] as? String == role && $0["holdOutcome"] as? String == "waiting" && $0["completed"] as? Bool == false }
            if matches.count == 1 { return try XCTUnwrap(matches[0]["holdID"] as? String) }
            XCTAssertLessThanOrEqual(matches.count, 1, "Only one exact target hold can own this phase")
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Actual target request never reached its owned hold")
        throw URLError(.timedOut)
    }

    private func waitCompletedHold(_ identifier: String, path: String) async throws {
        for _ in 0..<80 {
            let values = try await requests(path)
            if values.contains(where: { $0["holdID"] as? String == identifier && $0["holdOutcome"] as? String == "released" && $0["completed"] as? Bool == true }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The released exact owned request did not complete")
        throw URLError(.timedOut)
    }

    private func assertFreshCompleteOptions(_ path: String, after boundary: Int, expectedIDs: Set<String>, before firstItems: [String: Any]) async throws {
        let fresh = Array(try await requests(path).dropFirst(boundary))
        let firstStarted = try XCTUnwrap(firstItems["started"] as? Double)
        let completed = fresh.filter { row in
            guard row["completed"] as? Bool == true, row["status"] as? Int == 200,
                  let finished = row["finished"] as? Double, finished <= firstStarted,
                  let returned = row["returnedIDs"] as? [String], Set(returned) == expectedIDs,
                  row["total"] as? Int == expectedIDs.count else { return false }
            return true
        }
        let proof = XCTAttachment(string: "path=\(path);priorLedgerCount=\(boundary);freshRows=\(fresh.count);firstItemsSequence=\(String(describing: firstItems["sequence"]));firstItemsStarted=\(firstStarted);freshCompletedSequences=\(completed.compactMap { $0["sequence"] as? Int })")
        proof.name = "fresh-complete-options-before-items"; proof.lifetime = .keepAlways; add(proof)
        XCTAssertFalse(completed.isEmpty, "The restored ID must wait for a NEW successful complete options RESPONSE before the first Items request. Previous-launch rows or request-start order cannot qualify this barrier.")
    }

    private func attach(_ name: String) {
        let image = XCTAttachment(screenshot: app.screenshot()); image.name = name; image.lifetime = .keepAlways; add(image)
        let tree = XCTAttachment(string: app.debugDescription); tree.name = name + "-hierarchy"; tree.lifetime = .keepAlways; add(tree)
    }

    private func addAccount(_ identity: String) {
        tab("Home"); tap(app.buttons["servers"]); tap(app.buttons["addServer"])
        let name = app.textFields["username"]
        XCTAssertTrue(name.waitForExistence(timeout: 8))
        tap(name, in: app.scrollViews.containing(.textField, identifier: "username").firstMatch)
        name.typeText(identity); name.typeText(XCUIKeyboardKey.return.rawValue)
        let password = app.secureTextFields["password"]
        XCTAssertTrue(password.isHittable); password.typeText("demo"); password.typeText(XCUIKeyboardKey.return.rawValue)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        observedUsers.insert(identity); user = identity
    }

    private func switchAccount(_ identity: String) {
        tab("Home"); tap(app.buttons["servers"])
        XCTAssertTrue(app.navigationBars["Servers"].waitForExistence(timeout: 5))
        tap(app.buttons["server-" + identity])
        XCTAssertTrue(app.navigationBars["Servers"].waitForNonExistence(timeout: 8))
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15)); user = identity
    }

    func testDirectionAndAddedMetadataUseActualCurrentQueryAndSeriesContentField() async throws {
        launch(); tab("Library"); count(144)
        let before = try await requests("/Items").count
        tap(app.buttons["libraryDirection"], in: app.scrollViews["libraryScroll"])
        _ = try await waitRead("/Items", after: before, query: ["sortby": "SortName", "sortorder": "Descending", "limit": "60"])
        XCTAssertEqual(app.buttons["libraryDirection"].value as? String, "Descending")
        menu("librarySort", "Recently added")
        _ = try await waitRead("/Items", after: before, query: ["sortby": "DateCreated,SortName", "sortorder": "Descending,Ascending"])
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'libraryAddedDate-' AND label BEGINSWITH 'Added '")).firstMatch.waitForExistence(timeout: 8))
        category("Series"); count(48); menu("librarySort", "Latest episode added")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'libraryAddedDate-' AND label BEGINSWITH 'Content added '")).firstMatch.waitForExistence(timeout: 8))
        attach("direction-and-truthful-added-dates")
    }

    func testScopedCompoundChoicesAndRootSurviveActualTerminateAndRelaunch() async throws {
        launch(); tab("Library"); category("Episodes"); count(12)
        menu("libraryFilters", "Shows"); menu("librarySort", "Recently added")
        menu("libraryFilters", "Adventure"); menu("libraryFilters", "Unwatched")
        tap(app.buttons["libraryDirection"], in: app.scrollViews["libraryScroll"])
        tap(app.buttons["List"], in: app.scrollViews["libraryScroll"])
        let before = try await requests("/Items").count
        app.terminate(); launch(saved: true); tab("Library")
        let restored = try await waitRead("/Items", after: before, query: ["includeitemtypes": "Episode", "parentid": "library-shows", "genreids": "library-adventure", "isplayed": "false", "sortby": "DateCreated,SortName", "sortorder": "Ascending,Ascending"])
        XCTAssertEqual(restored["status"] as? Int, 200)
        XCTAssertTrue(app.buttons["filter-Episodes"].isSelected)
        XCTAssertEqual(app.buttons["libraryDirection"].value as? String, "Ascending")
        XCTAssertTrue(app.buttons["List"].isSelected)
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].label.contains("Shows"))
        attach("scoped-relaunch")
    }

    func testCategoryAndLibraryChoicesAreIndependentAndClearTargetsFinalScope() async throws {
        launch(); tab("Library"); count(144)
        menu("librarySort", "Recently added")
        menu("libraryFilters", "Films")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Title")
        menu("librarySort", "Release year")
        menu("libraryFilters", "Adventure")
        menu("libraryFilters", "All libraries")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        menu("libraryFilters", "Films")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Release year")
        menu("libraryFilters", "Unwatched")
        menu("libraryFilters", "Clear filters"); count(144)
        XCTAssertFalse(app.staticTexts["libraryFilterSummary"].exists)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Release year")
        category("Series"); count(48)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Title")
        category("All"); count(144)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Release year")
    }

    func testHomeEpisodeSeeAllOverridesQueryAndPersistsOnlyViewChoiceWhenOpened() async throws {
        launch(); tab("Library"); category("Episodes"); count(12)
        menu("libraryFilters", "Watched"); menu("librarySort", "Title")
        tab("Home")
        tap(app.buttons["recent-Episodes-seeAll"], in: app.scrollViews["homeScroll"])
        count(12)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        XCTAssertFalse(app.staticTexts["libraryFilterSummary"].exists)
        tap(app.buttons["List"], in: app.scrollViews["libraryScroll"])
        back(); tab("Library")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Title")
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].label.contains("Watched"))
        XCTAssertTrue(app.buttons["List"].isSelected)
        app.terminate(); launch(saved: true); tab("Library")
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Title")
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].label.contains("Watched"))
        XCTAssertTrue(app.buttons["List"].isSelected)
    }

    func testSavedAccountSwitchRestoresOnlyThatUsersRootAndChoices() async throws {
        launch(); let first = user
        tab("Library"); category("Episodes"); menu("librarySort", "Recently added")
        menu("libraryFilters", "Unwatched")
        let sibling = "browse-" + UUID().uuidString
        addAccount(sibling); tab("Library"); count(144)
        XCTAssertTrue(app.buttons["filter-All"].isSelected)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Title")
        XCTAssertFalse(app.staticTexts["libraryFilterSummary"].exists)
        category("Series"); menu("librarySort", "Latest episode added")
        switchAccount(first); tab("Library")
        XCTAssertTrue(app.buttons["filter-Episodes"].isSelected)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Recently added")
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].label.contains("Unwatched"))
        switchAccount(sibling); tab("Library")
        XCTAssertTrue(app.buttons["filter-Series"].isSelected)
        XCTAssertEqual(app.buttons["librarySort"].value as? String, "Latest episode added")
    }

    func testRemovedSavedLibraryIsRepairedBeforeAnyLibraryItemsQuery() async throws {
        launch(); tab("Library"); category("Episodes"); menu("libraryFilters", "Shows")
        app.terminate(); _ = try await json("/qa/browse-control", body: ["removeLibrary": true, "holdOptions": true])
        XCTAssertEqual(app.state, .notRunning)
        let before = try await requests("/Items").count
        let optionsBoundary = try await requests("/UserViews").count
        launch(saved: true); tab("Library")
        let held = try await waitHold(path: "/UserViews", method: "GET", role: "holdOptions")
        let pending = Array(try await requests("/Items").dropFirst(before)).filter { ($0["query"] as? [String: String])?["limit"] == "60" }
        XCTAssertTrue(pending.isEmpty, "No restored-library query may begin while its fresh options response is held")
        _ = try await json("/qa/browse-control", body: ["release": held])
        try await waitCompletedHold(held, path: "/UserViews"); count(12)
        let reads = Array(try await requests("/Items").dropFirst(before)).filter { ($0["query"] as? [String: String])?["limit"] == "60" }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertFalse(reads.contains { ($0["query"] as? [String: String])?["parentid"] == "library-shows" })
        XCTAssertFalse(app.staticTexts["libraryFilterSummary"].exists)
        try await assertFreshCompleteOptions("/UserViews", after: optionsBoundary, expectedIDs: ["library-films"], before: XCTUnwrap(reads.first))
    }

    func testRemovedSavedGenreIsRepairedOnlyAfterCompleteOptionsAndBeforeQuery() async throws {
        launch(); tab("Library"); menu("libraryFilters", "Drama"); count(108)
        app.terminate(); _ = try await json("/qa/browse-control", body: ["removeGenre": true, "holdGenres": true])
        XCTAssertEqual(app.state, .notRunning)
        let before = try await requests("/Items").count
        let optionsBoundary = try await requests("/Genres").count
        launch(saved: true); tab("Library")
        let held = try await waitHold(path: "/Genres", method: "GET", role: "holdGenres")
        let pending = Array(try await requests("/Items").dropFirst(before)).filter { ($0["query"] as? [String: String])?["limit"] == "60" }
        XCTAssertTrue(pending.isEmpty, "No restored-genre query may begin while its fresh complete response is held")
        _ = try await json("/qa/browse-control", body: ["release": held])
        try await waitCompletedHold(held, path: "/Genres"); count(144)
        let reads = Array(try await requests("/Items").dropFirst(before)).filter { ($0["query"] as? [String: String])?["limit"] == "60" }
        XCTAssertFalse(reads.isEmpty)
        XCTAssertFalse(reads.contains { ($0["query"] as? [String: String])?["genreids"] != nil })
        try await assertFreshCompleteOptions("/Genres", after: optionsBoundary, expectedIDs: ["library-adventure"], before: XCTUnwrap(reads.first))
        XCTAssertFalse(app.staticTexts["libraryFilterSummary"].exists)
    }

    func testSavedGenreOptionsFailureBlocksQueryUntilExplicitRetryRecovery() async throws {
        launch(); tab("Library"); menu("libraryFilters", "Drama"); count(108)
        let before = try await requests("/Items").count
        app.terminate(); _ = try await json("/qa/browse-control", body: ["failGenres": 100])
        launch(saved: true); tab("Library")
        XCTAssertTrue(app.staticTexts["libraryOptionsError"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["libraryRefresh"].isEnabled)
        let blocked = Array(try await requests("/Items").dropFirst(before)).filter { ($0["query"] as? [String: String])?["limit"] == "60" }
        XCTAssertTrue(blocked.isEmpty, "A restored unvalidated genre cannot issue a first page")
        _ = try await json("/qa/browse-control", body: ["failGenres": 0])
        tap(app.buttons["libraryOptionsRetry"], in: app.scrollViews["libraryScroll"]); count(108)
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].label.contains("Drama"))
        app.terminate(); launch(saved: true); tab("Library"); count(108)
        XCTAssertTrue(app.staticTexts["libraryFilterSummary"].label.contains("Drama"))
    }

    func testSeriesAndSeasonConfirmationCancelWritesNothingAndCommitRefreshesCounts() async throws {
        launch(); tab("Library"); category("Series"); count(48)
        open("library-title-003")
        let countLabel = app.staticTexts["unwatchedCount-library-title-003"]
        XCTAssertTrue(countLabel.waitForExistence(timeout: 8)); XCTAssertEqual(countLabel.label, "2 unwatched")
        chooseWatched(true)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'outside the current filters'")).firstMatch.waitForExistence(timeout: 5))
        tap(app.buttons["watchStatusCancel"])
        try await assertMutationCount(0)
        chooseWatched(true); tap(app.buttons["watchStatusConfirm"])
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "0 unwatched"), object: countLabel)], timeout: 10)
        let accepted = try await mutations()
        XCTAssertEqual(accepted.count, 1); XCTAssertEqual((accepted[0]["affectedIDs"] as? [String])?.count, 5)
        chooseWatched(false, identifier: "seasonWatchStatus")
        tap(app.buttons["seasonWatchStatusCancel"])
        try await assertMutationCount(1)
        chooseWatched(false, identifier: "seasonWatchStatus"); tap(app.buttons["seasonWatchStatusConfirm"])
        let seasonCount = app.staticTexts["unwatchedCount-browse-season-003-1"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "2 unwatched"), object: seasonCount)], timeout: 10)
        try await assertMutationCount(2)
    }

    func testUncertainAcceptedLeafWriteUsesReadbackAndDoesNotAutomaticallyRepeat() async throws {
        launch(); tab("Library"); category("Movies"); count(96); open("library-title-001")
        _ = try await json("/qa/browse-control", body: ["failMutation": 1, "acceptFailedMutation": 1])
        chooseWatched(true)
        XCTAssertTrue(app.staticTexts["watchStatusError"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["watchStatusReadback"].waitForExistence(timeout: 10))
        await status("Watched")
        XCTAssertFalse(app.buttons["watchStatusRetry"].exists)
        let writes = try await mutations(); XCTAssertEqual(writes.count, 1); XCTAssertEqual(writes[0]["accepted"] as? Bool, true)
        let reads = try await requests("/Items/library-title-001")
        XCTAssertTrue(reads.contains { ($0["sequence"] as? Int ?? 0) > (writes[0]["sequence"] as? Int ?? 0) && $0["completed"] as? Bool == true })
    }

    func testUncertainUnacceptedLeafRepeatRequiresReadbackThenFreshConfirmation() async throws {
        launch(); tab("Library"); category("Movies"); count(96); open("library-title-001")
        _ = try await json("/qa/browse-control", body: ["failMutation": 1])
        chooseWatched(true)
        let retry = app.buttons["watchStatusRetry"]
        XCTAssertTrue(retry.waitForExistence(timeout: 10)); tap(retry, in: app.scrollViews["detailScroll"])
        tap(app.buttons["watchStatusCancel"])
        try await assertMutationCount(1)
        tap(retry, in: app.scrollViews["detailScroll"]); tap(app.buttons["watchStatusConfirm"])
        await status("Watched")
        let writes = try await mutations(); XCTAssertEqual(writes.count, 2)
        XCTAssertEqual(writes.map { $0["desired"] as? Bool }, [true, true])
        XCTAssertEqual(writes.map { $0["accepted"] as? Bool }, [false, true])
    }

    func testFailedReadbackBlocksRepeatUntilActualReadOnlyRecovery() async throws {
        launch(); tab("Library"); category("Movies"); count(96); open("library-title-001")
        _ = try await json("/qa/browse-control", body: ["failMutation": 1, "failReadback": 100])
        chooseWatched(true)
        let message = app.staticTexts["watchStatusReadback"]
        XCTAssertTrue(message.waitForExistence(timeout: 10))
        XCTAssertTrue(message.label.contains("could not be checked"))
        XCTAssertFalse(app.buttons["watchStatusRetry"].exists)
        try await assertMutationCount(1)
        _ = try await json("/qa/browse-control", body: ["failReadback": 0])
        tap(app.buttons["watchStatusCheckStatus"], in: app.scrollViews["detailScroll"])
        XCTAssertTrue(app.buttons["watchStatusRetry"].waitForExistence(timeout: 10))
        try await assertMutationCount(1)
    }

    func testWrongIdentityReadbackCannotEnableAnotherWatchedWrite() async throws {
        launch(); tab("Library"); category("Movies"); count(96); open("library-title-001")
        _ = try await json("/qa/browse-control", body: ["failMutation": 1, "readbackMode": "wrongID"])
        chooseWatched(true)
        let text = app.staticTexts["watchStatusReadback"]
        XCTAssertTrue(text.waitForExistence(timeout: 10)); XCTAssertTrue(text.label.contains("different title"))
        XCTAssertFalse(app.buttons["watchStatusRetry"].exists)
        try await assertMutationCount(1)
    }

    func testUnknownFreshTypeRefusesFurtherMutationWithoutAssumingPlayedMeansLeaf() async throws {
        launch(); tab("Library"); category("Movies"); count(96); open("library-title-001")
        _ = try await json("/qa/browse-control", body: ["readbackMode": "unknown"])
        let before = try await requests("/Items/library-title-001").count
        app.scrollViews["detailScroll"].swipeDown()
        _ = try await waitRead("/Items/library-title-001", after: before)
        XCTAssertTrue(app.staticTexts["watchStatusUnavailable"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["watchStatus"].isEnabled)
        try await assertMutationCount(0)
    }

    func testContainerReadbackRepeatRetainsDesiredValueAndNewContainerScope() async throws {
        launch(); tab("Library"); category("Movies"); count(96); open("library-title-001")
        _ = try await json("/qa/browse-control", body: ["failMutation": 1, "readbackMode": "container"])
        chooseWatched(true)
        let metadata = app.staticTexts["watchStatusReadback"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", "type metadata"), object: metadata)], timeout: 10)
        XCTAssertFalse(app.buttons["watchStatusRetry"].exists, "Changed scope invalidates the captured retry")
        chooseWatched(true)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'all playable items in this container'")).firstMatch.waitForExistence(timeout: 5))
        tap(app.buttons["watchStatusCancel"])
        try await assertMutationCount(1)
    }

    func testOldSeasonReadbackFinalizerCannotClearNewSeasonPendingWrite() async throws {
        launch(); tab("Library"); category("Series"); count(48); open("library-title-003")
        let first = "browse-season-003-1", second = "browse-season-003-2"
        _ = try await json("/qa/browse-control", body: ["failMutation": 1, "holdReadbackItem": first])
        chooseWatched(false, identifier: "seasonWatchStatus"); tap(app.buttons["seasonWatchStatusConfirm"])
        let old = try await waitHold(path: "/Items/" + first, method: "GET", role: "readback")
        let watched = app.buttons["seasonWatchStatus"]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Checking"), object: watched)], timeout: 5)
        tap(app.buttons["seasonPicker"], in: app.scrollViews["detailScroll"]); tap(app.buttons["Season 2"])
        _ = try await json("/qa/browse-control", body: ["holdMutationItem": second])
        chooseWatched(true, identifier: "seasonWatchStatus"); tap(app.buttons["seasonWatchStatusConfirm"])
        let new = try await waitHold(path: "/UserPlayedItems/" + second, method: "POST", role: "mutation")
        XCTAssertEqual(watched.value as? String, "Saving"); XCTAssertFalse(watched.isEnabled)
        _ = try await json("/qa/browse-control", body: ["release": old])
        try await waitCompletedHold(old, path: "/Items/" + first)
        // Allow the real URLSession/MainActor completion to run through several
        // native UI snapshots while the independent new write remains held.
        for _ in 0..<5 {
            try await Task.sleep(for: .milliseconds(200))
            XCTAssertEqual(watched.value as? String, "Saving"); XCTAssertFalse(watched.isEnabled)
        }
        let pending = try await requests("/UserPlayedItems/" + second)
        XCTAssertTrue(pending.contains { $0["holdID"] as? String == new && $0["completed"] as? Bool == false })
        attach("old-season-complete-new-season-still-saving")
        _ = try await json("/qa/browse-control", body: ["release": new])
        try await waitCompletedHold(new, path: "/UserPlayedItems/" + second)
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true AND value != %@", "Saving"), object: watched)], timeout: 10)
        let countLabel = app.staticTexts["unwatchedCount-" + second]
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", "0 unwatched"), object: countLabel)], timeout: 10)
        try await assertMutationCount(2)
    }

    func testPrivateViewingDisablesWatchedControlAndProducesNoMutation() async throws {
        launch(); tab("Settings")
        let privacy = app.switches["privateViewing"]
        XCTAssertTrue(privacy.waitForExistence(timeout: 5)); if privacy.value as? String == "0" { tap(privacy) }
        XCTAssertEqual(privacy.value as? String, "1")
        tab("Library"); category("Movies"); count(96); open("library-title-001")
        let control = app.buttons["watchStatus"]
        XCTAssertTrue(control.waitForExistence(timeout: 8)); XCTAssertFalse(control.isEnabled)
        XCTAssertTrue(app.staticTexts["Turn off Private viewing to change watched status."].exists)
        try await assertMutationCount(0)
        back(); tab("Settings"); tap(privacy); XCTAssertEqual(privacy.value as? String, "0")
    }

    func testVersionAudioAndSubtitleSelectionsSurviveWatchedRefresh() async throws {
        launch(); tab("Library"); category("Movies"); count(96); open("library-title-001")
        tap(app.buttons["versionPicker"], in: app.scrollViews["detailScroll"]); tap(app.buttons["Synthetic alternate"])
        chooseTrack("Audio", "Alternate synthetic audio")
        chooseTrack("Subtitles", "Alternate synthetic subtitle")
        chooseWatched(true); await status("Watched")
        XCTAssertEqual(app.buttons["versionPicker"].value as? String, "Synthetic alternate")
        openTracks("Audio")
        XCTAssertTrue(app.buttons["Alternate synthetic audio"].isSelected)
        tap(app.buttons["Alternate synthetic audio"])
        openTracks("Subtitles")
        XCTAssertTrue(app.buttons["Alternate synthetic subtitle"].isSelected)
        tap(app.buttons["Alternate synthetic subtitle"])
        try await assertMutationCount(1)
    }

    func testLargestTextDirectionViewCountAndConfirmationStayWithinOwningViewport() async throws {
        launch(accessibility: true); tab("Library"); category("Series"); count(48)
        tap(app.buttons["libraryDirection"], in: app.scrollViews["libraryScroll"])
        tap(app.buttons["List"], in: app.scrollViews["libraryScroll"])
        attach("browse-largest-text-controls")
        open("library-title-003")
        chooseWatched(true); tap(app.buttons["watchStatusCancel"])
        try await assertMutationCount(0)
        XCUIDevice.shared.orientation = .landscapeLeft
        chooseWatched(true); tap(app.buttons["watchStatusCancel"])
        attach("browse-largest-text-landscape-confirmation")
        try await assertMutationCount(0)
    }
}
