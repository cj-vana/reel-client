"""Disposable browse-* state; no network, filesystem or household data access.

The server wrapper owns HTTP and records completed responses. Mutations model a
single synthetic user only; they do not claim Jellyfin descendant atomicity.
"""
import copy
import re
import threading
import time
import uuid
from dataclasses import dataclass

import library_contract


@dataclass
class Reply:
    status: int
    value: object = None
    delay_ms: int = 0
    hold: object = None


class Hold:
    def __init__(self, receipt):
        self.identifier = str(uuid.uuid4())
        self.event = threading.Event()
        self.deadline = time.monotonic() + 25
        self.receipt = receipt
        self.outcome = "waiting"


class Contract:
    def __init__(self):
        self.lock = threading.RLock()
        self.users = {}
        self.requests = []
        self.holds = {}
        self.sequence = 0

    @staticmethod
    def valid_user(user):
        return isinstance(user, str) and re.fullmatch(r"browse-[A-Za-z0-9_-]{1,100}", user) is not None

    def state(self, user):
        if not self.valid_user(user):
            raise ValueError("Only disposable browse-* users are admitted")
        return self.users.setdefault(user, self._fresh_state())

    @staticmethod
    def _fresh_state():
        return {"generation": str(uuid.uuid4()), "mode": {}, "played": {}, "favorites": {}, "phase": 0}

    def reset(self, user):
        with self.lock:
            self.state(user)
            for key, hold in list(self.holds.items()):
                if key[0] == user:
                    hold.outcome = "canceled"
                    hold.receipt["holdOutcome"] = "canceled"
                    hold.event.set()
                    del self.holds[key]
            self.users[user] = self._fresh_state()

    def snapshot(self, user):
        with self.lock:
            result = copy.deepcopy(self.state(user))
            result["requests"] = copy.deepcopy([r for r in self.requests if r["user"] == user])
            return result

    def configure(self, user, body):
        if not isinstance(body, dict):
            raise ValueError("Control must be an object")
        boolean = {"reset", "empty", "removeLibrary", "removeGenre", "holdItems", "holdOptions", "holdGenres"}
        integer = {"failItems", "failAppend", "failLibraries", "failGenres", "failReadback", "failMutation", "acceptFailedMutation", "overlapLater", "phase"}
        modes = {"readbackMode": {"normal", "wrongID", "unknown", "container"}}
        targets = {"holdReadbackItem", "holdMutationItem"}
        if set(body) - boolean - integer - set(modes) - targets - {"release"}:
            raise ValueError("Unknown browse control")
        if "release" in body:
            if set(body) != {"release"} or not isinstance(body["release"], str):
                raise ValueError("Release takes only its hold UUID")
            with self.lock:
                hold = self.holds.get((user, body["release"]))
                if hold is None or hold.outcome != "waiting" or time.monotonic() >= hold.deadline:
                    raise ValueError("No live hold belongs to this user and UUID")
                hold.outcome = "released"
                hold.receipt["holdOutcome"] = "released"
                hold.event.set()
                del self.holds[(user, body["release"])]
                return {"released": body["release"]}
        for key, value in body.items():
            if key in boolean and type(value) is not bool:
                raise ValueError("Expected a boolean")
            if key in integer and (type(value) is not int or not 0 <= value <= 100):
                raise ValueError("Control integer is out of bounds")
            if key in modes and (type(value) is not str or value not in modes[key]):
                raise ValueError("Unknown readback mode")
            if key in targets and (type(value) is not str or re.fullmatch(r"[A-Za-z0-9_-]{0,256}", value) is None):
                raise ValueError("Invalid hold target")
        with self.lock:
            if body.get("reset"):
                self.reset(user)
            state = self.state(user)
            if any(body.get(key) for key in ("holdItems", "holdOptions", "holdGenres")) and any(key[0] == user for key in self.holds):
                raise ValueError("Release the existing user hold before arming another")
            if "phase" in body:
                state["phase"] = body["phase"]
            state["mode"].update({k: v for k, v in body.items() if k not in ("reset", "phase")})
            return copy.deepcopy(state["mode"])

    def _take(self, state, key):
        value = state["mode"].get(key, 0)
        if value:
            state["mode"][key] = value - 1
            return True
        return False

    def _rows(self, user):
        state = self.state(user)
        main = library_contract.catalog(state=state)
        episodes = library_contract._episodes(main)
        for row in episodes:
            row["UserData"]["Played"] = state["played"].get(row["Id"], row["UserData"]["Played"])
            row["UserData"]["IsFavorite"] = state["favorites"].get(row["Id"], row["UserData"]["IsFavorite"])
            row["ParentId"] = f"browse-season-{row['SeriesId'].rsplit('-', 1)[1]}-{1 if row['IndexNumber'] <= 2 else 2}"
        groups = library_contract._groups()
        seasons = []
        for parent in (3, 6, 9):
            for number in (1, 2):
                seasons.append({"Id": f"browse-season-{parent:03d}-{number}", "Name": f"Season {number}", "Type": "Season", "IsFolder": True,
                                "SeriesId": f"library-title-{parent:03d}", "IndexNumber": number, "UserData": {"Played": False}})
        # A generic collection can contain every media type. These records let the
        # actual Detail control prove unknown refusal and music/photo scope safety.
        special = [{"Id": "browse-" + kind.lower(), "Name": "Synthetic " + kind, "Type": kind,
                    "IsFolder": False, "UserData": {"Played": True}} for kind in ("MusicAlbum", "MusicArtist", "PhotoAlbum", "Recording", "Unknown")]
        all_rows = main + episodes + groups + seasons + special
        for row in all_rows:
            if row["Type"] in ("Series", "Season", "BoxSet", "Playlist", "MusicAlbum", "MusicArtist", "PhotoAlbum"):
                descendants = self._descendants(row["Id"], main, episodes)
                row["UserData"]["UnplayedItemCount"] = sum(not child["UserData"].get("Played", False) for child in descendants)
                row["UserData"]["Played"] = state["played"].get(row["Id"], False)
            row["UserData"]["IsFavorite"] = state["favorites"].get(row["Id"], row["UserData"].get("IsFavorite", False))
        for row in main:
            if row["Type"] == "Movie":
                first = row["MediaSources"][0]
                first["MediaStreams"].append({"Index": 2, "Type": "Subtitle", "Codec": "vtt", "DisplayTitle": "Synthetic subtitle"})
                row["MediaSources"].append({"Id": row["Id"] + "-alternate", "Name": "Synthetic alternate", "Container": "mp4",
                                            "MediaStreams": [{"Index": 0, "Type": "Video", "Codec": "h264"}, {"Index": 4, "Type": "Audio", "Codec": "aac", "DisplayTitle": "Alternate synthetic audio"}, {"Index": 5, "Type": "Subtitle", "Codec": "vtt", "DisplayTitle": "Alternate synthetic subtitle"}]})
        return all_rows

    @staticmethod
    def _descendants(identifier, main, episodes):
        row = next((row for row in main if row["Id"] == identifier), None)
        if row and row["Type"] == "Series":
            return [e for e in episodes if e["SeriesId"] == identifier]
        if identifier.startswith("browse-season-"):
            return [e for e in episodes if e["ParentId"] == identifier]
        if identifier in library_contract._COLLECTIONS or identifier == "library-playlist-1":
            numbers = library_contract._COLLECTIONS.get(identifier, library_contract._PLAYLIST)
            children = []
            for number in numbers:
                child = next(row for row in main if row["Id"] == f"library-title-{number:03d}")
                children.extend([e for e in episodes if e["SeriesId"] == child["Id"]] if child["Type"] == "Series" else [child])
            return list({child["Id"]: child for child in children}.values())
        return []

    def begin(self, user, method, path, query):
        with self.lock:
            state = self.state(user)
            self.sequence += 1
            receipt = {"sequence": self.sequence, "stateGeneration": state["generation"], "user": user, "method": method, "path": path, "query": copy.deepcopy(query), "started": time.monotonic(), "completed": False}
            self.requests.append(receipt)
            return receipt

    def complete(self, receipt, status, write_error=None):
        with self.lock:
            receipt.update(status=status, completed=True, finished=time.monotonic())
            if write_error:
                receipt["responseWriteError"] = write_error

    def wait(self, user, reply):
        hold = reply.hold
        if hold is not None:
            hold.event.wait(max(0, hold.deadline - time.monotonic()))
            with self.lock:
                if hold.outcome == "waiting":
                    hold.outcome = "timedOut"
                    hold.receipt["holdOutcome"] = "timedOut"
                if self.holds.get((user, hold.identifier)) is hold:
                    del self.holds[(user, hold.identifier)]

    def _hold_reply(self, user, reply, receipt, role):
        if sum(key[0] == user for key in self.holds) >= 8:
            raise ValueError("Too many pending synthetic holds")
        hold = Hold(receipt)
        self.holds[(user, hold.identifier)] = hold
        receipt.update(holdID=hold.identifier, holdRole=role, holdOutcome="waiting", holdDeadlineSeconds=25)
        reply.hold = hold
        return reply

    def dispatch(self, user, method, path, query, body, receipt):
        with self.lock:
            state = self.users.get(user)
            if state is None or receipt.get("user") != user or receipt.get("stateGeneration") != state["generation"]:
                receipt["refusedStaleGeneration"] = True
                return Reply(409, {"error": "Registered request belongs to a replaced synthetic user generation"})
            if path == "/qa/browse-state" and method == "GET":
                return Reply(200, self.snapshot(user))
            if path == "/qa/browse-control" and method == "POST":
                return Reply(200, self.configure(user, body))
            if path == "/Users/Me" and method == "GET":
                return Reply(200, {"Id": user, "Name": user, "Policy": {"IsDisabled": False, "EnableMediaPlayback": True, "EnableContentDownloading": False, "EnableSharedDeviceControl": False}})
            if path.startswith("/Sessions/Playing"):
                return Reply(409, {"error": "History reports are forbidden in browse-only QA"})
            if path == "/Sessions/Logout" and method == "POST":
                return Reply(204)
            rows = self._rows(user)
            by_id = {row["Id"]: row for row in rows}
            mutation = re.fullmatch(r"/User(Played|Favorite)Items/([A-Za-z0-9_-]{1,256})", path)
            if mutation and method in ("POST", "DELETE"):
                item = by_id.get(mutation[2])
                if item is None:
                    return Reply(404)
                failed = self._take(state, "failMutation")
                accepted = not failed or self._take(state, "acceptFailedMutation")
                targets = [item]
                if mutation[1] == "Played":
                    targets += self._descendants(item["Id"], [r for r in rows if r["Id"].startswith("library-title-")], [r for r in rows if r["Type"] == "Episode"])
                if accepted:
                    table = state["played" if mutation[1] == "Played" else "favorites"]
                    for target in targets:
                        table[target["Id"]] = method == "POST"
                receipt.update(accepted=accepted, desired=method == "POST", affectedIDs=sorted({r["Id"] for r in targets}) if accepted else [])
                reply = Reply(503 if failed else 200, {"error": "Synthetic uncertain transport result"} if failed else {"Played": method == "POST"})
                if state["mode"].get("holdMutationItem") == item["Id"]:
                    state["mode"]["holdMutationItem"] = ""
                    return self._hold_reply(user, reply, receipt, "mutation")
                return reply
            if method != "GET":
                return Reply(404)
            if path.startswith("/Items/") and path.endswith("/Similar"):
                return Reply(200, {"Items": [], "TotalRecordCount": 0})
            if path.startswith("/Items/"):
                if self._take(state, "failReadback"):
                    return Reply(503, {"error": "Synthetic item read unavailable"})
                item = copy.deepcopy(by_id.get(path.rsplit("/", 1)[-1]))
                if item is None:
                    return Reply(404)
                mode = state["mode"].get("readbackMode", "normal")
                if mode == "wrongID":
                    item["Id"] = "browse-other"
                elif mode == "unknown":
                    item["Type"] = "Unknown"; item["IsFolder"] = False
                elif mode == "container":
                    item["Type"] = "MusicAlbum"; item["IsFolder"] = False
                reply = Reply(200, item)
                if state["mode"].get("holdReadbackItem") == path.rsplit("/", 1)[-1]:
                    state["mode"]["holdReadbackItem"] = ""
                    return self._hold_reply(user, reply, receipt, "readback")
                return reply
            start, limit = int(query.get("startindex", "0")), int(query.get("limit", "60"))
            if start < 0 or not 1 <= limit <= 200:
                raise ValueError("Fixture paging is out of bounds")
            hold_key = None
            if path == "/UserViews":
                if "startindex" in query or "limit" in query:
                    raise ValueError("UserViews does not support paging")
                if self._take(state, "failLibraries"):
                    return Reply(503, {"error": "Synthetic library options unavailable"})
                result = [{"Id": key, "Name": name, "Type": "CollectionFolder"} for key, name in (("library-films", "Films"), ("library-shows", "Shows"))]
                if state["mode"].get("removeLibrary"):
                    result = result[:1]
                hold_key = "holdOptions"
            elif path == "/Genres":
                if self._take(state, "failGenres"):
                    return Reply(503, {"error": "Synthetic genre options unavailable"})
                result = [{"Id": key, "Name": name, "Type": "Genre"} for key, name in (("library-adventure", "Adventure"), ("library-drama", "Drama"))]
                if state["mode"].get("removeGenre"):
                    result = result[:1]
                hold_key = "holdGenres"
            elif re.fullmatch(r"/Shows/library-title-\d{3}/Seasons", path):
                if "startindex" in query or "limit" in query:
                    raise ValueError("Seasons does not support paging")
                result = [r for r in rows if r["Type"] == "Season" and r["SeriesId"] == path.split("/")[2]]
            elif re.fullmatch(r"/Shows/library-title-\d{3}/Episodes", path):
                result = [r for r in rows if r["Type"] == "Episode" and r["SeriesId"] == path.split("/")[2] and (not query.get("seasonid") or r["ParentId"] == query["seasonid"])]
            elif path in ("/UserItems/Resume", "/Shows/NextUp"):
                result = [copy.deepcopy(r) for r in rows if r["Type"] == "Episode" and not r["UserData"]["Played"]][:2 if path.endswith("Resume") else 1]
                if path.endswith("Resume"):
                    for row in result:
                        row["UserData"]["PlaybackPositionTicks"] = 50_000_000
            elif path == "/Playlists/library-playlist-1/Items":
                unsupported = set(query) - {"userid", "fields", "enableuserdata", "startindex", "limit", "enabletotalrecordcount"}
                if unsupported:
                    raise ValueError("Playlist sequence does not admit catalogue predicates")
                result = [{**copy.deepcopy(by_id[f"library-title-{number:03d}"]), "PlaylistItemId": f"browse-entry-{index:03d}"} for index, number in enumerate(library_contract._PLAYLIST, 1)]
            elif path in ("/Items", "/Items/Latest"):
                if self._take(state, "failAppend" if start else "failItems"):
                    return Reply(503, {"error": "Synthetic page unavailable"})
                parent = query.get("parentid")
                result = rows if not parent else [r for r in rows if r.get("ParentId") == parent]
                if parent in library_contract._COLLECTIONS:
                    result = [by_id[f"library-title-{number:03d}"] for number in library_contract._COLLECTIONS[parent]] + [r for r in rows if r["Id"].startswith("browse-") and r["Type"] != "Season"]
                result = library_contract._filter(result, query)
                effective = query
                if path.endswith("Latest"):
                    effective = {**query, "sortby": "DateCreated,SortName", "sortorder": "Descending,Ascending"}
                result = library_contract._sort(result, effective)
                if state["mode"].get("empty"):
                    result = []
                hold_key = "holdItems" if path == "/Items" and limit != 18 else None
            else:
                return Reply(404)
            total = len(result)
            page = copy.deepcopy(result[start:start + limit])
            if path == "/Items" and start and page and self._take(state, "overlapLater"):
                page[0] = copy.deepcopy(result[start - 1])
                receipt["overlapLater"] = True
            receipt.update(total=total, returnedIDs=[r["Id"] for r in page])
            reply = Reply(200, page if path.endswith("Latest") else {"Items": page, "TotalRecordCount": total, "StartIndex": start})
            if hold_key and state["mode"].get(hold_key):
                state["mode"][hold_key] = False
                self._hold_reply(user, reply, receipt, hold_key)
            return reply
