import AVFoundation
import XCTest
@testable import ReelTV

@MainActor final class TVSubtitleSelectionTests: XCTestCase {
    typealias Option = PlaybackSubtitleSelection.NativeOption

    private func stream(_ index: Int = 2, _ title: String? = "English full", _ language: String? = "eng", delivery: String? = nil) -> MediaStream {
        MediaStream(Index: index, Type: "Subtitle", DisplayTitle: title, Codec: "vtt", Language: language, DeliveryMethod: delivery)
    }

    private func option(_ title: String = "English full", _ language: String? = "en", playable: Bool = true) -> Option {
        Option(titles: [title], language: language, playable: playable)
    }

    func testUniqueFullNameMapsProviderIndexWithoutArrayPosition() throws {
        let streams = [stream(2), stream(7, "French full", "fre")]
        XCTAssertEqual(try PlaybackSubtitleSelection.optionIndex(requested: 7, streams: streams, options: [option("French full", "fr"), option()]), 0)
    }

    func testSameLanguageForcedAndSDHNamesRemainDistinct() throws {
        let streams = [stream(2), stream(4, "English forced"), stream(9, "English SDH")]
        let options = [option("English SDH"), option(), option("English forced")]
        XCTAssertEqual(try PlaybackSubtitleSelection.optionIndex(requested: 4, streams: streams, options: options), 2)
        XCTAssertEqual(try PlaybackSubtitleSelection.optionIndex(requested: 9, streams: streams, options: options), 0)
    }

    func testDuplicateNativeTitlesRejectAmbiguousForcedOrSDHVariants() {
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream()], options: [option(), option()]))
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream()], options: [option(playable: false), option()]))
    }

    func testDuplicateProviderNamesCannotStandInForRequestedIndex() {
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream(), stream(4)], options: [option()]))
    }

    func testConflictingLanguageRejectsEvenAnExactName() {
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream()], options: [option("English full", "fr")]))
    }

    func testISOAliasesAndUnknownLanguageTags() {
        XCTAssertFalse(PlaybackSubtitleSelection.languagesConflict("eng", "en"))
        XCTAssertFalse(PlaybackSubtitleSelection.languagesConflict("fre", "fr"))
        XCTAssertFalse(PlaybackSubtitleSelection.languagesConflict("fra", "fr"))
        XCTAssertFalse(PlaybackSubtitleSelection.languagesConflict("und", "en"))
        XCTAssertFalse(PlaybackSubtitleSelection.languagesConflict("und-Latn", "en"))
        XCTAssertFalse(PlaybackSubtitleSelection.languagesConflict(nil, "en"))
        XCTAssertFalse(PlaybackSubtitleSelection.languagesConflict("unknown", "en"))
        XCTAssertTrue(PlaybackSubtitleSelection.languagesConflict("eng", "fr"))
        XCTAssertTrue(PlaybackSubtitleSelection.languagesConflict("pt-BR", "pt-PT"))
        XCTAssertTrue(PlaybackSubtitleSelection.languagesConflict("zh-Hans", "zh-Hant"))
    }

    func testSingleOptionFallbackRequiresMissingMetadataAndOneProvider() throws {
        XCTAssertEqual(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream()], options: [Option(titles: [], language: "en", playable: true)]), 0)
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream()], options: [option("Different track")]))
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream(), stream(4, "English forced")], options: [Option(titles: [], language: "en", playable: true)]))
    }

    func testUnplayableOrMissingRequestedTrackFailsClearly() {
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream()], options: [option(playable: false)]))
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 8, streams: [stream()], options: [option()]))
        XCTAssertThrowsError(try PlaybackSubtitleSelection.optionIndex(requested: 2, streams: [stream()], options: []))
    }

    func testOnlyAuthoritativeEncodeDeliveryBypassesNativeSelection() {
        var source = MediaSource(Id: "source", TranscodingUrl: "/master.m3u8?SubtitleMethod=Encode")
        XCTAssertTrue(PlaybackSubtitleSelection.isEncoded(source: source, selected: nil))
        source.TranscodingUrl = "/Encode/master.m3u8?note=SubtitleMethod%3DEncode"
        XCTAssertFalse(PlaybackSubtitleSelection.isEncoded(source: source, selected: nil))
        source.TranscodingUrl = "/master.m3u8?SubtitleMethod=Encode&SubtitleMethod=Hls"
        XCTAssertFalse(PlaybackSubtitleSelection.isEncoded(source: source, selected: nil))
        source.TranscodingUrl = "/master.m3u8?SubtitleMethod=EncodeSomething"
        XCTAssertFalse(PlaybackSubtitleSelection.isEncoded(source: source, selected: nil))
        XCTAssertTrue(PlaybackSubtitleSelection.isEncoded(source: source, selected: stream(delivery: "Encode")))
    }

    func testConflictingBurnedTrackOrDeliveryNeverBypassesSelection() {
        var source = MediaSource(Id: "source", TranscodingUrl: "/master.m3u8?SubtitleMethod=Encode&SubtitleStreamIndex=3")
        XCTAssertThrowsError(try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: stream(), requested: 2))
        source.TranscodingUrl = "/master.m3u8?SubtitleMethod=Encode&SubtitleStreamIndex=2"
        XCTAssertTrue(try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: stream(), requested: 2))
        XCTAssertThrowsError(try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: stream(delivery: "Hls"), requested: 2))
        source.TranscodingUrl = "/master.m3u8?SubtitleMethod=Hls"
        XCTAssertThrowsError(try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: stream(delivery: "Encode"), requested: 2))
        source.TranscodingUrl = "/master.m3u8?SubtitleMethod=Encode&SubtitleStreamIndex=2&SubtitleStreamIndex=3"
        XCTAssertThrowsError(try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: stream(), requested: 2))
        source.TranscodingUrl = "/master.m3u8?SubtitleMethod=Encode"
        source.DefaultSubtitleStreamIndex = 3
        XCTAssertThrowsError(try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: stream(), requested: 2))
        XCTAssertThrowsError(try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: nil, requested: -1))
    }

    func testNilDoesNotLoadOrApplyAnyMediaSelection() async throws {
        let prepared = try await PlaybackSubtitleSelection.prepare(asset: AVURLAsset(url: URL(string: "http://127.0.0.1:1/unreachable.m3u8")!), requested: nil, source: MediaSource(Id: "source"), streams: [])
        XCTAssertNil(prepared.group)
        XCTAssertNil(prepared.option)
    }

    func testEncodeWithoutLegibleGroupRemainsServerRendered() async throws {
        let prepared = try await PlaybackSubtitleSelection.prepare(asset: AVURLAsset(url: URL(string: "http://127.0.0.1:1/unreachable.m3u8")!), requested: 2, source: MediaSource(Id: "source"), streams: [stream(delivery: "Encode")])
        XCTAssertNil(prepared.group)
    }

    func testActualNativeOffOverridesAnOnSelectionWithoutTouchingAudioPolicy() async throws {
        try TVFixture.requireQAHost()
        let asset = AVURLAsset(url: URL(string: "http://127.0.0.1:18966/Videos/reel-tracks/original440/on/master.m3u8?ApiKey=fixture-tv-track-output")!)
        let loaded = try await asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loaded)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        try await PlaybackAudio.activate()
        defer { player.pause(); player.replaceCurrentItem(with: nil); PlaybackAudio.deactivate() }
        player.play()
        try await waitForDecodedPlayback(player)
        item.select(try XCTUnwrap(group.options.first), in: group)
        try await waitForSelection(true, item: item, group: group)
        XCTAssertNotNil(item.currentMediaSelection.selectedMediaOption(in: group))
        let audibleBefore = criteria(player.mediaSelectionCriteria(forMediaCharacteristic: .audible))
        let off = try await PlaybackSubtitleSelection.prepare(asset: asset, requested: -1, source: MediaSource(Id: "source"), streams: [stream(2, "Synthetic captions", nil)])
        off.apply(to: item)
        try await waitForSelection(false, item: item, group: group)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertTrue(player.appliesMediaSelectionCriteriaAutomatically)
        XCTAssertEqual(criteria(player.mediaSelectionCriteria(forMediaCharacteristic: .audible)), audibleBefore)
    }

    func testDirectRouteOffAdmissionIgnoresUnusedEncodeFallbackAndStillSelectsNativeNil() async throws {
        try TVFixture.requireQAHost()
        let asset = AVURLAsset(url: URL(string: "http://127.0.0.1:18966/Videos/reel-tracks/original440/on/master.m3u8?ApiKey=fixture-tv-track-output")!)
        let loaded = try await asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loaded)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        try await PlaybackAudio.activate()
        defer { player.pause(); player.replaceCurrentItem(with: nil); PlaybackAudio.deactivate() }
        player.play()
        try await waitForDecodedPlayback(player)
        item.select(try XCTUnwrap(group.options.first), in: group)
        try await waitForSelection(true, item: item, group: group)
        XCTAssertNotNil(item.currentMediaSelection.selectedMediaOption(in: group))
        let audibleBefore = criteria(player.mediaSelectionCriteria(forMediaCharacteristic: .audible))
        let unused = MediaSource(Id: "source", SupportsDirectPlay: true,
            TranscodingUrl: "/Videos/unused/master.m3u8?SubtitleStreamIndex=2&SubtitleMethod=Encode", DefaultSubtitleStreamIndex: -1,
            MediaStreams: [MediaStream(Index: 1, Type: "Audio"), stream(2, "Synthetic captions", nil)])
        let off = try await PlaybackSubtitleSelection.prepare(asset: asset, requested: -1, source: unused,
            streams: try XCTUnwrap(unused.MediaStreams), route: .directPlay)
        off.apply(to: item)
        try await waitForSelection(false, item: item, group: group)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        XCTAssertTrue(player.appliesMediaSelectionCriteriaAutomatically)
        XCTAssertEqual(criteria(player.mediaSelectionCriteria(forMediaCharacteristic: .audible)), audibleBefore)
    }

    func testActualNativeExplicitOnCanBeChangedToOffLater() async throws {
        try TVFixture.requireQAHost()
        let asset = AVURLAsset(url: URL(string: "http://127.0.0.1:18966/Videos/reel-tracks/original440/on/master.m3u8?ApiKey=fixture-tv-track-output")!)
        let loaded = try await asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(loaded)
        let item = AVPlayerItem(asset: asset)
        let player = AVPlayer(playerItem: item)
        try await PlaybackAudio.activate()
        defer { player.pause(); player.replaceCurrentItem(with: nil); PlaybackAudio.deactivate() }
        player.play()
        try await waitForDecodedPlayback(player)
        item.select(nil, in: group)
        try await waitForSelection(false, item: item, group: group)
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
        let on = try await PlaybackSubtitleSelection.prepare(asset: asset, requested: 2, source: MediaSource(Id: "source"), streams: [stream(2, "Synthetic captions", nil)])
        on.apply(to: item)
        try await waitForSelection(true, item: item, group: group)
        XCTAssertNotNil(item.currentMediaSelection.selectedMediaOption(in: group))
        item.select(nil, in: group)
        try await waitForSelection(false, item: item, group: group)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(item.currentMediaSelection.selectedMediaOption(in: group))
    }

    private func waitForDecodedPlayback(_ player: AVPlayer) async throws {
        for _ in 0..<150 {
            if player.currentItem?.status == .readyToPlay, (player.currentItem?.presentationSize.width ?? 0) > 0, player.currentTime().seconds > 0.5 { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("The native selection precondition requires a ready, decoded, advancing item.")
        throw URLError(.timedOut)
    }

    private func waitForSelection(_ selected: Bool, item: AVPlayerItem, group: AVMediaSelectionGroup) async throws {
        for _ in 0..<100 {
            if (item.currentMediaSelection.selectedMediaOption(in: group) != nil) == selected { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("The actual native legible selection did not reach the requested state.")
    }
    private struct Criteria: Equatable {
        let exists: Bool
        let languages: [String]?
        let characteristics: [String]?
        let principal: [String]?
    }
    private func criteria(_ value: AVPlayerMediaSelectionCriteria?) -> Criteria {
        Criteria(exists: value != nil, languages: value?.preferredLanguages,
                 characteristics: value?.preferredMediaCharacteristics?.map(\.rawValue),
                 principal: value?.principalMediaCharacteristics?.map(\.rawValue))
    }

}
