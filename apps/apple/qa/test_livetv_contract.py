import unittest
from datetime import datetime, timezone
import livetv_contract as tv


class Response:
    def respond(self, value=None, status=200, **_):
        self.value, self.status = value, status


class LiveTVContractTests(unittest.TestCase):
    def setUp(self):
        tv.reset()
        self.response = Response()

    def request(self, method, path, query=None, user="tv-tests", body=None):
        handled = tv.handle(self.response, method, path, query or {}, user, body)
        self.assertTrue(handled)
        return self.response.value, self.response.status

    def test_recording_and_series_lifecycle_preserves_defaults_and_accounts(self):
        program = self.request("GET", "/LiveTv/Programs/program-2")[0]
        defaults = self.request("GET", "/LiveTv/Timers/Defaults", {"programid": program["Id"]})[0]
        self.assertEqual(self.request("POST", "/LiveTv/Timers", body=defaults)[1], 204)
        timers = self.request("GET", "/LiveTv/Timers")[0]["Items"]
        self.assertEqual(timers[0]["ProviderDefault"], {"keep": "fixture-default"})
        self.assertEqual(self.request("GET", "/LiveTv/Timers", user="other")[0]["Items"], [])
        self.assertEqual(self.request("POST", "/LiveTv/Timers", body=defaults)[1], 409)
        self.assertEqual(self.request("DELETE", "/LiveTv/Timers/timer-1")[1], 204)
        self.assertEqual(self.request("GET", "/LiveTv/Timers")[0]["Items"], [])
        self.assertEqual(self.request("POST", "/LiveTv/SeriesTimers", body=defaults)[1], 204)
        self.assertEqual(self.request("GET", "/LiveTv/SeriesTimers")[0]["Items"][0]["Id"], "series-1")
        self.assertEqual(self.request("DELETE", "/LiveTv/SeriesTimers/series-1")[1], 204)
        self.assertEqual(self.request("GET", "/LiveTv/SeriesTimers")[0]["Items"], [])

    def test_guide_pagination_date_filter_and_permissions(self):
        day = "2026-12-14T00:00:00Z"
        page = self.request("GET", "/LiveTv/Programs", {"minenddate": day, "startindex": "2", "limit": "2"})[0]
        self.assertEqual(page["TotalRecordCount"], 6)
        self.assertEqual(page["Items"][0]["Id"], "program-3")
        self.assertTrue(page["Items"][0]["StartDate"].startswith("2026-12-14"))
        self.assertEqual(self.request("GET", "/LiveTv/Programs", {"channelids": "missing"})[0]["Items"], [])
        self.assertEqual(self.request("GET", "/LiveTv/Programs", user="notv")[1], 403)
        self.assertEqual(self.request("POST", "/LiveTv/Timers", user="readonlytv", body={})[1], 403)
        self.assertEqual(self.request("GET", "/LiveTv/Recordings")[0]["Items"][0]["Id"], "recording-1")


if __name__ == "__main__":
    unittest.main()
