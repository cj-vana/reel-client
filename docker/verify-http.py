#!/usr/bin/env python3
"""Exercise only the disposable Docker web origin; never a Jellyfin account."""
import hashlib
import json
import re
from urllib.error import HTTPError
from urllib.request import HTTPRedirectHandler, Request, build_opener

ORIGIN = "http://127.0.0.1:18790"


class NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


opener = build_opener(NoRedirect)


def get(path, method="GET"):
    try:
        response = opener.open(Request(ORIGIN + path, method=method), timeout=5)
    except HTTPError as error:
        response = error
    with response:
        return response.status, response.headers, response.read()


def verify():
    status, headers, html = get("/")
    assert status == 200 and "text/html" in headers["Content-Type"]
    assert headers["Cache-Control"] == "no-store"
    assert headers["X-Content-Type-Options"] == "nosniff"
    assert headers["Referrer-Policy"] == "no-referrer"
    assert get("/index.html")[2] == html
    status, head, body = get("/", "HEAD")
    assert status == 200 and not body and int(head["Content-Length"]) == len(html)
    assert get("/healthz")[2] == b"ok\n"
    assets = re.findall(rb'(?:src|href)="(\./assets/[^\"]+)"', html)
    assert len(assets) >= 2, assets
    receipts = {}
    for asset in assets:
        path = asset.decode().removeprefix(".")
        status, asset_headers, data = get(path)
        assert status == 200 and data
        assert "immutable" in asset_headers["Cache-Control"]
        assert ("javascript" if path.endswith(".js") else "text/css") in asset_headers["Content-Type"]
        receipts[path] = hashlib.sha256(data).hexdigest()
    for path, mime in [("/brand/mark.svg", "image/svg+xml"), ("/brand/icon.png", "image/png"), ("/THIRD_PARTY_NOTICES.txt", "text/plain"), ("/LICENSE.txt", "text/plain"), ("/reel-config.js", "javascript")]:
        status, resource_headers, data = get(path)
        assert status == 200 and mime in resource_headers["Content-Type"] and data, path
        receipts[path] = hashlib.sha256(data).hexdigest()
    assert b"previewMode: false" in get("/reel-config.js")[2]
    assert get("/reel-config.js")[1]["Cache-Control"] == "no-store"
    status, manifest_headers, manifest_bytes = get("/manifest.webmanifest")
    assert status == 200 and "application/manifest+json" in manifest_headers["Content-Type"]
    assert manifest_headers["Cache-Control"] == "no-cache"
    manifest = json.loads(manifest_bytes)
    assert manifest["id"] == manifest["start_url"] == manifest["scope"] == "./"
    assert manifest["display"] == "standalone"
    for size in [192, 512]:
        icon = next(icon for icon in manifest["icons"] if icon["sizes"] == f"{size}x{size}")
        status, icon_headers, image = get(icon["src"].removeprefix("."))
        assert status == 200 and "image/png" in icon_headers["Content-Type"]
        assert int.from_bytes(image[16:20], "big") == size and int.from_bytes(image[20:24], "big") == size
    status, worker_headers, worker = get("/reel-sw.js")
    assert status == 200 and "javascript" in worker_headers["Content-Type"]
    assert worker_headers["Cache-Control"] == "no-cache"
    shell = json.loads(re.search(rb"const ASSETS = (.*);", worker)[1])
    for entry in shell:
        status, _, body = get("/" + entry["path"])
        assert status == 200 and hashlib.sha256(body).hexdigest() == entry["sha256"], entry["path"]
    receipts["/reel-sw.js"] = hashlib.sha256(worker).hexdigest()
    for path in ["/assets/missing.js", "/brand/missing.svg", "/missing.css", "/.env", "/.git/config"]:
        assert get(path)[0] == 404, path
    for path in ["/unknown", "/unknown/deep", "/unknown/deep/"]:
        status, headers, _ = get(path)
        assert status == 302 and headers["Location"] == "/", path
    for path in ["/", "/Users/AuthenticateByName", "/healthz"]:
        assert get(path, "POST")[0] == 405, path
    print("Docker HTTP route checks passed:", receipts)
    return receipts


if __name__ == "__main__":
    verify()
