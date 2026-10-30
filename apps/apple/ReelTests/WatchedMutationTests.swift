import XCTest
@testable import Reel

final class WatchedMutationTests: XCTestCase {
    private let account = Account(server: URL(string: "https://synthetic.invalid/jellyfin")!, token: "synthetic-token", userID: "one", name: "One", serverName: "Synthetic")

    func testBulkPlansDescribeEveryContainedTitleRatherThanTheVisibleFilteredSubset() {
        for type in ["Series", "Season", "BoxSet", "Playlist", "Folder", "CollectionFolder", "MusicAlbum", "MusicArtist", "PhotoAlbum", "AggregateFolder", "BasePluginFolder", "ChannelFolderItem", "ManualPlaylistsFolder", "PlaylistsFolder", "UserRootFolder", "UserView"] {
            let item = MediaItem(Id: "synthetic-" + type, Name: "Synthetic " + type, Type: type)
            let plan = WatchedMutationPlan(item: item, played: true, account: account, revision: UUID())
            XCTAssertTrue(plan.isBulk); XCTAssertTrue(plan.confirmationMessage.contains("outside the current filters"))
            XCTAssertTrue(plan.confirmationMessage.contains("Continue watching and Up next"))
            XCTAssertEqual(plan.actionLabel, ["Series": "Mark series as watched", "Season": "Mark season as watched"][type] ?? "Mark all as watched")
            XCTAssertEqual(plan.method, "POST")
        }
    }

    func testSeasonAndSeriesConfirmationNamesTheCorrectScope() {
        for type in ["Series", "Season"] {
            let plan = WatchedMutationPlan(item: MediaItem(Id: "synthetic", Name: "Name", Type: type), played: false, account: account, revision: UUID())
            XCTAssertTrue(plan.confirmationMessage.contains("all episodes in this " + type.lowercased()))
            XCTAssertEqual(plan.actionLabel, "Mark " + type.lowercased() + " as unwatched"); XCTAssertEqual(plan.method, "DELETE")
        }
    }

    func testUnknownMissingAndUnprovenTypesRefuseMutationEvenWithPlayedData() {
        for type in [nil, "Unknown", "", "Recording", "TvChannel"] as [String?] {
            let unknown = MediaItem(Id: "unknown", Name: "Unknown", Type: type, UserData: UserData(Played: true, UnplayedItemCount: 4))
            let plan = WatchedMutationPlan(item: unknown, played: false, account: account, revision: UUID())
            XCTAssertFalse(plan.isSupported); XCTAssertNil(plan.path); XCTAssertFalse(plan.isBulk)
            XCTAssertFalse(plan.played); XCTAssertNil(unknown.itemWatched); XCTAssertNil(unknown.aggregateUnplayedCount)
            XCTAssertEqual(unknown.serverPlayed, true)
        }
    }

    func testEpisodeAndMoviePlansDoNotClaimAContainerScope() {
        for type in ["Movie", "Episode", "Video", "MusicVideo", "Audio", "AudioBook", "Book", "Photo", "Trailer"] {
            let plan = WatchedMutationPlan(item: MediaItem(Id: "leaf", Name: "Leaf", Type: type), played: true, account: account, revision: UUID())
            XCTAssertTrue(plan.isSupported); XCTAssertFalse(plan.requiresConfirmation)
            XCTAssertFalse(plan.isBulk); XCTAssertEqual(plan.actionLabel, "Mark as watched")
        }
    }

    func testPlanCapturesImmutableTargetDespiteLaterItemChanges() {
        var item = MediaItem(Id: "original", Name: "Original", Type: "Series")
        let revision = UUID(), plan = WatchedMutationPlan(item: item, played: false, account: account, revision: revision)
        item = MediaItem(Id: "changed", Name: "Changed", Type: "Movie")
        XCTAssertEqual(plan.itemID, "original"); XCTAssertEqual(plan.name, "Original"); XCTAssertEqual(plan.type, "Series")
        XCTAssertEqual(plan.accountRevision, revision); XCTAssertFalse(plan.played)
    }

    func testAccountAndRevisionFenceRejectsSwitchReauthenticationAndSignedOutState() {
        let revision = UUID(), plan = WatchedMutationPlan(item: MediaItem(Id: "leaf", Name: "Leaf"), played: true, account: account, revision: revision)
        let sibling = Account(server: account.server, token: "synthetic-other", userID: "two", name: "Two", serverName: "Synthetic")
        XCTAssertTrue(plan.isCurrent(account: account, revision: revision))
        XCTAssertFalse(plan.isCurrent(account: sibling, revision: revision))
        XCTAssertFalse(plan.isCurrent(account: account, revision: UUID()))
        XCTAssertFalse(plan.isCurrent(account: nil, revision: revision))
    }

    func testMutationPathRefusesSeparatorsControlAndOverlongIDsRatherThanDoubleEscaping() {
        for id in ["", "a/b", "a%2Fb", "a?x", "a#x", "../x", "a\u{0}b", String(repeating: "a", count: 257)] {
            let plan = WatchedMutationPlan(item: MediaItem(Id: id, Name: "Invalid", Type: "Movie"), played: true, account: account, revision: UUID())
            XCTAssertNil(plan.path, id)
        }
        let plan = WatchedMutationPlan(item: MediaItem(Id: "a0123456789_A-Z", Name: "Valid", Type: "Movie"), played: true, account: account, revision: UUID())
        XCTAssertEqual(plan.path, "UserPlayedItems/a0123456789_A-Z")
    }

    func testPositiveFolderFlagOverridesLeafAndEstablishesUnknownContainerScope() {
        for type in [nil, "Movie", "FutureFolder"] as [String?] {
            let item = MediaItem(Id: "folder", Name: "Folder", Type: type, IsFolder: true)
            let plan = WatchedMutationPlan(item: item, played: true, account: account, revision: UUID())
            XCTAssertEqual(item.watchedKind, .container); XCTAssertTrue(plan.requiresConfirmation)
            XCTAssertEqual(plan.path, "UserPlayedItems/folder")
        }
    }

    func testKnownContainerWithFalseFolderFlagStillRequiresDescendantConfirmation() {
        let artist = MediaItem(Id: "artist", Name: "Artist", Type: "MusicArtist", IsFolder: false, UserData: UserData(Played: true))
        XCTAssertEqual(artist.watchedKind, .container); XCTAssertNil(artist.itemWatched)
        XCTAssertTrue(WatchedMutationPlan(item: artist, played: false, account: account, revision: UUID()).requiresConfirmation)
    }

    func testMalformedFolderOrTypeMetadataCannotDecodeIntoSafeLeaf() throws {
        for json in [#"{"Id":"one","Name":"One","Type":"Movie","IsFolder":"false"}"#,
                     #"{"Id":"one","Name":"One","Type":"Movie","IsFolder":0}"#,
                     #"{"Id":"one","Name":"One","Type":["Movie"],"IsFolder":false}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(MediaItem.self, from: Data(json.utf8)))
        }
        let valid = try JSONDecoder().decode(MediaItem.self, from: Data(#"{"Id":"one","Name":"One","Type":"Movie","IsFolder":null}"#.utf8))
        XCTAssertEqual(valid.watchedKind, .leaf)
    }

    func testZeroUnwatchedCountDoesNotEstablishPlayedForEmptyOrPopulatedContainer() {
        let item = MediaItem(Id: "container", Name: "Container", Type: "Series", UserData: UserData(Played: false, UnplayedItemCount: 0))
        XCTAssertEqual(item.aggregateUnplayedCount, 0); XCTAssertEqual(item.serverPlayed, false); XCTAssertNil(item.itemWatched)
        let unknownCount = MediaItem(Id: "missing", Name: "Missing", Type: "Series", UserData: UserData(Played: true))
        XCTAssertNil(unknownCount.aggregateUnplayedCount); XCTAssertNil(unknownCount.itemWatched)
    }

    func testLeafReadbackCanPreventRepeatingDesiredStateButMissingPlayedCannot() {
        let played = WatchedReadback(item: MediaItem(Id: "movie", Name: "Movie", Type: "Movie", UserData: UserData(Played: true)))
        XCTAssertTrue(played.matches(true)); XCTAssertFalse(played.matches(false))
        let unknown = WatchedReadback(item: MediaItem(Id: "movie", Name: "Movie", Type: "Movie"))
        XCTAssertFalse(unknown.matches(true)); XCTAssertFalse(unknown.matches(false))
    }

    func testContainerReadbackNeverTreatsPlayedOrZeroCountAsConfirmedDescendantMutation() {
        for value in [true, false] {
            let observed = WatchedReadback(item: MediaItem(Id: "series", Name: "Series", Type: "Series", UserData: UserData(Played: value, UnplayedItemCount: 0)))
            XCTAssertEqual(observed.serverPlayed, value); XCTAssertEqual(observed.unplayedCount, 0)
            XCTAssertFalse(observed.matches(true)); XCTAssertFalse(observed.matches(false))
            XCTAssertTrue(observed.summary.contains("container Played field"))
        }
    }

    func testReadbackRefusesDifferentIdentityAndNewUnsupportedType() {
        let plan = WatchedMutationPlan(item: MediaItem(Id: "original", Name: "Original", Type: "Movie"), played: false, account: account, revision: UUID())
        XCTAssertThrowsError(try plan.refreshed(from: MediaItem(Id: "other", Name: "Other", Type: "Movie")))
        XCTAssertThrowsError(try plan.refreshed(from: MediaItem(Id: "original", Name: "Original", Type: "Recording")))
    }

    func testReadbackReclassifiesLeafIntoContainerWhileRetainingDesiredValueAndAccountFence() throws {
        let revision = UUID(), plan = WatchedMutationPlan(item: MediaItem(Id: "original", Name: "Original", Type: "Movie"), played: false, account: account, revision: revision)
        let refreshed = try plan.refreshed(from: MediaItem(Id: "original", Name: "Updated folder", Type: "MusicAlbum"))
        XCTAssertTrue(refreshed.isBulk); XCTAssertTrue(refreshed.requiresConfirmation)
        XCTAssertEqual(refreshed.name, "Updated folder"); XCTAssertFalse(refreshed.played)
        XCTAssertEqual(refreshed.itemID, plan.itemID); XCTAssertEqual(refreshed.accountID, plan.accountID)
        XCTAssertEqual(refreshed.accountRevision, revision); XCTAssertTrue(refreshed.confirmationMessage.contains("outside the current filters"))
        let changedIntent = refreshed.desiring(true)
        XCTAssertTrue(changedIntent.played); XCTAssertTrue(changedIntent.requiresConfirmation)
        XCTAssertEqual(changedIntent.type, "MusicAlbum"); XCTAssertEqual(changedIntent.accountRevision, revision)
    }

    func testWatchedClassifierDoesNotChangeVideoNavigationContainerRouting() {
        for type in ["MusicAlbum", "MusicArtist", "PhotoAlbum", "UserView"] {
            let item = MediaItem(Id: "one", Name: "One", Type: type)
            XCTAssertTrue(item.isAggregate); XCTAssertFalse(item.isContainer)
        }
        XCTAssertTrue(MediaItem(Id: "one", Name: "One", Type: "BoxSet").isContainer)
    }

    func testFullScopeFenceRejectsSameIDTypeOrFolderChangesAndUnknownDispatch() {
        let original = MediaItem(Id: "one", Name: "One", Type: "Movie", IsFolder: false)
        let plan = WatchedMutationPlan(item: original, played: true, account: account, revision: UUID())
        XCTAssertTrue(plan.matchesScope(original))
        for item in [MediaItem(Id: "one", Name: "One", Type: "Episode", IsFolder: false),
                     MediaItem(Id: "one", Name: "One", Type: "Movie", IsFolder: nil),
                     MediaItem(Id: "one", Name: "One", Type: "Movie", IsFolder: true),
                     MediaItem(Id: "one", Name: "One", Type: "Unknown", IsFolder: false),
                     MediaItem(Id: "other", Name: "One", Type: "Movie", IsFolder: false)] {
            XCTAssertFalse(plan.matchesScope(item))
        }
    }

    func testReadbackFreshScopeCannotBeConfusedWithOriginalScopeWhenKindIsUnchanged() throws {
        let original = MediaItem(Id: "one", Name: "One", Type: "MusicAlbum", IsFolder: false)
        let plan = WatchedMutationPlan(item: original, played: false, account: account, revision: UUID())
        let updated = MediaItem(Id: "one", Name: "One", Type: "MusicArtist", IsFolder: false)
        let refreshed = try plan.refreshed(from: updated)
        XCTAssertEqual(plan.kind, refreshed.kind); XCTAssertNotEqual(plan.scope, refreshed.scope)
        XCTAssertFalse(plan.matchesScope(updated)); XCTAssertTrue(refreshed.matchesScope(updated))
        XCTAssertFalse(refreshed.played); XCTAssertEqual(refreshed.desiring(true).scope, refreshed.scope)
    }

    func testNameAndUserDataRefreshDoNotInvalidateUnchangedMutationScope() {
        let original = MediaItem(Id: "one", Name: "Before", Type: "Season", IsFolder: true)
        let plan = WatchedMutationPlan(item: original, played: true, account: account, revision: UUID())
        let updated = MediaItem(Id: "one", Name: "After", Type: "Season", IsFolder: true, UserData: UserData(Played: true, UnplayedItemCount: 0))
        XCTAssertTrue(plan.matchesScope(updated))
    }

    func testQueuedReadbackBeforeEntryCannotAdoptReplacementOperationAfterScopeReturns() {
        let item = MediaItem(Id: "one", Name: "One", Type: "Season", IsFolder: true)
        let revision = UUID(), plan = WatchedMutationPlan(item: item, played: true, account: account, revision: revision)
        var operation = UUID(), scope = plan.scope
        let queuedAdmission = WatchedReadbackAdmission(plan: plan, operationID: operation, scope: scope)
        var checking = false, reads = 0, requestID = UUID()
        var readback = "replacement-readback", retry = "replacement-intent"
        // Deliberately park BEFORE helper entry, then run the same admission
        // guard the widget uses before changing request/checking state.
        let queuedCheck = {
            guard queuedAdmission.isCurrent(operationID: operation, scope: scope, account: self.account, revision: revision) else { return }
            checking = true; requestID = UUID(); reads += 1
            readback = "old-readback"; retry = "old-intent"
        }
        operation = UUID(); scope = WatchedMutationScope(item: MediaItem(Id: "other", Name: "Other", Type: "Season", IsFolder: true))
        operation = UUID(); scope = plan.scope
        let beforeRequest = requestID
        queuedCheck()
        XCTAssertEqual(reads, 0); XCTAssertFalse(checking); XCTAssertEqual(requestID, beforeRequest)
        XCTAssertEqual(readback, "replacement-readback"); XCTAssertEqual(retry, "replacement-intent")
        // Counterfactual: manufacturing the token at helper entry, as the old
        // widget did, admits the abandoned plan after A→B→A.
        let lateCapture = WatchedReadbackAdmission(plan: plan, operationID: operation, scope: scope)
        XCTAssertTrue(lateCapture.isCurrent(operationID: operation, scope: scope, account: account, revision: revision))
    }

    func testReadbackAdmissionRequiresOriginalScopeAccountRevisionAndOperation() {
        let revision = UUID(), operation = UUID()
        let plan = WatchedMutationPlan(item: MediaItem(Id: "one", Name: "One", Type: "Movie"), played: false, account: account, revision: revision)
        let admission = WatchedReadbackAdmission(plan: plan, operationID: operation, scope: plan.scope)
        XCTAssertTrue(admission.isCurrent(operationID: operation, scope: plan.scope, account: account, revision: revision))
        XCTAssertFalse(admission.isCurrent(operationID: UUID(), scope: plan.scope, account: account, revision: revision))
        XCTAssertFalse(admission.isCurrent(operationID: operation, scope: WatchedMutationScope(item: MediaItem(Id: "one", Name: "One", Type: "Season")), account: account, revision: revision))
        XCTAssertFalse(admission.isCurrent(operationID: operation, scope: plan.scope, account: account, revision: UUID()))
        XCTAssertFalse(admission.isCurrent(operationID: operation, scope: plan.scope, account: nil, revision: revision))
        let sibling = Account(server: account.server, token: "synthetic", userID: "sibling", name: "Sibling", serverName: "Synthetic")
        XCTAssertFalse(admission.isCurrent(operationID: operation, scope: plan.scope, account: sibling, revision: revision))
    }

    func testOriginalWriteAdmissionCannotBeReplacedByErrorPathCurrentToken() {
        let revision = UUID(), write = UUID()
        let plan = WatchedMutationPlan(item: MediaItem(Id: "one", Name: "One", Type: "Movie"), played: true, account: account, revision: revision)
        let writeAdmission = WatchedReadbackAdmission(plan: plan, operationID: write, scope: plan.scope)
        XCTAssertTrue(writeAdmission.isCurrent(operationID: write, scope: plan.scope, account: account, revision: revision))
        XCTAssertFalse(writeAdmission.isCurrent(operationID: UUID(), scope: plan.scope, account: account, revision: revision))
    }
}
