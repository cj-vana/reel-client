import XCTest

@MainActor final class NativeStorageUITests: XCTestCase {
    private let app = XCUIApplication()

    private func fixture(_ phase: Int? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18766" + (phase == nil ? "/qa/hub-state" : "/qa/hub-control"))!)
        request.setValue("MediaBrowser Token=\"fixture-storage-coordinator\"", forHTTPHeaderField: "Authorization")
        if let phase {
            request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: ["storagePhase": phase])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func waitForPhase(_ expected: Int) async throws {
        var arrived = false
        for _ in 0..<200 {
            let value = try await fixture()
            if (value["mode"] as? [String: Any])?["storagePhase"] as? Int == expected { arrived = true; break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(arrived, "The QA host coordinator did not finish storage phase \(expected).")
    }

    private func downloadRequestCount(_ user: String) async throws -> Int {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:18766/qa/hub-state")!)
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (state["requests"] as? [[String: Any]] ?? []).filter { $0["kind"] as? String == "Download" }.count
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<10 { if element.exists && element.isHittable { return }; app.swipeUp() }
    }

    private func tap(_ identifier: String) {
        let button = app.buttons[identifier].firstMatch
        reveal(button); XCTAssertTrue(button.waitForExistence(timeout: 8), app.debugDescription); button.tap()
    }

    private func media() {
        let more = app.buttons["ellipsis.circle"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 8)); more.tap()
        if !app.navigationBars["More"].waitForExistence(timeout: 2) { more.tap() }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 5)); tap("Media")
    }

    private func disappears(_ element: XCUIElement) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element)], timeout: 8)
    }

    func testCorruptManifestRecoveryThroughSavedAndTransferControls() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Storage fault injection is restricted to the disposable QA simulator.")
        #else
        let setup = try await fixture()
        guard let mode = setup["mode"] as? [String: Any], mode["storagePhase"] as? Int == 0, mode["storageRepairRequested"] as? Bool == true else {
            throw XCTSkip("Run qa/runtime_storage_recovery.py to preserve and repair the disposable simulator manifest during this native journey.")
        }
        continueAfterFailure = false
        app.launchArguments = ["-reel-qa-reset"]
        app.launchEnvironment["REEL_QA_SERVER"] = "http://127.0.0.1:18766"
        app.launch()
        let username = app.textFields["username"]; reveal(username)
        let user = "storage-ui-" + String(UUID().uuidString.prefix(8))
        username.tap(); username.typeText(user)
        app.secureTextFields["password"].tap(); app.secureTextFields["password"].typeText("demo"); tap("connect")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        media(); tap("hub-Book"); tap("hub-book-hub-book-1"); tap("hubSaveBook")
        XCTAssertTrue(app.staticTexts["hubBookError"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["hubOpenBook"].exists)
        media(); tap("hub-saved")
        XCTAssertTrue(app.buttons["hubRetryStorage"].waitForExistence(timeout: 8)); tap("hubRetryStorage")
        XCTAssertTrue(app.buttons["hubRetryStorage"].exists, "Retry must preserve the error while the manifest is still corrupt.")
        _ = try await fixture(1); try await waitForPhase(2)
        tap("hubRetryStorage"); await disappears(app.buttons["hubRetryStorage"])
        XCTAssertTrue(app.buttons["Retry saving"].waitForExistence(timeout: 8))
        let requestsBeforeDismiss = try await downloadRequestCount(user)
        tap("Dismiss")
        XCTAssertTrue(app.staticTexts["Take it with you"].waitForExistence(timeout: 8))
        try await Task.sleep(for: .seconds(2))
        let requestsAfterDismiss = try await downloadRequestCount(user)
        XCTAssertEqual(requestsAfterDismiss, requestsBeforeDismiss, "Dismissing a failed transfer must not also retry its download.")
        XCTAssertFalse(app.buttons["hub-saved-hub-book-1"].exists)
        XCTAssertFalse(app.buttons["hub-transfer-hub-book-1"].exists)
        app.terminate(); _ = try await fixture(3); try await waitForPhase(4)
        app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        media(); tap("hub-Audio"); tap("hub-audio-options-hub-track-1"); tap("Save original for offline")
        XCTAssertTrue(app.staticTexts["hub-save-error-hub-track-1"].waitForExistence(timeout: 8))
        tap("hub-recover-storage-hub-track-1")
        XCTAssertTrue(app.buttons["hub-recover-storage-hub-track-1"].exists)
        _ = try await fixture(5); try await waitForPhase(6)
        tap("hub-recover-storage-hub-track-1"); await disappears(app.buttons["hub-recover-storage-hub-track-1"])
        tap("hub-retry-save-hub-track-1")
        XCTAssertTrue(app.descendants(matching: .any).matching(identifier: "hub-save-status-hub-track-1").firstMatch.waitForExistence(timeout: 15))
        media(); tap("hub-saved"); XCTAssertTrue(app.buttons["hub-saved-hub-track-1"].waitForExistence(timeout: 8))
        tap("hub-saved-options-hub-track-1"); tap("Remove saved file"); tap("hubConfirmRemoveSaved")
        await disappears(app.buttons["hub-saved-hub-track-1"])
        _ = try await fixture(7)
        #endif
    }
}
