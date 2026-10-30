"""Real loopback HTTP contract tests; no media files or external server required."""
import itertools
import json
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import uuid

import library_contract as library
from fixture_server import Handler, STATE, catalog
from loopback_server import LoopbackHTTPServer


def title(number):
    return f"library-title-{number:03d}"


class LibraryContractHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.server = LoopbackHTTPServer(("127.0.0.1", 0), Handler)
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()
        cls.origin = "http://127.0.0.1:" + str(cls.server.server_port)
        cls.opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=2)

    def setUp(self):
        self.user = "library-test-" + uuid.uuid4().hex

    def tearDown(self):
        library.reset(self.user)

    def request(self, path, query=None, body=None, user=None, method=None, authenticated=True):
        if query is not None:
            path += "?" + urllib.parse.urlencode(query, doseq=True)
        headers = {}
        if authenticated:
            headers["Authorization"] = f'MediaBrowser Token="fixture-{user or self.user}"'
        data = None if body is None else json.dumps(body).encode()
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.origin + path, data=data, headers=headers, method=method)
        try:
            with self.opener.open(request, timeout=6) as response:
                payload = response.read()
                return response.status, json.loads(payload) if payload else None
        except urllib.error.HTTPError as error:
            try:
                payload = error.read()
                return error.code, json.loads(payload) if payload else None
            finally:
                error.close()

    def page(self, query=None, path="/Items", user=None):
        status, payload = self.request(path, query, user=user)
        self.assertEqual(status, 200, payload)
        return payload

    def control(self, values, user=None):
        status, value = self.request("/qa/library-control", body=values, user=user)
        self.assertEqual(status, 200, value)
        return value

    def ids(self, page):
        return [row["Id"] for row in page["Items"]]

    def test_fixture_is_opt_in_and_legacy_catalog_is_unchanged(self):
        original = self.page({"limit": 500}, user="demo")
        self.assertEqual(original["TotalRecordCount"], 75)
        self.assertEqual(len(original["Items"]), 75)
        self.assertTrue(all("DateCreated" not in row and "GenreItems" not in row for row in original["Items"]))
        self.assertEqual(catalog("demo")[0]["Id"], "movie-1")
        self.assertEqual(self.request("/qa/library-control", body={"empty": True}, user="demo")[0], 404)
        self.assertEqual(self.request("/qa/library-state", authenticated=False)[0], 401)

    def test_primary_dataset_and_independent_tied_sort_dimensions(self):
        page = self.page({"limit": 500})
        self.assertEqual(page["TotalRecordCount"], 144)
        self.assertEqual(sum(row["Type"] == "Movie" for row in page["Items"]), 96)
        self.assertEqual(sum(row["Type"] == "Series" for row in page["Items"]), 48)
        for field, expected_unique in [("Name", 48), ("ProductionYear", 12), ("DateCreated", 40)]:
            self.assertEqual(len({row[field] for row in page["Items"]}), expected_unique)
        self.assertEqual(self.ids(page)[:6], list(map(title, [48, 96, 144, 30, 78, 126])))
        views = self.page(path="/UserViews")
        self.assertEqual(self.ids(views), ["library-films", "library-shows"])
        genres = self.page(path="/Genres")
        self.assertEqual(self.ids(genres), ["library-drama", "library-adventure"])

    def test_episode_recency_orders_individual_episodes_across_three_series(self):
        query = {"includeItemTypes": "Episode", "sortBy": "DateCreated,SortName", "sortOrder": "Descending,Ascending", "limit": 5}
        pages = [self.page({**query, "startIndex": offset}) for offset in (0, 5, 10)]
        rows = [row for page in pages for row in page["Items"]]
        self.assertEqual([len(page["Items"]) for page in pages], [5, 5, 2])
        self.assertTrue(all(page["TotalRecordCount"] == 12 for page in pages))
        self.assertEqual([row["Id"] for row in rows[:3]], ["library-episode-05", "library-episode-10", "library-episode-02"])
        self.assertEqual(len({row["Id"] for row in rows}), 12)
        self.assertEqual({row["SeriesId"] for row in rows}, {title(3), title(6), title(9)})
        self.assertTrue(all(a["DateCreated"] >= b["DateCreated"] for a, b in zip(rows, rows[1:])))
        filtered = self.page({**query, "genreIds": "library-adventure", "isPlayed": "false"})
        self.assertEqual(self.ids(filtered), ["library-episode-05", "library-episode-07"])
        self.assertEqual(filtered["TotalRecordCount"], 2)

    def test_new_episode_date_resurfaces_an_older_series_without_rewriting_its_created_date(self):
        query = {"includeItemTypes": "Series", "sortBy": "DateLastContentAdded,SortName", "sortOrder": "Descending,Ascending", "limit": 60}
        latest = self.page(query)
        created = self.page({**query, "sortBy": "DateCreated,SortName"})
        self.assertEqual(self.ids(latest)[:3], [title(6), title(9), title(3)])
        self.assertEqual(self.ids(created)[0], title(87))
        original = next(row for row in created["Items"] if row["Id"] == title(6))
        self.assertEqual(original["DateCreated"], "2025-01-23T00:00:00Z")
        self.assertEqual(latest["Items"][0]["DateCreated"], original["DateCreated"])
        self.assertEqual(latest["Items"][0]["DateLastMediaAdded"], "2025-06-13T00:00:00Z")

    def test_episode_home_feed_has_separate_failure_counter_and_recovers(self):
        query = {"includeItemTypes": "Episode", "sortBy": "DateCreated,SortName", "sortOrder": "Descending,Ascending", "limit": 18}
        self.control({"failFirst": 1, "failEpisodeFeed": 1})
        self.assertEqual(self.request("/Items", query)[0], 503)
        recovered = self.page(query)
        self.assertEqual(recovered["Items"][0]["Id"], "library-episode-05")
        self.assertEqual(self.request("/Items", {"includeItemTypes": "Movie,Series", "limit": 60})[0], 503)
        self.assertEqual(self.page({"limit": 60})["TotalRecordCount"], 144)

    def test_full_sort_precedes_pagination_for_every_direction_and_key_order(self):
        fields = {"SortName": lambda row: row["SortName"].casefold(), "ProductionYear": lambda row: row["ProductionYear"], "DateCreated": lambda row: row["DateCreated"]}
        for primary, secondary in itertools.permutations(fields, 2):
            for directions in itertools.product(("Ascending", "Descending"), repeat=2):
                with self.subTest(sort=(primary, secondary), orders=directions):
                    query = {"sortBy": primary + "," + secondary, "sortOrder": ",".join(directions), "limit": 60}
                    pages = [self.page({**query, "startIndex": offset}) for offset in (0, 60, 120)]
                    combined = [row for page in pages for row in page["Items"]]
                    self.assertEqual(len({row["Id"] for row in combined}), 144)
                    self.assertTrue(all(page["TotalRecordCount"] == 144 for page in pages))
                    for left, right in zip(combined, combined[1:]):
                        a, b = fields[primary](left), fields[primary](right)
                        if a != b:
                            self.assertTrue(a < b if directions[0] == "Ascending" else a > b)
                        else:
                            a, b = fields[secondary](left), fields[secondary](right)
                            self.assertTrue(a <= b if directions[1] == "Ascending" else a >= b)
        year = self.page({"sortBy": "ProductionYear,SortName", "sortOrder": "Descending,Ascending"})
        added = self.page({"sortBy": "DateCreated,SortName", "sortOrder": "Descending,Ascending"})
        self.assertEqual(self.ids(year)[:6], list(map(title, [17, 65, 113, 29, 77, 125])))
        self.assertEqual(self.ids(added)[:6], list(map(title, [7, 127, 87, 47, 54, 134])))

    def test_single_direction_repeats_for_remaining_sort_fields(self):
        repeated = self.page({"sortBy": "ProductionYear,SortName", "sortOrder": "Descending,Descending", "limit": 500})
        single = self.page({"sortBy": "ProductionYear,SortName", "sortOrder": "Descending", "limit": 500})
        default = self.page({"sortBy": "ProductionYear,SortName", "limit": 500})
        explicit = self.page({"sortBy": "ProductionYear,SortName", "sortOrder": "Ascending,Ascending", "limit": 500})
        self.assertEqual(self.ids(repeated), self.ids(single))
        self.assertEqual(self.ids(default), self.ids(explicit))

    def test_combined_category_search_library_genre_watch_and_favorite_filters(self):
        # Arithmetic membership is independent of the fixture's filtering code.
        # All 486 combinations execute through the real HTTP handler.
        categories = ("Movie,Series", "Movie", "Series")
        for category, search, parent, genre, played, favorite in itertools.product(categories, ("", "North", "absent"), ("", "library-films", "library-shows"), ("", "library-drama", "library-adventure"), (None, False, True), (False, True)):
            query = {"includeItemTypes": category, "searchTerm": search, "parentId": parent, "genreIds": genre, "limit": 500}
            if played is not None:
                query["isPlayed"] = str(played).lower()
            if favorite:
                query["filters"] = "IsFavorite"
            expected = set()
            for number in range(1, 145):
                kind = "Series" if number % 3 == 0 else "Movie"
                group = number * 37 % 48
                name = ("Amber", "Cedar", "Harbor", "Meadow", "North", "Willow")[group % 6] + f" Story {group:02d}"
                if kind not in category.split(",") or search and search.lower() not in name.lower():
                    continue
                if parent and kind != ("Movie" if parent == "library-films" else "Series"):
                    continue
                if genre == "library-drama" and not (number % 2 == 1 or number % 4 == 0):
                    continue
                if genre == "library-adventure" and number % 2 != 0:
                    continue
                if played is not None and (number % 5 in (0, 2)) != played:
                    continue
                if favorite and number % 7 not in (0, 1):
                    continue
                expected.add(title(number))
            page = self.page(query)
            with self.subTest(query=query):
                self.assertEqual(set(self.ids(page)), expected)
                self.assertEqual(page["TotalRecordCount"], len(expected))

    def test_array_filters_boolean_false_and_search_episode_scope(self):
        either_genre = self.page({"genreIds": "library-drama,library-adventure", "limit": 500})
        self.assertEqual(either_genre["TotalRecordCount"], 144)
        not_favorite = self.page({"isFavorite": "false", "limit": 500})
        self.assertTrue(all(not row["UserData"]["IsFavorite"] for row in not_favorite["Items"]))
        combined = self.page({"filters": "IsFavorite,IsUnplayed", "limit": 500})
        self.assertTrue(all(row["UserData"]["IsFavorite"] and not row["UserData"]["Played"] for row in combined["Items"]))
        episodes = self.page({"includeItemTypes": "Episode", "searchTerm": "North Episode", "limit": 500})
        self.assertEqual(episodes["TotalRecordCount"], 12)
        self.assertEqual(episodes["Items"][0]["Id"], "library-episode-01")
        self.assertEqual(self.page({"includeItemTypes": "Episode", "parentId": "library-films"})["TotalRecordCount"], 0)

    def test_collections_sort_and_filter_members_without_leaking_global_titles(self):
        collections = self.page({"includeItemTypes": "BoxSet"})
        self.assertEqual(self.ids(collections), ["library-collection-1", "library-collection-2"])
        members = self.page({"parentId": "library-collection-1", "sortBy": "ProductionYear,SortName", "sortOrder": "Descending,Ascending"})
        self.assertEqual(set(self.ids(members)), set(map(title, [71, 2, 139, 18, 4, 87, 54, 23])))
        narrowed = self.page({"parentId": "library-collection-1", "includeItemTypes": "Movie", "genreIds": "library-drama", "isPlayed": "false", "filters": "IsFavorite"})
        self.assertEqual(self.ids(narrowed), [title(71)])
        unknown = self.page({"parentId": "missing-library"})
        self.assertEqual(unknown["TotalRecordCount"], 0)

    def test_playlist_raw_order_duplicates_and_entry_ids_survive_pagination(self):
        self.assertEqual(self.ids(self.page({"includeItemTypes": "Playlist"})), ["library-playlist-1"])
        path = "/Playlists/library-playlist-1/Items"
        query = {"sortBy": "ProductionYear", "sortOrder": "Descending", "searchTerm": "absent", "genreIds": "missing", "isPlayed": "true", "limit": 3}
        pages = [self.page({**query, "startIndex": offset}, path) for offset in (0, 3, 6)]
        rows = [row for page in pages for row in page["Items"]]
        self.assertEqual([row["Id"] for row in rows], list(map(title, [71, 2, 71, 139, 18, 4, 87, 2])))
        self.assertEqual(len({row["PlaylistItemId"] for row in rows}), 8)
        self.assertTrue(all(page["TotalRecordCount"] == 8 for page in pages))

    def test_first_and_later_failures_empty_pages_delays_and_recovery_are_scoped(self):
        self.control({"failFirst": 1, "failLater": 1, "emptyFirst": 1, "emptyLater": 1, "delayFirstMs": 90})
        started = time.monotonic()
        self.assertEqual(self.request("/Items")[0], 503)
        self.assertGreaterEqual(time.monotonic() - started, .08)
        self.assertEqual(self.page()["Items"], [])
        self.assertEqual(len(self.page()["Items"]), 60)
        self.assertEqual(self.request("/Items", {"startIndex": 60})[0], 503)
        empty = self.page({"startIndex": 60})
        self.assertEqual(empty["Items"], [])
        self.assertEqual(empty["TotalRecordCount"], 144)
        self.assertEqual(len(self.page({"startIndex": 60})["Items"]), 60)
        other = self.user + "-other"
        self.assertEqual(len(self.page(user=other)["Items"]), 60)
        self.assertEqual(self.request("/qa/library-state", user=other)[1]["mode"], {})
        library.reset(other)

    def test_controls_validate_atomically_and_reset_only_the_current_user(self):
        self.control({"empty": True})
        for invalid in ({"empty": False, "delayMs": 2001}, {"empty": False, "delayEpisodeFeedMs": 10001}, {"failFirst": True}, {"reset": "true"}, {"unknown": 1}, *({"empty": False, "overlapLater": value} for value in (-1, 21, True, 1.0, "1", None))):
            self.assertEqual(self.request("/qa/library-control", body=invalid)[0], 400)
            self.assertEqual(self.page()["TotalRecordCount"], 0)
        self.control({"reset": True})
        self.assertEqual(self.request("/qa/library-state")[1]["requests"], [])
        self.assertEqual(self.page()["TotalRecordCount"], 144)

    def test_first_page_delay_bounds_are_strict_and_other_caps_are_unchanged(self):
        self.assertEqual(self.control({"delayFirstMs": 10000}), {"delayFirstMs": 10000})
        for key, value in [("delayFirstMs", invalid) for invalid in (-1, 10001, True, 1.0, "1", None)] + [
            ("delayMs", 2001), ("delayLaterMs", 2001), ("delayOptionsMs", 2001),
        ]:
            with self.subTest(key=key, value=value):
                self.assertEqual(self.request("/qa/library-control", body={"delayFirstMs": 0, key: value})[0], 400)
                self.assertEqual(self.request("/qa/library-state")[1]["mode"], {"delayFirstMs": 10000})
        self.assertEqual(self.control({"delayFirstMs": 0}), {"delayFirstMs": 0})

    def test_long_first_page_delay_keeps_captured_failure_and_other_users_independent(self):
        self.control({"delayFirstMs": 2200, "failFirst": 1})
        completed = []
        failures = []

        def older_request():
            started = time.monotonic()
            try:
                response = self.request("/Items", {"fixtureGeneration": "slow-first"})
                completed.append(("older", response, time.monotonic() - started))
            except Exception as error:
                failures.append(error)

        worker = threading.Thread(target=older_request)
        worker.start()
        other = self.user + "-other"
        try:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                requests = self.request("/qa/library-state")[1]["requests"]
                if any(row.get("delayMs") == 2200 and row["query"].get("fixturegeneration") == "slow-first" for row in requests):
                    break
                time.sleep(.005)
            else:
                self.fail("Older first page did not enter its captured delay")
            self.assertNotIn("status", requests[-1])
            self.control({"delayFirstMs": 0})
            completed.append(("newer", self.request("/Items", {"fixtureGeneration": "new-first"}), 0))
            self.assertEqual(self.page(user=other)["TotalRecordCount"], 144)
            other_state = self.request("/qa/library-state", user=other)[1]
            self.assertEqual(other_state["mode"], {})
            self.assertEqual(other_state["requests"][0]["delayMs"], 0)
        finally:
            worker.join(timeout=6)
            library.reset(other)
        self.assertFalse(worker.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual([label for label, _, _ in completed], ["newer", "older"])
        self.assertEqual([result[0] for _, result, _ in completed], [200, 503])
        self.assertGreaterEqual(completed[1][2], 2.1)
        self.assertEqual(len(completed[0][1][1]["Items"]), 60)
        receipts = self.request("/qa/library-state")[1]["requests"]
        self.assertEqual([(row["query"]["fixturegeneration"], row["delayMs"], row["status"]) for row in receipts], [
            ("slow-first", 2200, 503), ("new-first", 0, 200),
        ])

    def test_later_overlap_preserves_raw_offsets_and_is_counted_scoped_and_captured(self):
        query = {"includeItemTypes": "Movie,Series", "sortBy": "DateCreated,SortName", "sortOrder": "Descending,Ascending", "limit": 60}
        expected = self.page({**query, "limit": 500})["Items"]
        self.control({"reset": True, "overlapLater": 1})
        self.page({**query, "startIndex": 60, "limit": 0})
        self.page({**query, "startIndex": 999})
        self.assertEqual(self.request("/Items", {**query, "startIndex": 60, "sortBy": "Unknown"})[0], 400)
        self.page(path="/UserViews")
        self.page(path="/Genres")
        self.page(path="/Shows/library-title-003/Seasons")
        self.page({"startIndex": 1}, path="/Playlists/library-playlist-1/Items")
        self.assertEqual(self.request("/Items/Latest", {**query, "startIndex": 1})[0], 200)
        other = self.user + "-other"
        self.addCleanup(library.reset, other)
        self.assertEqual(self.page({**query, "startIndex": 60}, user=other)["Items"], expected[60:120])
        self.assertEqual(self.request("/qa/library-state", user=other)[1]["mode"], {})
        self.assertEqual(self.page({"startIndex": 60}, user="demo")["TotalRecordCount"], 75)
        self.assertEqual(self.request("/qa/library-state")[1]["mode"]["overlapLater"], 1)

        pages, raw_offset, unique = [], 0, set()
        for count in (60, 60, 24):
            page = self.page({**query, "startIndex": raw_offset})
            self.assertEqual(len(page["Items"]), count)
            self.assertEqual(page["TotalRecordCount"], 144)
            pages.append(page)
            raw_offset += len(page["Items"])
            unique.update(self.ids(page))
            if len(pages) == 2:
                self.assertEqual((raw_offset, len(unique)), (120, 119))
        self.assertEqual(pages[0]["Items"], expected[:60])
        self.assertEqual(pages[1]["Items"], [expected[59], *expected[61:120]])
        self.assertEqual(pages[2]["Items"], expected[120:])
        self.assertEqual((raw_offset, len(unique)), (144, 143))
        self.assertNotIn(expected[60]["Id"], unique)  # Deliberately malformed, not a completeness fixture.
        state = self.request("/qa/library-state")[1]
        successful = [row for row in state["requests"] if row["path"] == "/Items" and row.get("status") == 200 and row.get("count", 0) > 0]
        self.assertEqual([int(row["query"]["startindex"]) for row in successful], [0, 60, 120])
        self.assertEqual([row.get("overlapLater", False) for row in successful], [False, True, False])
        self.assertEqual(state["mode"]["overlapLater"], 0)
        self.assertEqual(self.page({**query, "startIndex": 60})["Items"], expected[60:120])

        filtered = {**query, "includeItemTypes": "Movie", "parentId": "library-films", "genreIds": "library-adventure", "isPlayed": "false", "limit": 5}
        filtered_rows = self.page({**filtered, "limit": 500})["Items"]
        self.assertEqual(len(filtered_rows), 28)
        self.control({"overlapLater": 2})
        self.assertEqual(self.page(filtered)["Items"], filtered_rows[:5])
        for offset, remaining in ((5, 1), (10, 0)):
            page = self.page({**filtered, "startIndex": offset})
            self.assertEqual(page["Items"], [filtered_rows[offset - 1], *filtered_rows[offset + 1:offset + 5]])
            self.assertEqual(page["TotalRecordCount"], 28)
            self.assertEqual(self.request("/qa/library-state")[1]["mode"]["overlapLater"], remaining)
        self.assertEqual(self.page({**filtered, "startIndex": 15})["Items"], filtered_rows[15:20])
        self.assertEqual(self.control({"overlapLater": 20})["overlapLater"], 20)
        self.control({"overlapLater": 0})
        self.assertEqual(self.page({**query, "startIndex": 60})["Items"], expected[60:120])

        self.control({"overlapLater": 1, "failLater": 1, "emptyLater": 1})
        self.assertEqual(self.request("/Items", {**query, "startIndex": 60})[0], 503)
        self.assertEqual(self.page({**query, "startIndex": 60})["Items"], [])
        self.control({"empty": True})
        self.assertEqual(self.page({**query, "startIndex": 60})["TotalRecordCount"], 0)
        self.assertEqual(self.request("/qa/library-state")[1]["mode"]["overlapLater"], 1)
        self.control({"empty": False})
        self.assertEqual(self.page({**query, "startIndex": 60})["Items"], pages[1]["Items"])
        self.assertEqual(self.request("/qa/library-state")[1]["mode"]["overlapLater"], 0)

        self.control({"overlapLater": 1, "delayLaterMs": 160})
        completed = []
        worker = threading.Thread(target=lambda: completed.append(("older", self.request("/Items", {**query, "startIndex": 60, "fixtureGeneration": "overlap-older"}))))
        worker.start()
        try:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                requests = self.request("/qa/library-state")[1]["requests"]
                if any(row.get("overlapLater") and row["query"].get("fixturegeneration") == "overlap-older" for row in requests):
                    break
                time.sleep(.005)
            else:
                self.fail("Older overlap request did not enter its captured delay")
            self.assertEqual(self.request("/qa/library-state")[1]["mode"]["overlapLater"], 0)
            self.control({"overlapLater": 0, "delayLaterMs": 0})
            completed.append(("newer", self.request("/Items", {**query, "startIndex": 60})))
        finally:
            worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        self.assertEqual([label for label, _ in completed], ["newer", "older"])
        self.assertEqual([result[0] for _, result in completed], [200, 200])
        self.assertEqual(completed[0][1][1]["Items"], expected[60:120])
        self.assertEqual(completed[1][1][1]["Items"], pages[1]["Items"])
        self.control({"overlapLater": 2}, user=other)
        self.control({"reset": True})
        self.assertEqual(self.request("/qa/library-state")[1]["mode"], {})
        self.assertEqual(self.request("/qa/library-state", user=other)[1]["mode"]["overlapLater"], 2)

    def test_option_picker_failure_and_retry_are_independent_of_pages_and_users(self):
        self.control({"failOptions": 1, "failFirst": 1})
        self.assertEqual(self.page(path="/UserViews")["TotalRecordCount"], 2)
        self.assertEqual(self.request("/Genres")[0], 503)
        self.assertEqual(self.page(path="/Genres")["TotalRecordCount"], 2)
        self.assertEqual(self.request("/Items")[0], 503)
        self.assertEqual(self.page()["TotalRecordCount"], 144)
        other = self.user + "-other"
        self.assertEqual(self.request("/Genres", user=other)[0], 200)
        library.reset(other)
        for invalid in ({"failOptions": True}, {"failOptions": 21}, {"delayOptionsMs": 2001}):
            self.assertEqual(self.request("/qa/library-control", body=invalid)[0], 400)

    def test_delayed_older_option_failure_finishes_after_new_generation_success(self):
        self.control({"failOptions": 1, "delayOptionsMs": 160})
        completed = []

        def older_request():
            completed.append(("older", self.request("/Genres", {"fixtureGeneration": "older"})[0]))

        worker = threading.Thread(target=older_request)
        worker.start()
        try:
            deadline = time.monotonic() + 2
            while time.monotonic() < deadline:
                receipts = self.request("/qa/library-state")[1]["requests"]
                if any(row.get("delayMs") == 160 and row["query"].get("fixturegeneration") == "older" for row in receipts):
                    break
                time.sleep(.005)
            else:
                self.fail("Older options request did not enter its captured delay")
            self.control({"delayOptionsMs": 0})
            completed.append(("newer", self.request("/Genres", {"fixtureGeneration": "newer"})[0]))
        finally:
            worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        self.assertEqual(completed, [("newer", 200), ("older", 503)])
        requests = self.request("/qa/library-state")[1]["requests"]
        self.assertEqual([(row["query"]["fixturegeneration"], row["status"]) for row in requests], [("older", 503), ("newer", 200)])
        self.assertEqual(self.page(path="/Genres")["TotalRecordCount"], 2)

    def test_group_categories_apply_search_genre_watch_and_favorite_filters(self):
        groups = [
            ("library-collection-1", "Library collection 1", "BoxSet", {"library-drama", "library-adventure"}, True),
            ("library-collection-2", "Library collection 2", "BoxSet", {"library-drama", "library-adventure"}, False),
            ("library-playlist-1", "Library ordered duplicates", "Playlist", {"library-drama"}, True),
        ]
        for category, search, genre, played, favorite in itertools.product(("BoxSet", "Playlist"), ("", "collection", "ordered", "absent"), ("", "library-drama", "library-adventure"), (None, False, True), (None, False, True)):
            query = {"includeItemTypes": category, "searchTerm": search, "genreIds": genre}
            if played is not None:
                query["isPlayed"] = str(played).lower()
            if favorite is not None:
                query["isFavorite"] = str(favorite).lower()
            expected = [key for key, name, kind, genres, is_favorite in groups if kind == category and search in name.lower() and (not genre or genre in genres) and played is not True and (favorite is None or is_favorite == favorite)]
            self.assertEqual(self.ids(self.page(query)), expected)

    def test_receipts_preserve_full_raw_query_and_duplicate_query_pairs_per_user(self):
        query = [("includeItemTypes", "Movie,Series"), ("sortBy", "ProductionYear,SortName"), ("sortOrder", "Descending,Ascending"), ("searchTerm", "North & sea"), ("startIndex", "60"), ("limit", "60"), ("fields", "Genres"), ("fields", "DateCreated")]
        self.page(query)
        state = self.request("/qa/library-state")[1]
        receipt = state["requests"][0]
        self.assertEqual(receipt["queryItems"], [list(pair) for pair in query])
        self.assertEqual(receipt["rawQuery"], urllib.parse.urlencode(query))
        self.assertEqual(receipt["query"]["sortby"], "ProductionYear,SortName")
        self.assertEqual(receipt["status"], 200)
        self.assertEqual(self.request("/qa/library-state", user=self.user + "-other")[1]["requests"], [])
        library.reset(self.user + "-other")

    def test_synthetic_favorite_and_watch_changes_are_user_scoped_and_do_not_touch_legacy_state(self):
        before = dict(STATE["favorites"]), dict(STATE["played"])
        self.assertEqual(self.request("/UserFavoriteItems/" + title(2), body={})[0], 204)
        self.assertEqual(self.request("/UserPlayedItems/" + title(2), body={}, method="DELETE")[0], 204)
        item = self.request("/Items/" + title(2))[1]
        self.assertTrue(item["UserData"]["IsFavorite"])
        self.assertFalse(item["UserData"]["Played"])
        other = self.request("/Items/" + title(2), user=self.user + "-other")[1]
        self.assertFalse(other["UserData"]["IsFavorite"])
        self.assertTrue(other["UserData"]["Played"])
        self.assertEqual((STATE["favorites"], STATE["played"]), before)
        library.reset(self.user + "-other")

    def test_bad_pagination_sort_and_boolean_queries_fail_without_killing_server(self):
        for query in ({"startIndex": -1}, {"limit": "invalid"}, {"limit": 501}, {"sortBy": "Unknown"}, {"sortOrder": "Sideways"}, {"sortBy": "SortName", "sortOrder": "Ascending,Descending"}, {"isPlayed": "maybe"}):
            self.assertEqual(self.request("/Items", query)[0], 400)
        self.assertEqual(self.page()["TotalRecordCount"], 144)
        self.assertEqual(self.page({"limit": 0})["Items"], [])
        self.assertEqual(self.page({"startIndex": 999})["TotalRecordCount"], 144)
        self.assertEqual(self.page({"startIndex": 999})["Items"], [])

    def test_convenience_modes_do_not_let_home_consume_library_failure(self):
        for user, query in (("library-first-error", {}), ("library-page-error", {"startIndex": 60})):
            library.reset(user)
            self.assertEqual(self.request("/Items/Latest", {"includeItemTypes": "Movie"}, user=user)[0], 200)
            self.assertEqual(self.request("/Items", query, user=user)[0], 503)
            self.assertEqual(self.request("/Items", query, user=user)[0], 200)
            library.reset(user)
        self.assertEqual(self.page(user="library-empty")["TotalRecordCount"], 0)
        library.reset("library-empty")


if __name__ == "__main__":
    unittest.main()
