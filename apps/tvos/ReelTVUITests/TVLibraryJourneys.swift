import XCTest

private enum TVLibraryJourneyError: Error { case unsafeEnvironment, missingControl, queryDidNotArrive, clockDidNotAdvance }

@MainActor final class TVLibraryJourneys: XCTestCase {
    private let base = URL(string: "http://127.0.0.1:18970")!
    private var lastUIActionAt = Date().timeIntervalSince1970

    func testHomeIndividualEpisodesSeeAllExactDetailsPlaybackAndBack() async throws {
        let user = uniqueUser("home")
        let app = try await launch(user)
        XCTAssertTrue(app.buttons["seeAllEpisodes"].waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons["item-library-episode-05"].exists)
        XCTAssertTrue(app.buttons["item-library-episode-07"].exists, "Two different episodes in one existing series must remain separate")
        try select(app.buttons["seeAllEpisodes"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "sortby": "DateCreated,SortName", "sortorder": "Descending,Ascending", "limit": "60"])
        XCTAssertEqual(app.staticTexts["libraryTitle"].label, "Recently added episodes")
        XCTAssertTrue(app.buttons["item-library-episode-05"].waitForExistence(timeout: 15))
        XCTAssertTrue((app.buttons["item-library-episode-05"].value as? String ?? "").contains("Added"))
        try select(app.buttons["item-library-episode-05"], app: app)
        XCTAssertEqual(app.staticTexts["detailTitle"].label, "North Episode 05")
        try select(app.buttons["detailPlay"], app: app)
        try await waitForPlayback(user, item: "library-episode-05")
        try await requireAdvancingNativeClock(app)
        try await closePlayer(app, returningTo: app.buttons["detailPlay"])
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.staticTexts["libraryTitle"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["seeAllEpisodes"].waitForExistence(timeout: 10))
        try await requireFocus(app.buttons["seeAllEpisodes"], app: app)
        capture("Native Home and individual-episode See all", app)
        try await assertHistoryUntouched()
    }

    func testEpisodeLibraryCombinesLibraryGenreWatchFavoriteSortAndDirection() async throws {
        let user = uniqueUser("combined"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Episodes"], app: app)
        try menu("libraryPicker", choose: "Shows", app: app)
        try menu("genrePicker", choose: "Drama", app: app)
        try menu("watchPicker", choose: "Unwatched", app: app)
        try filterAction("favoritesOnly", app: app)
        try menu("librarySort", choose: "Episode added", app: app)
        try menu("libraryDirection", choose: "Ascending", app: app)
        let query = try await waitForQuery(user, ["includeitemtypes": "Episode", "parentid": "library-shows", "genreids": "library-drama", "isplayed": "false", "filters": "IsFavorite", "sortby": "DateCreated,SortName", "sortorder": "Ascending,Ascending"])
        XCTAssertEqual(query["startindex"], "0")
        XCTAssertTrue(app.buttons["item-library-episode-03"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["item-library-episode-09"].exists)
        try await waitForLabel(app.staticTexts["libraryCount"], "2 of 2 titles")
        try filterAction("clearFilters", app: app)
        let cleared = try await waitForQuery(user, ["includeitemtypes": "Episode", "sortorder": "Ascending,Ascending"], excluding: ["parentid", "genreids", "isplayed", "filters"])
        XCTAssertEqual(cleared["startindex"], "0")
        XCTAssertTrue(app.buttons["librarySort"].hasFocus || app.buttons["librarySort"].isHittable)
        capture("Combined server-side Episode filters", app)
    }

    func testSeriesAddedAndLatestEpisodeSortsProduceDifferentGlobalOrder() async throws {
        let user = uniqueUser("series"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Series"], app: app)
        try menu("librarySort", choose: "Series added", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Series", "sortby": "DateCreated,SortName", "sortorder": "Descending,Ascending"])
        let created = try await expectedFirstIDs(user, query: ["includeItemTypes": "Series", "sortBy": "DateCreated,SortName", "sortOrder": "Descending,Ascending"])
        try await waitForFirstVisibleItem(try XCTUnwrap(created.first), app: app)
        try menu("librarySort", choose: "Latest episode added", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Series", "sortby": "DateLastContentAdded,SortName", "sortorder": "Descending,Ascending"])
        let updated = try await expectedFirstIDs(user, query: ["includeItemTypes": "Series", "sortBy": "DateLastContentAdded,SortName", "sortOrder": "Descending,Ascending"])
        XCTAssertNotEqual(created.first, updated.first)
        let id = try XCTUnwrap(updated.first)
        try await waitForFirstVisibleItem(id, app: app)
        XCTAssertTrue(app.buttons["item-" + id].waitForExistence(timeout: 15))
        XCTAssertTrue((app.buttons["item-" + id].value as? String ?? "").contains("Content added"))
        try menu("libraryDirection", choose: "Ascending", app: app)
        _ = try await waitForQuery(user, ["sortby": "DateLastContentAdded,SortName", "sortorder": "Ascending,Ascending"])
        try select(app.buttons["filter-Movies"], app: app)
        XCTAssertFalse(app.buttons["librarySort"].label.contains("Latest episode added"))
        capture("Series added versus episode-added sort", app)
    }

    func testEveryCategoryYearSortFilterResetsAndMenuCancelUseActualCatalog() async throws {
        let user = uniqueUser("menu-matrix"), app = try await launch(user)
        try openTab("Library", app: app)
        let categories = [("All", "Movie,Series"), ("Movies", "Movie"), ("Series", "Series"), ("Episodes", "Episode"),
                          ("Favorites", "Movie,Series"), ("Collections", "BoxSet"), ("Playlists", "Playlist")]
        for (name, types) in categories {
            try select(app.buttons["filter-" + name], app: app)
            _ = try await waitForQuery(user, ["includeitemtypes": types], excluding: name == "Favorites" ? [] : ["filters"])
            if name == "Favorites" {
                _ = try await waitForQuery(user, ["filters": "IsFavorite"])
                try select(app.buttons["libraryFilters"], app: app)
                XCTAssertTrue(app.staticTexts["This category shows favorites."].exists)
                XCTAssertFalse(app.buttons["favoritesOnly"].exists)
                XCUIRemote.shared.press(.menu)
            }
        }
        try select(app.buttons["filter-Episodes"], app: app)
        try menu("libraryPicker", choose: "Shows", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "parentid": "library-shows"])
        try menu("libraryPicker", choose: "All libraries", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"], excluding: ["parentid"])
        try menu("genrePicker", choose: "Drama", app: app)
        _ = try await waitForQuery(user, ["genreids": "library-drama"])
        try menu("genrePicker", choose: "All genres", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"], excluding: ["genreids"])
        try menu("watchPicker", choose: "Watched", app: app)
        _ = try await waitForQuery(user, ["isplayed": "true"])
        try menu("watchPicker", choose: "Any", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"], excluding: ["isplayed"])
        try menu("librarySort", choose: "Release year", app: app)
        _ = try await waitForQuery(user, ["sortby": "ProductionYear,SortName", "sortorder": "Descending,Ascending"])
        let expected = try await expectedFirstIDs(user, query: ["includeItemTypes": "Episode", "sortBy": "ProductionYear,SortName", "sortOrder": "Descending,Ascending"])
        try await waitForFirstVisibleItem(try XCTUnwrap(expected.first), app: app)
        try menu("librarySort", choose: "Title", app: app)
        _ = try await waitForQuery(user, ["sortby": "SortName", "sortorder": "Ascending"])
        let before = try await userRequests(user).filter { ($0["query"] as? [String: String])?["limit"] == "60" }.count
        try select(app.buttons["librarySort"], app: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["librarySort"].isHittable)
        try await Task.sleep(for: .milliseconds(350))
        let after = try await userRequests(user).filter { ($0["query"] as? [String: String])?["limit"] == "60" }.count
        XCTAssertEqual(before, after, "Cancelling a menu must leave the current query untouched")
        capture("All category and filter-reset controls with actual server results", app)
    }

    func testRefreshFailureKeepsRowsAndSuccessReplacesEmptyThenRecovers() async throws {
        let user = uniqueUser("refresh"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Episodes"], app: app)
        try await waitForLabel(app.staticTexts["libraryCount"], "12 of 12 titles")
        try await control(user, ["failFirst": 1])
        try select(app.buttons["libraryRefresh"], app: app)
        XCTAssertTrue(app.staticTexts["libraryPageError"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["libraryCount"].label, "12 of 12 titles")
        XCTAssertTrue(app.buttons["item-library-episode-01"].exists)
        try await control(user, ["empty": true])
        try select(app.buttons["libraryRefresh"], app: app)
        XCTAssertTrue(app.staticTexts["No titles found."].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["libraryCount"].label, "0 of 0 titles")
        try await control(user, ["empty": false])
        try select(app.buttons["libraryRefresh"], app: app)
        try await waitForLabel(app.staticTexts["libraryCount"], "12 of 12 titles")
        XCTAssertTrue(app.buttons["item-library-episode-01"].waitForExistence(timeout: 15))
        capture("Refresh retained failure, actual empty replacement and recovery", app)
    }

    func testHomeEpisodeLoadingRepeatedFailureEmptyAndLocalRefreshPreserveFilms() async throws {
        let user = uniqueUser("home-recovery")
        try await control(user, ["reset": true, "failEpisodeFeed": 2])
        try await control(user, ["holdEpisodeFeed": true], options: true)
        let app = try await launch(user, resetFixture: false)
        XCTAssertTrue(app.otherElements["episodesLoading"].exists || app.staticTexts["Opening recent episodes…"].exists)
        XCTAssertTrue(app.buttons["heroDetails"].isHittable)
        try await control(user, ["holdEpisodeFeed": false], options: true)
        XCTAssertTrue(app.staticTexts["episodesError"].waitForExistence(timeout: 15))
        try await control(user, ["holdEpisodeFeed": true], options: true)
        try select(app.buttons["refreshEpisodes"], app: app)
        XCTAssertFalse(app.buttons["refreshEpisodes"].isEnabled)
        XCTAssertTrue(app.buttons["heroDetails"].exists)
        try await control(user, ["holdEpisodeFeed": false], options: true)
        XCTAssertTrue(app.staticTexts["episodesError"].waitForExistence(timeout: 15))
        try await control(user, ["delayEpisodeFeedMs": 0, "empty": true])
        try select(app.buttons["refreshEpisodes"], app: app)
        XCTAssertTrue(app.staticTexts["episodesEmpty"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["heroDetails"].exists)
        XCTAssertTrue(app.buttons["seeAllEpisodes"].isHittable)
        try await control(user, ["empty": false])
        try select(app.buttons["refreshEpisodes"], app: app)
        XCTAssertTrue(app.buttons["item-library-episode-05"].waitForExistence(timeout: 15))
        capture("Independent Episode shelf loading, failure, empty and refresh", app)
    }

    func testMissingZeroInvalidAndLongEpisodeMetadataStayTruthfulAndReachable() async throws {
        let user = uniqueUser("metadata-labels")
        try await control(user, ["reset": true])
        try await control(user, ["metadataMode": "missing"], options: true)
        let app = try await launch(user, resetFixture: false)
        let home = app.buttons["item-library-episode-05"]
        XCTAssertTrue(home.waitForExistence(timeout: 15))
        let missing = home.value as? String ?? ""
        XCTAssertFalse(missing.contains("S1")); XCTAssertFalse(missing.contains("E1")); XCTAssertFalse(missing.contains("Added"))
        try openTab("Library", app: app)
        try select(app.buttons["filter-Episodes"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"])
        let item = app.buttons["item-library-episode-01"]
        XCTAssertTrue(item.waitForExistence(timeout: 15))
        XCTAssertFalse((item.value as? String ?? "").contains("Added"))
        try await control(user, ["metadataMode": "zero"], options: true)
        try select(app.buttons["libraryRefresh"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"])
        let zero = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "S0 E0"), object: item)
        await fulfillment(of: [zero], timeout: 15)
        try await control(user, ["metadataMode": "invalid"], options: true)
        try select(app.buttons["libraryRefresh"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"])
        let invalid = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (value CONTAINS %@)", "Added"), object: item)
        await fulfillment(of: [invalid], timeout: 15)
        try await control(user, ["metadataMode": "long"], options: true)
        try select(app.buttons["libraryRefresh"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"])
        let long = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "An individual episode with a long original fixture title"), object: item)
        await fulfillment(of: [long], timeout: 15)
        try menu("libraryViewStyle", choose: "List", app: app)
        try select(item, app: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["detailTitle"].label.trimmingCharacters(in: .whitespacesAndNewlines),
                       String(repeating: "An individual episode with a long original fixture title and complete metadata ", count: 2).trimmingCharacters(in: .whitespacesAndNewlines))
        XCUIRemote.shared.press(.menu)
        try select(app.buttons["librarySort"], app: app)
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["librarySort"].isHittable)
        capture("Missing, zero, invalid and long Episode metadata", app)
    }

    func testLaterFailureEmptyRetryAndOverlapUseRawCursorWithReachableFocus() async throws {
        let user = uniqueUser("paging"), app = try await launch(user)
        try await control(user, ["failLater": 1, "emptyLater": 1, "overlapLater": 1])
        try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["loadMore"].waitForExistence(timeout: 15))
        for attempt in 1...2 {
            try select(app.buttons["loadMore"], app: app)
            try await waitForPageAttempts(user, start: "60", count: attempt)
            XCTAssertTrue(app.staticTexts["libraryPageError"].waitForExistence(timeout: 15))
            XCTAssertEqual(app.staticTexts["libraryCount"].label, "60 of 144 titles")
            XCTAssertTrue(app.buttons["loadMore"].isHittable)
        }
        try select(app.buttons["loadMore"], app: app)
        _ = try await waitForQuery(user, ["startindex": "60", "limit": "60"])
        try await waitForLabel(app.staticTexts["libraryCount"], "119 of 144 titles")
        try select(app.buttons["loadMore"], app: app)
        _ = try await waitForQuery(user, ["startindex": "120", "limit": "60"])
        try await waitForLabel(app.staticTexts["libraryCount"], "143 of 144 titles")
        XCTAssertFalse(app.buttons["loadMore"].exists)
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true AND identifier BEGINSWITH 'item-'")).firstMatch.exists)
        capture("Raw cursor overlap and preserved later-page recovery", app)
    }

    func testMissingOptionalTotalsKeepLoadMoreUntilActualShortTerminalPage() async throws {
        let user = uniqueUser("no-total")
        try await control(user, ["reset": true])
        try await control(user, ["omitTotals": true], options: true)
        let app = try await launch(user, resetFixture: false)
        try openTab("Library", app: app)
        try await waitForLabel(app.staticTexts["libraryCount"], "60 titles loaded")
        try select(app.buttons["loadMore"], app: app)
        _ = try await waitForQuery(user, ["startindex": "60", "limit": "60"])
        try await waitForLabel(app.staticTexts["libraryCount"], "120 titles loaded")
        try select(app.buttons["loadMore"], app: app)
        _ = try await waitForQuery(user, ["startindex": "120", "limit": "60"])
        try await waitForLabel(app.staticTexts["libraryCount"], "144 titles loaded")
        XCTAssertFalse(app.buttons["loadMore"].exists)
        capture("Missing optional total with real raw-page termination", app)
    }

    func testSavedFiltersRestoreAfterRelaunchAndRemovedIDsRepairBeforeFirstItems() async throws {
        let user = uniqueUser("restore"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Episodes"], app: app)
        try menu("librarySort", choose: "Episode added", app: app)
        try menu("genrePicker", choose: "Drama", app: app)
        try menu("libraryPicker", choose: "Shows", app: app)
        try menu("genrePicker", choose: "Drama", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "parentid": "library-shows", "genreids": "library-drama"])
        try menu("libraryViewStyle", choose: "List", app: app)
        try await waitForLabel(app.buttons["libraryViewStyle"], "View: List")
        app.terminate()
        try await control(user, ["reset": true, "failOptions": 1])
        try await control(user, ["removedLibrary": true, "removedGenre": true], options: true)
        app.launchArguments = ["-privateViewing", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["retryFilterOptions"].waitForExistence(timeout: 15))
        let before = try await userRequests(user)
        XCTAssertFalse(before.contains { ($0["path"] as? String == "/Items") && ($0["query"] as? [String: String])?["limit"] == "60" })
        try select(app.buttons["retryFilterOptions"], app: app)
        let repaired = try await waitForQuery(user, ["includeitemtypes": "Episode", "sortby": "DateCreated,SortName"], excluding: ["parentid", "genreids"])
        XCTAssertEqual(repaired["startindex"], "0")
        XCTAssertFalse((app.buttons["libraryFilters"].value as? String ?? "").contains("Drama"))
        XCTAssertFalse((app.buttons["libraryFilters"].value as? String ?? "").contains("Shows"))
        capture("Removed saved option IDs repaired before Items", app)
    }

    func testOptionsFailureHasExplicitTemporaryDefaultsAndLocalRecovery() async throws {
        let user = uniqueUser("metadata")
        try await control(user, ["reset": true, "failOptions": 2])
        let app = try await launch(user, resetFixture: false)
        try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["browseDefaults"].waitForExistence(timeout: 15))
        try select(app.buttons["retryFilterOptions"], app: app)
        try await waitForOptionsFailure(user)
        XCTAssertTrue(app.buttons["retryFilterOptions"].isHittable)
        try select(app.buttons["browseDefaults"], app: app)
        XCTAssertTrue(app.staticTexts["temporaryBrowseDefaults"].waitForExistence(timeout: 10))
        try select(app.buttons["filter-Episodes"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"], excluding: ["genreids", "parentid", "isplayed", "filters"])
        try select(app.buttons["retryFilterOptions"], app: app)
        XCTAssertTrue(app.buttons["librarySort"].waitForExistence(timeout: 10))
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["temporaryBrowseDefaults"])
        await fulfillment(of: [recovered], timeout: 15)
        XCTAssertFalse(app.staticTexts["temporaryBrowseDefaults"].exists)
        capture("Explicit metadata-default escape and Retry", app)
    }

    func testMetadataAndItemsPermissionErrorsPreserveChoicesAndRecoverThroughRealControls() async throws {
        let user = uniqueUser("permission")
        try await control(user, ["reset": true])
        try await control(user, ["denyOptions": true], options: true)
        let app = try await launch(user, resetFixture: false)
        try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["browseDefaults"].waitForExistence(timeout: 15))
        let blocked = try await state()["scopedRequests"] as? [[String: Any]] ?? []
        XCTAssertTrue(blocked.contains { $0["user"] as? String == user && $0["path"] as? String == "/Genres" && $0["status"] as? Int == 403 })
        XCTAssertFalse(blocked.contains { $0["user"] as? String == user && ($0["query"] as? [String: [String]])?["limit"] == ["60"] })
        try select(app.buttons["browseDefaults"], app: app)
        try await waitForLabel(app.staticTexts["libraryCount"], "60 of 144 titles")
        try await control(user, ["denyOptions": false], options: true)
        try select(app.buttons["retryFilterOptions"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Movie,Series"])
        try await control(user, ["denyItems": true], options: true)
        try select(app.buttons["libraryRefresh"], app: app)
        XCTAssertTrue(app.staticTexts["libraryPageError"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.staticTexts["libraryCount"].label, "60 of 144 titles")
        try select(app.buttons["filter-Episodes"], app: app)
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        try await control(user, ["denyItems": false], options: true)
        try select(app.buttons["retry"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode"])
        try await waitForLabel(app.staticTexts["libraryCount"], "12 of 12 titles")
        capture("Metadata and initial/refresh Items403 with real recovery", app)
    }

    func testPlaylistRepeatedEntriesCollectionsAndBackKeepEntryIdentity() async throws {
        let user = uniqueUser("playlist"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Playlists"], app: app)
        try select(app.buttons["item-library-playlist-1"], app: app)
        XCTAssertTrue(app.buttons["item-library-entry-001"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["item-library-entry-003"].exists)
        XCTAssertFalse(app.buttons["librarySort"].exists)
        let requests = try await userRequests(user)
        let playlist = try XCTUnwrap(requests.last { $0["path"] as? String == "/Playlists/library-playlist-1/Items" })
        let parameters = try XCTUnwrap(playlist["query"] as? [String: String])
        XCTAssertNil(parameters["sortby"]); XCTAssertNil(parameters["genreids"])
        let beforeStyle = requests.filter { $0["path"] as? String == "/Playlists/library-playlist-1/Items" }.count
        try menu("libraryViewStyle", choose: "List", app: app)
        try await waitForLabel(app.buttons["libraryViewStyle"], "View: List")
        let afterStyle = try await userRequests(user).filter { $0["path"] as? String == "/Playlists/library-playlist-1/Items" }.count
        XCTAssertEqual(beforeStyle, afterStyle, "Presentation changes must not refetch or reorder playlist entries")
        try select(app.buttons["item-library-entry-003"], app: app)
        XCTAssertTrue(app.staticTexts["detailTitle"].waitForExistence(timeout: 10))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["item-library-entry-003"].waitForExistence(timeout: 10))
        try await requireFocus(app.buttons["item-library-entry-003"], app: app)
        XCUIRemote.shared.press(.menu)
        try select(app.buttons["filter-Collections"], app: app)
        try select(app.buttons["item-library-collection-1"], app: app)
        _ = try await waitForQuery(user, ["parentid": "library-collection-1"])
        try await waitForLabel(app.staticTexts["libraryCount"], "8 of 8 titles")
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["item-library-collection-1"].waitForExistence(timeout: 10))
        try await requireFocus(app.buttons["item-library-collection-1"], app: app)
        capture("Ordered playlist duplicate identity and collection navigation", app)
    }

    func testSearchDebounceClearEmptyRetryAndBackRemainRemoteReachable() async throws {
        let user = uniqueUser("search"), app = try await launch(user)
        try openTab("Search", app: app)
        try enter("North Episode", into: app.textFields["search"], app: app)
        _ = try await waitForQuery(user, ["searchterm": "North Episode", "includeitemtypes": "Movie,Series,Episode"])
        XCTAssertTrue(app.buttons["item-library-episode-01"].waitForExistence(timeout: 15))
        try enter("Nothing matches", into: app.textFields["search"], replacing: "North Episode", app: app)
        XCTAssertTrue(app.staticTexts["No titles found."].waitForExistence(timeout: 15))
        try enter("", into: app.textFields["search"], replacing: "Nothing matches", app: app)
        XCTAssertTrue(app.staticTexts["A title in mind?"].waitForExistence(timeout: 15))
        try await control(user, ["failFirst": 1])
        try enter("North Episode", into: app.textFields["search"], app: app)
        XCTAssertTrue(app.buttons["retry"].waitForExistence(timeout: 15))
        try select(app.buttons["retry"], app: app)
        XCTAssertTrue(app.buttons["item-library-episode-01"].waitForExistence(timeout: 15))
        XCTAssertEqual(app.textFields["search"].value as? String, "North Episode")
        try await control(user, ["delayFirstMs": 1500, "failFirst": 1])
        try enter("Old unmatched", into: app.textFields["search"], replacing: "North Episode", app: app)
        try await waitForPlannedSearchFailure(user, term: "Old unmatched")
        try enter("Another unmatched", into: app.textFields["search"], replacing: "Old unmatched", app: app)
        XCTAssertFalse(app.buttons["retry"].exists); XCTAssertFalse(app.staticTexts["libraryPageError"].exists)
        _ = try await waitForQuery(user, ["searchterm": "Another unmatched"])
        XCTAssertTrue(app.staticTexts["No titles found."].waitForExistence(timeout: 15))
        capture("Search clear, real empty and recovery", app)
    }

    func testDifferentServerBasePathKeepsBrowseChoicesIsolatedAndRestoresOriginal() async throws {
        let user = uniqueUser("basepath"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Episodes"], app: app)
        try menu("genrePicker", choose: "Drama", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "genreids": "library-drama"])
        try menu("libraryViewStyle", choose: "List", app: app)
        try openTab("Settings", app: app)
        try select(app.buttons["addServer"], app: app)
        try signIn(user, server: base.appendingPathComponent("alternate").absoluteString, app: app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        XCTAssertTrue(app.buttons["librarySort"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["librarySort"].label.contains("Title"))
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("Grid"))
        XCTAssertFalse((app.buttons["libraryFilters"].value as? String ?? "").contains("Drama"))
        try select(app.buttons["filter-Movies"], app: app)
        try menu("genrePicker", choose: "Adventure", app: app)
        try menu("libraryDirection", choose: "Descending", app: app)
        _ = try await waitForScopedQuery(user, basePath: "/alternate", expected: ["includeitemtypes": "Movie", "genreids": "library-adventure", "sortorder": "Descending"])
        try openTab("Settings", app: app)
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'open-' AND label ENDSWITH %@", " on Reel Browse One")).firstMatch
        try select(original, app: app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        _ = try await waitForScopedQuery(user, basePath: "", expected: ["includeitemtypes": "Episode", "genreids": "library-drama"])
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        XCTAssertTrue(app.otherElements["libraryList"].exists || app.scrollViews["libraryList"].exists)
        capture("Account base-path browse preference isolation", app)
    }

    func testSeedChoicesForOwnedUnreadableRecovery() async throws {
        let user = try storageUser(phase: "seed"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Episodes"], app: app)
        try menu("genrePicker", choose: "Drama", app: app)
        try menu("watchPicker", choose: "Watched", app: app)
        try filterAction("favoritesOnly", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "genreids": "library-drama", "isplayed": "true", "filters": "IsFavorite"])
        try openTab("Settings", app: app)
        try select(app.buttons["addServer"], app: app)
        try signIn(user + "-sibling", server: "http://127.0.0.1:18971", app: app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        try select(app.buttons["filter-Movies"], app: app)
        try menu("libraryDirection", choose: "Descending", app: app)
        try openTab("Settings", app: app)
        let original = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'open-' AND label ENDSWITH %@", " on Reel Browse One")).firstMatch
        try select(original, app: app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        try select(app.buttons["filter-Series"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Series"])
        capture("Durable Episode query and separate server-account seed", app)
        app.terminate()
        XCTAssertEqual(app.state, .notRunning)
    }

    func testSeedLastAccountAndSiblingChoicesForRemovalRecovery() async throws {
        let user = try storageUser(phase: "seed-removal"), app = try await launch(user)
        try openTab("Library", app: app)
        try select(app.buttons["filter-Episodes"], app: app)
        try menu("genrePicker", choose: "Drama", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "genreids": "library-drama"])
        try openTab("Settings", app: app); try select(app.buttons["addServer"], app: app)
        try signIn(user + "-sibling", server: "http://127.0.0.1:18971", app: app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app); try select(app.buttons["filter-Movies"], app: app)
        try menu("libraryDirection", choose: "Descending", app: app)
        try await waitForLabel(app.buttons["libraryDirection"], "Direction: Descending")
        app.terminate()
        // The existing protected QA reset clears only this disposable vault.
        // Re-signing only the first identity leaves a known sibling preference
        // document for exact scope-isolation proof, with one actual saved sign-in.
        let only = try await launch(user, resetFixture: false)
        try openTab("Library", app: only)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "genreids": "library-drama"])
        only.terminate()
    }

    func testUnreadableSeeAllViewEditRecoversInSameOwnedAppProcess() async throws {
        try await runUnreadableViewRecovery(try storageUser(phase: "retry"))
    }

    func testUnreadableFilePermissionRecoversPendingViewInSameOwnedProcess() async throws {
        try await runUnreadableViewRecovery(try storageUser(phase: "retry-read"))
    }

    private func runUnreadableViewRecovery(_ user: String) async throws {
        _ = try await owner()
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        guard app.state == .notRunning else { throw TVLibraryJourneyError.unsafeEnvironment }
        try await control(user, ["reset": true])
        app.launchArguments = ["-privateViewing", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["seeAllEpisodes"].waitForExistence(timeout: 20))
        try select(app.buttons["seeAllEpisodes"], app: app)
        XCTAssertTrue(app.staticTexts["browsePreferenceError"].waitForExistence(timeout: 15))
        try menu("libraryViewStyle", choose: "List", app: app)
        let observations: [String: Any] = ["libraryTitle": app.staticTexts["libraryTitle"].label,
                                           "preferenceErrorVisible": app.staticTexts["browsePreferenceError"].exists,
                                           "viewStyle": "List"]
        XCTAssertEqual(observations["libraryTitle"] as? String, "Recently added episodes")
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        try await repairWhileSameOwnedProcessIsBackgrounded(app, user: user, observations: observations)
        try select(app.buttons["retryBrowsePreferences"], app: app)
        let recovered = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["browsePreferenceError"])
        await fulfillment(of: [recovered], timeout: 15)
        XCTAssertFalse(app.staticTexts["browsePreferenceError"].exists)
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        XCUIRemote.shared.press(.menu)
        XCTAssertTrue(app.buttons["seeAllEpisodes"].waitForExistence(timeout: 10))
        try openTab("Library", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Series"])
        try select(app.buttons["filter-Episodes"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "sortby": "SortName", "sortorder": "Ascending", "genreids": "library-drama", "isplayed": "true", "filters": "IsFavorite"])
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        XCTAssertTrue((app.buttons["libraryFilters"].value as? String ?? "").contains("Drama"))
        capture("Same-process Retry preserved recovered predicates and pending view patch", app)
        try await continuityHandshake(user, phase: "retry-completed", state: app.state,
                                      observations: ["libraryTitle": app.staticTexts["libraryTitle"].label, "preferenceErrorVisible": false, "viewStyle": "List"])
        app.terminate()
    }

    func testSyntheticDirectoryWriteDenialKeepsQueryUntilSameProcessRetry() async throws {
        let user = try storageUser(phase: "retry-write"); _ = try await owner()
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        guard app.state == .notRunning else { throw TVLibraryJourneyError.unsafeEnvironment }
        try await control(user, ["reset": true])
        app.launchArguments = ["-privateViewing", "YES"]; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Series"])
        try menu("libraryViewStyle", choose: "List", app: app)
        XCTAssertTrue(app.staticTexts["browsePreferenceError"].waitForExistence(timeout: 15))
        try menu("librarySort", choose: "Release year", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Series", "sortby": "ProductionYear,SortName", "sortorder": "Descending,Ascending"])
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        let observations: [String: Any] = ["libraryTitle": app.staticTexts["libraryTitle"].label,
                                           "preferenceErrorVisible": app.staticTexts["browsePreferenceError"].exists, "viewStyle": "List"]
        try await repairWhileSameOwnedProcessIsBackgrounded(app, user: user, observations: observations)
        try select(app.buttons["retryBrowsePreferences"], app: app)
        let saved = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["browsePreferenceError"])
        await fulfillment(of: [saved], timeout: 15)
        _ = try await waitForQuery(user, ["includeitemtypes": "Series", "sortby": "ProductionYear,SortName", "sortorder": "Descending,Ascending"])
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        XCTAssertTrue(app.buttons["librarySort"].label.contains("Release year"))
        try select(app.buttons["filter-Episodes"], app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Episode", "genreids": "library-drama", "isplayed": "true", "filters": "IsFavorite"])
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("Grid"), "Another saved scope must remain unchanged")
        capture("Real synthetic-directory write error and same-process Retry", app)
        try await continuityHandshake(user, phase: "retry-completed", state: app.state,
                                      observations: ["libraryTitle": app.staticTexts["libraryTitle"].label, "preferenceErrorVisible": false, "viewStyle": "Grid"])
        app.terminate()
    }

    func testUnreadableResetRequiresConfirmationAndKeepsCatalogReachable() async throws {
        let user = try storageUser(phase: "reset"); _ = try await owner()
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        guard app.state == .notRunning else { throw TVLibraryJourneyError.unsafeEnvironment }
        try await control(user, ["reset": true])
        app.launchArguments = ["-privateViewing", "YES"]; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        XCTAssertTrue(app.staticTexts["browsePreferenceError"].waitForExistence(timeout: 15))
        try select(app.buttons["resetBrowsePreferences"], app: app)
        try select(app.buttons["Keep saved choices"], app: app)
        XCTAssertTrue(app.staticTexts["browsePreferenceError"].exists)
        try await continuityHandshake(user, phase: "reset-cancelled", state: app.state,
                                      observations: ["libraryTitle": app.staticTexts["libraryTitle"].label, "preferenceErrorVisible": true, "viewStyle": "Grid"])
        try select(app.buttons["resetBrowsePreferences"], app: app)
        try select(app.buttons["confirmResetBrowse"], app: app)
        let cleared = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: app.staticTexts["browsePreferenceError"])
        await fulfillment(of: [cleared], timeout: 15)
        XCTAssertTrue(app.buttons["librarySort"].label.contains("Title"))
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("Grid"))
        try await waitForLabel(app.staticTexts["libraryCount"], "60 of 144 titles")
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'item-library-title-'")).firstMatch.waitForExistence(timeout: 15))
        capture("Owned corrupt-choice Reset cancel and confirmation", app)
        try await continuityHandshake(user, phase: "reset-completed", state: app.state,
                                      observations: ["libraryTitle": app.staticTexts["libraryTitle"].label, "preferenceErrorVisible": false, "viewStyle": "Grid"])
        app.terminate()
    }

    func testRemovedChoicesFailureSurvivesConnectAndExplicitRetryClearsOnlyRemovedScope() async throws {
        let user = try storageUser(phase: "remove-retry")
        let app = try await launchForStagedRemoval(user)
        try await removeLastAccount(user, app: app)
        let observations: [String: Any] = ["connectionVisible": true, "cleanupNoticeVisible": true]
        try await repairWhileSameOwnedProcessIsBackgrounded(app, user: user, observations: observations)
        try select(app.buttons["retryRemovedBrowseChoices"], app: app)
        try await acknowledgeCleanupResult(app)
        XCTAssertTrue(app.buttons["dismissRemovedBrowseCleanup"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.textFields["server"].exists, "Retry must not restore the removed sign-in")
        try await continuityHandshake(user, phase: "cleanup-completed", state: app.state, observations: observations)
        capture("Last-account Connect keeps removal warning and real Retry", app)
        try select(app.buttons["dismissRemovedBrowseCleanup"], app: app)
        XCTAssertFalse(app.otherElements["removedBrowseCleanupNotice"].exists)
        XCTAssertTrue(app.textFields["server"].isHittable)
        app.terminate(); app.launchArguments = ["-privateViewing", "YES"]; app.launch()
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15))
        XCTAssertFalse(app.otherElements["removedBrowseCleanupNotice"].exists)
    }

    func testReaddedAccountKeepsNewChoicesWhenOldRemovalCleanupRetries() async throws {
        let user = try storageUser(phase: "remove-readd")
        let app = try await launchForStagedRemoval(user)
        try await removeLastAccount(user, app: app)
        try await repairWhileSameOwnedProcessIsBackgrounded(app, user: user,
                                                           observations: ["connectionVisible": true, "cleanupNoticeVisible": true])
        try signIn(user, server: base.absoluteString, app: app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app); try select(app.buttons["filter-Movies"], app: app)
        try menu("genrePicker", choose: "Adventure", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Movie", "genreids": "library-adventure"])
        try menu("libraryViewStyle", choose: "List", app: app)
        try await waitForLabel(app.buttons["libraryViewStyle"], "View: List")
        let observations: [String: Any] = ["connectionVisible": false, "cleanupNoticeVisible": true,
                                           "libraryTitle": app.staticTexts["libraryTitle"].label, "viewStyle": "List"]
        try await continuityHandshake(user, phase: "readded-before-cleanup-retry", state: app.state, observations: observations)
        try select(app.buttons["retryRemovedBrowseChoices"], app: app)
        try await acknowledgeCleanupResult(app)
        XCTAssertTrue(app.buttons["dismissRemovedBrowseCleanup"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
        try await continuityHandshake(user, phase: "cleanup-completed", state: app.state, observations: observations)
        capture("Re-added identity preserves newer preferences through stale cleanup Retry", app)
        try select(app.buttons["dismissRemovedBrowseCleanup"], app: app)
        XCTAssertFalse(app.otherElements["removedBrowseCleanupNotice"].exists)
        XCTAssertTrue(app.buttons["libraryViewStyle"].isHittable)
        app.terminate(); app.launchArguments = ["-privateViewing", "YES"]; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        try openTab("Library", app: app)
        _ = try await waitForQuery(user, ["includeitemtypes": "Movie", "genreids": "library-adventure"])
        XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains("List"))
    }

    private func uniqueUser(_ suffix: String) -> String { "library-tv-ui-" + suffix + "-" + String(UUID().uuidString.lowercased().prefix(8)) }
    private func storageUser(phase: String) throws -> String {
        guard ProcessInfo.processInfo.environment["REEL_TV_PARITY_STORAGE_PHASE"] == phase,
              let user = ProcessInfo.processInfo.environment["REEL_TV_PARITY_STORAGE_USER"],
              user.hasPrefix("library-tv-storage-"), user.count < 100 else { throw TVLibraryJourneyError.unsafeEnvironment }
        return user
    }
    private func launchForStagedRemoval(_ user: String) async throws -> XCUIApplication {
        _ = try await owner()
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        guard app.state == .notRunning else { throw TVLibraryJourneyError.unsafeEnvironment }
        try await control(user, ["reset": true]); app.launchArguments = ["-privateViewing", "YES"]; app.launch()
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20)); return app
    }
    private func removeLastAccount(_ user: String, app: XCUIApplication) async throws {
        try openTab("Settings", app: app)
        let target = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'remove-' AND label ENDSWITH %@", " on Reel Browse One")).firstMatch
        try select(target, app: app); try select(app.buttons["Sign out"], app: app)
        XCTAssertTrue(app.textFields["server"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "local browse settings remain")).firstMatch.exists)
        capture("Post-commit removal warning remains at the Connect root", app)
        try select(app.buttons["OK"], app: app)
        XCTAssertTrue(app.buttons["retryRemovedBrowseChoices"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.otherElements["removedBrowseCleanupNotice"].exists)
        // Storage is still denied: this real Retry must keep removal committed,
        // preserve the pending scope, and leave another reachable Retry.
        try select(app.buttons["retryRemovedBrowseChoices"], app: app)
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "Some local browse settings still")).firstMatch.exists)
        try select(app.buttons["OK"], app: app)
        XCTAssertTrue(app.textFields["server"].exists)
        XCTAssertTrue(app.buttons["retryRemovedBrowseChoices"].isHittable)
        capture("Failed explicit cleanup Retry keeps Connect and pending cleanup", app)
    }
    private func acknowledgeCleanupResult(_ app: XCUIApplication) async throws {
        XCTAssertTrue(app.buttons["OK"].waitForExistence(timeout: 15))
        try select(app.buttons["OK"], app: app)
        XCTAssertTrue(app.buttons["dismissRemovedBrowseCleanup"].waitForExistence(timeout: 15))
    }
    private func repairWhileSameOwnedProcessIsBackgrounded(_ app: XCUIApplication, user: String, observations: [String: Any]) async throws {
        capture("Storage error and pending in-memory browse choices", app)
        XCUIRemote.shared.press(.home)
        for _ in 0..<100 {
            if app.state == .runningBackground || app.state == .runningBackgroundSuspended { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard app.state == .runningBackground || app.state == .runningBackgroundSuspended else { throw TVLibraryJourneyError.unsafeEnvironment }
        try await continuityHandshake(user, phase: "background-for-retry", state: app.state, observations: observations)
        // activate() can cold-launch, so both XCTest state and the independent
        // host PID/start/executable proofs fence it. No terminate/launch here.
        guard app.state == .runningBackground || app.state == .runningBackgroundSuspended else { throw TVLibraryJourneyError.unsafeEnvironment }
        app.activate()
        XCTAssertEqual(app.state, .runningForeground)
        if observations["connectionVisible"] as? Bool == true {
            XCTAssertTrue(app.textFields["server"].exists); XCTAssertTrue(app.otherElements["removedBrowseCleanupNotice"].exists)
        } else {
            XCTAssertEqual(app.staticTexts["browsePreferenceError"].exists, observations["preferenceErrorVisible"] as? Bool)
            XCTAssertTrue(app.buttons["libraryViewStyle"].label.contains(observations["viewStyle"] as? String ?? "missing expected style"))
            XCTAssertEqual(app.staticTexts["libraryTitle"].label, observations["libraryTitle"] as? String)
        }
        try await continuityHandshake(user, phase: "foreground-before-retry", state: app.state, observations: observations)
    }
    private func continuityHandshake(_ user: String, phase: String, state appState: XCUIApplication.State, observations: [String: Any]) async throws {
        let marker = UUID().uuidString.lowercased()
        let stateName: String
        switch appState {
        case .runningForeground: stateName = "runningForeground"
        case .runningBackground: stateName = "runningBackground"
        case .runningBackgroundSuspended: stateName = "runningBackgroundSuspended"
        default: throw TVLibraryJourneyError.unsafeEnvironment
        }
        var request = URLRequest(url: base.appendingPathComponent("qa/parity-continuity"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(try await owner(), forHTTPHeaderField: "X-Reel-Parity-Owner")
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["action": "record", "marker": marker, "phase": phase,
                                                                       "deviceID": ProcessInfo.processInfo.environment["SIMULATOR_UDID"] ?? "",
                                                                       "appState": stateName, "coldLaunchAllowed": false, "observations": observations])
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        for _ in 0..<1200 {
            let snapshot = try await state()
            if let entry = (snapshot["continuity"] as? [String: [String: Any]])?[marker], entry["acknowledged"] as? Bool == true,
               let pin = entry["hostProofSHA256"] as? String, pin.count == 64 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Exact owned host recovery handshake was not acknowledged")
        throw TVLibraryJourneyError.unsafeEnvironment
    }
    private func owner() async throws -> String {
        guard ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] == "Reel QA Apple TV",
              let device = ProcessInfo.processInfo.environment["REEL_TV_PARITY_DEVICE_UDID"],
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == device,
              let owner = ProcessInfo.processInfo.environment["REEL_TV_PARITY_OWNER"], owner.count >= 24 else { throw TVLibraryJourneyError.unsafeEnvironment }
        let (data, response) = try await URLSession.shared.data(from: base.appendingPathComponent("qa/parity-identity"))
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let identity = try JSONSerialization.jsonObject(with: data) as? [String: Any], identity["owner"] as? String == owner,
              identity["kind"] as? String == "reel-tv-library-parity", identity["port"] as? Int == 18970 else { throw TVLibraryJourneyError.unsafeEnvironment }
        return owner
    }
    private func launch(_ user: String, resetFixture: Bool = true) async throws -> XCUIApplication {
        _ = try await owner()
        if resetFixture { try await control(user, ["reset": true]) }
        let app = XCUIApplication(bundleIdentifier: "app.reelclient.tv.qa")
        app.terminate()
        app.launchArguments = ["-reel-qa-reset", "-privateViewing", "YES", "-streamQuality", "120000000"]
        app.launch()
        try signIn(user, server: base.absoluteString, app: app)
        XCTAssertTrue(app.buttons["heroDetails"].waitForExistence(timeout: 20))
        return app
    }
    private func signIn(_ user: String, server: String, app: XCUIApplication) throws {
        try enter(server, into: app.textFields["server"], app: app)
        try enter(user, into: app.textFields["username"], app: app)
        try enter("demo", into: app.secureTextFields["password"], app: app)
        try select(app.buttons["connect"], app: app)
    }
    private func control(_ user: String, _ body: [String: Any], options: Bool = false) async throws {
        var request = URLRequest(url: base.appendingPathComponent(options ? "qa/parity-control" : "qa/library-control"))
        request.httpMethod = "POST"; request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("MediaBrowser Client=\"Reel TV QA\", Device=\"Owned fixture\", DeviceId=\"parity\", Version=\"1\", Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        request.setValue(try await owner(), forHTTPHeaderField: "X-Reel-Parity-Owner")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
    }
    private func state() async throws -> [String: Any] {
        var request = URLRequest(url: base.appendingPathComponent("qa/parity-state"))
        request.setValue(try await owner(), forHTTPHeaderField: "X-Reel-Parity-Owner")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private func userRequests(_ user: String) async throws -> [[String: Any]] {
        let data = try await state()
        return ((data["users"] as? [String: [String: Any]])?[user])?["requests"] as? [[String: Any]] ?? []
    }
    private func waitForQuery(_ user: String, _ expected: [String: String], excluding: [String] = []) async throws -> [String: String] {
        for _ in 0..<180 {
            let snapshot = try await state()
            let requests = snapshot["scopedRequests"] as? [[String: Any]] ?? []
            if let found = requests.last(where: { row in
                guard row["path"] as? String == "/Items", row["user"] as? String == user, row["status"] as? Int == 200,
                      (row["atUnix"] as? Double ?? 0) >= lastUIActionAt,
                      let query = row["query"] as? [String: [String]], query["limit"] == ["60"] else { return false }
                return expected.allSatisfy { query[$0.key] == [$0.value] } && excluding.allSatisfy { query[$0] == nil }
            })?["query"] as? [String: [String]] { return found.mapValues { $0.joined(separator: ",") } }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("No successful actual UI Items request matched \(expected)")
        throw TVLibraryJourneyError.queryDidNotArrive
    }
    private func waitForScopedQuery(_ user: String, basePath: String, expected: [String: String]) async throws -> [String: Any] {
        for _ in 0..<150 {
            let snapshot = try await state()
            let rows = snapshot["scopedRequests"] as? [[String: Any]] ?? []
            if let row = rows.last(where: { row in
                guard row["user"] as? String == user, row["basePath"] as? String == basePath,
                      row["path"] as? String == "/Items", row["status"] as? Int == 200,
                      (row["atUnix"] as? Double ?? 0) >= lastUIActionAt,
                      let query = row["query"] as? [String: [String]], query["limit"] == ["60"] else { return false }
                return expected.allSatisfy { query[$0.key] == [$0.value] }
            }) { return row }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TVLibraryJourneyError.queryDidNotArrive
    }
    private func waitForFirstVisibleItem(_ identifier: String, app: XCUIApplication) async throws {
        for _ in 0..<120 {
            let visible = app.buttons.allElementsBoundByIndex.filter { $0.identifier.hasPrefix("item-") && $0.isHittable }
                .sorted { abs($0.frame.minY - $1.frame.minY) > 20 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
            if visible.first?.identifier == "item-" + identifier { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        capture("Unexpected first visible item order", app)
        XCTFail("Expected first visible item \(identifier)")
        throw TVLibraryJourneyError.missingControl
    }
    private func waitForPageAttempts(_ user: String, start: String, count: Int) async throws {
        for _ in 0..<150 {
            let requests = try await userRequests(user)
            if requests.filter({ $0["path"] as? String == "/Items" && ($0["query"] as? [String: String])?["startindex"] == start && $0["status"] is Int }).count >= count { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TVLibraryJourneyError.queryDidNotArrive
    }
    private func waitForOptionsFailure(_ user: String) async throws {
        for _ in 0..<150 {
            let snapshot = try await state()
            let requests = snapshot["scopedRequests"] as? [[String: Any]] ?? []
            if requests.contains(where: { $0["user"] as? String == user && $0["path"] as? String == "/Genres" && $0["status"] as? Int == 503 && ($0["atUnix"] as? Double ?? 0) >= lastUIActionAt }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TVLibraryJourneyError.queryDidNotArrive
    }
    private func waitForPlannedSearchFailure(_ user: String, term: String) async throws {
        for _ in 0..<150 {
            let requests = try await userRequests(user)
            if requests.contains(where: { $0["path"] as? String == "/Items" && $0["plannedStatus"] as? Int == 503 && ($0["query"] as? [String: String])?["searchterm"] == term }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TVLibraryJourneyError.queryDidNotArrive
    }
    private func expectedFirstIDs(_ user: String, query: [String: String]) async throws -> [String] {
        // Independent read-only expected dataset request is explicit in the ledger;
        // it never substitutes for the actual UI request/control assertion above.
        var parts = URLComponents(url: base.appendingPathComponent("Items"), resolvingAgainstBaseURL: false)!
        parts.queryItems = ["userId": user, "recursive": "true", "limit": "1"].merging(query) { _, value in value }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        request.setValue("MediaBrowser Token=\"fixture-\(user)\"", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let page = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        return (page["Items"] as? [[String: Any]] ?? []).compactMap { $0["Id"] as? String }
    }
    private func waitForPlayback(_ user: String, item: String) async throws {
        for _ in 0..<150 {
            let snapshot = try await state()
            if (snapshot["reports"] as? [[String: Any]] ?? []).contains(where: { $0["user"] as? String == user && $0["path"] as? String == "/Items/\(item)/PlaybackInfo" }) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw TVLibraryJourneyError.queryDidNotArrive
    }
    private func requireAdvancingNativeClock(_ app: XCUIApplication) async throws {
        func seconds(_ text: String) -> Int? {
            let parts = text.split(separator: ":").compactMap { Int($0) }
            return parts.count == 2 ? parts[0] * 60 + parts[1] : nil
        }
        let clock = app.otherElements["AXElapsedTime"]
        XCTAssertTrue(clock.waitForExistence(timeout: 10), "Wait for AVKit presentation before revealing transport controls")
        XCUIRemote.shared.press(.up)
        var first: Int?
        for attempt in 0..<150 {
            if clock.exists, let value = seconds(clock.label) {
                if let first, value >= first + 1 {
                    let receipt = XCTAttachment(string: "Native elapsed clock advanced from \(first)s to \(value)s")
                    receipt.name = "Native episode playback advancement"; receipt.lifetime = .keepAlways; add(receipt)
                    capture("Native advancing episode playback", app)
                    return
                }
                if first == nil { first = value }
            }
            if attempt > 0 && attempt.isMultiple(of: 20) { XCUIRemote.shared.press(.up) }
            try await Task.sleep(for: .milliseconds(100))
        }
        capture("Native playback clock did not advance", app)
        throw TVLibraryJourneyError.clockDidNotAdvance
    }
    private func closePlayer(_ app: XCUIApplication, returningTo target: XCUIElement) async throws {
        for _ in 0..<4 {
            XCUIRemote.shared.press(.menu)
            try await Task.sleep(for: .milliseconds(500))
            if !app.otherElements["AXElapsedTime"].exists && !app.cells["Quality"].exists && target.isHittable { return }
        }
        capture("Native player did not close", app)
        throw TVLibraryJourneyError.missingControl
    }
    private func assertHistoryUntouched() async throws {
        let snapshot = try await state()
        let reports = snapshot["reports"] as? [[String: Any]] ?? []
        XCTAssertFalse(reports.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        XCTAssertFalse(reports.contains { ($0["path"] as? String)?.hasPrefix("/UserPlayedItems") == true || ($0["path"] as? String)?.hasPrefix("/UserFavoriteItems") == true })
        for user in (snapshot["users"] as? [String: [String: Any]] ?? [:]).values {
            XCTAssertTrue((user["favorites"] as? [String: Bool] ?? [:]).isEmpty)
            XCTAssertTrue((user["played"] as? [String: Bool] ?? [:]).isEmpty)
        }
    }
    private func waitForLabel(_ element: XCUIElement, _ label: String) async throws {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label == %@", label), object: element)
        await fulfillment(of: [expectation], timeout: 15)
    }
    private func menu(_ id: String, choose title: String, app: XCUIApplication) throws {
        if ["libraryPicker", "genrePicker", "watchPicker"].contains(id), !app.buttons[id].exists {
            try select(app.buttons["libraryFilters"], app: app)
        }
        try select(app.buttons[id], app: app)
        try select(app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch, app: app)
        for _ in 0..<2 {
            if app.buttons["librarySort"].isHittable || app.buttons["libraryViewStyle"].isHittable { break }
            XCUIRemote.shared.press(.menu)
        }
    }
    private func filterAction(_ id: String, app: XCUIApplication) throws {
        if !app.buttons[id].exists { try select(app.buttons["libraryFilters"], app: app) }
        try select(app.buttons[id], app: app)
        for _ in 0..<2 {
            if app.buttons["libraryFilters"].isHittable { break }
            XCUIRemote.shared.press(.menu)
        }
    }
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
    private func enter(_ text: String, into field: XCUIElement, replacing old: String = "", app: XCUIApplication) throws {
        try select(field, app: app)
        if !old.isEmpty { field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count)) }
        if !text.isEmpty { field.typeText(text) }
        XCUIRemote.shared.press(.menu)
    }
    private func capture(_ name: String, _ app: XCUIApplication) {
        let hierarchy = XCTAttachment(string: app.debugDescription); hierarchy.name = name + " hierarchy"; hierarchy.lifetime = .keepAlways; add(hierarchy)
        if app.state == .runningForeground { let screenshot = XCTAttachment(screenshot: app.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot) }
    }
    private func requireFocus(_ element: XCUIElement, app: XCUIApplication) async throws {
        for _ in 0..<100 {
            if element.hasFocus { return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if focused.exists, element.exists {
                let target = element.frame, wrapper = focused.frame
                if !target.isEmpty, wrapper.insetBy(dx: -2, dy: -2).contains(target),
                   wrapper.width <= max(target.width * 1.2, target.width + 20), wrapper.height <= max(target.height * 1.2, target.height + 20) { return }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        capture("Back did not restore the selected native focus target", app)
        XCTFail("Expected native focus to return to \(element.identifier)")
        throw TVLibraryJourneyError.missingControl
    }
    private func select(_ element: XCUIElement, app: XCUIApplication) throws {
        guard app.state == .runningForeground, element.waitForExistence(timeout: 15) else { capture("Missing remote control", app); throw TVLibraryJourneyError.missingControl }
        var previous = "", stationary = 0
        for _ in 0..<55 {
            if element.hasFocus { lastUIActionAt = Date().timeIntervalSince1970; XCUIRemote.shared.press(.select); return }
            let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
            if !focused.exists {
                // tvOS can hold focus on the tab bar without reporting it; a tab target walks along the tab bar.
                let tabBar = app.tabBars.firstMatch
                let onTabBar = tabBar.exists && tabBar.frame.contains(CGPoint(x: element.frame.midX, y: element.frame.midY))
                XCUIRemote.shared.press(onTabBar ? .right : .down)
                continue
            }
            let target = element.frame, wrapper = focused.frame
            let tight = wrapper.width <= max(target.width * 1.2, target.width + 20) && wrapper.height <= max(target.height * 1.2, target.height + 20)
            let compact = wrapper.height <= 180 && wrapper.width <= app.frame.width * 0.8
            if element.isHittable, !target.isEmpty, wrapper.insetBy(dx: -2, dy: -2).contains(target), tight || compact {
                lastUIActionAt = Date().timeIntervalSince1970; XCUIRemote.shared.press(.select); return
            }
            let dx = target.midX - wrapper.midX, dy = target.midY - wrapper.midY
            let identity = focused.identifier + focused.label + wrapper.debugDescription
            stationary = identity == previous ? stationary + 1 : 0; previous = identity
            if stationary >= 2, abs(dx) > 30 { XCUIRemote.shared.press(dx > 0 ? .right : .left); stationary = 0 }
            else if abs(dy) > 30 { XCUIRemote.shared.press(dy > 0 ? .down : .up) }
            else { XCUIRemote.shared.press(dx > 0 ? .right : .left) }
        }
        capture("Unreachable native remote control", app)
        XCTFail("Native remote could not reach \(element.identifier)")
        throw TVLibraryJourneyError.missingControl
    }
}
