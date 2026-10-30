import XCTest

private enum TVWatchedJourneyError: Error { case unsafeEnvironment, missingControl, wrongEffect }

@MainActor final class TVWatchedJourneys: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:18970")!

    func testAggregateCountsZeroUnknownMalformedLargeGridListAndHomeAreServerTruth() async throws {
        let user = unique("counts"), app = try await launch(user)
        try search("Meadow Story 15", app: app)
        let card = app.buttons["item-library-title-003"]
        try await value(card, contains: "2 unwatched")
        try menu("libraryViewStyle", choose: "List", app: app)
        try await value(card, contains: "2 unwatched")
        for mode in ["zero", "missing", "negative", "invalid", "overflow", "large"] {
            try await control(user, ["countMode": mode]); try select(app.buttons["libraryRefresh"], app: app)
            try await value(card, contains: mode == "zero" ? "0 unwatched" : mode == "large" ? "123456789 unwatched" : "Unwatched count unavailable")
            XCTAssertFalse((card.value as? String ?? "").contains("All watched"))
        }
        try openTab("Home", app: app)
        let homeCount = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-library-title-' AND value CONTAINS '123456789 unwatched'")).firstMatch
        try await reveal(homeCount, app: app)
        capture("Exact server count and unknown presentation at native TV scale", app)
        try await assertNoWrites(user)
    }

    func testEpisodeOnlyHeroUsesPlayAndRetainsIndividualEpisodeIdentity() async throws {
        let user = unique("hero"), app = try await launch(user, modes: ["episodeOnly": true])
        XCTAssertTrue(app.buttons["heroPlay"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.buttons["heroPlay"].label, "Play")
        XCTAssertTrue(app.buttons["item-library-episode-05"].exists)
        capture("Episode-only hero has a truthful Play action", app)
        try await assertNoWrites(user)
    }

    func testSeriesAndSeasonConfirmationCancelBackZeroWritesThenExactServerScope() async throws {
        let user = unique("series"), app = try await launch(user)
        try search("Meadow Story 15", app: app); try select(app.buttons["item-library-title-003"], app: app)
        try await value(app.staticTexts["unwatchedCount-library-title-003"], contains: "Server supplied")
        try watchMenu("detailWatchStatus", played: true, app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'outside the current filters'")).firstMatch.exists)
        try select(app.buttons["cancelWatchedChanges"], app: app)
        try await assertNoWrites(user)
        try watchMenu("seasonWatchStatus", played: true, app: app); XCUIRemote.shared.press(.menu)
        XCTAssertFalse(app.buttons["confirmWatchedChanges"].exists); try await assertNoWrites(user)
        try watchMenu("seasonWatchStatus", played: true, app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 requests accepted")
        let first = try await waitForRequests(user, count: 1)
        XCTAssertEqual(first.map { $0["path"] as? String }, ["/UserPlayedItems/library-season-003-1"])
        XCTAssertEqual(first[0]["descendants"] as? [String], ["library-episode-01", "library-episode-02"])
        try await label(app.staticTexts["unwatchedCount-library-title-003"], equals: "1 unwatched")
        try plainMenu("season", choose: "Season 2", app: app)
        try watchMenu("detailWatchStatus", played: false, app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        _ = try await waitForRequests(user, count: 2)
        try await label(app.staticTexts["unwatchedCount-library-title-003"], equals: "4 unwatched")
        XCTAssertEqual(app.segmentedControls["season"].value as? String, "Season 2")
        capture("Actual Series and selected Season changes refresh authoritative counts", app)
    }

    func testLeafWatchedRefreshKeepsChosenVersionAudioAndSubtitle() async throws {
        let user = unique("choices"), app = try await launch(user)
        try search("Harbor Story 26", app: app); try select(app.buttons["item-library-title-002"], app: app)
        try plainMenu("sourceOptions", choose: "Owned alternate", app: app)
        try plainMenu("audioOptions", choose: "Spanish owned AAC", app: app)
        try plainMenu("subtitleOptions", choose: "English owned VTT", app: app)
        let labels = ["sourceOptions", "audioOptions", "subtitleOptions"].map { app.buttons[$0].label }
        try watchMenu("detailWatchStatus", played: false, app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 requests accepted")
        _ = try await waitForRequests(user, count: 1)
        for (index,id) in ["sourceOptions", "audioOptions", "subtitleOptions"].enumerated() { XCTAssertEqual(app.buttons[id].label, labels[index]) }
        capture("Watched refresh preserves version, audio and captions", app)
    }

    func testSelectionToggleClearDoneBackAndBulkCancelSendZeroWrites() async throws {
        let user = unique("cancel"), app = try await launch(user)
        try await episodes(app)
        try select(app.buttons["beginTitleSelection"], app: app)
        try select(app.buttons["item-library-episode-01"], app: app)
        try await label(app.staticTexts["selectedTitleCount"], equals: "1 titles selected")
        XCTAssertFalse(app.staticTexts["detailTitle"].exists)
        try select(app.buttons["item-library-episode-03"], app: app)
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["cancelWatchedChanges"], app: app)
        try await label(app.staticTexts["selectedTitleCount"], equals: "2 titles selected")
        try select(app.buttons["bulkMarkUnwatched"], app: app)
        XCTAssertTrue(app.buttons["confirmWatchedChanges"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["confirmWatchedChanges"].waitForNonExistence(timeout: 10))
        try select(app.buttons["clearTitleSelection"], app: app); try await label(app.staticTexts["selectedTitleCount"], equals: "0 titles selected")
        try select(app.buttons["selectLoadedTitles"], app: app); try await label(app.staticTexts["selectedTitleCount"], equals: "12 titles selected")
        try select(app.buttons["finishTitleSelection"], app: app)
        try select(app.buttons["beginTitleSelection"], app: app); XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["beginTitleSelection"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["finishTitleSelection"].exists)
        try select(app.buttons["item-library-episode-01"], app: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        try await assertNoWrites(user)
        capture("Actual selection, confirmation Cancel and Back leave history unchanged", app)
    }

    func testBulkPartialPermissionFailureRetriesOnlyFailedAndUnsentIDs() async throws {
        let user = unique("partial"), app = try await launch(user)
        try await control(user, ["failID": "library-episode-03", "failure": "before403", "failures": 1])
        try await selectEpisodes(["01", "03", "05"], app: app)
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 failed")
        XCTAssertTrue(app.staticTexts["watchedSummary"].label.contains("1 not started"))
        XCTAssertTrue(app.staticTexts["watchedResult-library-episode-03"].label.contains("permissions"))
        let first = try await waitForRequests(user, count: 2)
        XCTAssertEqual(first.map { $0["path"] as? String }, ["/UserPlayedItems/library-episode-01", "/UserPlayedItems/library-episode-03"])
        try await control(user, ["failure": "none"])
        try select(app.buttons["retryWatchedChanges"], app: app); try await summary(app, contains: "3 requests accepted")
        let final = try await waitForRequests(user, count: 4)
        XCTAssertEqual(final.map { $0["path"] as? String }, ["/UserPlayedItems/library-episode-01", "/UserPlayedItems/library-episode-03", "/UserPlayedItems/library-episode-03", "/UserPlayedItems/library-episode-05"])
        try select(app.buttons["dismissWatchedResult"], app: app)
        XCTAssertTrue(app.buttons["finishTitleSelection"].isHittable)
        capture("Permission partial success and actual failed-only retry", app)
    }

    func testAcceptedButFailedOrMalformedResponseReadsBackWithoutDuplicateWrite() async throws {
        for mode in ["after503", "afterMalformed"] {
            let user = unique(mode), app = try await launch(user)
            try await control(user, ["failID": "library-episode-01", "failure": mode, "failures": 1])
            try await selectEpisodes(["01"], app: app)
            try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
            try await summary(app, contains: "1 states confirmed")
            XCTAssertFalse(app.buttons["retryWatchedChanges"].exists)
            let receipts = try await waitForRequests(user, count: 1)
            XCTAssertEqual(receipts.count, 1); XCTAssertEqual(receipts[0]["committed"] as? Bool, true)
            capture("Server state readback after " + mode, app)
            app.terminate()
        }
    }

    func testRepeatedFailureKeepsExplicitDesiredValueAndSuccessfulIDsUntouched() async throws {
        let user = unique("repeat"), app = try await launch(user)
        try await control(user, ["failID": "library-episode-02", "failure": "before503", "failures": 2])
        try await selectEpisodes(["02", "04"], app: app)
        try select(app.buttons["bulkMarkUnwatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 failed"); try select(app.buttons["retryWatchedChanges"], app: app)
        _ = try await waitForRequests(user, count: 3); try await summary(app, contains: "1 failed")
        try select(app.buttons["retryWatchedChanges"], app: app); try await summary(app, contains: "2 requests accepted")
        let receipts = try await waitForRequests(user, count: 4)
        XCTAssertTrue(receipts.allSatisfy { $0["method"] as? String == "DELETE" })
        XCTAssertEqual(receipts.filter { $0["path"] as? String == "/UserPlayedItems/library-episode-04" }.count, 1)
        capture("Repeated failure preserves explicit unwatched intent", app)
    }

    func testStopRemainingHeldRequestReportsPossibleCommitAndDoesNotSendNext() async throws {
        let user = unique("stop"), app = try await launch(user)
        try await control(user, ["holdID": "library-episode-01"])
        try await selectEpisodes(["01", "03"], app: app)
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        _ = try await waitForRequests(user, count: 1)
        try select(app.buttons["cancelWatchedRemaining"], app: app)
        try await control(user, ["releaseWrites": true]); try await waitForCommit(user)
        try await summary(app, contains: "1 unconfirmed")
        try select(app.buttons["checkWatchedStatus"], app: app); try await summary(app, contains: "1 states confirmed")
        let finalRequests = try await requests(user); XCTAssertEqual(finalRequests.count, 1)
        capture("Stop remaining acknowledges an issued request may commit", app)
    }

    func testPrivateViewingShowsDisabledBulkAndDetailControlsWithZeroMutations() async throws {
        let user = unique("private"), app = try await launch(user, privateViewing: true)
        try await selectEpisodes(["01"], app: app)
        XCTAssertFalse(app.buttons["bulkMarkWatched"].isEnabled); XCTAssertFalse(app.buttons["bulkMarkUnwatched"].isEnabled)
        XCTAssertTrue(app.staticTexts["bulkWatchRefusal"].label.contains("Private viewing"))
        try select(app.buttons["finishTitleSelection"], app: app)
        try select(app.buttons["item-library-episode-01"], app: app)
        XCTAssertFalse(app.buttons["detailWatchStatus"].isEnabled)
        XCTAssertTrue(app.staticTexts["detailWatchStatusRefusal"].label.contains("Private viewing"))
        try await assertNoWrites(user)
        capture("Private viewing blocks actual watched controls", app)
    }

    func testLoadedSelectionPaginationViewStyleAndQueryChangeHaveBoundedScope() async throws {
        let user = unique("paging"), app = try await launch(user)
        try openTab("Library", app: app); try select(app.buttons["filter-Movies"], app: app)
        try await label(app.staticTexts["libraryCount"], equals: "60 of 96 titles")
        try select(app.buttons["beginTitleSelection"], app: app); try select(app.buttons["selectLoadedTitles"], app: app)
        try await label(app.staticTexts["selectedTitleCount"], equals: "60 titles selected")
        try select(app.buttons["loadMore"], app: app); try await label(app.staticTexts["libraryCount"], equals: "96 of 96 titles")
        try await label(app.staticTexts["selectedTitleCount"], equals: "60 titles selected")
        try menu("libraryViewStyle", choose: "List", app: app); try await label(app.staticTexts["selectedTitleCount"], equals: "60 titles selected")
        try select(app.buttons["filter-Episodes"], app: app)
        XCTAssertTrue(app.buttons["beginTitleSelection"].waitForExistence(timeout: 15)); XCTAssertFalse(app.buttons["selectedTitleCount"].exists)
        try await assertNoWrites(user)
        capture("Loaded selection remains bounded through paging and view change", app)
    }

    func testPlaylistDuplicateRowsShareSelectionAndBulkSendsUniqueMediaIDs() async throws {
        let user = unique("playlist"), app = try await launch(user)
        try openTab("Library", app: app); try select(app.buttons["filter-Playlists"], app: app)
        try select(app.buttons["item-library-playlist-1"], app: app)
        XCTAssertTrue(app.buttons["parentWatchStatus"].waitForExistence(timeout: 15))
        try select(app.buttons["beginTitleSelection"], app: app); try select(app.buttons["item-library-entry-001"], app: app)
        try await value(app.buttons["item-library-entry-003"], contains: "Selected")
        try select(app.buttons["selectLoadedTitles"], app: app); try await label(app.staticTexts["selectedTitleCount"], equals: "6 titles selected")
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "6 requests accepted")
        let receipts = try await waitForRequests(user, count: 6)
        XCTAssertEqual(Set(receipts.compactMap { $0["path"] as? String }).count, 6)
        capture("Repeated playlist entries mutate each underlying title once", app)
    }

    func testContainerParentConfirmationAndAuthoritativeCountRefresh() async throws {
        let user = unique("collection"), app = try await launch(user)
        try openTab("Library", app: app); try select(app.buttons["filter-Collections"], app: app)
        try select(app.buttons["item-library-collection-1"], app: app)
        try watchMenu("parentWatchStatus", played: true, app: app); try select(app.buttons["cancelWatchedChanges"], app: app)
        try await assertNoWrites(user)
        try watchMenu("parentWatchStatus", played: true, app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 requests accepted")
        let rows = try await waitForRequests(user, count: 1)
        let receipt = try XCTUnwrap(rows.first)
        XCTAssertEqual(receipt["path"] as? String, "/UserPlayedItems/library-collection-1")
        XCTAssertEqual(receipt["descendants"] as? [String], ["library-title-002", "library-title-004", "library-title-023", "library-title-071", "library-title-139"])
        try await label(app.staticTexts["unwatchedCount-library-collection-1"], equals: "0 unwatched")
        capture("Parent container confirms server scope and refreshes count", app)
    }

    func testUnconfirmedEffectRequiresActualReadRecoveryAndNeverBlindRetry() async throws {
        let user = unique("uncertain"), app = try await launch(user)
        try await selectEpisodes(["01"], app: app)
        try await control(user, ["failID": "library-episode-01", "failure": "after503", "failures": 1, "denyReads": true])
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 unconfirmed")
        XCTAssertFalse(app.buttons["retryWatchedChanges"].exists)
        try select(app.buttons["checkWatchedStatus"], app: app); try await summary(app, contains: "1 unconfirmed")
        try await control(user, ["denyReads": false])
        try select(app.buttons["checkWatchedStatus"], app: app); try await summary(app, contains: "1 states confirmed")
        let receipts = try await requests(user); XCTAssertEqual(receipts.count, 1)
        XCTAssertFalse(app.buttons["retryWatchedChanges"].exists)
        capture("Unconfirmed write requires explicit authoritative read recovery", app)
    }

    func testWatchFilterDisappearanceReconcilesSelectionAndLeavesRealControlsReachable() async throws {
        let user = unique("disappear"), app = try await launch(user)
        try await episodes(app)
        try menu("watchPicker", choose: "Unwatched", app: app)
        try await label(app.staticTexts["libraryCount"], equals: "6 of 6 titles")
        try select(app.buttons["beginTitleSelection"], app: app); try select(app.buttons["item-library-episode-01"], app: app)
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 requests accepted"); try await label(app.staticTexts["libraryCount"], equals: "5 of 5 titles")
        try await label(app.staticTexts["selectedTitleCount"], equals: "0 titles selected")
        XCTAssertFalse(app.buttons["item-library-episode-01"].exists)
        try select(app.buttons["dismissWatchedResult"], app: app); try select(app.buttons["finishTitleSelection"], app: app)
        try select(app.buttons["libraryRefresh"], app: app)
        try await label(app.staticTexts["libraryCount"], equals: "5 of 5 titles")
        let receipts = try await requests(user); XCTAssertEqual(receipts.count, 1)
        capture("Filtered disappearance reconciles selection with reachable focus", app)
    }

    func testColdRelaunchRestoresPreferencesAndServerStateWithoutSelectionOrAutomaticRetry() async throws {
        let user = unique("cold"), app = try await launch(user)
        try await episodes(app); try menu("libraryViewStyle", choose: "List", app: app)
        try await control(user, ["failID": "library-episode-03", "failure": "before403", "failures": 1])
        try select(app.buttons["beginTitleSelection"], app: app)
        for number in ["01", "03"] {
            let item = app.buttons["item-library-episode-" + number]
            try await reveal(item, app: app)
            try select(item, app: app)
        }
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 failed")
        app.terminate(); app.launchArguments = ["-privateViewing", "NO"]; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20)); try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        XCTAssertFalse(app.buttons["finishTitleSelection"].exists); XCTAssertFalse(app.otherElements["watchedResults"].exists)
        try select(app.buttons["libraryRefresh"], app: app); try await label(app.staticTexts["libraryCount"], equals: "12 of 12 titles")
        let receipts = try await requests(user); XCTAssertEqual(receipts.count, 2)
        capture("Cold process retains server data and choices without replaying a failed change", app)
    }

    func testSwitchAccountDuringHeldWriteStopsUnsentAndDoesNotLeakOldSelection() async throws {
        let user = unique("old-account"), next = unique("new-account"), app = try await launch(user)
        try await control(user, ["holdID": "library-episode-01"])
        try await selectEpisodes(["01", "03"], app: app)
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        _ = try await waitForRequests(user, count: 1)
        try openTab("Settings", app: app); try select(app.buttons["addServer"], app: app)
        try enter(base.absoluteString, into: app.textFields["server"], app: app)
        try enter(next, into: app.textFields["username"], app: app); try enter("demo", into: app.secureTextFields["password"], app: app)
        try select(app.buttons["connect"], app: app); XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try await control(user, ["releaseWrites": true]); try await waitForCommit(user)
        try await episodes(app)
        XCTAssertFalse(app.buttons["finishTitleSelection"].exists); XCTAssertFalse(app.otherElements["watchedResults"].exists)
        let old = try await requests(user), new = try await requests(next)
        XCTAssertEqual(old.count, 1); XCTAssertTrue(new.isEmpty)
        capture("Account switch stops unsent old work and clears its UI state", app)
    }

    func testPrivateViewingChangeStopsUnsentWorkAndDisablesReturningSelection() async throws {
        let user = unique("privacy-change"), app = try await launch(user)
        try await control(user, ["holdID": "library-episode-01"])
        try await selectEpisodes(["01", "03"], app: app)
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        _ = try await waitForRequests(user, count: 1)
        try openTab("Settings", app: app)
        try select(app.descendants(matching: .any).matching(identifier: "privateViewing").firstMatch, app: app)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Watch progress stays off'")).firstMatch.exists)
        try await control(user, ["releaseWrites": true]); try await waitForCommit(user)
        try await episodes(app)
        if !app.buttons["finishTitleSelection"].exists { try select(app.buttons["beginTitleSelection"], app: app) }
        try select(app.buttons["item-library-episode-03"], app: app)
        XCTAssertFalse(app.buttons["bulkMarkWatched"].isEnabled)
        XCTAssertTrue(app.staticTexts["bulkWatchRefusal"].label.contains("Private viewing"))
        let receipts = try await requests(user); XCTAssertEqual(receipts.count, 1)
        capture("Private viewing stops unsent mutations without claiming issued work was undone", app)
    }

    func testUnknownPlayedMetadataRefusesChangesAndKnownAdditionalContainersAlwaysConfirm() async throws {
        for kind in ["missing", "PluginFolder", "MusicAlbum", "MusicArtist", "PhotoAlbum"] {
            let user = unique("kind-" + kind), app = try await launch(user, modes: ["detailID": "library-episode-02", "detailType": kind])
            try await episodes(app); try select(app.buttons["item-library-episode-02"], app: app)
            XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
            if kind == "missing" || kind == "PluginFolder" {
                XCTAssertFalse(app.buttons["detailWatchStatus"].isEnabled)
                XCTAssertTrue(app.staticTexts["detailWatchStatusTypeRefusal"].exists)
            } else {
                try watchMenu("detailWatchStatus", played: true, app: app)
                XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'container'")).firstMatch.exists)
                try select(app.buttons["cancelWatchedChanges"], app: app)
            }
            try await assertNoWrites(user); capture("Watched classification for " + kind, app); app.terminate()
        }
    }

    func testSeriesReadFailureKeepsSeasonAndStaleCountUntilActualUserDataRetry() async throws {
        let user = unique("detail-read"), app = try await launch(user)
        try search("Meadow Story 15", app: app); try select(app.buttons["item-library-title-003"], app: app)
        try plainMenu("season", choose: "Season 2", app: app)
        let count = app.staticTexts["unwatchedCount-library-title-003"]
        try await label(count, equals: "2 unwatched")
        try await control(user, ["denyReads": true])
        try watchMenu("detailWatchStatus", played: true, app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        XCTAssertTrue(app.staticTexts["watchedDataError"].waitForExistence(timeout: 20))
        XCTAssertEqual(count.label, "2 unwatched"); try await value(count, contains: "out of date")
        XCTAssertEqual(app.segmentedControls["season"].value as? String, "Season 2")
        capture("Read failure keeps truthful stale count and current Season", app)
        try await control(user, ["denyReads": false]); try select(app.buttons["retryWatchedData"], app: app)
        try await label(count, equals: "0 unwatched"); try await value(count, contains: "Server supplied")
        XCTAssertEqual(app.segmentedControls["season"].value as? String, "Season 2")
        let receipts = try await requests(user); XCTAssertEqual(receipts.count, 1)
        capture("Actual UserData Retry refreshes count without resetting Season", app)
    }

    func testParentReadFailureRetainsMutationResultAndRecoversThroughContainerRetry() async throws {
        let user = unique("parent-read"), app = try await launch(user)
        try openTab("Library", app: app); try select(app.buttons["filter-Collections"], app: app)
        try select(app.buttons["item-library-collection-1"], app: app)
        let count = app.staticTexts["unwatchedCount-library-collection-1"]
        XCTAssertTrue(count.waitForExistence(timeout: 15)); let before = count.label
        try await control(user, ["denyReads": true])
        try watchMenu("parentWatchStatus", played: true, app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        try await summary(app, contains: "1 requests accepted")
        XCTAssertTrue(app.staticTexts["parentStatusError"].waitForExistence(timeout: 20))
        XCTAssertEqual(count.label, before); try await value(count, contains: "out of date")
        capture("Container read failure retains result and truthful stale count", app)
        try await control(user, ["denyReads": false]); try select(app.buttons["retryParentStatus"], app: app)
        try await label(count, equals: "0 unwatched"); try await summary(app, contains: "1 requests accepted")
        try select(app.buttons.matching(NSPredicate(format: "(identifier == %@ OR identifier == %@) AND label == %@", "dismissWatchedResult", "watchedResults", "Dismiss result")).firstMatch, app: app)
        try select(app.buttons["libraryRefresh"], app: app)
        let receipts = try await requests(user); XCTAssertEqual(receipts.count, 1)
        capture("Container Retry restores current counts with a reachable result dismissal", app)
    }

    func testBackDuringHeldSubmissionStopsRemainingAndKeepsUncertainResultReachable() async throws {
        let user = unique("back-busy"), app = try await launch(user)
        try await control(user, ["holdID": "library-episode-01"])
        try await selectEpisodes(["01", "03"], app: app)
        try select(app.buttons["bulkMarkWatched"], app: app); try select(app.buttons["confirmWatchedChanges"], app: app)
        _ = try await waitForRequests(user, count: 1)
        XCUIRemote.shared.press(.menu)
        try await control(user, ["releaseWrites": true]); try await waitForCommit(user)
        try await summary(app, contains: "1 unconfirmed")
        XCTAssertTrue(app.buttons["beginTitleSelection"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.buttons["finishTitleSelection"].exists)
        try select(app.buttons["checkWatchedStatus"], app: app); try await summary(app, contains: "1 states confirmed")
        let receipts = try await requests(user); XCTAssertEqual(receipts.count, 1)
        capture("Actual Back stops unsent work while retaining the issued outcome", app)
    }

    private func assertNoWrites(_ user: String) async throws { let rows = try await requests(user); XCTAssertTrue(rows.isEmpty) }
    private func unique(_ suffix: String) -> String { "library-tv-watched-" + suffix + "-" + String(UUID().uuidString.prefix(8)).lowercased() }
    private func owner() async throws -> String {
        guard ProcessInfo.processInfo.environment["REEL_TV_PARITY_MUTABLE"] == "1",
              ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV",
              let device = ProcessInfo.processInfo.environment["REEL_TV_PARITY_DEVICE_UDID"], ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == device,
              let owner = ProcessInfo.processInfo.environment["REEL_TV_PARITY_OWNER"], owner.count >= 24 else { throw TVWatchedJourneyError.unsafeEnvironment }
        var request = URLRequest(url: base.appendingPathComponent("qa/parity-identity")); request.setValue(owner, forHTTPHeaderField: "X-Reel-Parity-Owner")
        let (data,response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let value = try JSONSerialization.jsonObject(with: data) as? [String:Any], value["owner"] as? String == owner,
              value["kind"] as? String == "reel-tv-library-parity", value["port"] as? Int == 18970 else { throw TVWatchedJourneyError.unsafeEnvironment }
        return owner
    }
    private func fixture(_ user: String, path: String, body: [String:Any]? = nil) async throws -> [String:Any] {
        var request = URLRequest(url: base.appendingPathComponent(path)); request.setValue(try await owner(), forHTTPHeaderField: "X-Reel-Parity-Owner")
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        if let body { request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body); request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data,response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let value = try JSONSerialization.jsonObject(with: data) as? [String:Any] else { throw TVWatchedJourneyError.wrongEffect }
        return value
    }
    private func control(_ user: String, _ body: [String:Any]) async throws { _ = try await fixture(user, path: "qa/watched-control", body: body) }
    private func requests(_ user: String) async throws -> [[String:Any]] { try await fixture(user,path:"qa/watched-state")["requests"] as? [[String:Any]] ?? [] }
    private func waitForRequests(_ user: String, count: Int) async throws -> [[String:Any]] {
        for _ in 0..<150 { let rows = try await requests(user); if rows.count >= count { return rows }; try await Task.sleep(for:.milliseconds(100)) }
        throw TVWatchedJourneyError.wrongEffect
    }
    private func waitForCommit(_ user: String) async throws {
        for _ in 0..<150 { if try await requests(user).first?["committed"] as? Bool == true { return }; try await Task.sleep(for:.milliseconds(100)) }
        throw TVWatchedJourneyError.wrongEffect
    }
    private func launch(_ user: String, privateViewing: Bool = false, modes: [String:Any] = [:]) async throws -> XCUIApplication {
        _ = try await owner(); try await control(user, ["reset":true].merging(modes) { _,new in new })
        let app = XCUIApplication(bundleIdentifier:"app.reelclient.tv.qa");app.terminate()
        app.launchArguments = ["-reel-qa-reset", "-privateViewing", privateViewing ? "YES" : "NO"]
        app.launch(); try enter(base.absoluteString, into:app.textFields["server"], app:app)
        try enter(user, into:app.textFields["username"], app:app);try enter("demo", into:app.secureTextFields["password"], app:app)
        try select(app.buttons["connect"],app:app);XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout:20));return app
    }
    private func search(_ text: String, app: XCUIApplication) throws { try openTab("Search",app:app);try enter(text,into:app.textFields["search"],app:app) }
    private func episodes(_ app: XCUIApplication) async throws { try openTab("Library",app:app);try select(app.buttons["filter-Episodes"],app:app);try await label(app.staticTexts["libraryCount"],equals:"12 of 12 titles") }
    private func selectEpisodes(_ numbers: [String], app: XCUIApplication) async throws { try await episodes(app);try select(app.buttons["beginTitleSelection"],app:app);for number in numbers { try select(app.buttons["item-library-episode-"+number],app:app) } }
    /// Series and seasons open a scoped menu; a movie or episode toggles, so its state before the press must be the opposite.
    private func watchMenu(_ id: String, played: Bool, app: XCUIApplication) throws {
        let state = app.buttons[id].value as? String
        try select(app.buttons[id], app: app)
        let item = app.descendants(matching: .any).matching(identifier: id + (played ? "MarkWatched" : "MarkUnwatched")).firstMatch
        if item.waitForExistence(timeout: 2) { try select(item, app: app) }
        else { XCTAssertEqual(state, played ? "Unwatched" : "Watched", "The toggle asks for the opposite of its current state.") }
        XCTAssertTrue(app.buttons["confirmWatchedChanges"].waitForExistence(timeout: 10))
    }
    private func plainMenu(_ id:String,choose title:String,app:XCUIApplication)throws {
        if id == "season" {
            try select(app.segmentedControls[id].buttons[title],app:app)
            return
        }
        try select(app.buttons[id],app:app)
        try select(app.descendants(matching:.any).matching(NSPredicate(format:"label == %@",title)).firstMatch,app:app)
    }
    private func menu(_ id:String,choose title:String,app:XCUIApplication)throws {if ["watchPicker","genrePicker","libraryPicker"].contains(id),!app.buttons[id].exists {try select(app.buttons["libraryFilters"],app:app)};try plainMenu(id,choose:title,app:app);for _ in 0..<2 {if app.buttons["libraryViewStyle"].isHittable {break};XCUIRemote.shared.press(.menu)}}
    /// Menu reveals the tab bar from content. Pressed while the tab bar already holds focus on Home, it leaves the
    /// app, so Menu is only for focus that is in content. Tab buttons can read as not hittable while the tab bar
    /// holds focus, so the focused element's position decides.
    private func openTab(_ title: String, app: XCUIApplication) throws {
        let reachable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: app.buttons[title])
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        let tabBar = app.tabBars.firstMatch
        let focusInContent = focused.exists && !(tabBar.exists && tabBar.frame.contains(CGPoint(x: focused.frame.midX, y: focused.frame.midY)))
        if XCTWaiter().wait(for: [reachable], timeout: 2) != .completed, focusInContent { XCUIRemote.shared.press(.menu) }
        try select(app.buttons[title], app: app)
    }
    private func enter(_ text:String,into field:XCUIElement,app:XCUIApplication)throws {try select(field,app:app);field.typeText(text);XCUIRemote.shared.press(.menu)}
    private func label(_ element:XCUIElement,equals expected:String)async throws {let wait=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label == %@",expected),object:element);await fulfillment(of:[wait],timeout:20);guard element.label==expected else {throw TVWatchedJourneyError.wrongEffect}}
    private func value(_ element:XCUIElement,contains expected:String)async throws {let wait=XCTNSPredicateExpectation(predicate:NSPredicate(format:"value CONTAINS %@",expected),object:element);await fulfillment(of:[wait],timeout:20);guard (element.value as? String ?? "").contains(expected) else {throw TVWatchedJourneyError.wrongEffect}}
    private func summary(_ app:XCUIApplication,contains expected:String)async throws {
        let details = app.buttons["watchedResultDetails"]
        if details.waitForExistence(timeout: 15), !app.staticTexts["watchedSummary"].exists {
            capture("Watched outcome with details collapsed", app)
            try select(details, app: app)
        }
        let element=app.staticTexts.matching(NSPredicate(format:"(identifier == %@ OR identifier == %@) AND label CONTAINS %@","watchedSummary","watchedResults","requests accepted")).firstMatch
        let wait=XCTNSPredicateExpectation(predicate:NSPredicate(format:"label CONTAINS %@",expected),object:element)
        await fulfillment(of:[wait],timeout:25)
        guard element.label.contains(expected) else {throw TVWatchedJourneyError.wrongEffect}
        capture("Watched outcome with exact details expanded", app)
    }
    private func reveal(_ element:XCUIElement,app:XCUIApplication)async throws {for _ in 0..<30 {if element.exists {return};XCUIRemote.shared.press(.down);try await Task.sleep(for:.milliseconds(100))};capture("Missing aggregate Home count",app);throw TVWatchedJourneyError.missingControl}
    private func capture(_ name:String,_ app:XCUIApplication) {let tree=XCTAttachment(string:app.debugDescription);tree.name=name+" hierarchy";tree.lifetime = .keepAlways;add(tree);if app.state == .runningForeground {let shot=XCTAttachment(screenshot:app.screenshot());shot.name=name;shot.lifetime = .keepAlways;add(shot)}}
    private func select(_ element:XCUIElement,app:XCUIApplication)throws {
        guard app.state == .runningForeground,element.waitForExistence(timeout:15) else {capture("Missing remote control",app);throw TVWatchedJourneyError.missingControl}
        var previous="",stationary=0,missingFocus=0
        for _ in 0..<65 {
            if element.hasFocus {XCUIRemote.shared.press(.select);return}
            let focused=app.descendants(matching:.any).matching(NSPredicate(format:"hasFocus == true")).firstMatch
            if !focused.exists {
                // tvOS sometimes omits AX focus during the native card lift. Its
                // unique, measured scale still identifies the remote's target.
                if element.identifier.hasPrefix("item-"), element.isHittable {
                    let peers = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-'")).allElementsBoundByIndex
                        .filter { $0.identifier != element.identifier && $0.isHittable && $0.frame.width > 0 }
                    let widths = peers.map { $0.frame.width }.sorted()
                    if widths.count >= 2, let smallest = widths.first,
                       widths.allSatisfy({ abs($0 - smallest) <= 1 }),
                       element.frame.width >= smallest * 1.06, element.frame.width <= smallest * 1.15 {
                        XCUIRemote.shared.press(.select); return
                    }
                }
                missingFocus+=1
                // tvOS can hold focus on the tab bar without reporting it; a tab target walks along the tab bar.
                let tabBar = app.tabBars.firstMatch
                let onTabBar = tabBar.exists && tabBar.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
                if missingFocus>=4 {XCUIRemote.shared.press(onTabBar ? .right : .down);missingFocus=0}
                else {Thread.sleep(forTimeInterval:0.15)}
                continue
            }
            missingFocus=0
            let target=element.frame,wrapper=focused.frame
            let tight=wrapper.width<=max(target.width*1.2,target.width+20) && wrapper.height<=max(target.height*1.2,target.height+20)
            if element.isHittable,!target.isEmpty,wrapper.insetBy(dx:-2,dy:-2).contains(target),tight {XCUIRemote.shared.press(.select);return}
            let dx=target.midX-wrapper.midX,dy=target.midY-wrapper.midY,identity=focused.identifier+focused.label+wrapper.debugDescription
            stationary=identity==previous ? stationary+1:0;previous=identity
            if stationary>=2,abs(dx)>30 {XCUIRemote.shared.press(dx>0 ? .right:.left);stationary=0}
            else if abs(dy)>30 {XCUIRemote.shared.press(dy>0 ? .down:.up)}
            else {XCUIRemote.shared.press(dx>0 ? .right:.left)}
        }
        capture("Unreachable native remote control",app);throw TVWatchedJourneyError.missingControl
    }
}
