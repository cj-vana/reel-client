"""Runtime contract checks for isolated Remote/Seerr UI fixture controls."""
import base64
import http.client
import json
import os
import socket
import struct
import threading
import time
import unittest
import uuid
from loopback_server import LoopbackHTTPServer

import remote_contract
import seerr_contract


class ModeContractTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.remote = LoopbackHTTPServer(("127.0.0.1", 0), remote_contract.Handler)
        cls.seerr = LoopbackHTTPServer(("127.0.0.1", 0), seerr_contract.Handler)
        for server in (cls.remote, cls.seerr):
            threading.Thread(target=server.serve_forever, daemon=True).start()

    @classmethod
    def tearDownClass(cls):
        for server in (cls.remote, cls.seerr):
            server.shutdown()
            server.server_close()

    def setUp(self):
        self.user = "mode-" + str(uuid.uuid4())
        self.call(self.seerr, "/api/v1/qa/reset", "POST")
        for user in ("viewer", "admin", "quota", "restricted"):
            self.seerr_mode(user, reset=True)

    def call(self, server, path, method="GET", body=None, user=None, seerr_user=None):
        self.assertEqual(server.server_address[0], "127.0.0.1")
        connection = http.client.HTTPConnection(*server.server_address, timeout=3)
        headers = {"Content-Type": "application/json"}
        if user:
            headers["Authorization"] = f'MediaBrowser Token="fixture-{user}"'
        if seerr_user == "admin":
            headers["X-Api-Key"] = "fixture-seerr"
        elif seerr_user:
            headers["Cookie"] = f"connect.sid=fixture-{seerr_user}"
        try:
            connection.request(method, path, body=json.dumps(body or {}) if method != "GET" else None, headers=headers)
            response = connection.getresponse()
            data = response.read()
            return response.status, json.loads(data) if data else None
        finally:
            connection.close()

    def remote_mode(self, **flags):
        status, value = self.call(self.remote, "/qa/remote-control", "POST", flags, user=self.user)
        self.assertEqual(status, 200)
        return value

    def seerr_mode(self, user, **flags):
        status, value = self.call(self.seerr, "/api/v1/qa/control", "POST", {"user": user, **flags})
        self.assertEqual(status, 200)
        return value

    def test_remote_modes_are_user_scoped_and_resettable(self):
        self.remote_mode(sessionsEmpty=True, groupsEmpty=True, syncAccess="None")
        self.assertEqual(self.call(self.remote, "/Sessions", user=self.user), (200, []))
        self.assertEqual(self.call(self.remote, "/SyncPlay/List", user=self.user), (200, []))
        self.assertEqual(self.call(self.remote, "/Users/Me", user=self.user)[1]["Policy"]["SyncPlayAccess"], "None")
        self.assertEqual(len(self.call(self.remote, "/Sessions", user="another-user")[1]), 1)
        self.assertGreater(len(self.call(self.remote, "/SyncPlay/List", user="another-user")[1]), 0)
        self.remote_mode(reset=True, mediaControl=False, canSeek=False, acceptsVideo=False)
        receiver = self.call(self.remote, "/Sessions", user=self.user)[1][0]
        self.assertFalse(receiver["SupportsMediaControl"])
        self.assertFalse(receiver["PlayState"]["CanSeek"])
        self.assertEqual(receiver["PlayableMediaTypes"], ["Audio"])
        self.remote_mode(reset=True)
        self.assertTrue(self.call(self.remote, "/Sessions", user=self.user)[1][0]["SupportsMediaControl"])

    def test_remote_delays_one_shot_failures_and_validation(self):
        self.remote_mode(sessionsDelayMs=200, failSessions=1, failGroups=1, failCommand=1)
        start = time.monotonic()
        self.assertEqual(self.call(self.remote, "/Sessions", user=self.user)[0], 503)
        self.assertGreaterEqual(time.monotonic() - start, 0.15)
        self.assertEqual(self.call(self.remote, "/Sessions", user=self.user)[0], 200)
        self.assertEqual(self.call(self.remote, "/SyncPlay/List", user=self.user)[0], 503)
        self.assertEqual(self.call(self.remote, "/SyncPlay/List", user=self.user)[0], 200)
        command = "/Sessions/qa-living-room/Playing/Pause"
        self.assertEqual(self.call(self.remote, command, "POST", user=self.user)[0], 503)
        self.assertEqual(self.call(self.remote, command, "POST", user=self.user)[0], 204)
        self.assertEqual(self.call(self.remote, "/qa/remote-control", "POST", {"sessionsEmpty": True, "sessionsDelayMs": -1}, user=self.user)[0], 400)
        self.assertEqual(len(self.call(self.remote, "/Sessions", user=self.user)[1]), 1, "Invalid control updates must not partially commit.")
        self.assertEqual(self.call(self.remote, "/qa/remote-control", "POST", {"groupsEmpty": True})[0], 401)

    def websocket(self, user):
        connection = socket.create_connection(self.remote.server_address, timeout=3)
        key = base64.b64encode(os.urandom(16)).decode()
        request = (f"GET /socket HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                   f"Sec-WebSocket-Version: 13\r\nSec-WebSocket-Key: {key}\r\nAuthorization: MediaBrowser Token=\"fixture-{user}\"\r\n\r\n")
        connection.sendall(request.encode())
        reader = connection.makefile("rb")
        self.assertIn(b"101", reader.readline())
        while reader.readline().strip():
            pass
        return connection, reader

    def test_socket_loss_control_closes_only_target_users_peer(self):
        own, own_reader = self.websocket(self.user)
        other_user = "other-" + str(uuid.uuid4())
        other, other_reader = self.websocket(other_user)
        try:
            for _ in range(100):
                sockets = self.call(self.remote, "/qa/remote-state")[1].get("sockets", {})
                if sockets.get(self.user) == 1 and sockets.get(other_user) == 1:
                    break
                time.sleep(0.01)
            self.remote_mode(disconnectSockets=True)
            header = own_reader.read(2)
            self.assertEqual(header[0] & 15, 8)
            self.assertEqual(struct.unpack("!H", own_reader.read(header[1] & 127))[0], 1001)
            payload, mask = b"alive", b"test"
            masked = bytes(value ^ mask[index % 4] for index, value in enumerate(payload))
            other.sendall(bytes([0x89, 0x80 | len(payload)]) + mask + masked)
            reply = other_reader.read(2)
            self.assertEqual(reply[0] & 15, 10)
            self.assertEqual(other_reader.read(reply[1] & 127), payload)
        finally:
            own_reader.close(); other_reader.close(); own.close(); other.close()

    def test_seerr_failures_delays_empty_results_and_actor_isolation(self):
        self.seerr_mode("viewer", authDelayMs=200, browseDelayMs=100, failBrowse=1, failDetail=1)
        started = time.monotonic()
        self.assertEqual(self.call(self.seerr, "/api/v1/auth/jellyfin", "POST", {"username": "viewer", "password": "demo"})[0], 200)
        self.assertGreaterEqual(time.monotonic() - started, 0.15)
        self.assertEqual(self.call(self.seerr, "/api/v1/discover/trending", seerr_user="admin")[0], 200)
        self.assertEqual(self.call(self.seerr, "/api/v1/discover/trending", seerr_user="viewer")[0], 503)
        self.assertEqual(self.call(self.seerr, "/api/v1/discover/trending", seerr_user="viewer")[0], 200)
        self.assertEqual(self.call(self.seerr, "/api/v1/movie/101", seerr_user="viewer")[0], 503)
        self.assertEqual(self.call(self.seerr, "/api/v1/movie/101", seerr_user="viewer")[0], 200)
        self.seerr_mode("viewer", emptyDiscovery=True)
        self.assertEqual(self.call(self.seerr, "/api/v1/discover/trending", seerr_user="viewer")[1]["results"], [])
        self.assertTrue(self.call(self.seerr, "/api/v1/discover/trending", seerr_user="admin")[1]["results"])

    def test_seerr_request_pagination_and_quota_contract(self):
        self.seerr_mode("viewer", requestPageSize=1)
        for body in ({"mediaType": "movie", "mediaId": 101}, {"mediaType": "tv", "mediaId": 201, "seasons": [2]}):
            self.assertEqual(self.call(self.seerr, "/api/v1/request", "POST", body, seerr_user="viewer")[0], 201)
        first = self.call(self.seerr, "/api/v1/user/2/requests?take=20&skip=0", seerr_user="viewer")[1]
        second = self.call(self.seerr, "/api/v1/user/2/requests?take=20&skip=1", seerr_user="viewer")[1]
        self.assertEqual(first["pageInfo"]["results"], 2)
        self.assertEqual(first["pageInfo"]["pages"], 2)
        self.assertEqual(len(first["results"]), 1)
        self.assertNotEqual(first["results"][0]["id"], second["results"][0]["id"])
        self.seerr_mode("restricted", tvQuotaRemaining=1, movieQuotaRemaining=0)
        quota = self.call(self.seerr, "/api/v1/user/3/quota", seerr_user="restricted")[1]
        self.assertEqual(quota["tv"]["remaining"], 1)
        self.assertTrue(quota["movie"]["restricted"])

    def test_seerr_invalid_modes_do_not_change_existing_configuration(self):
        self.seerr_mode("viewer", emptyDiscovery=True)
        self.assertEqual(self.call(self.seerr, "/api/v1/qa/control", "POST", {"user": "viewer", "emptyDiscovery": False, "authDelayMs": 10001})[0], 400)
        self.assertEqual(self.call(self.seerr, "/api/v1/qa/control", "POST", {"user": "unknown", "emptyDiscovery": True})[0], 400)
        self.assertEqual(self.call(self.seerr, "/api/v1/discover/trending", seerr_user="viewer")[1]["results"], [])

    def test_tv_availability_is_specific_to_the_requested_resolution(self):
        regular = {"mediaType": "tv", "mediaId": 201, "seasons": [1], "is4k": False}
        high_resolution = {**regular, "seasons": [1, 2, 3], "is4k": True}
        self.assertEqual(self.call(self.seerr, "/api/v1/request", "POST", regular, seerr_user="admin")[0], 202)
        status, request = self.call(self.seerr, "/api/v1/request", "POST", high_resolution, seerr_user="admin")
        self.assertEqual(status, 201)
        self.assertEqual([season["seasonNumber"] for season in request["seasons"]], [1, 2, 3])
        self.assertTrue(request["is4k"])


if __name__ == "__main__":
    unittest.main()
