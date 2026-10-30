import tempfile
import math
from pathlib import Path
import unittest

import multiaudio_contract as contract
from multiaudio_tone import decoded_frequency


class MultiAudioContractTests(unittest.TestCase):
    def test_distinct_provider_indices_languages_and_real_caption(self):
        source = contract.source()
        self.assertEqual([s["Index"] for s in source["MediaStreams"]], [0, 1, 3, 2])
        self.assertEqual([s["Language"] for s in source["MediaStreams"] if s["Type"] == "Audio"], ["eng", "spa"])
        self.assertEqual(source["MediaStreams"][-1]["DeliveryMethod"], "Hls")

    def test_choices_are_strict_and_preserve_both_audible_options(self):
        for audio in (1, 3):
            for subtitle in (-1, 2):
                response = contract.negotiation({"AudioStreamIndex": audio, "SubtitleStreamIndex": subtitle, "StartTimeTicks": 10_000_000})
                source = response["MediaSources"][0]
                self.assertEqual(source["DefaultAudioStreamIndex"], audio)
                self.assertEqual(source["DefaultSubtitleStreamIndex"], subtitle)
                self.assertEqual(len([s for s in source["MediaStreams"] if s["Type"] == "Audio"]), 2)
        for body in [{"AudioStreamIndex": True}, {"AudioStreamIndex": 2}, {"SubtitleStreamIndex": 3}, {"StartTimeTicks": float("nan")}, {"StartTimeTicks": -1}, {"StartTimeTicks": contract.DURATION_TICKS}, {"MediaSourceId": "foreign"}]:
            with self.assertRaises(ValueError):
                contract.negotiation(body)

    def test_routes_never_accept_traversal_or_unknown_groups(self):
        self.assertEqual(contract.media_route("/Videos/reel-multiaudio/p1/a3/s-1/es/segment001.ts")[-1], "es/segment001.ts")
        for path in ["/Videos/reel-multiaudio/p0/a1/s2/master.m3u8", "/Videos/reel-multiaudio/p1/a2/s2/master.m3u8", "/Videos/reel-multiaudio/p1/a1/s0/master.m3u8", "/Videos/reel-multiaudio/p1/a1/s2/../secret", "/Videos/reel-multiaudio/p1/a1/s2/%2e%2e/secret", "/Videos/reel-multiaudio/p1/a1/s2/en/segment000.ts/extra"]:
            with self.assertRaises(ValueError):
                contract.media_route(path)

    def test_master_and_child_urls_are_authenticated_and_fixed(self):
        data = b'#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI="en/index.m3u8"\nvideo/index.m3u8\n'
        text = contract.playlist(data, 1, -1, "master.m3u8").decode()
        self.assertIn('/a1/s-1/en/index.m3u8?ApiKey=fixture-tv-multiaudio', text)
        self.assertIn('/a1/s-1/video/index.m3u8?ApiKey=fixture-tv-multiaudio', text)
        child = contract.playlist(b'#EXTM3U\nsegment000.ts\n', 3, 2, "es/index.m3u8").decode()
        self.assertIn('/a3/s2/es/segment000.ts?ApiKey=fixture-tv-multiaudio', child)
        with self.assertRaises(ValueError):
            contract.playlist(b'#EXTM3U\nhttps://foreign.invalid/secret\n', 1, 2, "master.m3u8")

    def test_new_playback_generation_cannot_reuse_old_rendition_requests(self):
        first = contract.negotiation({}, sequence=1)
        second = contract.negotiation({}, sequence=2)
        self.assertNotEqual(first["PlaySessionId"], second["PlaySessionId"])
        self.assertNotEqual(first["MediaSources"][0]["TranscodingUrl"], second["MediaSources"][0]["TranscodingUrl"])
        rewritten = contract.playlist(b'#EXTM3U\nsegment000.ts\n', 1, -1, "es/index.m3u8", sequence=2)
        self.assertIn(b'/p2/a1/s-1/es/segment000.ts?', rewritten)

    def test_file_resolution_rejects_symlinks_and_common_prefix_escape(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "owned"
            (root / "multiaudio/en").mkdir(parents=True)
            path = root / "multiaudio/en/segment000.ts"
            path.write_bytes(b"original")
            self.assertEqual(contract.media_file(root, "en/segment000.ts"), path.resolve())
            path.unlink()
            foreign = Path(temporary) / "owned-other"
            foreign.mkdir()
            (foreign / "secret.ts").write_bytes(b"foreign")
            path.symlink_to(foreign / "secret.ts")
            with self.assertRaises(ValueError):
                contract.media_file(root, "en/segment000.ts")
            path.unlink()
            (root / "multiaudio/en").rmdir()
            (root / "multiaudio/en").symlink_to(foreign, target_is_directory=True)
            (foreign / "segment000.ts").write_bytes(b"foreign")
            with self.assertRaises(ValueError):
                contract.media_file(root, "en/segment000.ts")


class DecodedToneTests(unittest.TestCase):
    def tone(self, frequency, count=96_000):
        return [int(3_000 * math.sin(2 * math.pi * frequency * index / 48_000)) for index in range(count)]

    def test_actual_periods_exclude_leading_codec_priming_without_lowering_frequency(self):
        for frequency in [440, 880]:
            samples = [0] * 455 + self.tone(frequency, 96_000 - 455)
            measured = decoded_frequency(samples)
            self.assertAlmostEqual(measured["decodedZeroCrossingHz"], frequency, delta=0.1)
            self.assertGreater(measured["crossingSpanSamples"], 62_400)
        self.assertNotAlmostEqual(decoded_frequency(self.tone(880))["decodedZeroCrossingHz"], 440, delta=1)

    def test_silence_short_and_discontinuous_samples_do_not_prove_a_tone(self):
        for samples in [[0] * 96_000, self.tone(440, 48_000), self.tone(440, 24_000) + [0] * 72_000,
                        self.tone(440, 40_000) + [0] * 16_000 + self.tone(440, 40_000)]:
            with self.assertRaises(ValueError):
                decoded_frequency(samples)


if __name__ == "__main__":
    unittest.main()
