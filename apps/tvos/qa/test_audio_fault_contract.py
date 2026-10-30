import unittest
import audio_fault_contract as faults
import multiaudio_contract as media


class AudioFaultContractTests(unittest.TestCase):
    def test_controls_require_exact_bools_and_fixed_keys(self):
        self.assertEqual(faults.controls({'failNextMaster': True}), {'failNextMaster': True})
        for body in [None, [], {'failNextMaster': 1}, {'failNextVideo': 'true'}, {'path': '/etc/passwd'}, {'unresolvableAudio': None}]:
            with self.assertRaises(ValueError): faults.controls(body)

    def test_failures_are_consumed_once_and_bound_to_exact_generation(self):
        settings = {'failNextMaster': True, 'failNextVideo': True}
        masters, videos = [], []
        first, second = media.negotiation({}, sequence=2), media.negotiation({}, sequence=3)
        faults.apply(first, settings, 2, masters, videos)
        faults.apply(second, settings, 3, masters, videos)
        self.assertEqual(masters, [2]); self.assertEqual(videos, [2]); self.assertEqual(settings, {})
        self.assertNotEqual(first['PlaySessionId'], second['PlaySessionId'])

    def test_ambiguity_changes_only_authoritative_audio_identity_not_native_media(self):
        original = media.negotiation({'AudioStreamIndex': 3, 'SubtitleStreamIndex': 2})
        response = media.negotiation({'AudioStreamIndex': 3, 'SubtitleStreamIndex': 2})
        faults.apply(response, {'unresolvableAudio': True}, 1, [], [])
        after = response['MediaSources'][0]
        self.assertEqual(after['TranscodingUrl'], original['MediaSources'][0]['TranscodingUrl'])
        self.assertEqual(after['DefaultAudioStreamIndex'], 3)
        audio = [s for s in after['MediaStreams'] if s['Type'] == 'Audio']
        self.assertEqual([s['Index'] for s in audio], [1, 3])
        self.assertEqual({s['Language'] for s in audio}, {'eng'})
        self.assertEqual(response['MediaSources'][0]['MediaStreams'][-1], original['MediaSources'][0]['MediaStreams'][-1])

    def test_changed_source_keeps_identical_tracks_but_is_consumed_once(self):
        original = media.negotiation({'AudioStreamIndex': 3}, sequence=2)
        changed = media.negotiation({'AudioStreamIndex': 3}, sequence=2)
        settings = {'changedSource': True}
        faults.apply(changed, settings, 2, [], [])
        self.assertNotEqual(changed['MediaSources'][0]['Id'], original['MediaSources'][0]['Id'])
        self.assertEqual(changed['MediaSources'][0]['MediaStreams'], original['MediaSources'][0]['MediaStreams'])
        self.assertEqual(changed['MediaSources'][0]['TranscodingUrl'], original['MediaSources'][0]['TranscodingUrl'])
        self.assertEqual(settings, {})

    def test_negotiated_enabled_subtitle_is_independent_of_requested_off(self):
        response = media.negotiation({'SubtitleStreamIndex': -1})
        settings = {'negotiatedSubtitleEnabled': True, 'detailsSubtitleDefault': True}
        faults.apply(response, settings, 1, [], [])
        self.assertEqual(response['MediaSources'][0]['DefaultSubtitleStreamIndex'], 2)
        self.assertIn('/s-1/', response['MediaSources'][0]['TranscodingUrl'])
        self.assertEqual(settings, {'detailsSubtitleDefault': True})

    def test_encoded_off_contradiction_is_fixed_owned_plan_and_consumed_once(self):
        settings = {'encodedSubtitlePlan': True, 'omittedSubtitleDefault': True}
        first, second = media.negotiation({'SubtitleStreamIndex': -1}, sequence=2), media.negotiation({'SubtitleStreamIndex': -1}, sequence=3)
        faults.apply(first, settings, 2, [], [])
        faults.apply(second, settings, 3, [], [])
        self.assertEqual(settings, {})
        self.assertNotIn('DefaultSubtitleStreamIndex', first['MediaSources'][0])
        self.assertTrue(first['MediaSources'][0]['TranscodingUrl'].endswith('?SubtitleStreamIndex=2&SubtitleMethod=Encode'))
        self.assertEqual(second['MediaSources'][0], media.source(subtitle=-1, sequence=3))

    def test_duplicate_plan_changes_only_fixed_negotiated_query(self):
        response = media.negotiation({'SubtitleStreamIndex': -1}, sequence=2)
        original = media.source(subtitle=-1, sequence=2)
        settings = {'conflictingSubtitlePlan': True}
        faults.apply(response, settings, 2, [], [])
        changed = response['MediaSources'][0]
        self.assertEqual(settings, {})
        self.assertEqual(changed['DefaultSubtitleStreamIndex'], -1)
        self.assertEqual(changed['MediaStreams'], original['MediaStreams'])
        self.assertEqual(changed['TranscodingUrl'].split('?', 1)[0], original['TranscodingUrl'])
        self.assertTrue(changed['TranscodingUrl'].endswith('SubtitleStreamIndex=-1&subtitlestreamindex=2&SubtitleMethod=Hls'))

    def test_false_controls_leave_ordinary_contract_exact(self):
        first, second = media.negotiation({}), media.negotiation({})
        faults.apply(second, {k: False for k in faults.CONTROLS}, 1, [], [])
        self.assertEqual(first, second)


if __name__ == '__main__': unittest.main()
