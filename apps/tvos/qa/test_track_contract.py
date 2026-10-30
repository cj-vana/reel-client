import tempfile
from pathlib import Path
import unittest

import track_contract as contract


class TrackContractTests(unittest.TestCase):
    def test_catalog_faults_are_explicit_and_do_not_change_playback_contract(self):
        self.assertEqual(contract.sources(renamed_subtitle=True)[0]["MediaStreams"][-1]["DisplayTitle"], "Synthetic captions renamed")
        subtitles = [s for s in contract.sources(ambiguous_subtitle=True)[0]["MediaStreams"] if s["Type"] == "Subtitle"]
        self.assertEqual([s["Index"] for s in subtitles], [2, 5])
        self.assertEqual(len({s["DisplayTitle"] for s in subtitles}), 1)
        self.assertEqual([s["Index"] for s in contract.negotiation({"SubtitleStreamIndex": 2})["MediaSources"][0]["MediaStreams"] if s["Type"] == "Subtitle"], [2])
        self.assertEqual(contract.sources()[0]["MediaStreams"][-1]["DisplayTitle"], "Synthetic captions")

    def test_retained_caption_fixture_keeps_explicit_off_dto_and_real_rendition(self):
        source = contract.negotiation({"SubtitleStreamIndex": -1}, retain_subtitles=True)["MediaSources"][0]
        self.assertEqual(source["DefaultSubtitleStreamIndex"], -1)
        self.assertEqual(source["TranscodingUrl"], "/Videos/reel-tracks/original440/on/master.m3u8")
        self.assertEqual([s["Index"] for s in source["MediaStreams"] if s["Type"] == "Subtitle"], [2])
        self.assertEqual(contract.negotiation({"SubtitleStreamIndex": -1})["MediaSources"][0]["TranscodingUrl"], "/Videos/reel-tracks/original440/off/master.m3u8")

    def test_retained_caption_master_has_default_no_and_authenticated_child(self):
        data = b'#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,NAME="Synthetic captions",DEFAULT=YES,FORCED=NO,URI="subtitles.m3u8"\nvideo.m3u8\n'
        rendered = contract.playlist(data, "original440", "on", retain_subtitles=True).decode()
        self.assertIn('NAME="Synthetic captions",DEFAULT=NO,FORCED=NO', rendered)
        self.assertIn('subtitles.m3u8?ApiKey=fixture-tv-track-output', rendered)
        self.assertNotIn('DEFAULT=YES', rendered)

    def test_default_is_original_first_audio_without_captions(self):
        source = contract.negotiation({})["MediaSources"][0]
        self.assertEqual(source["Id"], "movie-1-source")
        self.assertEqual(source["DefaultAudioStreamIndex"], 1)
        self.assertEqual(source["DefaultSubtitleStreamIndex"], -1)
        self.assertEqual(source["TranscodingUrl"], "/Videos/reel-tracks/original440/off/master.m3u8")

    def test_explicit_audio_subtitle_and_alternate_choose_distinct_media(self):
        for body, suffix in [({"AudioStreamIndex": 3}, "original880/off"), ({"SubtitleStreamIndex": 2}, "original440/on"), ({"MediaSourceId": "movie-1-alternate", "AudioStreamIndex": 4}, "alternate880/off")]:
            source = contract.negotiation(body)["MediaSources"][0]
            self.assertIn("/" + suffix + "/", source["TranscodingUrl"])
            self.assertFalse(source["SupportsDirectPlay"])

    def test_unknown_or_cross_source_streams_are_rejected(self):
        for body in [{"MediaSourceId": "other"}, {"AudioStreamIndex": 4}, {"AudioStreamIndex": True}, {"AudioStreamIndex": "1"}, {"SubtitleStreamIndex": 3}, {"MediaSourceId": "movie-1-alternate", "AudioStreamIndex": 1}, {"MediaSourceId": "movie-1-alternate", "SubtitleStreamIndex": 2}]:
            with self.assertRaises(ValueError): contract.negotiation(body)

    def test_source_dtos_do_not_share_mutable_state(self):
        first = contract.negotiation({})
        first["MediaSources"][0]["MediaStreams"].clear()
        self.assertEqual(len(contract.sources()[0]["MediaStreams"]), 4)

    def test_known_routes_and_disabled_subtitles(self):
        self.assertEqual(contract.media_route("/Videos/reel-tracks/original440/on/master.m3u8"), ("original440", "on", "master-on.m3u8"))
        self.assertEqual(contract.media_route("/Videos/reel-tracks/alternate880/off/segment014.ts"), ("alternate880", "off", "segment014.ts"))
        for path in ["/Videos/reel-tracks/original440/off/captions.vtt", "/Videos/reel-tracks/original440/off/subtitles.m3u8", "/Videos/reel-tracks/original440/on/../captions.vtt", "/Videos/reel-tracks/original440/on/%2e%2e/secret", "/Videos/reel-tracks/other/on/video.m3u8"]:
            with self.assertRaises(ValueError): contract.media_route(path)

    def test_file_resolution_rejects_unknown_names_and_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            folder = root / "tracks/original440"
            folder.mkdir(parents=True)
            (folder / "video.m3u8").write_text("#EXTM3U\n")
            self.assertEqual(contract.media_file(root, "original440", "video.m3u8"), (folder / "video.m3u8").resolve())
            (root / "outside.vtt").write_text("sensitive fixture sentinel")
            (folder / "captions.vtt").symlink_to(root / "outside.vtt")
            for name in ["captions.vtt", "../../outside.vtt", "source.mp4"]:
                with self.assertRaises(ValueError): contract.media_file(root, "original440", name)

    def test_symlinked_parent_cannot_escape_fixture(self):
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryDirectory() as external:
            root = Path(directory)
            (root / "tracks").mkdir()
            (Path(external) / "video.m3u8").write_text("external sentinel")
            (root / "tracks/original440").symlink_to(external, target_is_directory=True)
            with self.assertRaises(ValueError): contract.media_file(root, "original440", "video.m3u8")

    def test_playlists_authenticate_all_fixed_subresources(self):
        raw = b'#EXTM3U\n#EXT-X-MEDIA:TYPE=SUBTITLES,URI="subtitles.m3u8"\nvideo.m3u8\n'
        rendered = contract.playlist(raw, "original440", "on").decode()
        self.assertEqual(rendered.count("?ApiKey=fixture-tv-track-output"), 2)
        self.assertIn('/original440/on/subtitles.m3u8?ApiKey=', rendered)
        self.assertIn('/original440/on/video.m3u8?ApiKey=', rendered)
        for raw in [b"#EXTM3U\nhttps://remote.example/stream\n", b'#EXTM3U\n#EXT-X-MEDIA:URI="../secret"\n']:
            with self.assertRaises(ValueError): contract.playlist(raw, "original440", "on")

    def test_valid_range_and_suffix_semantics(self):
        for header, expected in [(None, (0, 9, 200)), ("bytes=0-2", (0, 2, 206)), ("bytes=3-", (3, 9, 206)), ("bytes=-2", (8, 9, 206)), ("bytes=8-999", (8, 9, 206))]:
            self.assertEqual(contract.byte_range(header, 10), expected)

    def test_invalid_ranges_are_not_silently_served(self):
        for header in ["bytes=10-", "bytes=5-2", "bytes=-0", "bytes=-", "items=0-1", "bytes=0-1,3-4", "bytes=0-2garbage"]:
            with self.assertRaises(ValueError): contract.byte_range(header, 10)
        with self.assertRaises(ValueError): contract.byte_range(None, 0)


if __name__ == "__main__": unittest.main()
