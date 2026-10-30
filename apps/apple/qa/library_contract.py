"""Deterministic library-* users for loopback filtering/pagination regression tests.

This module is deliberately independent of fixture_server.catalog and STATE.
Only fixture_server's authenticated library-* dispatch reaches these routes.
"""
import copy
import re
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from urllib.parse import parse_qsl, urlsplit

_LOCK = threading.RLock()
_USERS = {}
_HOLDS = {}
_FAMILIES = ("Amber", "Cedar", "Harbor", "Meadow", "North", "Willow")
_LIBRARIES = {"library-films": "Movie", "library-shows": "Series"}
_GENRES = {"library-drama": "Drama", "library-adventure": "Adventure"}
_COLLECTIONS = {
    "library-collection-1": (71, 2, 139, 18, 4, 87, 54, 23),
    "library-collection-2": (5, 21, 48, 97, 140, 12),
}
_PLAYLIST = (71, 2, 71, 139, 18, 4, 87, 2)


class _FirstPageHold:
    TIMEOUT_SECONDS = 60

    def __init__(self, user, receipt):
        self.user = user
        self.identifier = str(uuid.uuid4())
        self.receipt = receipt
        self.event = threading.Event()
        self.deadline = time.monotonic() + self.TIMEOUT_SECONDS
        self.outcome = "waiting"


class _ControlError(ValueError):
    def __init__(self, message, status):
        super().__init__(message)
        self.status = status


def _cancel_holds_locked(user=None):
    for key, hold in list(_HOLDS.items()):
        if user is None or key[0] == user:
            hold.outcome = "canceled"
            hold.receipt["holdState"] = "canceled"
            del _HOLDS[key]
            hold.event.set()


def _release_first(user, identifier):
    if type(identifier) is not str or not re.fullmatch(r"[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}", identifier):
        raise ValueError("releaseFirst must be a canonical UUIDv4")
    with _LOCK:
        hold = _HOLDS.get((user, identifier))
        if hold is None or hold.outcome != "waiting" or time.monotonic() >= hold.deadline:
            # In particular, do not call _state for an unknown/cross-user ID.
            raise _ControlError("Unknown first-page hold", 404)
        hold.outcome = "released"
        hold.receipt["holdState"] = "released"
        del _HOLDS[(user, identifier)]
        hold.event.set()
    return {"releasedFirst": identifier}


def _wait_first(hold):
    hold.event.wait(max(0, hold.deadline - time.monotonic()))
    with _LOCK:
        if hold.outcome == "waiting":
            hold.outcome = "timedOut"
            hold.receipt["holdState"] = "timedOut"
        key = (hold.user, hold.identifier)
        if _HOLDS.get(key) is hold:
            del _HOLDS[key]


def _respond_page(handler, receipt, value, status, hold):
    try:
        handler.respond(value, status=status)
    except (BrokenPipeError, ConnectionResetError):
        if hold is None:
            raise
        with _LOCK:
            receipt["responseWriteFailed"] = True


def _episode_parent(index):
    return (3, 6, 9)[(index - 1) // 4]


def _episode_created(index):
    return (datetime(2025, 6, 1, tzinfo=timezone.utc) + timedelta(days=index * 5 % 13)).isoformat().replace("+00:00", "Z")


def reset(user=None):
    with _LOCK:
        _cancel_holds_locked(user)
        if user is None:
            _USERS.clear()
        else:
            _USERS.pop(user, None)


def _state(user):
    if user not in _USERS:
        defaults = {
            "library-empty": {"empty": True},
            "library-slow": {"delayMs": 700},
            "library-first-error": {"failFirst": 1},
            "library-page-error": {"failLater": 1},
            "library-episode-error": {"failEpisodeFeed": 1},
        }
        _USERS[user] = {"mode": copy.deepcopy(defaults.get(user, {})), "requests": [], "favorites": {}, "played": {}}
    return _USERS[user]


def catalog(user="library-demo", state=None):
    """144 main titles; independent name/year/date permutations and deliberate ties."""
    with _LOCK:
        state = _state(user) if state is None else state
        favorites, played = copy.deepcopy(state["favorites"]), copy.deepcopy(state["played"])
    items = []
    for index in range(1, 145):
        key = f"library-title-{index:03d}"
        group = index * 37 % 48
        name = f"{_FAMILIES[group % 6]} Story {group:02d}"
        series = index % 3 == 0
        genres = ["Drama", "Adventure"] if index % 4 == 0 else ["Adventure"] if index % 2 == 0 else ["Drama"]
        created = datetime(2025, 1, 1, tzinfo=timezone.utc) + timedelta(days=index * 17 % 40)
        items.append({
            "Id": key, "Name": name, "SortName": name, "Type": "Series" if series else "Movie", "MediaType": "Video",
            "ParentId": "library-shows" if series else "library-films", "ProductionYear": 1990 + index * 7 % 12,
            "DateCreated": created.isoformat().replace("+00:00", "Z"), "Genres": genres,
            "GenreItems": [{"Id": identifier, "Name": title} for identifier, title in _GENRES.items() if title in genres],
            "Overview": f"Synthetic library record {index:03d}. No household media or watch history.",
            "RunTimeTicks": 240_000_000, "ImageTags": {"Primary": "fixture-v1"}, "BackdropImageTags": ["fixture-v1"],
            "UserData": {"Played": played.get(key, index % 5 in (0, 2)), "IsFavorite": favorites.get(key, index % 7 in (0, 1)), "PlaybackPositionTicks": 0},
            "MediaSources": [{"Id": key + "-source", "Name": "Synthetic original", "Container": "mp4", "MediaStreams": [{"Index": 0, "Type": "Video", "Codec": "h264"}, {"Index": 1, "Type": "Audio", "Codec": "aac", "DisplayTitle": "Synthetic AAC stereo"}]}],
        })
        if series:
            episode_dates = [_episode_created(number) for number in range(1, 13) if _episode_parent(number) == index]
            items[-1]["DateLastMediaAdded"] = max(episode_dates, default=items[-1]["DateCreated"])
    return items


def _groups():
    rows = [{"Id": key, "Name": f"Library collection {index}", "SortName": f"Library collection {index}", "Type": "BoxSet", "Genres": ["Drama", "Adventure"], "GenreItems": [{"Id": key, "Name": value} for key, value in _GENRES.items()], "DateCreated": f"2025-03-0{index}T00:00:00Z", "ProductionYear": 2024 + index, "ImageTags": {"Primary": "fixture-v1"}, "UserData": {"Played": False, "IsFavorite": index == 1}} for index, key in enumerate(_COLLECTIONS, 1)]
    rows.append({"Id": "library-playlist-1", "Name": "Library ordered duplicates", "SortName": "Library ordered duplicates", "Type": "Playlist", "MediaType": "Video", "Genres": ["Drama"], "GenreItems": [{"Id": "library-drama", "Name": "Drama"}], "DateCreated": "2025-03-03T00:00:00Z", "ProductionYear": 2026, "ImageTags": {"Primary": "fixture-v1"}, "UserData": {"Played": False, "IsFavorite": True}})
    return rows


def _episodes(items):
    parents = {row["Id"]: row for row in items}
    rows = []
    for index in range(1, 13):
        parent = parents[f"library-title-{_episode_parent(index):03d}"]
        rows.append({**copy.deepcopy(parent), "Id": f"library-episode-{index:02d}", "Name": f"North Episode {index:02d}", "SortName": f"North Episode {index:02d}", "Type": "Episode", "ParentId": "library-season-1", "SeriesId": parent["Id"], "SeriesName": parent["Name"], "DateCreated": _episode_created(index), "IndexNumber": (index - 1) % 4 + 1, "ParentIndexNumber": 1, "UserData": {"Played": index % 2 == 0, "IsFavorite": index % 3 == 0, "PlaybackPositionTicks": 0}})
    return rows


def _array(query, key):
    value = query.get(key, "")
    return [part.strip() for part in value.split(",") if part.strip()]


def _boolean(query, key):
    value = query.get(key)
    if value is None:
        return None
    if value.lower() not in ("true", "false"):
        raise ValueError(key + " must be true or false")
    return value.lower() == "true"


def _filter(rows, query):
    types = set(_array(query, "includeitemtypes"))
    if types:
        rows = [row for row in rows if row["Type"] in types]
    search = query.get("searchterm", "").strip().casefold()
    if search:
        rows = [row for row in rows if search in (row["Name"] + " " + row.get("SeriesName", "")).casefold()]
    genres = set(_array(query, "genreids"))
    names = set(query.get("genres", "").split("|")) - {""}
    if genres:
        rows = [row for row in rows if genres.intersection(genre["Id"] for genre in row.get("GenreItems", []))]
    if names:
        rows = [row for row in rows if names.intersection(row.get("Genres", []))]
    played, favorite = _boolean(query, "isplayed"), _boolean(query, "isfavorite")
    filters = set(_array(query, "filters"))
    rows = [row for row in rows if (played is None or row["UserData"].get("Played", False) == played)
            and (favorite is None or row["UserData"].get("IsFavorite", False) == favorite)
            and ("IsPlayed" not in filters or row["UserData"].get("Played", False))
            and ("IsUnplayed" not in filters or not row["UserData"].get("Played", False))
            and ("IsFavorite" not in filters or row["UserData"].get("IsFavorite", False))]
    return rows


def _sort(rows, query):
    keys = _array(query, "sortby") or ["SortName"]
    orders = _array(query, "sortorder")
    fields = {"SortName": lambda row: row.get("SortName", row["Name"]).casefold(), "Name": lambda row: row["Name"].casefold(), "ProductionYear": lambda row: row.get("ProductionYear", 0), "DateCreated": lambda row: row.get("DateCreated", ""), "DateLastContentAdded": lambda row: row.get("DateLastMediaAdded", row.get("DateCreated", "")), "Id": lambda row: row["Id"]}
    if any(key not in fields for key in keys) or any(order not in ("Ascending", "Descending") for order in orders) or len(orders) > len(keys):
        raise ValueError("Unsupported sort field or direction")
    # Jellyfin RequestHelpers.GetOrderBy repeats the first requested direction
    # for fields without their own direction, defaulting to Ascending.
    fallback = orders[0] if orders else "Ascending"
    directions = [orders[index] if index < len(orders) else fallback for index in range(len(keys))]
    rows = sorted(rows, key=lambda row: row["Id"])
    for key, direction in reversed(list(zip(keys, directions))):
        rows.sort(key=fields[key], reverse=direction == "Descending")
    return rows


def _pagination(query):
    start, limit = int(query.get("startindex", "0")), int(query.get("limit", "60"))
    if start < 0 or not 0 <= limit <= 500:
        raise ValueError("Pagination is out of fixture bounds")
    return start, limit


def _configure(user, body):
    if not isinstance(body, dict):
        raise ValueError("Expected an object")
    if "releaseFirst" in body:
        if set(body) != {"releaseFirst"}:
            raise ValueError("releaseFirst cannot be mixed with other controls")
        return _release_first(user, body["releaseFirst"])
    integers = {"delayMs": (0, 2000), "delayFirstMs": (0, 10000), "delayLaterMs": (0, 2000), "delayOptionsMs": (0, 2000), "delayEpisodeFeedMs": (0, 10000), "failOptions": (0, 20), "failMovieLatest": (0, 20), "failSeriesLatest": (0, 20), "failEpisodeFeed": (0, 20), "failFirst": (0, 20), "failLater": (0, 20), "emptyFirst": (0, 20), "emptyLater": (0, 20), "overlapLater": (0, 20)}
    booleans = {"reset", "empty", "holdFirst"}
    if set(body) - set(integers) - booleans:
        raise ValueError("Unknown library control")
    for key, value in body.items():
        if key in booleans and type(value) is not bool:
            raise ValueError("Expected a boolean")
        if key in integers and (type(value) is not int or not integers[key][0] <= value <= integers[key][1]):
            raise ValueError("Control is out of fixture bounds")
    with _LOCK:
        if body.get("holdFirst") and not body.get("reset") and any(key[0] == user for key in _HOLDS):
            raise ValueError("Release or reset the active first-page hold before rearming")
        if body.get("reset"):
            _cancel_holds_locked(user)
            _USERS[user] = {"mode": {}, "requests": [], "favorites": {}, "played": {}}
        state = _state(user)
        state["mode"].update({key: value for key, value in body.items() if key != "reset"})
        return copy.deepcopy(state["mode"])


def _receipt(handler, user, path, query):
    raw_query = urlsplit(handler.path).query
    pairs = parse_qsl(raw_query, keep_blank_values=True)
    receipt = {"method": "GET", "path": path, "query": copy.deepcopy(query), "queryItems": [list(pair) for pair in pairs], "rawQuery": raw_query}
    with _LOCK:
        state = _state(user)
        state["requests"].append(receipt)
    return receipt, state


def handle(handler, method, path, query, user, body=None):
    if not user or not user.startswith("library-"):
        return False
    if path == "/qa/library-state":
        if method != "GET":
            handler.respond(status=405)
        else:
            with _LOCK:
                value = copy.deepcopy(_state(user))
            handler.respond(value)
        return True
    if path == "/qa/library-control":
        try:
            if method != "POST":
                handler.respond(status=405)
            else:
                handler.respond(_configure(user, body))
        except _ControlError as error:
            handler.respond({"error": str(error)}, status=error.status)
        except ValueError as error:
            handler.respond({"error": str(error)}, status=400)
        return True
    if method != "GET":
        match = re.fullmatch(r"/User(Favorite|Played)Items/(library-title-\d{3})", path)
        if match and method in ("POST", "DELETE"):
            if match[2] not in {row["Id"] for row in catalog(user)}:
                handler.respond(status=404)
            else:
                with _LOCK:
                    _state(user)["favorites" if match[1] == "Favorite" else "played"][match[2]] = method == "POST"
                handler.respond(status=204)
            return True
        return False
    list_routes = {"/Items", "/Items/Latest", "/UserViews", "/Genres", "/UserItems/Resume", "/Shows/NextUp"}
    playlist = re.fullmatch(r"/Playlists/(library-playlist-1)/Items", path)
    detail = re.fullmatch(r"/Items/(library-[^/]+)", path)
    seasons = re.fullmatch(r"/Shows/library-title-\d{3}/Seasons", path)
    episodes = re.fullmatch(r"/Shows/library-title-\d{3}/Episodes", path)
    if path not in list_routes and not (playlist or detail or seasons or episodes):
        return False
    receipt, request_state = _receipt(handler, user, path, query)
    try:
        start, limit = _pagination(query)
        items = catalog(user, state=request_state)
        by_id = {row["Id"]: row for row in items}
        if path == "/UserViews":
            rows = [{"Id": key, "Name": "Films" if kind == "Movie" else "Shows", "Type": "CollectionFolder", "CollectionType": "movies" if kind == "Movie" else "tvshows"} for key, kind in _LIBRARIES.items()]
        elif path == "/Genres":
            rows = [{"Id": key, "Name": name, "Type": "Genre"} for key, name in _GENRES.items()]
        elif playlist:
            # GetPlaylistItems exposes pagination, not catalog search/filter/sort.
            rows = [{**copy.deepcopy(by_id[f"library-title-{number:03d}"]), "PlaylistItemId": f"library-entry-{index:03d}"} for index, number in enumerate(_PLAYLIST, 1)]
        elif detail:
            rows = [row for row in items + _groups() + _episodes(items) if row["Id"] == detail[1]]
            value = rows[0] if rows else None
            receipt.update(status=200 if value else 404, count=len(rows))
            handler.respond(value, status=receipt["status"])
            return True
        elif seasons:
            rows = [{"Id": "library-season-1", "Name": "Season 1", "Type": "Season", "IndexNumber": 1}]
        elif episodes:
            rows = [row for row in _episodes(items) if row["SeriesId"] == path.split("/")[2]]
        elif path in ("/UserItems/Resume", "/Shows/NextUp"):
            rows = []  # Keep Home deterministic without manufacturing watch history.
        else:
            parent = query.get("parentid")
            if parent in _COLLECTIONS:
                rows = [by_id[f"library-title-{number:03d}"] for number in _COLLECTIONS[parent]]
            elif parent in _LIBRARIES:
                rows = [row for row in items if row["Type"] == _LIBRARIES[parent]]
                if parent == "library-shows" and "Episode" in _array(query, "includeitemtypes"):
                    rows += _episodes(items)
            elif parent:
                rows = []
            else:
                rows = items + _groups() + _episodes(items)
            effective = {"includeitemtypes": "Movie,Series", **query}
            rows = _filter(rows, effective)
            if path == "/Items/Latest":
                effective = {**effective, "sortby": "DateCreated,SortName", "sortorder": "Descending,Ascending"}
            rows = _sort(rows, effective)
        total = len(rows)
        episode_feed = path == "/Items" and query.get("includeitemtypes") == "Episode" and limit == 18
        # Page counters affect /Items only. Options have a separate failure
        # counter, so Home and metadata cannot consume Library page failures.
        hold = None
        with _LOCK:
            mode = request_state["mode"]
            empty = mode.get("empty", False)
            phase = "First" if start == 0 else "Later"
            latest_type = query.get("includeitemtypes") if path == "/Items/Latest" else None
            failure_key = "fail" + latest_type + "Latest" if latest_type in ("Movie", "Series") else "failOptions" if path == "/Genres" else "failEpisodeFeed" if episode_feed else "fail" + phase
            failed = (path in ("/Items", "/Genres") or latest_type in ("Movie", "Series")) and mode.get(failure_key, 0) > 0
            empty_page = path == "/Items" and not episode_feed and mode.get("empty" + phase, 0) > 0
            overlap_page = (path == "/Items" and 0 < start < total and limit > 0
                            and not failed and not empty_page and not empty and mode.get("overlapLater", 0) > 0)
            if failed:
                mode[failure_key] -= 1
            elif empty_page:
                mode["empty" + phase] -= 1
            elif overlap_page:
                mode["overlapLater"] -= 1
            delay = (mode.get("delayEpisodeFeedMs", 0) if episode_feed else (mode.get("delayMs", 0) + mode.get("delay" + phase + "Ms", 0)) if path == "/Items" else mode.get("delayOptionsMs", 0) if path in ("/UserViews", "/Genres") else 0) / 1000
            receipt.update(plannedStatus=503 if failed else 200, delayMs=round(delay * 1000))
            if overlap_page:
                receipt["overlapLater"] = True
            if _USERS.get(user) is request_state and path == "/Items" and start == 0 and limit > 0 and not episode_feed and mode.get("holdFirst", False):
                hold = _FirstPageHold(user, receipt)
                mode["holdFirst"] = False
                _HOLDS[(user, hold.identifier)] = hold
                receipt.update(heldRequestID=hold.identifier, holdState="waiting", holdTimeoutMs=round(hold.TIMEOUT_SECONDS * 1000))
        if hold is not None:
            _wait_first(hold)
        if delay:
            time.sleep(delay)
        if failed:
            with _LOCK:
                receipt.update(status=503, total=total, count=0)
            _respond_page(handler, receipt, {"error": "Synthetic library page unavailable"}, 503, hold)
            return True
        if empty and path in ("/Items", "/Items/Latest"):
            rows, total = [], 0
        page = [] if empty_page else rows[start:start + limit]
        if overlap_page:
            # Repeat a raw boundary record without shifting offsets or the total.
            page[0] = rows[start - 1]
        with _LOCK:
            receipt.update(status=200, total=total, count=len(page))
        _respond_page(handler, receipt, page if path == "/Items/Latest" else {"Items": page, "TotalRecordCount": total, "StartIndex": start}, 200, hold)
    except (ValueError, TypeError) as error:
        receipt.update(status=400, count=0)
        handler.respond({"error": str(error)}, status=400)
    return True
