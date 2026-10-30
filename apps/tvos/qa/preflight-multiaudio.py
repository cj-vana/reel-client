#!/usr/bin/env python3
"""Actual HTTP boundary checks for only the fixed disposable loopback fixture."""
from http.client import HTTPConnection
import json
import re
from urllib.parse import urlsplit

import multiaudio_contract as contract

checks = []


def request(path, status, *, method="GET", headers=None):
    parsed = urlsplit(path)
    assert not parsed.scheme and not parsed.netloc and parsed.path.startswith("/")
    connection = HTTPConnection("127.0.0.1", 18969, timeout=8)
    try:
        connection.request(method, path, headers=headers or {})
        response = connection.getresponse()
        data = response.read()
        actual_headers = dict(response.getheaders())
        assert response.status == status, (method, path, response.status, status)
        checks.append({"method": method, "path": parsed.path, "expected": status, "actual": response.status})
        return data, actual_headers
    finally:
        connection.close()


path = "/Videos/reel-multiaudio/p1/a1/s-1/master.m3u8"
authorized = path + "?ApiKey=" + contract.TOKEN
for method in ["GET", "HEAD"]:
    for suffix in ["", "?ApiKey=bad", "?ApiKey=" + contract.TOKEN + "&ApiKey=" + contract.TOKEN, "?ApiKey=" + contract.TOKEN + "&foreign=1"]:
        request(path + suffix, 401, method=method)
master, master_headers = request(authorized, 200)
head, head_headers = request(authorized, 200, method="HEAD")
assert head == b"" and int(head_headers["Content-Length"]) == len(master)
assert master_headers["Cache-Control"] == "no-store"
assert master.count(b"TYPE=AUDIO") == 2 and master.count(b"TYPE=SUBTITLES") == 1
children = re.findall(r'URI="([^"]+)"', master.decode())
children += [line for line in master.decode().splitlines() if line and not line.startswith("#")]
assert len(children) == 4
for child in children:
    parsed = urlsplit(child)
    assert not parsed.scheme and not parsed.netloc
    assert parsed.query == "ApiKey=" + contract.TOKEN
    data, _ = request(child, 200)
    lines = [line for line in data.decode().splitlines() if line and not line.startswith("#")]
    assert lines and all(urlsplit(line).query == "ApiKey=" + contract.TOKEN for line in lines)
    leaf = lines[0]
    content, leaf_headers = request(leaf, 200)
    assert content
    partial, partial_headers = request(leaf, 206, headers={"Range": "bytes=0-7"})
    assert partial == content[:8] and partial_headers["Content-Range"] == f"bytes 0-7/{len(content)}"
    head_partial, _ = request(leaf, 206, method="HEAD", headers={"Range": "bytes=0-7"})
    assert head_partial == b""
    _, invalid_headers = request(leaf, 416, headers={"Range": f"bytes={len(content)}-"})
    assert invalid_headers["Content-Range"] == f"bytes */{len(content)}"
    request(urlsplit(leaf).path, 401)
for suffix in ["../secret", "%2e%2e/secret", "unknown/index.m3u8", "es/segment000.ts/extra"]:
    request("/Videos/reel-multiaudio/p1/a1/s-1/" + suffix + "?ApiKey=" + contract.TOKEN, 404)
request("/System/Info/Public", 501, method="HEAD")
print(json.dumps({"result": "passed", "scope": "Only original fixed loopback18969; no app/native selection or physical output claim", "checks": checks}, indent=2))
