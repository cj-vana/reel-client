"""Noncredential admission for the exact owned synthetic TV listeners."""
import os
import re

HEADER = "X-Reel-TV-Owner"

def owner_from_environment():
    value = os.environ.get("REEL_TV_QA_OWNER", "")
    if not re.fullmatch(r"[A-Za-z0-9_-]{24,120}", value):
        raise ValueError("Provide a fresh owned TV fixture identity in REEL_TV_QA_OWNER")
    return value

def identity(owner, port):
    if not re.fullmatch(r"[A-Za-z0-9_-]{24,120}", owner) or port not in (18966, 18967, 18968, 18969):
        raise ValueError("Invalid owned TV listener")
    return {"kind": "reel-tv-owned-fixture", "owner": owner, "port": port}

def admit(handler, path, owner):
    if path == "/qa/tv-identity":
        handler.respond(identity(owner, handler.server.server_port)); return False
    if path.startswith("/qa/") and handler.headers.get(HEADER) != owner:
        handler.respond(status=403); return False
    return True
