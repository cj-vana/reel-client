import AVFoundation
import XCTest
@testable import ReelTV

@MainActor final class TVTrackOutputTests: XCTestCase {
    func testAlternateVersionEnablesTheNegotiatedAACRendition() async throws {
        try await verify(source: "movie-1-alternate", audio: 4, subtitle: -1, variant: "alternate880")
    }

    func testExplicitAlternateAudioEnablesItsAACWithoutSubtitles() async throws {
        try await verify(source: "movie-1-source", audio: 3, subtitle: -1, variant: "original880")
    }

    func testRequestedWebVTTIsSelectedByTheUnmodifiedPlayer() async throws {
        try await verify(source: "movie-1-source", audio: 1, subtitle: 2, variant: "original440")
    }

    func testAlternateFixtureMetadataMapsItsActualTaggedNativeOptionWithoutWeakeningUnknownRefusal() throws {
        let selected = PlaybackAudioSelection.NativeOption(titles: ["Synthetic 880 Hz"], language: "en", roles: [], playable: true)
        let known = MediaSource(Id: "movie-1-alternate", MediaStreams: [MediaStream(Index: 4, Type: "Audio", DisplayTitle: "Alternate 880 Hz", Language: "eng")])
        XCTAssertEqual(try PlaybackAudioSelection.optionIndex(requested: 4, options: [selected], source: known), 0)
        XCTAssertEqual(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: known), 4)
        let unknown = MediaSource(Id: "movie-1-alternate", MediaStreams: [MediaStream(Index: 4, Type: "Audio", DisplayTitle: "Alternate 880 Hz")])
        XCTAssertThrowsError(try PlaybackAudioSelection.optionIndex(requested: 4, options: [selected], source: unknown))
        XCTAssertThrowsError(try PlaybackAudioSelection.providerIndex(selected: selected, options: [selected], source: unknown))
    }

    private func verify(source: String, audio: Int, subtitle: Int, variant: String) async throws {
        try await TVFixture.reset()
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18966")!, token: "fixture-tv-track-output", userID: "tv-track-output", deviceID: "tv-track-output-qa", historyEnabled: false)
        let media = try await api.item("movie-1")
        let player = PlaybackController()
        do {
            player.present(media, audio: audio, subtitle: subtitle, fromBeginning: true, mediaSourceID: source)
            player.start(api: api, quality: .original)
            for _ in 0..<150 {
                if player.error != nil || (player.isPlaying && player.player.currentTime().seconds > 0.5) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            XCTAssertNil(player.error)
            XCTAssertEqual(player.player.currentItem?.status, .readyToPlay)
            XCTAssertEqual(player.method, "Transcode")
            XCTAssertGreaterThan(player.player.currentTime().seconds, 0.5)
            XCTAssertGreaterThan(player.player.currentItem?.presentationSize.width ?? 0, 0)
            let item = try XCTUnwrap(player.player.currentItem)
            let url = try XCTUnwrap((item.asset as? AVURLAsset)?.url)
            XCTAssertTrue(url.path.contains("/" + variant + "/"))
            let loadedAudio = try await item.asset.loadMediaSelectionGroup(for: .audible)
            let group = try XCTUnwrap(loadedAudio)
            let selectedAudio = try XCTUnwrap(item.currentMediaSelection.selectedMediaOption(in: group))
            XCTAssertEqual(selectedAudio.mediaType, .audio)
            XCTAssertTrue(selectedAudio.isPlayable)
            var enabledAudioTracks = 0
            for track in item.tracks where track.isEnabled {
                if let assetTrack = track.assetTrack, assetTrack.mediaType == .audio { enabledAudioTracks += 1 }
            }
            XCTAssertGreaterThan(enabledAudioTracks, 0)
            let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
            if subtitle == 2 {
                for _ in 0..<100 {
                    if let legible, item.currentMediaSelection.selectedMediaOption(in: legible) != nil { break }
                    try await Task.sleep(for: .milliseconds(100))
                }
            }
            let selectedCaption = legible.flatMap { item.currentMediaSelection.selectedMediaOption(in: $0) }
            XCTAssertEqual(selectedCaption != nil, subtitle == 2)
            // LANGUAGE=en is localized to English by AVKit. Rendition identity
            // comes from the selected asset URL and the independently decoded
            // fixture bytes, rather than a frequency in the display name.
            let attachment = XCTAttachment(string: "variant=\(variant) selectedAudio=\(selectedAudio.displayName) enabledAudioTracks=\(enabledAudioTracks) legibleOptions=\(legible?.options.map(\.displayName) ?? []) selectedCaption=\(selectedCaption?.displayName ?? "none") position=\(player.player.currentTime().seconds)")
            attachment.name = "Actual native HLS media selection"
            attachment.lifetime = .keepAlways; add(attachment)
            player.stop(); await player.flushReports()
        } catch {
            player.stop(); await player.flushReports()
            throw error
        }
    }
}
