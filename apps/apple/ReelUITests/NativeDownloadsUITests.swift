import XCTest

@MainActor final class NativeDownloadsUITests: XCTestCase {
    private var app = XCUIApplication()
    private var user = ""
    private let origin = "http://127.0.0.1:18766"

    private func launch() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Download fault controls use only disposable simulator accounts and loopback media.")
        #else
        continueAfterFailure = false
        user = "native-hls-" + String(UUID().uuidString.prefix(8))
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["-reel-qa-reset"]
        app.launchEnvironment["REEL_QA_SERVER"] = origin
        app.launch()
        signIn(user)
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

    private func tap(_ id: String, down: Bool = false) {
        app.prepareReelPlayerControl(id)
        let button = app.buttons[id].firstMatch
        reveal(button, down: down)
        XCTAssertTrue(button.waitForExistence(timeout: 8), "\(id)\n\(app.debugDescription)")
        XCTAssertTrue(button.isHittable, id)
        button.tap()
    }

    private func replace(_ field: XCUIElement, _ text: String) {
        reveal(field); field.tap()
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

    private func signIn(_ name: String, server: String? = nil) {
        if let server { replace(app.textFields["server"], server) }
        replace(app.textFields["username"], name)
        replace(app.secureTextFields["password"], "demo")
        tap("connect")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15))
        app.dismissReelPasswordPrompt()
    }

    private func wait(_ element: XCUIElement, _ predicate: NSPredicate, timeout: TimeInterval = 10) async {
        await fulfillment(of: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: timeout)
    }

    private func json(_ path: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: origin + path)!)
        request.timeoutInterval = 20
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0))
        return data.isEmpty ? [:] : try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    private func control(_ body: [String: Any]) async throws { _ = try await json("/qa/download-control", body: body) }

    private func start() {
        tap("heroDetails"); tap("downloadMenu")
        XCTAssertTrue(app.buttons["downloadOptimized"].waitForExistence(timeout: 5))
        tap("downloadOptimized"); tap("Downloads")
    }

    private func home() {
        tap("Home")
        if app.staticTexts["detailTitle"].exists { tap("BackButton", down: true) }
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 10))
    }

    private func enableHistoryForOfflineCheck() async {
        tap("ellipsis.circle")
        if !app.navigationBars["More"].waitForExistence(timeout: 2) { tap("ellipsis.circle") }
        XCTAssertTrue(app.navigationBars["More"].waitForExistence(timeout: 8)); tap("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 8))
        let privacy = app.switches["privateViewing"].firstMatch
        reveal(privacy); XCTAssertTrue(privacy.waitForExistence(timeout: 8))
        if privacy.value as? String != "0" {
            let nested = privacy.switches.firstMatch
            if nested.exists { nested.tap() } else { privacy.tap() }
        }
        await wait(privacy, NSPredicate(format: "value == %@", "0"))
        XCTAssertEqual(privacy.value as? String, "0", "Offline history isolation must be checked with reporting enabled")
        home(); tap("Downloads"); saved()
    }

    private func saved() {
        XCTAssertTrue(app.buttons["offline-movie-1"].waitForExistence(timeout: 75), app.debugDescription)
        XCTAssertFalse(app.buttons["retryDownload"].exists)
    }

    private func offlinePlayAndClose() async {
        tap("offline-movie-1")
        app.prepareReelPlayerControl("transportPlayPause")
        let transport = app.reelPlaybackButton("transportPlayPause")
        XCTAssertTrue(transport.waitForExistence(timeout: 15))
        await wait(transport, NSPredicate(format: "enabled == true"), timeout: 25)
        if transport.label == "Pause" { tap("transportPlayPause") }
        XCTAssertEqual(transport.label, "Play")
        tap("closePlayer", down: true)
        XCTAssertTrue(app.buttons["offline-movie-1"].waitForExistence(timeout: 10))
    }

    private func playbackReceipts() async throws -> Int {
        let state = try await json("/qa/state")
        return (state["reports"] as? [[String: Any]] ?? []).filter {
            $0["user"] as? String == user && ($0["path"] as? String ?? "").hasPrefix("/Sessions/Playing")
        }.count
    }

    private func dismissRemovalPreservingDownload() async throws {
        let savedItem = app.buttons["offline-movie-1"].firstMatch
        let savedLabel = savedItem.label
        let beforeReports = try await playbackReceipts()
        var results: [[String: String]] = []

        func confirmation() throws -> XCUIElement {
            tap("removeDownload-movie-1")
            let query = app.buttons.matching(identifier: "confirmRemoveDownload")
            XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 8))
            let candidates = query.allElementsBoundByIndex
            let window = app.windows.firstMatch.frame
            let visible = candidates.filter {
                $0.exists && $0.frame.width > 0 && $0.frame.height > 0 && window.contains($0.frame)
            }
            // Retain the actual AX candidates before the ownership admission
            // assertion. A duplicate count alone cannot establish alias identity.
            func describe(_ value: XCUIElement) -> [String: Any] {
                ["identifier": value.identifier, "label": value.label,
                 "value": String(describing: value.value), "typeRaw": value.elementType.rawValue,
                 "frame": String(describing: value.frame), "exists": value.exists,
                 "hittable": value.isHittable, "enabled": value.isEnabled,
                 "selected": value.isSelected]
            }
            let candidateRecords: [[String: Any]] = candidates.enumerated().map { index, value in
                var record = describe(value); record["index"] = index
                record["childButtons"] = value.children(matching: .button).allElementsBoundByIndex.map(describe)
                return record
            }
            let owners = app.descendants(matching: .any).containing(.button, identifier: "confirmRemoveDownload").allElementsBoundByIndex
            let admission: [String: Any] = ["candidateCount": candidates.count, "visibleCount": visible.count,
                "hittableCount": candidates.filter { $0.exists && $0.isHittable }.count,
                "candidates": candidateRecords, "containingElements": Array(owners.prefix(40)).map(describe),
                "containingElementCount": owners.count,
                "expectedTitleExists": app.staticTexts["Remove this download?"].exists,
                "expectedMessageExists": app.staticTexts["Only the downloaded file is removed. The original stays on Jellyfin."].exists,
                "cancelCandidates": app.buttons.matching(identifier: "cancelRemoveDownload").allElementsBoundByIndex.map(describe),
                "outsideRegions": app.otherElements.matching(identifier: "PopoverDismissRegion").allElementsBoundByIndex.map(describe),
                "window": String(describing: app.windows.firstMatch.frame)]
            let data = try JSONSerialization.data(withJSONObject: admission, options: [.sortedKeys, .prettyPrinted])
            let diagnostic = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            diagnostic.name = "download-confirmation-admission-candidates"; diagnostic.lifetime = .keepAlways; add(diagnostic)
            let hierarchy = XCTAttachment(string: app.debugDescription)
            hierarchy.name = "download-confirmation-admission-hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "download-confirmation-admission-screen"; screenshot.lifetime = .keepAlways; add(screenshot)
            let title = "Remove this download?"
            let message = "Only the downloaded file is removed. The original stays on Jellyfin."
            let presentations = (app.sheets.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex
                + app.alerts.matching(NSPredicate(format: "label == %@", title)).allElementsBoundByIndex).filter {
                    $0.exists && $0.frame.width > 0 && $0.frame.height > 0 && window.contains($0.frame)
                }
            guard presentations.count == 1, let dialog = presentations.first else {
                XCTFail("Exactly one on-screen removal presentation must own the action.")
                throw URLError(.cannotParseResponse)
            }
            XCTAssertTrue(dialog.staticTexts[title].exists)
            XCTAssertTrue(dialog.staticTexts[message].exists)
            // The observed native popover exposes a Button containing another
            // Button with the SAME identifier/label/frame. Select its unique
            // leaf, while rejecting any second action or different hit area.
            let leaves = visible.filter { $0.children(matching: .button).count == 0 }
            guard leaves.count == 1, let leaf = leaves.first else {
                XCTFail("Only one leaf removal action may be dismissed.")
                throw URLError(.cannotParseResponse)
            }
            let actionFrame = leaf.frame
            func sameAction(_ value: XCUIElement) -> Bool {
                value.elementType == .button && value.identifier == "confirmRemoveDownload"
                    && value.label == "Remove download" && value.frame == actionFrame
            }
            let wrappers = visible.filter { $0.children(matching: .button).count > 0 }
            guard wrappers.count <= 1 else {
                XCTFail("The observed action may have at most one identical button wrapper.")
                throw URLError(.cannotParseResponse)
            }
            for wrapper in wrappers {
                let children = wrapper.children(matching: .button).allElementsBoundByIndex
                guard children.count == 1, children.allSatisfy(sameAction) else {
                    XCTFail("Only the observed identical nested button alias is permitted.")
                    throw URLError(.cannotParseResponse)
                }
            }
            // This helper identifies the destructive action's exclusion rect;
            // it dismisses through Cancel or an outside tap, never this action.
            // The recorded AX aliases can report false hittability after queries.
            // Keep that diagnostic separate from ownership and geometry gates.
            let confirm = wrappers.count == 1 ? wrappers[0] : leaf
            let scoped = dialog.buttons.matching(identifier: "confirmRemoveDownload").allElementsBoundByIndex
            let gates: [String: Bool] = [
                "targetExists": confirm.exists, "targetEnabled": confirm.isEnabled,
                "targetHasPositiveFrame": confirm.frame.width > 0 && confirm.frame.height > 0,
                "targetInsideWindow": window.contains(confirm.frame),
                "targetInsideDialog": dialog.frame.contains(confirm.frame),
                "allVisibleAliasesOwned": visible.allSatisfy({ sameAction($0) && $0.isEnabled && dialog.frame.contains($0.frame) }),
                "actionIsDialogDescendant": scoped.contains(where: sameAction)
            ]
            let gateData: [String: Any] = ["gates": gates, "targetHittableInformational": confirm.isHittable,
                "target": describe(confirm), "semanticLeaf": describe(leaf),
                "wrapperCount": wrappers.count, "leafCount": leaves.count, "actionFrame": String(describing: actionFrame),
                "dialogFrame": String(describing: dialog.frame), "windowFrame": String(describing: window),
                "scopedCandidates": scoped.map(describe)]
            let gateAttachment = XCTAttachment(data: try JSONSerialization.data(withJSONObject: gateData, options: [.sortedKeys, .prettyPrinted]), uniformTypeIdentifier: "public.json")
            gateAttachment.name = "download-confirmation-owned-action-gates"; gateAttachment.lifetime = .keepAlways; add(gateAttachment)
            guard gates.values.allSatisfy({ $0 }) else {
                XCTFail("Every confirmation ownership, enabled-state and exclusion-geometry gate must pass.")
                throw URLError(.cannotParseResponse)
            }
            let selection = XCTAttachment(string: "rawVisibleMatches=\(visible.count);uniqueLeaves=\(leaves.count);nativeWrappers=\(wrappers.count);actionFrame=\(confirm.frame);ownedDialog=\(dialog.frame);title=\(title)")
            selection.name = "download-confirmation-owned-leaf"; selection.lifetime = .keepAlways; add(selection)
            return confirm
        }
        func attach(_ phase: String, mode: String) throws {
            let receipt: [String: Any] = ["phase": phase, "actualMode": mode, "controls": results,
                "confirmVisible": app.buttons["confirmRemoveDownload"].exists,
                "cancelVisible": app.buttons["cancelRemoveDownload"].exists,
                "popoverDismissRegionVisible": app.otherElements["PopoverDismissRegion"].exists,
                "savedItemVisible": savedItem.exists, "window": String(describing: app.windows.firstMatch.frame)]
            let data = try JSONSerialization.data(withJSONObject: receipt, options: [.sortedKeys])
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            attachment.name = "download-cancel-" + phase; attachment.lifetime = .keepAlways; add(attachment)
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "download-cancel-" + phase; screenshot.lifetime = .keepAlways; add(screenshot)
        }
        func preserved(_ confirm: XCUIElement) async throws {
            await wait(confirm, NSPredicate(format: "exists == false"))
            XCTAssertFalse(confirm.exists)
            XCTAssertFalse(app.buttons["cancelRemoveDownload"].exists)
            XCTAssertFalse(app.otherElements["PopoverDismissRegion"].exists)
            XCTAssertTrue(savedItem.exists); XCTAssertTrue(savedItem.isHittable)
            XCTAssertEqual(savedItem.label, savedLabel)
            XCTAssertFalse(app.staticTexts["downloadsEmpty"].exists)
            XCTAssertFalse(app.staticTexts["downloadRemovalError"].exists)
            await offlinePlayAndClose()
            XCTAssertEqual(savedItem.label, savedLabel)
            let afterReports = try await playbackReceipts()
            XCTAssertEqual(afterReports, beforeReports, "Dismissing removal must preserve the same offline file and its history isolation.")
        }

        var confirm = try confirmation()
        let cancel = app.buttons["cancelRemoveDownload"].firstMatch
        let region = app.otherElements["PopoverDismissRegion"].firstMatch
        // Classify the observed native presentation, not the model name or window width.
        for _ in 0..<30 {
            if cancel.exists || region.exists { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let hasCancel = cancel.exists, hasPopover = region.exists
        guard hasCancel || hasPopover else {
            try attach("missing-dismiss-control", mode: "unrecognized")
            XCTFail("The owned removal confirmation exposes neither Cancel nor a popover outside-dismiss region; compact Cancel coverage cannot be skipped.")
            throw URLError(.cannotParseResponse)
        }
        if hasCancel {
            XCTAssertTrue(cancel.isHittable)
            try attach("before-explicit-cancel", mode: "explicitCancel")
            cancel.tap(); try await preserved(confirm)
            results.append(["control": "explicitCancel", "result": "passed", "reason": "The native confirmation exposed Cancel; it was activated and the same file played offline afterward."])
            if hasPopover { confirm = try confirmation() }
            else { results.append(["control": "popoverOutsideDismiss", "result": "inapplicable", "reason": "This native confirmation exposes explicit Cancel and no PopoverDismissRegion; outside-popover dismissal is not offered in this presentation."]) }
        } else {
            results.append(["control": "explicitCancel", "result": "inapplicable", "reason": "The observed native popover exposes PopoverDismissRegion and omits the standard Cancel action, as regular-size iOS confirmation popovers do."])
        }
        if hasPopover {
            XCTAssertTrue(region.waitForExistence(timeout: 3)); XCTAssertTrue(region.isHittable)
            let bar = app.navigationBars["Downloads"].firstMatch
            XCTAssertTrue(bar.exists)
            let outside = bar.coordinate(withNormalizedOffset: CGVector(dx: 0.12, dy: 0.5))
            XCTAssertFalse(confirm.frame.contains(outside.screenPoint), "Outside dismissal must not activate destructive removal.")
            if cancel.exists { XCTAssertFalse(cancel.frame.contains(outside.screenPoint), "Outside dismissal must not activate Cancel instead.") }
            try attach("before-outside-dismiss", mode: "popoverOutsideDismiss")
            outside.tap(); try await preserved(confirm)
            results.append(["control": "popoverOutsideDismiss", "result": "passed", "reason": "The owned native popover was dismissed by an outside tap; the same file played offline afterward."])
        }
        try attach("after-preservation", mode: hasCancel ? (hasPopover ? "bothNativeControls" : "explicitCancel") : "popoverOutsideDismiss")
    }

    private func remove() async {
        tap("removeDownload-movie-1"); tap("confirmRemoveDownload")
        await wait(app.buttons["offline-movie-1"], NSPredicate(format: "exists == false"))
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].exists)
    }

    func testOptimizedPackageRelaunchSwitchRemoveAndOfflineHistoryIsolation() async throws {
        try launch(); start(); saved()
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15)); tap("Downloads"); saved()
        await enableHistoryForOfflineCheck()
        let before = try await playbackReceipts()
        await offlinePlayAndClose()
        let after = try await playbackReceipts(); XCTAssertEqual(after, before)
        home(); tap("servers"); tap("addServer")
        let second = "hls-other-" + String(UUID().uuidString.prefix(8))
        signIn(second, server: "http://127.0.0.1:18767"); tap("Downloads")
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 8)); XCTAssertFalse(app.buttons["offline-movie-1"].exists)
        home(); tap("servers"); tap("server-" + user); tap("Downloads"); saved()
        try await dismissRemovalPreservingDownload()
        await remove()
        app.terminate(); app.launchArguments = []; app.launch(); tap("Downloads")
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 8))
    }

    func testOptimizedPermissionDenialAndNativeRetryRecovery() async throws {
        try launch(); try await control(["downloadAllowed": false]); start()
        XCTAssertTrue(app.buttons["retryDownload"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Your Jellyfin account doesn’t allow downloads. Ask your server administrator to enable downloading."].exists)
        XCTAssertFalse(app.buttons["offline-movie-1"].exists)
        try await control(["downloadAllowed": true]); tap("retryDownload"); saved()
        await offlinePlayAndClose(); await remove()
    }

    func testOptimizedManifestFailureAndNativeRetryRecovery() async throws {
        try await failureRecovery(stage: "manifest")
    }

    func testOptimizedSegmentFailureAndNativeRetryRecovery() async throws {
        try await failureRecovery(stage: "segment")
    }

    private func failureRecovery(stage: String) async throws {
        try launch(); try await control(["failHLS": 100, "failureStage": stage]); start()
        XCTAssertTrue(app.buttons["retryDownload"].waitForExistence(timeout: 100), app.debugDescription)
        XCTAssertFalse(app.buttons["offline-movie-1"].exists)
        let failed = try await json("/qa/download-state")
        XCTAssertTrue((failed["requests"] as? [[String: Any]] ?? []).contains { $0["stage"] as? String == stage && $0["failed"] as? Bool == true })
        try await control(["failHLS": 0]); tap("retryDownload"); saved()
        await offlinePlayAndClose(); await remove()
    }

    func testOptimizedDelayedCancelDoesNotImportLatePackageAfterRelaunch() async throws {
        try launch(); try await control(["hlsDelayMs": 10000]); start()
        XCTAssertTrue(app.buttons["cancelDownload"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Downloading…"].exists)
        tap("cancelDownload")
        await wait(app.buttons["cancelDownload"], NSPredicate(format: "exists == false"), timeout: 20)
        try await control(["hlsDelayMs": 0])
        try await Task.sleep(for: .seconds(11))
        XCTAssertFalse(app.buttons["offline-movie-1"].exists)
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].exists)
        app.terminate(); app.launchArguments = []; app.launch(); tap("Downloads")
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["offline-movie-1"].exists)
    }

    func testRemovingAccountCancelsItsOptimizedTransferAndCleansUp() async throws {
        try launch()
        let second = "hls-retained-" + String(UUID().uuidString.prefix(8))
        tap("servers"); tap("addServer"); signIn(second, server: "http://127.0.0.1:18767")
        tap("servers"); tap("server-" + user)
        try await control(["hlsDelayMs": 10000]); start()
        XCTAssertTrue(app.buttons["cancelDownload"].waitForExistence(timeout: 8))
        home(); tap("servers"); tap("serverOptions-" + user); tap("Remove from device"); tap("confirmRemoveServer")
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 25))
        XCTAssertTrue((app.buttons["servers"].value as? String ?? "").contains("Reel Second Server"))
        tap("Downloads")
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 10))
        try await control(["hlsDelayMs": 0]); try await Task.sleep(for: .seconds(11))
        app.terminate(); app.launchArguments = []; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 15)); tap("servers")
        XCTAssertTrue(app.buttons["server-" + second].waitForExistence(timeout: 8))
        XCTAssertFalse(app.buttons["server-" + user].exists)
        XCTAssertEqual(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'server-' ")).count, 1)
        tap("Done", down: true); tap("Downloads")
        XCTAssertTrue(app.staticTexts["downloadsEmpty"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["offline-movie-1"].exists)
        let state = try await json("/qa/state")
        XCTAssertTrue((state["reports"] as? [[String: Any]] ?? []).contains {
            $0["user"] as? String == user && $0["path"] as? String == "/Videos/ActiveEncodings"
        }, "Removed account must release its synthetic transcoding session.")
    }
}
