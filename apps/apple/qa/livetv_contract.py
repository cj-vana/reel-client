"""Loopback fixture routes for guide and DVR; never contacts a real Jellyfin server.

Integration in fixture_server.py after its authentication checks:
  if livetv_contract.handle(self, "GET", path, q, user): return
  if livetv_contract.handle(self, "POST", path, {}, user, body): return
  if livetv_contract.handle(self, "DELETE", path, {}, self.user()): return
Merge user_policy(user) into GET /Users/Me's Policy. Call reset() from /qa/reset.
Include snapshot() in /qa/state if receipt assertions are wanted.
"""
import copy
import threading
import time
from datetime import datetime, timedelta, timezone

_LOCK = threading.RLock()
_USERS = {}
_MODES = {}


def reset():
    with _LOCK:
        _USERS.clear()
        _MODES.clear()


def user_policy(user):
    return {"EnableLiveTvAccess": user != "notv", "EnableLiveTvManagement": user not in ("notv", "readonlytv")}


def _state(user):
    return _USERS.setdefault(user, {"timers": {}, "series": {}, "timerCount": 0, "seriesCount": 0, "events": [], "requests": []})


def snapshot():
    with _LOCK:
        return {user: {**copy.deepcopy(state), "mode": copy.deepcopy(_MODES.get(user, {}))} for user, state in _USERS.items()}


def _configure(handler, user, body):
    if not user:
        handler.respond(status=401)
        return
    values = {} if body is None else body
    if not isinstance(values, dict):
        handler.respond(status=400); return
    booleans = {"reset", "emptyChannels", "emptyPrograms", "emptyRecordings"}
    integers = {"delayMs": (0, 5000), "failGet": (0, 20), "failPost": (0, 20), "failDelete": (0, 20), "failPermissions": (0, 20), "pageSize": (1, 200), "channelCount": (1, 12), "recordingCount": (1, 12)}
    if set(values) - booleans - set(integers) - {"failPath"}:
        handler.respond(status=400)
        return
    for key, value in values.items():
        if key in booleans and not isinstance(value, bool):
            handler.respond(status=400); return
        if key in integers and (type(value) is not int or not integers[key][0] <= value <= integers[key][1]):
            handler.respond(status=400); return
        if key == "failPath" and (not isinstance(value, str) or (value and not value.startswith(("/LiveTv/", "/Items/recording-")))):
            handler.respond(status=400); return
    with _LOCK:
        if values.get("reset"):
            _MODES.pop(user, None)
        mode = _MODES.setdefault(user, {})
        mode.update({key: value for key, value in values.items() if key != "reset"})
        _state(user)
        result = copy.deepcopy(mode)
    handler.respond(result)


def _gate(handler, method, path, query, user):
    with _LOCK:
        state = _state(user)
        state["requests"].append({"method": method, "path": path, "query": copy.deepcopy(query)})
        mode = _MODES.setdefault(user, {})
        failure = {"GET": "failGet", "POST": "failPost", "DELETE": "failDelete"}.get(method)
        fails = bool(failure and mode.get(failure, 0) and (not mode.get("failPath") or mode["failPath"] == path))
        if fails:
            mode[failure] -= 1
        delay = mode.get("delayMs", 0) / 1000
    if delay:
        time.sleep(delay)
    if fails:
        handler.respond(status=503)
    return fails


def handle_permissions(handler, path, user):
    if path != "/Users/Me" or not user or user == "expired": return False
    with _LOCK:
        mode = _MODES.get(user, {})
        if not mode.get("failPermissions", 0): return False
        mode["failPermissions"] -= 1
        _state(user)["requests"].append({"method": "GET", "path": path, "query": {}})
    handler.respond(status=503)
    return True


def _iso(value):
    return value.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")


def _date(value):
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _programs(user, day=None):
    now = datetime.now(timezone.utc)
    if day is None:
        anchor = now.replace(minute=0, second=0, microsecond=0)
    else:
        selected = _date(day)
        # A date query returns listings spanning that selected day, including a current
        # and a future airing on today. Stable IDs make native UI regression tests clear.
        anchor = selected.replace(hour=12, minute=0, second=0, microsecond=0)
        if selected.date() == now.date():
            anchor = now.replace(minute=0, second=0, microsecond=0)
    results = []
    state = _state(user)
    for index in range(1, 7):
        start = anchor + timedelta(hours=index - 1)
        item = {"Id": f"program-{index}", "Name": "Reel Test Series" if index <= 4 else "Reel Test Movie", "Type": "Program", "EpisodeTitle": f"Guide episode {index}", "Overview": "A loopback-only guide listing for native recording tests.", "ChannelId": "channel-1", "ChannelName": "Reel Test TV", "StartDate": _iso(start), "EndDate": _iso(start + timedelta(hours=1)), "IsSeries": index <= 4, "IsRepeat": False, "ImageTags": {"Primary": "fixture"}}
        timer = next((value for value in state["timers"].values() if value.get("ProgramId") == item["Id"]), None)
        series = next((value for value in state["series"].values() if value.get("Name") == item["Name"]), None)
        if timer:
            item["TimerId"] = timer["Id"]
        if series:
            item["SeriesTimerId"] = series["Id"]
        results.append(item)
    return results


def _recording(index=1):
    return {"Id": f"recording-{index}", "Name": "Reel test recording" if index == 1 else f"Reel test recording {index}", "Type": "Movie", "Overview": "A local recording fixture. Playback uses the existing loopback video.", "RunTimeTicks": 240_000_000, "ImageTags": {"Primary": "fixture"}, "BackdropImageTags": ["fixture"], "UserData": {"PlaybackPositionTicks": 0, "Played": False}, "MediaSources": [{"Id": f"recording-{index}-source", "Name": "Recorded broadcast", "Container": "mp4", "MediaStreams": [{"Index": 0, "Type": "Video", "Codec": "h264"}, {"Index": 1, "Type": "Audio", "Codec": "aac"}]}]}


def handle(handler, method, path, query, user, body=None):
    if path == "/qa/livetv-control":
        if method == "POST": _configure(handler, user, body)
        else: handler.respond(status=405)
        return True
    recording_item = path.startswith("/Items/recording-") and path.count("/") == 2
    if not (path.startswith("/LiveTv/") or recording_item):
        return False
    with _LOCK:
        mode = copy.deepcopy(_MODES.get(user, {}))
    if (path == "/LiveTv/Channels" or path.startswith("/LiveTv/Channels/")) and not mode:
        return False  # Preserve the existing channel fixture and IDs.
    if not user:
        handler.respond(status=401)
        return True
    if not user_policy(user)["EnableLiveTvAccess"]:
        handler.respond(status=403)
        return True
    if _gate(handler, method, path, query, user):
        return True
    with _LOCK:
        state = _state(user)
        if method == "GET":
            if path == "/LiveTv/Channels":
                count = mode.get("channelCount", 1)
                channels = [] if mode.get("emptyChannels") else [{**_recording(index), "Id": f"channel-{index}", "Name": "Reel Test TV" if index == 1 else f"Reel Test TV {index}", "Type": "TvChannel", "CurrentProgram": {"Name": "Local test program"}} for index in range(1, count + 1)]
                start = int(query.get("startindex", 0)); limit = min(int(query.get("limit", 60)), mode.get("pageSize", 200))
                handler.respond({"Items": channels[start:start + limit], "TotalRecordCount": len(channels)})
            elif path == "/LiveTv/Programs":
                programs = [] if mode.get("emptyPrograms") else _programs(user, query.get("minenddate"))
                if query.get("channelids") not in (None, "", "channel-1"):
                    programs = []
                start = int(query.get("startindex", 0))
                limit = min(int(query.get("limit", 200)), mode.get("pageSize", 200))
                handler.respond({"Items": programs[start:start + limit], "TotalRecordCount": len(programs)})
            elif path.startswith("/LiveTv/Programs/"):
                program = next((item for item in _programs(user) if item["Id"] == path.rsplit("/", 1)[-1]), None)
                handler.respond(program, status=200 if program else 404)
            elif path == "/LiveTv/Timers/Defaults":
                program = next((item for item in _programs(user) if item["Id"] == query.get("programid")), None)
                if not program:
                    handler.respond(status=404)
                else:
                    handler.respond({"ProgramId": program["Id"], "Name": program["Name"], "ChannelId": "channel-1", "StartDate": program["StartDate"], "EndDate": program["EndDate"], "PrePaddingSeconds": 60, "PostPaddingSeconds": 180, "IsPrePaddingRequired": False, "IsPostPaddingRequired": False, "RecordNewOnly": True, "RecordAnyTime": True, "RecordAnyChannel": False, "SkipEpisodesInLibrary": True, "Days": ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"], "KeepUntil": "UntilDeleted", "ProviderDefault": {"keep": "fixture-default"}})
            elif path == "/LiveTv/Timers":
                values = list(state["timers"].values())
                handler.respond({"Items": values, "TotalRecordCount": len(values)})
            elif path == "/LiveTv/SeriesTimers":
                values = list(state["series"].values())
                handler.respond({"Items": values, "TotalRecordCount": len(values)})
            elif path == "/LiveTv/Recordings":
                values = [] if mode.get("emptyRecordings") else [_recording(index) for index in range(1, mode.get("recordingCount", 1) + 1)]
                start = int(query.get("startindex", 0))
                limit = min(int(query.get("limit", 60)), mode.get("pageSize", 200))
                handler.respond({"Items": values[start:start + limit], "TotalRecordCount": len(values)})
            elif path.startswith(("/Items/recording-", "/LiveTv/Recordings/recording-")):
                identifier = path.rsplit("-", 1)[-1]
                handler.respond(_recording(int(identifier)) if identifier.isdigit() else None, status=200 if identifier.isdigit() else 404)
            else:
                handler.respond(status=404)
            return True
        if not user_policy(user)["EnableLiveTvManagement"]:
            handler.respond(status=403)
            return True
        if method == "POST" and path in ("/LiveTv/Timers", "/LiveTv/SeriesTimers"):
            data = copy.deepcopy(body or {})
            if not all(data.get(key) for key in ("ProgramId", "ChannelId", "Name", "StartDate", "EndDate")):
                handler.respond(status=400)
                return True
            series = path.endswith("SeriesTimers")
            bucket = "series" if series else "timers"
            counter = "seriesCount" if series else "timerCount"
            if any(item.get("ProgramId") == data["ProgramId"] for item in state[bucket].values()):
                handler.respond(status=409)
                return True
            state[counter] += 1
            identifier = ("series-" if series else "timer-") + str(state[counter])
            data.update(Id=identifier, ChannelName="Reel Test TV")
            if not series:
                data["Status"] = "New"
            state[bucket][identifier] = data
            state["events"].append({"method": method, "path": path, "body": copy.deepcopy(data)})
            handler.respond(status=204)
            return True
        if method == "DELETE" and (path.startswith("/LiveTv/Timers/") or path.startswith("/LiveTv/SeriesTimers/")):
            series = path.startswith("/LiveTv/SeriesTimers/")
            bucket = "series" if series else "timers"
            identifier = path.rsplit("/", 1)[-1]
            if identifier not in state[bucket]:
                handler.respond(status=404)
                return True
            del state[bucket][identifier]
            if series:
                state["timers"] = {key: item for key, item in state["timers"].items() if item.get("SeriesTimerId") != identifier}
            state["events"].append({"method": method, "path": path})
            handler.respond(status=204)
            return True
        handler.respond(status=404)
        return True
