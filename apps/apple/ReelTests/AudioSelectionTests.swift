import Foundation
import XCTest
#if canImport(ReelTV)
@testable import ReelTV
#else
@testable import Reel
#endif

final class AudioSelectionTests: XCTestCase {
    typealias Option = PlaybackAudioSelection.NativeOption
    private func stream(_ index: Int, _ language: String? = nil, _ name: String? = nil, raw: String? = nil, original: Bool? = nil, defaultTrack: Bool? = nil) -> MediaStream {
        MediaStream(Index: index, Type: "Audio", DisplayTitle: name, Language: language, Title: raw, IsOriginal: original, IsDefault: defaultTrack)
    }
    private func source(_ streams: [MediaStream]) -> MediaSource { MediaSource(Id: "exact-negotiated-source", MediaStreams: streams) }
    private func option(_ name: String? = nil, _ language: String? = nil, roles: Set<PlaybackAudioSelection.Role> = [], playable: Bool = true) -> Option {
        Option(titles: name.map { [$0] } ?? [], language: language, roles: roles, playable: playable)
    }

    func testProviderIndexIsNotNativeArrayPositionAndUsesExactName() throws {
        let en = option("English full", "en"), es = option("Spanish full", "es")
        let media = source([stream(1, "eng", "English full"), stream(7, "spa", "Spanish full")])
        XCTAssertEqual(try PlaybackAudioSelection.providerIndex(selected: es, options: [en, es], source: media), 7)
        XCTAssertEqual(try PlaybackAudioSelection.optionIndex(requested: 7, options: [en, es], source: media), 1)
    }
    func testAConvertedStreamUsesTheTrackTheServerWasAskedFor() {
        // Two English tracks: the stream's one native track matches both, so the native match refuses.
        var media = source([stream(1, "eng", "English 5.1"), stream(2, "eng", "English Stereo"), stream(3, "spa")])
        media.DefaultAudioStreamIndex = 1
        let single = option(nil, "en")
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: single, options: [single], source: media))
        XCTAssertEqual(PlaybackAudioSelection.servedIndex(method: "Transcode", nativeOptions: 1, requested: 2, source: media), 2)
        XCTAssertEqual(PlaybackAudioSelection.servedIndex(method: "DirectStream", nativeOptions: 1, requested: nil, source: media), 1)
        // Direct play carries every track, and a stream with several tracks still needs the native match.
        XCTAssertNil(PlaybackAudioSelection.servedIndex(method: "DirectPlay", nativeOptions: 1, requested: 2, source: media))
        XCTAssertNil(PlaybackAudioSelection.servedIndex(method: "Transcode", nativeOptions: 2, requested: 2, source: media))
        // A requested index the source does not hold is never trusted.
        XCTAssertNil(PlaybackAudioSelection.servedIndex(method: "Transcode", nativeOptions: 1, requested: 9, source: media))
        media.DefaultAudioStreamIndex = nil
        XCTAssertNil(PlaybackAudioSelection.servedIndex(method: "Transcode", nativeOptions: 1, requested: nil, source: media))
    }
    func testKnownLanguageAliasesAreMatchedWithoutNames() throws {
        for (provider, native) in [("eng", "en"), ("spa", "es"), ("fre", "fr"), ("ger", "de"), ("dut", "nl"), ("chi", "zh")] {
            let selected = option(nil, native)
            XCTAssertEqual(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(9, provider)])), 9)
        }
    }
    func testUnknownLanguageCannotBecomeALanguageFallback() {
        for tag: String? in [nil, "", " ", "und", "und-Latn", "unknown", "zzz", "mul", "mis", "zxx"] {
            let selected = option(nil, tag)
            XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(8, tag)])))
        }
    }
    func testUniqueFullTitleCanIdentifyTrackWithUnknownLanguage() throws {
        let selected = option("Exact authored title", "und")
        XCTAssertEqual(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(5, "und", "Exact authored title")])), 5)
    }
    func testConflictingLanguageCannotBeOverriddenByTitle() {
        let selected = option("Same title", "pt-PT")
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(1, "pt-BR", "Same title")])))
    }
    func testDuplicateProviderIndicesFailEvenWithDifferentNames() {
        let selected = option("Spanish", "es")
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(2, "spa", "Spanish"), stream(2, "eng", "English")])))
    }
    func testDuplicateProviderIdentitiesNeverUseDefaultAsTieBreaker() {
        let selected = option("English", "en")
        let media = source([stream(2, "eng", "English", defaultTrack: true), stream(4, "eng", "English", defaultTrack: false)])
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: media))
        XCTAssertThrowsError(try PlaybackAudioSelection.optionIndex(requested: 2, options: [selected], source: media))
    }
    func testMixedPlayabilityNativeDuplicatesRemainAmbiguous() {
        let selected = option("English", "en")
        let media = source([stream(2, "eng", "English")])
        let options = [option("English", "en", playable: false), selected]
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: options, source: media))
        XCTAssertThrowsError(try PlaybackAudioSelection.optionIndex(requested: 2, options: options, source: media))
    }
    func testUniqueUnplayableNativeIdentityIsRejected() {
        let selected = option("English", "en", playable: false)
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(2, "eng", "English")])))
        XCTAssertThrowsError(try PlaybackAudioSelection.optionIndex(requested: 2, options: [selected], source: source([stream(2, "eng", "English")])))
    }
    func testSameLanguageMainAndCommentaryWithoutIdentityFail() {
        let selected = option(nil, "en")
        let media = source([stream(2, "eng", "Main", defaultTrack: true), stream(4, "eng", "Commentary")])
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: media))
    }
    func testExactCommentaryNameCanMapWithoutSelectingMainByDefault() throws {
        let main = option("Main", "en"), commentary = option("Commentary", "en", roles: [.auxiliary])
        let media = source([stream(2, "eng", "Main", defaultTrack: true), stream(4, "eng", "Commentary")])
        XCTAssertEqual(try PlaybackAudioSelection.providerIndex(selected: commentary, options: [main, commentary], source: media), 4)
    }
    func testAccessibilityRoleCannotUseLanguageOnlyFallback() {
        let selected = option(nil, "es", roles: [.description])
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(4, "spa")])))
    }
    func testConflictingRawTitleCannotUseLanguageOnlyFallback() {
        let selected = option("Main", "es")
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(4, "spa", "Spanish AAC", raw: "Commentary")])))
    }
    func testPositiveOriginalCharacteristicCannotMapToKnownNonOriginal() {
        let selected = option("English", "en", roles: [.original])
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: source([stream(4, "eng", "English", original: false)])))
    }
    func testLocalNativeIdentityRequiresUniquePlayableMatch() throws {
        let en = option("Main", "en"), es = option("Principal", "es")
        XCTAssertEqual(try PlaybackAudioSelection.optionIndex(identity: es, options: [en, es]), 1)
        XCTAssertThrowsError(try PlaybackAudioSelection.optionIndex(identity: es, options: [es, es]))
    }
    func testChangedProviderIdentityCannotReuseAnOldIndexButDefaultChangeIsNotIdentity() {
        let first = stream(7, "spa", "Main", raw: "Principal", original: true, defaultTrack: false)
        let changed = stream(7, "spa", "Commentary", raw: "Comentario", original: false, defaultTrack: true)
        let defaultChanged = stream(7, "es", "Main", raw: "Principal", original: true, defaultTrack: true)
        XCTAssertFalse(PlaybackAudioSelection.sameProviderIdentity(first, changed))
        XCTAssertTrue(PlaybackAudioSelection.sameProviderIdentity(first, defaultChanged))
    }
    func testCaptionProviderRoleChangeAtSameIndexIsDifferentIdentity() {
        let first = MediaStream(Index: 2, Type: "Subtitle", DisplayTitle: "English full", Language: "eng", IsForced: false, IsHearingImpaired: false)
        var forced = first; forced.IsForced = true
        var sdh = first; sdh.IsHearingImpaired = true
        XCTAssertFalse(PlaybackAudioSelection.sameProviderIdentity(first, forced))
        XCTAssertFalse(PlaybackAudioSelection.sameProviderIdentity(first, sdh))
        XCTAssertFalse(PlaybackAudioSelection.sameProviderIdentity(first, stream(2, "eng", "English full")))
    }
    func testNewOptionalIdentityFieldsTolerateMalformedValues() throws {
        let data = Data(#"{"Index":7,"Type":"Audio","Title":42,"IsOriginal":"yes","IsDefault":[],"IsForced":"true","IsHearingImpaired":2,"Channels":2}"#.utf8)
        let decoded = try JSONDecoder().decode(MediaStream.self, from: data)
        XCTAssertNil(decoded.Title); XCTAssertNil(decoded.IsOriginal); XCTAssertNil(decoded.IsDefault); XCTAssertNil(decoded.IsForced); XCTAssertNil(decoded.IsHearingImpaired)
        XCTAssertEqual(decoded.Channels, 2)
    }
    func testOptionalIdentityFieldsRoundTripWithoutChangingExistingMetadata() throws {
        let original = stream(7, "spa", "Spanish AAC", raw: "Principal", original: true, defaultTrack: false)
        XCTAssertEqual(try JSONDecoder().decode(MediaStream.self, from: JSONEncoder().encode(original)), original)
    }
    private func capturedTracks(audio: MediaStream? = nil, subtitle: MediaStream? = nil) -> PlaybackTrackSelection {
        PlaybackTrackSelection(sourceID: "exact-negotiated-source", audioIndex: audio?.Index, audio: audio,
                               subtitleIndex: subtitle?.Index ?? -1, subtitle: subtitle)
    }
    func testCapturedCastIdentityAcceptsOnlyUniqueExactSourceAndProvider() throws {
        let audio = stream(7, "spa", "Spanish full", raw: "Principal", original: true)
        let selection = capturedTracks(audio: audio)
        XCTAssertEqual(try selection.source(in: [source([audio])]).Id, "exact-negotiated-source")
        XCTAssertThrowsError(try selection.source(in: [source([audio]), source([audio])]))
        XCTAssertThrowsError(try selection.source(in: [MediaSource(Id: "another", MediaStreams: [audio])]))
    }
    func testCapturedCastAudioRejectsChangedTitleLanguageOriginalAndMissingMetadata() {
        let audio = stream(7, "spa", "Spanish full", raw: "Principal", original: true)
        let selection = capturedTracks(audio: audio)
        for changed in [stream(7, "eng", "Spanish full", raw: "Principal", original: true),
                        stream(7, "spa", "Commentary", raw: "Comentario", original: true),
                        stream(7, "spa", "Spanish full", raw: "Principal", original: false)] {
            XCTAssertThrowsError(try selection.validate(source([changed])))
        }
        XCTAssertThrowsError(try selection.validate(MediaSource(Id: "exact-negotiated-source")))
        XCTAssertThrowsError(try selection.validate(source([])))
        XCTAssertThrowsError(try selection.validate(source([audio, audio])))
    }
    func testCapturedCastSubtitleRejectsRoleOrTitleChangeAndDuplicateIndex() {
        let subtitle = MediaStream(Index: 2, Type: "Subtitle", DisplayTitle: "English full", Language: "eng", DeliveryMethod: "Encode", IsForced: false, IsHearingImpaired: false)
        let selection = capturedTracks(subtitle: subtitle)
        var forced = subtitle; forced.IsForced = true
        var sdh = subtitle; sdh.IsHearingImpaired = true
        var title = subtitle; title.DisplayTitle = "Commentary"
        for changed in [forced, sdh, title] { XCTAssertThrowsError(try selection.validate(source([changed]))) }
        XCTAssertThrowsError(try selection.validate(source([subtitle, subtitle])))
    }
    func testCapturedEncodeIdentityAndNoAudioSourceNeedNoInventedNativeIdentity() throws {
        let subtitle = MediaStream(Index: 2, Type: "Subtitle", DisplayTitle: "English full", Language: "eng", DeliveryMethod: "Encode")
        try capturedTracks(subtitle: subtitle).validate(source([subtitle]))
        try capturedTracks().validate(source([MediaStream(Index: 0, Type: "Video")]))
    }
    func testUncapturedCastAudioAndUnspecifiedSubtitlesCannotBecomeNewDefaults() {
        let audio = stream(1, "eng", "Main")
        var media = source([audio]); media.DefaultAudioStreamIndex = 1
        XCTAssertThrowsError(try capturedTracks().validate(media))
        let subtitle = MediaStream(Index: 2, Type: "Subtitle", DisplayTitle: "English", Language: "eng")
        var on = source([subtitle]); on.DefaultSubtitleStreamIndex = 2
        let unspecified = PlaybackTrackSelection(sourceID: on.Id, audioIndex: nil, audio: nil, subtitleIndex: nil, subtitle: nil)
        XCTAssertThrowsError(try unspecified.validate(on))
    }
    func testExplicitOffAcceptsDetailsDefaultButRejectsNegotiatedEnabledSubtitles() throws {
        let subtitle = MediaStream(Index: 2, Type: "Subtitle", DisplayTitle: "English", Language: "eng")
        var media = source([subtitle]); media.DefaultSubtitleStreamIndex = 2
        let off = capturedTracks()
        XCTAssertEqual(off.subtitleIndex, -1)
        try off.validate(media)
        XCTAssertThrowsError(try off.validate(media, negotiated: true))
        media.DefaultSubtitleStreamIndex = -1
        try off.validate(media, negotiated: true)
        XCTAssertEqual(try off.source(in: [media], negotiated: true).Id, media.Id)
    }
    func testRestorationSelectsUniqueExactVersionInsteadOfFirstOrMatchingTrackLabels() throws {
        let original = source([stream(3, "spa", "Spanish")])
        let another = MediaSource(Id: "different-version", MediaStreams: original.MediaStreams)
        XCTAssertEqual(try PlaybackAudioSelection.restorationSource(in: [another, original], expectedID: original.Id).Id, original.Id)
        XCTAssertThrowsError(try PlaybackAudioSelection.restorationSource(in: [another], expectedID: original.Id))
        XCTAssertThrowsError(try PlaybackAudioSelection.restorationSource(in: [original, original], expectedID: original.Id))
        XCTAssertThrowsError(try PlaybackAudioSelection.restorationSource(in: [original], expectedID: ""))
        XCTAssertEqual(try PlaybackAudioSelection.restorationSource(in: [another], expectedID: nil).Id, another.Id)
    }
    func testLiveRestorationNeverGuessesAChangedTunerSourceIdentity() throws {
        let current = MediaSource(Id: "opened-tuner-source", LiveStreamId: "owned-tuner", RequiresClosing: true)
        let changed = MediaSource(Id: "new-tuner-source", LiveStreamId: "new-tuner", RequiresClosing: true)
        XCTAssertEqual(try PlaybackAudioSelection.restorationSource(in: [current], expectedID: current.Id).LiveStreamId, "owned-tuner")
        XCTAssertThrowsError(try PlaybackAudioSelection.restorationSource(in: [changed], expectedID: current.Id))
    }

    func testNegotiatedOffRejectsSelectedEncodePlanWithOffOrAbsentDefault() {
        for declared: Int? in [nil, -1] {
            var media = source([MediaStream(Index: 2, Type: "Subtitle", DisplayTitle: "English", Language: "eng")])
            media.DefaultSubtitleStreamIndex = declared
            media.TranscodingUrl = "/Videos/owned/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode"
            XCTAssertThrowsError(try capturedTracks().validate(media, negotiated: true))
        }
    }
    func testNegotiatedOffRejectsDuplicateConflictingOrMalformedPlanFacts() {
        for query in ["SubtitleStreamIndex=2&SubtitleMethod=Hls", "SubtitleStreamIndex=-1&SubtitleStreamIndex=-1",
                      "SubtitleStreamIndex=-1&subtitlestreamindex=2", "SubtitleMethod=Hls&SubtitleMethod=Hls",
                      "SubtitleMethod=Encode&SubtitleMethod=Hls", "SubtitleStreamIndex=invalid", "SubtitleStreamIndex",
                      "SubtitleMethod", "SubtitleMethod=Unknown"] {
            var media = source([]); media.TranscodingUrl = "/Videos/owned/master.m3u8?" + query
            XCTAssertThrowsError(try capturedTracks().validate(media, negotiated: true), query)
        }
    }
    func testNegotiatedOffAllowsAvailableCatalogAndUnusedDirectFallbackWithoutSelectingIt() throws {
        for query in ["", "?SubtitleStreamIndex=-1", "?SubtitleStreamIndex=-1&SubtitleMethod=Hls", "?SubtitleMethod=External"] {
            var media = source([MediaStream(Index: 2, Type: "Subtitle", DeliveryMethod: "Encode")])
            media.TranscodingUrl = "/Videos/owned/master.m3u8" + query
            try capturedTracks().validate(media, negotiated: true)
        }
        var direct = source([]); direct.SupportsDirectPlay = true
        direct.TranscodingUrl = "/Videos/unused/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode"
        try capturedTracks().validate(direct, negotiated: true)
    }
    func testSharedEncodedValueContractRetainsExactSelectionAndDeliveryConflicts() throws {
        var media = source([]); media.DefaultSubtitleStreamIndex = 2
        var selected = MediaStream(Index: 2, Type: "Subtitle", DeliveryMethod: "Encode")
        XCTAssertTrue(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: selected, requested: 2))
        XCTAssertThrowsError(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: selected, requested: -1))
        media.TranscodingUrl = "/Videos/owned/master.m3u8?SubtitleStreamIndex=3&SubtitleMethod=Encode"
        XCTAssertThrowsError(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: selected, requested: 2))
        media.TranscodingUrl = "/Videos/owned/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode"
        XCTAssertTrue(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: selected, requested: 2))
        selected.DeliveryMethod = "Hls"
        XCTAssertThrowsError(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: selected, requested: 2))
        media.TranscodingUrl = "/Videos/Encode/SubtitleMethod=Encode/master.m3u8"
        XCTAssertFalse(PlaybackSubtitlePlan.isEncoded(source: media, selected: nil), "Only exact query facts or authoritative selected delivery establish Encode.")
    }
    func testUnspecifiedCapturedSubtitlesCannotConcealAnExplicitSelectedPlan() {
        var media = source([]); media.TranscodingUrl = "/Videos/owned/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode"
        let unresolved = PlaybackTrackSelection(sourceID: media.Id, audioIndex: nil, audio: nil, subtitleIndex: nil, subtitle: nil)
        XCTAssertThrowsError(try unresolved.validate(media, negotiated: true))
    }

    func testDirectRouteOffDoesNotUseAnOfferedEncodeFallback() throws {
        var media = source([stream(1, "eng", "Main"), MediaStream(Index: 2, Type: "Subtitle", DeliveryMethod: "Encode")])
        media.SupportsDirectPlay = true; media.DefaultSubtitleStreamIndex = -1
        media.TranscodingUrl = "/Videos/unused/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode"
        XCTAssertFalse(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: nil, requested: -1, route: .directPlay))
        XCTAssertFalse(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: media.MediaStreams?.last, requested: 2, route: .directPlay), "A catalog delivery value cannot establish output on the selected direct route.")
    }
    func testSelectedTranscodeStillRejectsOffAndEncodedIdentityConflicts() throws {
        var media = source([stream(1, "eng", "Main"), MediaStream(Index: 2, Type: "Subtitle", DeliveryMethod: "Encode")])
        media.SupportsDirectPlay = true; media.DefaultSubtitleStreamIndex = -1
        media.TranscodingUrl = "/Videos/selected/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode"
        XCTAssertThrowsError(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: nil, requested: -1, route: .transcode), "The selected route, not an offered direct capability, establishes the output.")
        media.DefaultSubtitleStreamIndex = 2
        XCTAssertTrue(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: media.MediaStreams?.last, requested: 2, route: .transcode))
        XCTAssertThrowsError(try PlaybackSubtitlePlan.encodedDelivery(source: media, selected: media.MediaStreams?.last, requested: 3, route: .transcode))
    }
    func testEstablishedCastStopFencesCapturedContextAfterIndependentCleanup() {
        final class Client { var content: String?; init(_ content: String? = nil) { self.content = content } }
        final class Session { var client: Client; var connected = true; init(_ client: Client) { self.client = client } }
        let clientA = Client(), sessionA = Session(clientA), sessionB = Session(Client())
        var current: Session? = sessionA, stops = 0, cleaned: [String] = []
        func end(expectedSession: Session?, expectedClient: Client?, established: Bool = true, cleanup: () -> Void = {}) {
            cleaned.append("owned-jellyfin-A"); cleanup()
            guard let expectedSession, let expectedClient else { return }
            if CastSessionOwnership.mayStop(ownedContentID: "owned-title", receiverContentID: expectedClient.content, established: established,
                sameSession: current === expectedSession, sameClient: expectedSession.client === expectedClient, connected: expectedSession.connected) { stops += 1 }
        }
        current = sessionB; end(expectedSession: sessionA, expectedClient: clientA)
        XCTAssertEqual(stops, 0, "A replacement session with no media does not inherit A's Stop authority.")
        current = sessionA; sessionA.client = Client(); end(expectedSession: sessionA, expectedClient: clientA)
        XCTAssertEqual(stops, 0, "A replacement client in the same session is a new receiver context.")
        sessionA.client = clientA; sessionA.connected = false; end(expectedSession: sessionA, expectedClient: clientA)
        XCTAssertEqual(stops, 0)
        sessionA.connected = true; current = nil; end(expectedSession: sessionA, expectedClient: clientA)
        XCTAssertEqual(stops, 0)
        current = sessionA; end(expectedSession: sessionA, expectedClient: nil)
        XCTAssertEqual(stops, 0)
        end(expectedSession: sessionA, expectedClient: clientA)
        XCTAssertEqual(stops, 1, "An established same connected session/client may stop its own nil-content context.")
        clientA.content = "owned-title"; end(expectedSession: sessionA, expectedClient: clientA)
        XCTAssertEqual(stops, 2)
        clientA.content = "foreign-title"; end(expectedSession: sessionA, expectedClient: clientA)
        XCTAssertEqual(stops, 2)
        clientA.content = nil; end(expectedSession: sessionA, expectedClient: clientA, established: false)
        XCTAssertEqual(stops, 2, "An unestablished Load never grants receiver Stop authority.")
        end(expectedSession: sessionA, expectedClient: clientA, cleanup: { current = sessionB })
        XCTAssertEqual(stops, 2, "The current SDK context must be rechecked after old local cleanup.")
        XCTAssertEqual(cleaned, Array(repeating: "owned-jellyfin-A", count: 10), "Old Jellyfin cleanup is independent; B is neither cleaned nor stopped.")
    }

    func testUnknownEffectiveAudioNeverFallsBackToDeclaredDefault() {
        let aac = MediaStream(Index: 1, Type: "Audio", Codec: "aac", Channels: 2, SampleRate: 48000)
        let flac = MediaStream(Index: 3, Type: "Audio", Codec: "flac", Channels: 6, SampleRate: 96000)
        let media = MediaSource(Id: "format", DefaultAudioStreamIndex: 1, MediaStreams: [aac, flac])
        let unknown = PlaybackFormat.describe(source: media, method: "DirectPlay", audio: .unresolved)
        XCTAssertTrue(unknown.source.contains("Current audio selection unknown"))
        XCTAssertFalse(unknown.source.contains("AAC")); XCTAssertFalse(unknown.source.contains("FLAC")); XCTAssertFalse(unknown.source.contains("kHz"))
        let actual = PlaybackFormat.describe(source: media, method: "DirectPlay", audio: .effective(3))
        XCTAssertTrue(actual.source.contains("FLAC")); XCTAssertTrue(actual.source.contains("96 kHz")); XCTAssertFalse(actual.source.contains("AAC"))
        XCTAssertTrue(PlaybackFormat.describe(source: media, method: "DirectPlay", audio: .serverIntent(nil)).source.contains("AAC"))
    }
    func testUnknownEffectiveAudioDoesNotUseSingleTrackFallback() {
        let audio = MediaStream(Index: 1, Type: "Audio", Codec: "aac")
        let media = source([audio])
        XCTAssertFalse(PlaybackFormat.describe(source: media, method: "DirectPlay", audio: .unresolved).source.contains("AAC"))
        XCTAssertTrue(PlaybackFormat.describe(source: media, method: "DirectPlay", audio: .serverIntent(nil)).source.contains("AAC"))
    }

    func testDisclosureLanguageNameUsesKnownAliasesAndNeverRawUnknownTags() {
        XCTAssertEqual(PlaybackAudioSelection.languageName("spa"), PlaybackAudioSelection.languageName("es"))
        XCTAssertNotNil(PlaybackAudioSelection.languageName("es"))
        XCTAssertNil(PlaybackAudioSelection.languageName("und"))
        XCTAssertNil(PlaybackAudioSelection.languageName("malformed-private-label"))
    }

}
