"""Per-user, loopback-only native video download fault controls."""
import copy
import threading
import time

_LOCK = threading.Lock()
_STATES = {}


def _state(user):
    return _STATES.setdefault(user, {"mode": {}, "requests": []})


def reset():
    with _LOCK: _STATES.clear()


def policy(user):
    with _LOCK:
        mode = _state(user)["mode"]
        return {"EnableContentDownloading": mode["downloadAllowed"]} if "downloadAllowed" in mode else {}


def handle_post(handler, path, body, user):
    if path != "/qa/download-control": return False
    if not user or handler.client_address[0] != "127.0.0.1":
        handler.respond(status=403); return True
    if not isinstance(body, dict):
        handler.respond(status=400); return True
    booleans = {"reset", "downloadAllowed"}
    integers = {"hlsDelayMs": (0, 15000), "failHLS": (0, 100)}
    for key, value in body.items():
        if key in booleans:
            valid = isinstance(value, bool)
        elif key in integers:
            low, high = integers[key]
            valid = isinstance(value, int) and not isinstance(value, bool) and low <= value <= high
        elif key == "failureStage": valid = value in ("manifest", "segment")
        else: valid = False
        if not valid:
            handler.respond(status=400); return True
    with _LOCK:
        current = _state(user)
        if body.get("reset"): current["mode"] = {}
        current["mode"].update({key: value for key, value in body.items() if key != "reset"})
        result = copy.deepcopy(current)
    handler.respond(result); return True


def handle_get(handler, path, query, user):
    if path == "/qa/download-state":
        if not user or handler.client_address[0] != "127.0.0.1": handler.respond(status=403)
        else:
            with _LOCK: result = copy.deepcopy(_state(user))
            handler.respond(result)
        return True
    if not path.startswith("/Videos/") or not (path.endswith(".m3u8") or path.endswith(".ts")): return False
    token = query.get("apikey", "")
    actor = token.removeprefix("fixture-") if token.startswith("fixture-") else None
    if not actor: return False
    stage = "manifest" if path.endswith(".m3u8") else "segment"
    with _LOCK:
        current = _state(actor); mode = current["mode"]
        delay = mode.get("hlsDelayMs", 0)
        fail = mode.get("failHLS", 0) > 0 and mode.get("failureStage", "manifest") == stage
        if fail: mode["failHLS"] -= 1
        current["requests"].append({"path": path, "stage": stage, "failed": fail})
    if delay: time.sleep(delay / 1000)
    if fail:
        handler.respond(status=503); return True
    return False
