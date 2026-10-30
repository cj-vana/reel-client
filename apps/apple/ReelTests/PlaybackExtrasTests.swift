import XCTest
@testable import Reel

final class PlaybackExtrasTests: XCTestCase {
    func testTrickplayGridSelectsSheetAndCellOnOriginalTimeline() throws {
        let info = TrickplayInfo(Width: 160, Height: 90, TileWidth: 2, TileHeight: 2, ThumbnailCount: 10, Interval: 2000)
        XCTAssertEqual(info.frame(at: 0), TrickplayFrame(sheet: 0, thumbnail: 0, rect: CGRect(x: 0, y: 0, width: 160, height: 90)))
        XCTAssertEqual(info.frame(at: 14), TrickplayFrame(sheet: 1, thumbnail: 7, rect: CGRect(x: 160, y: 90, width: 160, height: 90)))
        XCTAssertEqual(info.frame(at: 20_000)?.thumbnail, 9)
        XCTAssertEqual(info.frame(at: -10)?.thumbnail, 0)
        XCTAssertNil(info.frame(at: .infinity))
        XCTAssertNil(TrickplayInfo(Width: 2048, Height: 2048, TileWidth: 50, TileHeight: 50, ThumbnailCount: 12, Interval: 2000).frame(at: 0))
        XCTAssertNil(TrickplayInfo(Width: 160, Height: 90, TileWidth: 2, TileHeight: 2, ThumbnailCount: 0, Interval: 2000).frame(at: 0))
    }

    func testTrickplayVersionSelectionNeverUsesAnotherVersion() throws {
        let data = Data(#"{"Trickplay":{"version-a":{"160":{"Width":160,"Height":90,"TileWidth":2,"TileHeight":2,"ThumbnailCount":10,"Interval":2000}},"version-b":{"320":{"Width":320,"Height":180,"TileWidth":2,"TileHeight":2,"ThumbnailCount":12,"Interval":1000}}}}"#.utf8)
        let metadata = try JSONDecoder().decode(TrickplayMetadata.self, from: data)
        XCTAssertEqual(metadata.selected(sourceID: "version-b", itemID: "movie")?.info.Width, 320)
        XCTAssertNil(metadata.selected(sourceID: "version-missing", itemID: "movie"))
        XCTAssertNil(metadata.selected(sourceID: nil, itemID: "movie"))
    }

    func testCastBitratePreservesStricterLimitsAndCapsOriginalForReceiver() throws {
        for (effective, expected) in [(250_000, 250_000), (2_000_000, 2_000_000), (4_000_000, 4_000_000),
                                      (8_000_000, 8_000_000), (20_000_000, 20_000_000), (120_000_000, 20_000_000)] {
            XCTAssertEqual(try CastBitratePolicy.receiverBitrate(effective), expected)
        }
        for invalid in [Int.min, -1, 0, 249_999, 120_000_001, Int.max] {
            XCTAssertThrowsError(try CastBitratePolicy.receiverBitrate(invalid)) { error in
                guard case CastPlaybackError.invalidBitrate = error else { return XCTFail("Invalid quality must fail explicitly: \(error)") }
            }
        }
    }

    @MainActor func testInvalidCastBitrateRejectsBeforeMediaPreparationOrReceiverConfiguration() async {
        // No server is needed: invalid input must fail before the first metadata request.
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:1")!, token: "fixture-cast-invalid", userID: "cast-invalid", deviceID: "cast-tests")
        let item = MediaItem(Id: "must-not-request", Name: "Invalid bitrate")
        let selection = PlaybackTrackSelection(sourceID: "must-not-request-source", audioIndex: nil, audio: nil, subtitleIndex: -1, subtitle: nil)
        let cast = CastCoordinator()
        for invalid in [Int.min, 0, 249_999, 120_000_001, Int.max] {
            do {
                _ = try await api.prepareCast(item, position: 0, bitrate: invalid)
                XCTFail("Invalid quality must not prepare media.")
            } catch {
                guard case CastPlaybackError.invalidBitrate = error else { return XCTFail("Unexpected media preparation: \(error)") }
            }
            XCTAssertNil(cast.cast(item, api: api, position: 0, bitrate: invalid, selection: selection, admitted: { true }, onStarted: { true }))
            XCTAssertEqual(cast.error, CastPlaybackError.invalidBitrate.localizedDescription)
            XCTAssertFalse(cast.loading)
        }
    }

    func testCastRequiresMediaAndSharedDevicePermissions() throws {
        let denied = try JSONDecoder().decode(CastUserPermissions.self, from: Data(#"{"Policy":{"EnableMediaPlayback":true,"EnableSharedDeviceControl":false}}"#.utf8))
        XCTAssertFalse(denied.allows(MediaItem(Id: "movie", Name: "Film", Type: "Movie")))
        let allowed = try JSONDecoder().decode(CastUserPermissions.self, from: Data(#"{"Policy":{"EnableMediaPlayback":true,"EnableSharedDeviceControl":true,"EnableLiveTvAccess":false}}"#.utf8))
        XCTAssertTrue(allowed.allows(MediaItem(Id: "movie", Name: "Film", Type: "Movie")))
        XCTAssertFalse(allowed.allows(MediaItem(Id: "channel", Name: "TV", Type: "TvChannel")))
    }

    func testAutomaticCastCleanupDoesNotStopUnownedReceiverMedia() {
        XCTAssertFalse(CastSessionOwnership.mayStop(ownedContentID: nil, receiverContentID: "another-app", established: false, sameSession: true, sameClient: true, connected: true))
        XCTAssertFalse(CastSessionOwnership.mayStop(ownedContentID: nil, receiverContentID: nil, established: false, sameSession: true, sameClient: true, connected: true))
        XCTAssertFalse(CastSessionOwnership.mayStop(ownedContentID: "reel-title", receiverContentID: "another-app", established: false, sameSession: true, sameClient: true, connected: true))
        XCTAssertTrue(CastSessionOwnership.mayStop(ownedContentID: "reel-title", receiverContentID: "reel-title", established: true, sameSession: true, sameClient: true, connected: true))
        XCTAssertFalse(CastSessionOwnership.mayStop(ownedContentID: "reel-title", receiverContentID: nil, established: false, sameSession: true, sameClient: true, connected: true))
        XCTAssertTrue(CastSessionOwnership.mayStop(ownedContentID: "reel-title", receiverContentID: nil, established: true, sameSession: true, sameClient: true, connected: true))
    }

    func testSentButUnestablishedCastIsAlwaysPendingAndCannotStopReceiver() {
        for receiver in [nil, "reel", "foreign"] as [String?] {
            XCTAssertFalse(CastSessionOwnership.mayStop(ownedContentID: "reel", receiverContentID: receiver, established: false, sameSession: true, sameClient: true, connected: true))
        }
        XCTAssertTrue(CastSessionOwnership.hasPendingLoad(loading: true, hasPlan: false, established: false))
        XCTAssertTrue(CastSessionOwnership.hasPendingLoad(loading: false, hasPlan: true, established: false), "Accepted Load is still pending until owned receiver media actually plays or pauses.")
        XCTAssertFalse(CastSessionOwnership.hasPendingLoad(loading: false, hasPlan: true, established: true))
        XCTAssertFalse(CastSessionOwnership.hasPendingLoad(loading: false, hasPlan: false, established: false))
    }

    func testReceiverHandoffUsesRemotePositionAfterLocalPlayerHasStopped() {
        XCTAssertEqual(CastSessionOwnership.startPosition(local: .nan, remote: 42, remembered: 12), 42)
        XCTAssertEqual(CastSessionOwnership.startPosition(local: .nan, remote: nil, remembered: 37), 37)
        XCTAssertEqual(CastSessionOwnership.startPosition(local: 7, remote: nil, remembered: nil), 7)
        XCTAssertEqual(CastSessionOwnership.startPosition(local: .nan, remote: .infinity, remembered: nil), 0)
        XCTAssertEqual(CastSessionOwnership.startPosition(local: -7, remote: nil, remembered: nil), 0)
    }

    func testCastDefaultNonfirstAudioAndSubtitlesRequireNegotiation() throws {
        let source = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"Id":"multi","DefaultAudioStreamIndex":4,"DefaultSubtitleStreamIndex":2,"MediaStreams":[{"Index":1,"Type":"Audio"},{"Index":4,"Type":"Audio"},{"Index":2,"Type":"Subtitle"}]}"#.utf8))
        XCTAssertFalse(CastTrackPolicy.permitsDirectPlay(source: source, audioIndex: nil, subtitleIndex: nil))
        XCTAssertFalse(CastTrackPolicy.permitsDirectPlay(source: source, audioIndex: 1, subtitleIndex: -1))
        let single = try JSONDecoder().decode(MediaSource.self, from: Data(#"{"Id":"single","DefaultAudioStreamIndex":4,"DefaultSubtitleStreamIndex":2,"MediaStreams":[{"Index":4,"Type":"Audio"},{"Index":2,"Type":"Subtitle"}]}"#.utf8))
        XCTAssertFalse(CastTrackPolicy.permitsDirectPlay(source: single, audioIndex: nil, subtitleIndex: nil))
        XCTAssertTrue(CastTrackPolicy.permitsDirectPlay(source: single, audioIndex: nil, subtitleIndex: -1))
    }

    func testCastRejectsProtectedSimulatorBeforePreparingStream() async throws {
        let api = JellyfinAPI(server: URL(string: "http://192.0.2.10:8096")!, token: "not-a-real-token", userID: "test", deviceID: "cast-protection-test")
        do { _ = try await api.prepareCast(MediaItem(Id: "movie", Name: "Film"), position: 0, bitrate: StreamQuality.original.rawValue); XCTFail("Real-server casting must be blocked in simulator.") }
        catch { XCTAssertEqual(error as? ReelError, .previewProtected) }
    }

    @MainActor func testFixtureMetadataAuthenticatedTilesCropAndAccountFailure() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-trickplay", userID: "trickplay", deviceID: "trickplay-tests")
        let store = TrickplayStore()
        await store.load(itemID: "movie-1", mediaSourceID: "movie-1-source", api: api)
        XCTAssertEqual(store.info?.Width, 320)
        let image = try await store.thumbnail(itemID: "movie-1", seconds: 0, api: api)
        XCTAssertEqual(image?.size.width, 320)
        XCTAssertEqual(image?.size.height, 180)
        let otherCell = try await store.thumbnail(itemID: "movie-1", seconds: 2, api: api)
        XCTAssertNotEqual(image?.pngData(), otherCell?.pngData())
        let expired = JellyfinAPI(server: api.server, token: "fixture-expired", userID: "expired", deviceID: "trickplay-tests")
        await store.load(itemID: "movie-1", mediaSourceID: nil, api: expired)
        XCTAssertNil(store.info)
        XCTAssertTrue(store.unavailable)
        let unavailable = JellyfinAPI(server: api.server, token: "fixture-notrickplay", userID: "notrickplay", deviceID: "trickplay-tests")
        await store.load(itemID: "movie-1", mediaSourceID: nil, api: unavailable)
        XCTAssertNil(store.info)
        XCTAssertTrue(store.unavailable)
    }

    func testFixtureCastPermissionAndSourceNegotiation() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-cast-contract", userID: "cast-contract", deviceID: "cast-tests")
        let item = try await api.item("movie-1")
        let plan = try await api.prepareCast(item, position: 7, bitrate: StreamQuality.original.rawValue, mediaSourceID: "movie-1-alternate")
        XCTAssertTrue(JellyfinAPI.sameOrigin(plan.url, api.server))
        XCTAssertEqual(plan.source.Id, "movie-1-alternate")
        XCTAssertEqual(plan.startPosition, 7)
        let selected = try await api.prepareCast(item, position: 7, bitrate: StreamQuality.original.rawValue, mediaSourceID: "movie-1-alternate", audioIndex: 4, subtitleIndex: -1)
        XCTAssertEqual(selected.method, "DirectPlay")
        XCTAssertEqual(selected.audioIndex, 4)
        XCTAssertEqual(selected.subtitleIndex, -1)
        let captioned = try await api.prepareCast(item, position: 7, bitrate: StreamQuality.original.rawValue, mediaSourceID: "movie-1-source", audioIndex: 1, subtitleIndex: 2)
        XCTAssertEqual(captioned.method, "Transcode")
        XCTAssertEqual(captioned.subtitleIndex, 2)
        let multiaudio = JellyfinAPI(server: api.server, token: "fixture-cast-multiaudio", userID: "cast-multiaudio", deviceID: "cast-tests")
        let implicitDefault = try await multiaudio.prepareCast(item, position: 0, bitrate: StreamQuality.original.rawValue)
        XCTAssertEqual(implicitDefault.method, "Transcode")
        XCTAssertEqual(implicitDefault.audioIndex, 4)
        XCTAssertEqual(implicitDefault.subtitleIndex, 2)
        do { _ = try await api.prepareCast(item, position: 0, bitrate: StreamQuality.original.rawValue, mediaSourceID: "movie-1-alternate", audioIndex: 99); XCTFail("Missing tracks must be rejected.") }
        catch { XCTAssertTrue(error is CastPlaybackError) }
        let denied = JellyfinAPI(server: api.server, token: "fixture-cast-denied", userID: "cast-denied", deviceID: "cast-tests")
        do { _ = try await denied.prepareCast(item, position: 0, bitrate: StreamQuality.original.rawValue); XCTFail("Shared-device permission must be enforced.") }
        catch { XCTAssertTrue(error is CastPlaybackError) }
    }
}
