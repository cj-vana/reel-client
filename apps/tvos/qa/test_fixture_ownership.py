import copy
import os
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import fixture_ownership as admission
from native_fixture_contract import native_audio_metadata
import track_contract

OWNER = "owned-synthetic-tv-identity-123456"
class Handler:
    server = SimpleNamespace(server_port=18968)
    def __init__(self, owner=None): self.headers = {admission.HEADER: owner}; self.status = None; self.value = None
    def respond(self, value=None, status=200): self.status = status; self.value = value

class FixtureOwnershipTests(unittest.TestCase):
    def test_missing_invalid_or_oversized_owner_never_starts_owned_listener(self):
        for owner in ["", "short", "x"*121, "x"*25+"/", "x"*25+"\n"]:
            with patch.dict(os.environ, {"REEL_TV_QA_OWNER": owner}), self.assertRaises(ValueError): admission.owner_from_environment()
        with patch.dict(os.environ, {"REEL_TV_QA_OWNER": OWNER}): self.assertEqual(admission.owner_from_environment(), OWNER)
    def test_identity_is_exact_to_loopback_fixture_role_and_port(self):
        h = Handler(); self.assertFalse(admission.admit(h, "/qa/tv-identity", OWNER))
        self.assertEqual(h.value, {"kind":"reel-tv-owned-fixture", "owner":OWNER, "port":18968})
        with self.assertRaises(ValueError): admission.identity(OWNER, 8096)
    def test_qa_reads_and_mutations_refuse_missing_wrong_owner_before_handlers(self):
        for path in ["/qa/reset", "/qa/state", "/qa/control", "/qa/tv-control", "/qa/audio-control"]:
            for owner in [None, "another-owned-fixture"]:
                h = Handler(owner); self.assertFalse(admission.admit(h, path, OWNER)); self.assertEqual(h.status, 403)
            self.assertTrue(admission.admit(Handler(OWNER), path, OWNER))
        self.assertTrue(admission.admit(Handler(), "/Items/movie-1", OWNER))
    def test_generic_negotiation_exposes_actual_tagged_audio_without_changing_resources(self):
        response={"MediaSources":[{"Id":"movie-3-source", "TranscodingUrl":"/Videos/movie-3/master.m3u8", "DefaultSubtitleStreamIndex":-1}], "PlaySessionId":"owned"}
        original=copy.deepcopy(response); enriched=native_audio_metadata(response); self.assertEqual(response,original)
        source=enriched["MediaSources"][0]; self.assertEqual(source["DefaultAudioStreamIndex"],1)
        self.assertEqual(source["MediaStreams"][1]["Language"],"eng"); self.assertEqual(source["TranscodingUrl"],original["MediaSources"][0]["TranscodingUrl"])
        self.assertEqual(source["DefaultSubtitleStreamIndex"],-1); self.assertEqual(enriched["PlaySessionId"],"owned")
    def test_alternate_track_metadata_matches_real_hls_language_without_inventing_identity(self):
        source=track_contract.negotiation({"MediaSourceId":"movie-1-alternate", "AudioStreamIndex":4})["MediaSources"][0]
        self.assertEqual(source["MediaStreams"][1]["Language"],"eng"); self.assertEqual(source["MediaStreams"][1]["Index"],4)
        self.assertEqual(source["MediaStreams"][1]["DisplayTitle"],"Alternate 880 Hz")
        self.assertIn("/alternate880/off/",source["TranscodingUrl"])
    def test_details_and_negotiation_audio_identity_remain_exact_for_retained_replay(self):
        details=native_audio_metadata({"MediaSources":[{"Id":"movie-3-source","MediaStreams":[{"Index":1,"Type":"Audio","Codec":"aac","DisplayTitle":"English · AAC stereo"}]}]})
        negotiated=native_audio_metadata({"MediaSources":[{"Id":"movie-3-source","DefaultAudioStreamIndex":1}]})
        detail=next(s for s in details["MediaSources"][0]["MediaStreams"]if s["Type"]=="Audio")
        fresh=next(s for s in negotiated["MediaSources"][0]["MediaStreams"]if s["Type"]=="Audio")
        self.assertEqual(detail,fresh); self.assertEqual(detail["Channels"],1)
    def test_metadata_enrichment_preserves_explicit_catalog_faults_and_non_audio_fields(self):
        value={"Items":[{"Id":"movie-1", "MediaSources":track_contract.sources(renamed_subtitle=True,ambiguous_subtitle=True)}]}
        fresh=native_audio_metadata(value); streams=fresh["Items"][0]["MediaSources"][0]["MediaStreams"]
        self.assertEqual([s["Index"]for s in streams if s["Type"]=="Subtitle"],[2,5])
        self.assertEqual([s["DisplayTitle"]for s in streams if s["Type"]=="Subtitle"],["Synthetic captions renamed"]*2)

if __name__ == "__main__": unittest.main()
