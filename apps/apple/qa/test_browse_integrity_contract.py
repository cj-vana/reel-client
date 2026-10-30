"""Pure fixture regressions. These never bind a socket or qualify native UI."""
import unittest

from browse_integrity_contract import Contract


class BrowseIntegrityContractTests(unittest.TestCase):
    def setUp(self):
        self.contract = Contract()
        self.user = "browse-unit"

    def request(self, method, path, query=None, body=None, user=None):
        user = user or self.user
        receipt = self.contract.begin(user, method, path, query or {})
        reply = self.contract.dispatch(user, method, path, query or {}, body or {}, receipt)
        if reply.hold is None:
            self.contract.complete(receipt, reply.status)
        return reply, receipt

    def control(self, **values):
        return self.contract.configure(self.user, values)

    def item(self, identifier):
        reply, _ = self.request("GET", "/Items/" + identifier)
        self.assertEqual(reply.status, 200)
        return reply.value

    def testOnlySyntheticUserIdentitiesAreAccepted(self):
        for value in (None, "household", "browse-", "browse-a/b", "browse-" + "a" * 101):
            self.assertFalse(self.contract.valid_user(value))
        self.assertTrue(self.contract.valid_user("browse-owned-123"))
        with self.assertRaises(ValueError):
            self.contract.state("household")

    def testLibraryAndGenreContractsDoNotInventUserViewsPaging(self):
        reply, _ = self.request("GET", "/UserViews")
        self.assertEqual(reply.value["TotalRecordCount"], 2)
        with self.assertRaises(ValueError):
            self.request("GET", "/UserViews", {"limit": "60"})
        reply, _ = self.request("GET", "/Genres", {"limit": "1", "startindex": "1"})
        self.assertEqual(reply.value["Items"][0]["Id"], "library-drama")
        self.assertEqual(reply.value["TotalRecordCount"], 2)

    def testCompoundEpisodeRecencyUsesIndividualEpisodesAndStableTitleTieBreak(self):
        reply, _ = self.request("GET", "/Items", {"includeitemtypes": "Episode", "sortby": "DateCreated,SortName", "sortorder": "Descending,Ascending"})
        rows = reply.value["Items"]
        self.assertEqual(len(rows), 12)
        self.assertEqual({row["Type"] for row in rows}, {"Episode"})
        self.assertGreater(sum(row["SeriesId"] == "library-title-003" for row in rows), 1)
        self.assertEqual([(-int(row["DateCreated"][8:10]), row["SortName"]) for row in rows], sorted((-int(row["DateCreated"][8:10]), row["SortName"]) for row in rows))

    def testEveryExplicitSortDirectionChangesActualFixtureOrdering(self):
        for sort in ("SortName", "DateCreated", "ProductionYear", "DateLastContentAdded"):
            q = {"includeitemtypes": "Series", "sortby": sort if sort == "SortName" else sort + ",SortName"}
            ascending, _ = self.request("GET", "/Items", {**q, "sortorder": "Ascending" if sort == "SortName" else "Ascending,Ascending"})
            descending, _ = self.request("GET", "/Items", {**q, "sortorder": "Descending" if sort == "SortName" else "Descending,Ascending"})
            self.assertNotEqual(ascending.value["Items"][0]["Id"], descending.value["Items"][0]["Id"])

    def testRawPagingBeyondOneHundredTwentyAndOverlappingBoundaryAreObservable(self):
        self.control(overlapLater=1)
        pages = [self.request("GET", "/Items", {"includeitemtypes": "Movie,Series", "startindex": str(start), "limit": "60", "sortby": "SortName"}) for start in (0, 60, 120)]
        self.assertEqual([len(reply.value["Items"]) for reply, _ in pages], [60, 60, 24])
        self.assertEqual(pages[0][0].value["Items"][-1]["Id"], pages[1][0].value["Items"][0]["Id"])
        self.assertTrue(pages[1][1]["overlapLater"])
        self.assertTrue(all(reply.value["TotalRecordCount"] == 144 for reply, _ in pages))

    def testPlaylistPreservesRepeatedEntryIdentityAndRejectsCatalogueSort(self):
        reply, _ = self.request("GET", "/Playlists/library-playlist-1/Items", {"userid": self.user, "fields": "Overview", "enableuserdata": "true"})
        rows = reply.value["Items"]
        self.assertEqual(rows[0]["Id"], rows[2]["Id"])
        self.assertNotEqual(rows[0]["PlaylistItemId"], rows[2]["PlaylistItemId"])
        with self.assertRaises(ValueError):
            self.request("GET", "/Playlists/library-playlist-1/Items", {"sortby": "SortName"})

    def testSeriesAndSeasonWritesAffectActualDescendantsOutsideVisibleFilter(self):
        series = "library-title-003"
        self.assertEqual(self.item(series)["UserData"]["UnplayedItemCount"], 2)
        reply, receipt = self.request("POST", "/UserPlayedItems/" + series)
        self.assertEqual(reply.status, 200)
        self.assertEqual(len(receipt["affectedIDs"]), 5)
        self.assertEqual(self.item(series)["UserData"]["UnplayedItemCount"], 0)
        _, receipt = self.request("DELETE", "/UserPlayedItems/browse-season-003-2")
        self.assertEqual(len(receipt["affectedIDs"]), 3)
        self.assertEqual(self.item(series)["UserData"]["UnplayedItemCount"], 2)
        self.assertEqual(self.item("browse-season-003-1")["UserData"]["UnplayedItemCount"], 0)

    def testEmptySeriesZeroCountAndExplicitPlayedRemainDifferent(self):
        row = self.item("library-title-012")
        self.assertEqual(row["UserData"]["UnplayedItemCount"], 0)
        self.assertFalse(row["UserData"]["Played"])

    def testUncertainAcceptedFailureAndRejectedFailureHaveDifferentDurableFixtureEffects(self):
        target = "library-title-001"
        before = self.item(target)["UserData"]["Played"]
        self.control(failMutation=1, acceptFailedMutation=0)
        reply, receipt = self.request("POST", "/UserPlayedItems/" + target)
        self.assertEqual(reply.status, 503); self.assertFalse(receipt["accepted"])
        self.assertEqual(self.item(target)["UserData"]["Played"], before)
        self.control(failMutation=1, acceptFailedMutation=1)
        reply, receipt = self.request("POST", "/UserPlayedItems/" + target)
        self.assertEqual(reply.status, 503); self.assertTrue(receipt["accepted"])
        self.assertTrue(self.item(target)["UserData"]["Played"])

    def testAccountStateDoesNotLeakPlayedOrOptionsIntoSibling(self):
        self.request("POST", "/UserPlayedItems/library-title-001")
        self.control(removeLibrary=True, removeGenre=True)
        sibling, _ = self.request("GET", "/Items/library-title-001", user="browse-sibling")
        self.assertFalse(sibling.value["UserData"]["Played"])
        sibling, _ = self.request("GET", "/UserViews", user="browse-sibling")
        self.assertEqual(sibling.value["TotalRecordCount"], 2)

    def testResumeAndNextUpReflectWatchedMutationRatherThanStaticResponses(self):
        initial, _ = self.request("GET", "/Shows/NextUp")
        identifier = initial.value["Items"][0]["Id"]
        self.request("POST", "/UserPlayedItems/" + identifier)
        next_up, _ = self.request("GET", "/Shows/NextUp")
        resume, _ = self.request("GET", "/UserItems/Resume")
        self.assertNotEqual(next_up.value["Items"][0]["Id"], identifier)
        self.assertNotIn(identifier, [row["Id"] for row in resume.value["Items"]])

    def testReadbackFailureWrongIdentityUnknownAndContainerCounterfactualsAreExplicit(self):
        self.control(failReadback=1)
        reply, _ = self.request("GET", "/Items/library-title-001")
        self.assertEqual(reply.status, 503)
        for mode, field, value in (("wrongID", "Id", "browse-other"), ("unknown", "Type", "Unknown"), ("container", "Type", "MusicAlbum")):
            self.control(readbackMode=mode)
            self.assertEqual(self.item("library-title-001")[field], value)

    def testHoldRequiresExactUserUuidAndResetReleasesOnlyThatUser(self):
        self.control(holdItems=True)
        reply, receipt = self.request("GET", "/Items", {"includeitemtypes": "Movie"})
        identifier = receipt["holdID"]
        self.assertEqual(reply.hold.outcome, "waiting")
        with self.assertRaises(ValueError):
            self.contract.configure("browse-sibling", {"release": identifier})
        self.assertEqual(reply.hold.outcome, "waiting")
        self.contract.configure("browse-sibling", {"reset": True})
        self.assertFalse(reply.hold.event.is_set())
        self.control(release=identifier)
        self.assertTrue(reply.hold.event.is_set())
        self.assertEqual(receipt["holdOutcome"], "released")

    def testMalformedControlsCannotResetExistingStateOrReleaseOtherWork(self):
        self.request("POST", "/UserPlayedItems/library-title-001")
        for body in ({"reset": "true"}, {"reset": True, "unknown": 1}, {"failItems": True}, {"readbackMode": []}, {"phase": 101}):
            with self.assertRaises(ValueError):
                self.contract.configure(self.user, body)
        self.assertTrue(self.item("library-title-001")["UserData"]["Played"])

    def testSeparateReadbackAndMutationHoldsWitnessOldAndNewOperationIndependently(self):
        first = "browse-season-003-1"
        second = "browse-season-003-2"
        self.control(failMutation=1, holdReadbackItem=first)
        failed, _ = self.request("DELETE", "/UserPlayedItems/" + first)
        self.assertEqual(failed.status, 503)
        old, old_receipt = self.request("GET", "/Items/" + first)
        self.assertEqual(old_receipt["holdRole"], "readback")
        self.assertFalse(old_receipt["completed"])
        self.control(holdMutationItem=second)
        new, new_receipt = self.request("POST", "/UserPlayedItems/" + second)
        self.assertEqual(new_receipt["holdRole"], "mutation")
        self.assertTrue(new_receipt["accepted"]); self.assertFalse(new_receipt["completed"])
        self.control(release=old_receipt["holdID"])
        self.assertTrue(old.hold.event.is_set()); self.assertFalse(new.hold.event.is_set())
        self.assertEqual(new.hold.outcome, "waiting")
        self.control(release=new_receipt["holdID"])
        self.assertTrue(new.hold.event.is_set())

    def testHistoryReportsAreRejectedAndRemainInStrictRequestCensus(self):
        reply, _ = self.request("POST", "/Sessions/Playing", body={"ItemId": "library-title-001"})
        self.assertEqual(reply.status, 409)
        reports = [r for r in self.contract.snapshot(self.user)["requests"] if r["path"].startswith("/Sessions/Playing")]
        self.assertEqual(len(reports), 1); self.assertTrue(reports[0]["completed"])

    def testRegisteredOldRequestCannotMutateOrConsumeRearmedGenerationAfterReset(self):
        stale_write = self.contract.begin(self.user, "POST", "/UserPlayedItems/library-title-001", {})
        stale_read = self.contract.begin(self.user, "GET", "/Items", {"includeitemtypes": "Movie"})
        old_generation = stale_write["stateGeneration"]
        self.control(reset=True, failItems=1, holdItems=True, failMutation=1)
        before = self.contract.snapshot(self.user)
        self.assertNotEqual(before["generation"], old_generation)
        reply = self.contract.dispatch(self.user, "POST", "/UserPlayedItems/library-title-001", {}, {}, stale_write)
        self.assertEqual(reply.status, 409); self.assertTrue(stale_write["refusedStaleGeneration"])
        reply = self.contract.dispatch(self.user, "GET", "/Items", {"includeitemtypes": "Movie"}, {}, stale_read)
        self.assertEqual(reply.status, 409); self.assertTrue(stale_read["refusedStaleGeneration"])
        after = self.contract.snapshot(self.user)
        self.assertEqual(after["played"], before["played"])
        self.assertEqual(after["mode"], before["mode"])
        self.assertEqual(len(self.contract.holds), 0)
        fresh, _ = self.request("GET", "/Items", {"includeitemtypes": "Movie"})
        self.assertEqual(fresh.status, 503)
        self.assertTrue(self.contract.snapshot(self.user)["mode"]["holdItems"])

    def testResetFenceDoesNotRejectOtherUserOrCurrentGenerationRequests(self):
        sibling = "browse-sibling"
        owned = self.contract.begin(sibling, "GET", "/Items", {"includeitemtypes": "Movie"})
        self.control(reset=True)
        reply = self.contract.dispatch(sibling, "GET", "/Items", {"includeitemtypes": "Movie"}, {}, owned)
        self.assertEqual(reply.status, 200)
        current, _ = self.request("POST", "/UserPlayedItems/library-title-001")
        self.assertEqual(current.status, 200)
        self.assertTrue(self.item("library-title-001")["UserData"]["Played"])

    def testLibraryAndGenreOptionHoldsOwnOnlyTheirExactResponseRoute(self):
        self.control(holdOptions=True)
        genres, _ = self.request("GET", "/Genres")
        self.assertIsNone(genres.hold)
        views, views_receipt = self.request("GET", "/UserViews")
        self.assertEqual(views_receipt["holdRole"], "holdOptions")
        self.control(release=views_receipt["holdID"])
        self.control(holdGenres=True)
        views, _ = self.request("GET", "/UserViews")
        self.assertIsNone(views.hold)
        genres, genres_receipt = self.request("GET", "/Genres")
        self.assertEqual(genres_receipt["holdRole"], "holdGenres")
        self.assertFalse(genres_receipt["completed"])
        self.control(release=genres_receipt["holdID"])


if __name__ == "__main__":
    unittest.main()
