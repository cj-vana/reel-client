import XCTest
import AVFoundation
import SwiftUI
import Vision
@testable import Reel

final class ReelTests: XCTestCase {
    func testServerAddressValidationAndBasePath() throws {
        XCTAssertEqual(try JellyfinAPI.normalize(" https://media.example.com/jellyfin/// ").absoluteString, "https://media.example.com/jellyfin")
        for address in ["example.com", "ftp://example.com", "https://user:pass@example.com", "https://example.com?token=x", "https://example.com/#fragment"] {
            XCTAssertThrowsError(try JellyfinAPI.normalize(address), address)
        }
        XCTAssertThrowsError(try JellyfinAPI.normalize("http://media.example.com"))
        for address in ["http://192.168.1.10:8096", "http://127.0.0.1:18766", "http://192.168.1.4", "http://172.16.0.2", "http://100.64.0.10", "http://server.tailabc.ts.net"] {
            XCTAssertNoThrow(try JellyfinAPI.normalize(address))
        }
        XCTAssertFalse(JellyfinAPI.isPrivateHost("192.168.999.3"))
        XCTAssertFalse(JellyfinAPI.isPrivateHost("172.32.0.2"))
        for hostname in ["10.1.2.3.attacker.example", "10..1.2.3", "10.0.0.1.", "x.10.0.0.1", "1e1.0.0.1"] {
            XCTAssertFalse(JellyfinAPI.isPrivateHost(hostname), hostname)
        }
    }

    func testRequestDoesNotPutCredentialsInAPIOrArtworkURL() throws {
        let api = JellyfinAPI(server: try JellyfinAPI.normalize("https://media.example.com/jellyfin"), token: "secret\"\nvalue", userID: "user", deviceID: "device")
        let request = api.request("Items", query: ["searchTerm": "a & b/?"])
        XCTAssertEqual(request.url?.path, "/jellyfin/Items")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "a & b/?")
        XCTAssertFalse(request.url!.absoluteString.contains("secret"))
        XCTAssertFalse(api.authorization.contains("\n"))
        XCTAssertTrue(api.authorization.contains("Token=\"secretvalue\""))
        let item = MediaItem(Id: "film", Name: "Film")
        XCTAssertFalse(api.imageRequest(item, backdrop: false, width: 400).url!.absoluteString.contains("secret"))
    }

    func testEpisodeThumbnailsPreferTheEpisodeStill() {
        var episode = MediaItem(Id: "episode", Name: "Pilot", Type: "Episode", SeriesId: "show")
        episode.ImageTags = ["Primary": "still-tag"]
        episode.ParentBackdropItemId = "show"; episode.ParentBackdropImageTags = ["series-backdrop"]
        XCTAssertEqual(episode.thumbnailItem.imageReference(backdrop: true).id, "episode")
        XCTAssertEqual(episode.thumbnailItem.imageReference(backdrop: true).tag, "still-tag")
        episode.ImageTags = nil
        XCTAssertEqual(episode.thumbnailItem.imageReference(backdrop: true).id, "show", "Without a still the series backdrop remains.")
        var movie = MediaItem(Id: "film", Name: "Film", Type: "Movie")
        movie.ImageTags = ["Primary": "poster"]; movie.BackdropImageTags = ["backdrop"]
        XCTAssertEqual(movie.thumbnailItem.imageReference(backdrop: true).type, "Backdrop")
    }

    func testWatchPositionIsClampedAndEpisodeArtworkUsesSeries() {
        var item = MediaItem(Id: "episode", Name: "Pilot", Type: "Episode", RunTimeTicks: 100, SeriesId: "show", SeriesName: "A Show", SeriesPrimaryImageTag: "series-tag", UserData: UserData(PlaybackPositionTicks: 200))
        XCTAssertEqual(item.progress, 1)
        XCTAssertEqual(item.title, "A Show")
        XCTAssertEqual(item.imageReference(backdrop: false).id, "show")
        XCTAssertEqual(item.imageReference(backdrop: false).tag, "series-tag")
        item.UserData?.PlaybackPositionTicks = -30
        XCTAssertEqual(item.resumeTicks, 0)
        XCTAssertEqual(item.progress, 0)
    }

    func testPlaybackRejectsForeignOriginsAndUsesModernApiKey() throws {
        let server = URL(string: "https://media.example.com/jellyfin")!
        let api = JellyfinAPI(server: server, token: "test-token", userID: "user", deviceID: "device")
        let item = MediaItem(Id: "film", Name: "Film", UserData: UserData(PlaybackPositionTicks: 30_000_000))
        let source = MediaSource(Id: "source", TranscodingUrl: "/jellyfin/Videos/film/master.m3u8?api_key=old&x=1")
        let stream = try api.streamURL(item: item, source: source, sessionID: "session")
        XCTAssertEqual(stream.offset, 0)
        let q = URLComponents(url: stream.url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.filter { $0.name == "ApiKey" }.map(\.value), ["test-token"])
        XCTAssertFalse(q.contains { $0.name == "api_key" })
        XCTAssertEqual(stream.method, "Transcode")
        let basePathStream = try api.streamURL(item: item, source: MediaSource(Id: "source", TranscodingUrl: "/videos/film/master.m3u8?x=1"), sessionID: "session")
        XCTAssertEqual(basePathStream.url.path, "/jellyfin/videos/film/master.m3u8")
        for destination in ["https://evil.example/Videos/film/master.m3u8", "http://media.example.com/x", "https://media.example.com:8443/x", "//evil.example/x"] {
            XCTAssertThrowsError(try api.streamURL(item: item, source: MediaSource(Id: "source", TranscodingUrl: destination), sessionID: "session"))
        }
    }

    func testDirectPlayStartsAtOriginalTimeline() throws {
        let api = JellyfinAPI(server: URL(string: "https://media.example.com/jellyfin")!, token: "token", userID: "user", deviceID: "device")
        let item = MediaItem(Id: "film", Name: "Film", UserData: UserData(PlaybackPositionTicks: 50_000_000))
        let stream = try api.streamURL(item: item, source: MediaSource(Id: "source", SupportsDirectPlay: true), sessionID: "session")
        XCTAssertEqual(stream.url.path, "/jellyfin/Videos/film/stream")
        XCTAssertEqual(stream.offset, 0)
        XCTAssertEqual(stream.method, "DirectPlay")
    }

    func testRealFixtureAuthenticationBrowseAndPlaybackNegotiation() async throws {
        let anonymous = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, deviceID: "unit-tests")
        let account = try await anonymous.authenticate(username: "unit", password: "demo")
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: "unit-tests")
        let page = try await api.page("Items", query: ["limit": "60", "includeItemTypes": "Movie,Series"])
        XCTAssertEqual(page.Items.count, 60)
        XCTAssertEqual(page.TotalRecordCount, 75)
        let next = try await api.page("Items", query: ["startIndex": "60", "limit": "60", "includeItemTypes": "Movie,Series"])
        XCTAssertEqual(next.Items.count, 15)
        let item = try await api.item("movie-1")
        let info = try await api.playback(item, quality: .dataSaver, audio: 1, subtitle: -1, mediaSourceID: item.MediaSources?.first?.Id)
        XCTAssertEqual(info.MediaSources.first?.SupportsDirectPlay, false)
        let stream = try api.streamURL(item: item, source: info.MediaSources[0], sessionID: info.PlaySessionId!)
        let (playlist, response) = try await URLSession.shared.data(from: stream.url)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertTrue(String(decoding: playlist, as: UTF8.self).contains("#EXTM3U"))
        try await api.favorite("movie-1", value: true)
        let favorite = try await api.item("movie-1")
        XCTAssertTrue(favorite.isFavorite)
        try await api.favorite("movie-1", value: false)
        let unfavorite = try await api.item("movie-1")
        XCTAssertFalse(unfavorite.isFavorite)
    }

    func testBadCredentialsAreActionable() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, deviceID: "unit-tests")
        do { _ = try await api.authenticate(username: "demo", password: "wrong"); XCTFail("Bad credentials accepted") }
        catch { XCTAssertEqual(error as? ReelError, .unauthorized) }
    }

    @MainActor func testNativeHLSResumeAndRewindUseFullTimeline() async throws {
        let anonymous = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, deviceID: "native-tests")
        let account = try await anonymous.authenticate(username: "hlsresume", password: "demo")
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: "native-tests")
        try await api.post("Sessions/Playing/Stopped", body: ["ItemId": "movie-1", "PositionTicks": Int64(100_000_000)])
        var item = try await api.item("movie-1")
        item.UserData?.PlaybackPositionTicks = 100_000_000
        let controller = PlaybackController()
        controller.present(item)
        controller.start(api: api, quality: .dataSaver)
        for _ in 0..<150 {
            if !controller.preparing { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.preparing)
        XCTAssertEqual(controller.method, "Transcode")
        controller.player.pause()
        XCTAssertGreaterThanOrEqual(controller.player.currentTime().seconds, 9.8)
        XCTAssertLessThan(controller.player.currentTime().seconds, 13)
        controller.skip(-15)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertLessThan(controller.player.currentTime().seconds, 1)
        controller.stop()
        await controller.flushReports()
        let updated = try await api.item("movie-1")
        XCTAssertLessThan(updated.resumeTicks, 10_000_000)
    }

    @MainActor func testFailedFinalProgressPersistsAndRetriesWithFreshReporter() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-outbox", userID: "outbox", deviceID: "outbox-test")
        try await api.post("qa/control", body: ["failReports": true])
        let reporter = PlaybackReporter()
        reporter.enqueue(api: api, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "movie-1", "MediaSourceId": "source", "PlaySessionId": "outbox-session", "PositionTicks": Int64(77_000_000)])
        await reporter.flush()
        let saved = UserDefaults.standard.data(forKey: "pendingWatchReports")!
        XCTAssertFalse(String(decoding: saved, as: UTF8.self).contains("fixture-outbox"))
        let entries = try JSONDecoder().decode([PlaybackReporter.Stored].self, from: saved)
        XCTAssertTrue(entries.contains { $0.userID == "outbox" })
        try await api.post("qa/control", body: ["failReports": false])
        let restored = PlaybackReporter()
        await restored.retryStored(api: api)
        let item = try await api.item("movie-1")
        XCTAssertEqual(item.resumeTicks, 77_000_000)
        let remaining = try JSONDecoder().decode([PlaybackReporter.Stored].self, from: UserDefaults.standard.data(forKey: "pendingWatchReports")!)
        XCTAssertFalse(remaining.contains { $0.userID == "outbox" })
    }

    @MainActor func testOverlappingReportersPreserveOtherAccountsPendingProgress() async throws {
        let server = URL(string: "http://127.0.0.1:18766")!
        let first = JellyfinAPI(server: server, token: "fixture-first", userID: "first", deviceID: "overlap-test")
        let second = JellyfinAPI(server: server, token: "fixture-second", userID: "second", deviceID: "overlap-test")
        try await first.post("qa/control", body: ["failReports": true])
        let outgoing = PlaybackReporter()
        let incoming = PlaybackReporter()
        outgoing.enqueue(api: first, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "movie-1", "PositionTicks": Int64(111)])
        incoming.enqueue(api: second, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "movie-2", "PositionTicks": Int64(222)])
        await outgoing.flush(); await incoming.flush()
        XCTAssertEqual(outgoing.pendingPosition(api: first, itemID: "movie-1"), 111)
        XCTAssertEqual(incoming.pendingPosition(api: second, itemID: "movie-2"), 222)
        try await first.post("qa/control", body: ["failReports": false])
        await outgoing.retryStored(api: first)
        XCTAssertEqual(incoming.pendingPosition(api: second, itemID: "movie-2"), 222)
        await incoming.retryStored(api: second)
        XCTAssertNil(incoming.pendingPosition(api: second, itemID: "movie-2"))
    }

    @MainActor func testRapidReplayUsesLatestPositionEvenWhenDetailsAreStale() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-rapid", userID: "rapid", deviceID: "rapid-test")
        try await api.post("Sessions/Playing/Stopped", body: ["ItemId": "movie-1", "PositionTicks": Int64(0)])
        let staleDetails = try await api.item("movie-1")
        let controller = PlaybackController()
        controller.present(staleDetails)
        controller.start(api: api, quality: .dataSaver)
        for _ in 0..<100 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(controller.error)
        controller.player.pause()
        await controller.player.seek(to: CMTime(seconds: 8, preferredTimescale: 600))
        controller.stop()
        controller.activeItem = nil
        // Deliberately replay before a mounted Details view has refreshed its old zero position.
        controller.present(staleDetails)
        controller.start(api: api, quality: .dataSaver)
        for _ in 0..<100 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(controller.error)
        XCTAssertGreaterThanOrEqual(controller.player.currentTime().seconds, 7.8)
        controller.stop()
        await controller.flushReports()
    }

    @MainActor func testMultipleAudioTracksRenegotiateServerSelectedTrack() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-multiaudio", userID: "multiaudio", deviceID: "multiaudio-test")
        var item = try await api.item("movie-1")
        item.MediaSources?[0].MediaStreams?.append(MediaStream(Index: 3, Type: "Audio", DisplayTitle: "Alternate audio"))
        let controller = PlaybackController()
        controller.present(item)
        controller.start(api: api, quality: .original)
        for _ in 0..<100 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.preparing)
        XCTAssertEqual(controller.method, "Transcode")
        controller.stop()
        await controller.flushReports()
    }

    @MainActor func testNativeDirectPlaybackDecodesAndAdvances() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-direct", userID: "direct", deviceID: "direct-test")
        let item = try await api.item("movie-3")
        let controller = PlaybackController()
        controller.present(item)
        controller.start(api: api, quality: .original)
        for _ in 0..<100 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(controller.error)
        XCTAssertFalse(controller.preparing)
        XCTAssertEqual(controller.method, "DirectPlay")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertGreaterThan(controller.player.currentTime().seconds, 0)
        controller.stop()
        await controller.flushReports()
    }
    func testSavedAccountMigrationSwitchingAndDuplicateUpdates() throws {
        let one = Account(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-one", userID: "one", name: "One", serverName: "Home")
        let two = Account(server: URL(string: "http://127.0.0.1:18767")!, token: "fixture-two", userID: "two", name: "Two", serverName: "Travel")
        var vault = try AccountVault.decode(JSONEncoder().encode(one))
        XCTAssertEqual(vault.active, one)
        vault.remember(two); XCTAssertEqual(vault.accounts.count, 2)
        vault.select(one.id); XCTAssertEqual(vault.active, one)
        vault.select("missing"); XCTAssertEqual(vault.active, one)
        vault.remember(one); XCTAssertEqual(vault.accounts.count, 2)
        vault = try AccountVault.decode(JSONEncoder().encode(vault))
        XCTAssertEqual(vault.active, one)
        vault.remove(one.id); XCTAssertEqual(vault.active, two)
        vault.remove(two.id); XCTAssertNil(vault.active)
    }

    func testSimulatorRejectsRealServerMutationBeforeNetwork() async throws {
        let api = JellyfinAPI(server: URL(string: "http://192.0.2.10:8096")!, token: "fixture-not-a-real-token", userID: "test", deviceID: "safety-test")
        XCTAssertTrue(api.isSimulatorPreview)
        XCTAssertFalse(api.recordsHistory)
        for path in ["Sessions/Playing", "Sessions/Playing/Progress", "Sessions/Playing/Stopped", "UserPlayedItems/test", "UserFavoriteItems/test", "Playlists"] {
            for method in ["POST", "DELETE"] {
                do { _ = try await api.send(api.request(path, method: method)); XCTFail("Mutation passed guard: \(path)") }
                catch { XCTAssertEqual(error as? ReelError, .previewProtected) }
            }
        }
    }

    @MainActor func testPrivateViewingDoesNotQueueOrSendWatchHistory() async throws {
        let user = "private-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "private-tests", historyEnabled: false)
        let reporter = PlaybackReporter()
        reporter.enqueue(api: api, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "movie-1", "PositionTicks": 123, "PlaySessionId": "private-test"], cleanup: true)
        await reporter.flush()
        await reporter.retryStored(api: api)
        XCTAssertNil(reporter.pendingPosition(api: api, itemID: "movie-1"))
        let state = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: state) as! [String: Any]
        let reports = json["reports"] as! [[String: Any]]
        XCTAssertFalse(reports.contains { ($0["user"] as? String) == user && ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        XCTAssertTrue(reports.contains { ($0["user"] as? String) == user && ($0["path"] as? String) == "/Videos/ActiveEncodings" })
    }

    @MainActor func testDownloadPersistenceIsolationAndNativeOfflinePlayback() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-offline", userID: "offline", deviceID: "offline-tests")
        let account = Account(server: api.server, token: "fixture-offline", userID: "offline", name: "Offline", serverName: "Test")
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads(directory: directory)
        let item = try await api.item("movie-1")
        XCTAssertTrue(Downloads.compatible(item))
        downloads.download(item, account: account, api: api)
        await downloads.waitForDownloads()
        let saved = try XCTUnwrap(downloads.saved(account: account, item: item))
        XCTAssertGreaterThan(saved.bytes, 0)
        let manifest = try String(contentsOf: directory.appendingPathComponent("library.json"), encoding: .utf8)
        XCTAssertFalse(manifest.contains("fixture-offline"))
        XCTAssertEqual(Downloads(directory: directory).items.count, 1)
        let other = Account(server: api.server, token: "fixture-other", userID: "other", name: "Other", serverName: "Test")
        XCTAssertNil(downloads.saved(account: other, item: item))
        let player = PlaybackController()
        player.presentDownload(saved.item, url: downloads.url(saved))
        player.start(api: api, quality: .original)
        for _ in 0..<100 { if !player.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(player.error)
        XCTAssertEqual(player.method, "Offline")
        player.speed = 1.5
        XCTAssertEqual(player.player.defaultRate, 1.5)
        player.setSleepTimer(minutes: 15); XCTAssertNotNil(player.sleepDeadline)
        player.setSleepTimer(minutes: nil); XCTAssertNil(player.sleepDeadline)
        player.scheduleSleep(after: 0.05)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(player.player.rate, 0)
        XCTAssertFalse(player.isPlaying)
        await player.player.seek(to: CMTime(seconds: 7, preferredTimescale: 600))
        player.reportPauseState()
        XCTAssertGreaterThanOrEqual(UserDefaults.standard.double(forKey: "offline-" + saved.filename), 6.9)
        player.stop()
        let reopened = PlaybackController()
        reopened.presentDownload(saved.item, url: downloads.url(saved))
        reopened.start(api: api, quality: .original)
        for _ in 0..<100 { if !reopened.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(reopened.player.currentTime().seconds, 6.9)
        reopened.stop()
        // Recover a process interruption before the manifest removal commits.
        try FileManager.default.moveItem(at: downloads.url(saved), to: downloads.url(saved).appendingPathExtension("removing"))
        XCTAssertEqual(Downloads(directory: directory).items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.url(saved).path))
        // A failed manifest commit must roll the file back and leave the row playable.
        let manifestURL = directory.appendingPathComponent("library.json")
        let manifestData = try Data(contentsOf: manifestURL)
        try FileManager.default.removeItem(at: manifestURL)
        try FileManager.default.createDirectory(at: manifestURL, withIntermediateDirectories: false)
        XCTAssertThrowsError(try downloads.remove(saved))
        XCTAssertTrue(FileManager.default.fileExists(atPath: downloads.url(saved).path))
        XCTAssertEqual(downloads.items.count, 1)
        try FileManager.default.removeItem(at: manifestURL)
        try manifestData.write(to: manifestURL)
        try downloads.remove(saved)
        XCTAssertTrue(downloads.items.isEmpty)
        XCTAssertTrue(Downloads(directory: directory).items.isEmpty)
    }

    func testFixtureFeatureContracts() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-contract", userID: "contract", deviceID: "contract-tests")
        let channels = try await api.page("LiveTv/Channels")
        XCTAssertEqual(channels.Items.first?.CurrentProgram?.Name, "Local test program")
        let segments: MediaSegmentPage = try await api.get("MediaSegments/movie-1")
        XCTAssertEqual(segments.Items.first?.EndTicks, 40_000_000)
        let movie = try await api.item("movie-1")
        XCTAssertEqual(movie.Chapters?.count, 2)
        XCTAssertEqual(movie.People?.first?.Name, "Test Actor")
        try await api.post("UserPlayedItems/movie-1", query: ["userId": "contract"])
        let watched = try await api.item("movie-1")
        XCTAssertEqual(watched.UserData?.Played, true)
        try await api.post("UserPlayedItems/movie-1", query: ["userId": "contract"], method: "DELETE")
        let unwatched = try await api.item("movie-1")
        XCTAssertEqual(unwatched.UserData?.Played, false)
        let collection = try await api.page("Items", query: ["includeItemTypes": "BoxSet"])
        XCTAssertEqual(collection.Items.first?.isContainer, true)
    }

    @MainActor func testLivePreviewPlaysWithoutChangingHistory() async throws {
        let account = try livePreviewAccount()
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: "reel-live-preview-verification")
        XCTAssertTrue(api.isSimulatorPreview)
        let movies = try await api.latest(type: "Movie")
        let movie = try XCTUnwrap(movies.first)
        let before = try await api.item(movie.id)
        let controller = PlaybackController()
        controller.present(before)
        controller.start(api: api, quality: .balanced)
        for _ in 0..<600 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(controller.error)
        if controller.preparing || controller.error != nil {
            let state = controller.player.currentItem
            let codes = state?.errorLog()?.events.map { $0.errorStatusCode } ?? []
            if let error = state?.error as NSError? { print("Live AV error: \(error.domain) \(error.code)") }
            if let asset = state?.asset as? AVURLAsset {
                let safeParameters = URLComponents(url: asset.url, resolvingAgainstBaseURL: false)?.queryItems?.filter { ["VideoCodec", "AudioCodec", "SegmentContainer", "VideoBitrate", "MaxWidth", "MaxHeight"].contains($0.name) }.map { $0.name + "=" + ($0.value ?? "") } ?? []
                print("Live stream codec profile: \(safeParameters)")
                var request = URLRequest(url: asset.url)
                request.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
                if let (data, response) = try? await JellyfinAPI.transport.data(for: request) {
                    print("Live stream HTTP status: \((response as? HTTPURLResponse)?.statusCode ?? 0), type=\(response.mimeType ?? "unknown"), path=\(asset.url.path)")
                    if let text = String(data: data, encoding: .utf8), text.hasPrefix("#EXTM3U"), let uri = text.split(separator: "\n").first(where: { !$0.hasPrefix("#") && !$0.isEmpty }), let child = URL(string: String(uri), relativeTo: asset.url)?.absoluteURL {
                        let names = URLComponents(url: child, resolvingAgainstBaseURL: false)?.queryItems?.map(\.name) ?? []
                        var childRequest = URLRequest(url: child); childRequest.setValue("bytes=0-2047", forHTTPHeaderField: "Range")
                        if let (playlistData, childResponse) = try? await JellyfinAPI.transport.data(for: childRequest) {
                            print("Live child HTTP status: \((childResponse as? HTTPURLResponse)?.statusCode ?? 0), path=\(child.path), parameterNames=\(names)")
                            if let playlist = String(data: playlistData, encoding: .utf8) {
                                var paths = playlist.split(separator: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }.prefix(1).map(String.init)
                                if let map = playlist.split(separator: "\n").first(where: { $0.hasPrefix("#EXT-X-MAP:") }), let start = map.range(of: "URI=\"") {
                                    paths.append(String(map[start.upperBound...].prefix { $0 != "\"" }))
                                }
                                for path in paths {
                                    guard let resource = URL(string: path, relativeTo: child)?.absoluteURL else { continue }
                                    var check = URLRequest(url: resource); check.setValue("bytes=0-2047", forHTTPHeaderField: "Range"); check.timeoutInterval = 10
                                    if let (bytes, response) = try? await JellyfinAPI.transport.data(for: check) {
                                        print("Live media resource: status=\((response as? HTTPURLResponse)?.statusCode ?? 0), type=\(response.mimeType ?? "unknown"), bytes=\(bytes.count), path=\(resource.path)")
                                    }
                                }
                            }
                        }
                    }
                }
            }
            print("Live preview diagnostics: method=\(controller.method), player=\(controller.player.status.rawValue), item=\(state?.status.rawValue ?? -1), bufferEmpty=\(state?.isPlaybackBufferEmpty ?? true), errors=\(codes)")
        }
        XCTAssertFalse(controller.preparing)
        try await Task.sleep(for: .seconds(3))
        controller.togglePause()
        controller.skip(15)
        controller.stop()
        await controller.flushReports()
        let after = try await api.item(movie.id)
        XCTAssertEqual(before.UserData, after.UserData, "Live movie watch position, watched status and play count must remain unchanged.")
    }

    @MainActor func testDownloadPermissionFailureRecoveryAndCancellation() async throws {
        let server = URL(string: "http://127.0.0.1:18766")!
        let api = JellyfinAPI(server: server, token: "fixture-nodownload", userID: "nodownload", deviceID: "download-error-tests")
        let account = Account(server: server, token: "fixture-nodownload", userID: "nodownload", name: "Denied", serverName: "Test")
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let downloads = Downloads(directory: directory)
        let item = try await api.item("movie-1")
        try await api.post("qa/control", body: ["allowDeniedDownloads": false])
        downloads.download(item, account: account, api: api); await downloads.waitForDownloads()
        let key = Downloads.key(account: account, item: item)
        XCTAssertNotNil(downloads.errors[key]); XCTAssertNotNil(downloads.requested[key])
        XCTAssertTrue(downloads.items.isEmpty)
        try await api.post("qa/control", body: ["allowDeniedDownloads": true])
        downloads.download(item, account: account, api: api); await downloads.waitForDownloads()
        XCTAssertNotNil(downloads.saved(account: account, item: item))
        XCTAssertNil(downloads.errors[key]); XCTAssertNil(downloads.requested[key])
        try await api.post("qa/control", body: ["allowDeniedDownloads": false])
        let slow = Account(server: server, token: "fixture-slowdownload", userID: "slowdownload", name: "Slow", serverName: "Test")
        let slowAPI = JellyfinAPI(server: server, token: slow.token, userID: slow.userID, deviceID: "cancel-tests")
        downloads.download(item, account: slow, api: slowAPI)
        downloads.cancel(Downloads.key(account: slow, item: item)); await downloads.waitForDownloads()
        XCTAssertNil(downloads.saved(account: slow, item: item))
        XCTAssertFalse(downloads.active.contains(Downloads.key(account: slow, item: item)))
    }

    @MainActor func testLiveTunerCleanupIsIndependentOfWatchReports() async throws {
        let user = "tuner-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "tuner-tests", historyEnabled: false)
        let controller = PlaybackController()
        controller.present(try await api.item("channel-1"))
        controller.start(api: api, quality: .original)
        for _ in 0..<100 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(controller.error)
        controller.stop(); await controller.flushReports()
        let state = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: state) as! [String: Any]
        let reports = (json["reports"] as! [[String: Any]]).filter { $0["user"] as? String == user }
        XCTAssertTrue(reports.contains { $0["path"] as? String == "/LiveStreams/Close" })
        XCTAssertFalse(reports.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
    }

    @MainActor func testLiveTranscoderDiagnostics() async throws {
        let account = try livePreviewAccount()
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: "reel-transcode-diagnostics")
        struct Log: Decodable, Sendable { let Name: String; let DateModified: String? }
        let logs: [Log]
        do { logs = try await api.get("System/Logs") }
        catch { throw XCTSkip("Server diagnostic log access is unavailable to this account.") }
        guard let log = logs.filter({ $0.Name.lowercased().contains("ffmpeg") }).sorted(by: { ($0.DateModified ?? "") > ($1.DateModified ?? "") }).first else { throw XCTSkip("No FFmpeg diagnostic is available.") }
        let data = try await api.send(api.request("System/Logs/Log", query: ["name": log.Name]))
        let content = String(decoding: data, as: UTF8.self)
        for line in content.split(separator: "\n").filter({ line in !line.contains(" -i ") && !line.contains(" -loglevel ") && ["error", "failed", "cannot", "no device", "unable", "permission", "unsupported"].contains(where: { line.lowercased().contains($0) }) }).suffix(12) {
            var safe = String(line).replacingOccurrences(of: #"(?i)(https?://|file:)[^\s"]+"#, with: "[resource]", options: .regularExpression)
            safe = safe.replacingOccurrences(of: #"(?i)(ApiKey|api_key|Token|Password|Secret)=[^&,\s"]+"#, with: "$1=[redacted]", options: .regularExpression)
            safe = safe.replacingOccurrences(of: #"/[^\s"]+"#, with: "[path]", options: .regularExpression)
            print("Transcoder diagnostic: " + String(safe.prefix(300)))
        }
    }

    @MainActor func testLiveServerSessionInventory() async throws {
        let account = try livePreviewAccount()
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: "reel-readonly-session-inventory")
        struct ServerSession: Decodable, Sendable { let Client: String?; let NowPlayingItem: MediaItem? }
        let sessions: [ServerSession] = try await api.get("Sessions")
        print("Other media sessions, including paused: \(sessions.filter { $0.Client != "Reel" && $0.NowPlayingItem != nil }.count)")
    }

    @MainActor private func livePreviewAccount() throws -> Account {
        guard ProcessInfo.processInfo.environment["REEL_LIVE_PREVIEW_TESTS"] == "1" else {
            throw XCTSkip("Explicit opt-in is required before accessing a signed-in live preview.")
        }
        guard let account = try SecureAccount.read().active,
              JellyfinAPI.previewProtected(server: account.server),
              !GatewayHeaderStore.isLoopback(account.server.host) else {
            throw XCTSkip("Sign in to a protected live preview before enabling live tests.")
        }
        return account
    }

    @MainActor func testFailedStopReplayClosesTunerExactlyOnce() async throws {
        let user = "cleanup-replay-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "cleanup-replay")
        try await api.post("qa/control", body: ["failReports": true])
        let reporter = PlaybackReporter()
        reporter.enqueue(api: api, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "channel-1", "PositionTicks": 40, "LiveStreamId": "fixture-tuner", "PlaySessionId": "fixture-session", "CleanupEncoder": true], cleanup: true)
        await reporter.flush()
        XCTAssertEqual(reporter.pendingPosition(api: api, itemID: "channel-1"), 40)
        try await api.post("qa/control", body: ["failReports": false])
        let restored = PlaybackReporter()
        await restored.retryStored(api: api)
        let data = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let reports = (json["reports"] as! [[String: Any]]).filter { $0["user"] as? String == user }
        XCTAssertEqual(reports.filter { $0["path"] as? String == "/LiveStreams/Close" }.count, 1)
        XCTAssertEqual(reports.filter { $0["path"] as? String == "/Videos/ActiveEncodings" }.count, 1)
        XCTAssertEqual(reports.filter { $0["path"] as? String == "/Sessions/Playing/Stopped" }.count, 1)
    }

    @MainActor func testExplicitOriginalRetryResetsFailedFallbackAndRetainsResume() async throws {
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-failed-recovery", userID: "failed-recovery", deviceID: "retry-test")
        let controller = PlaybackController()
        func negotiations() async throws -> [[String: Any]] {
            let data = try await api.send(api.request("qa/state"))
            let state = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            return (state["reports"] as? [[String: Any]] ?? []).filter {
                $0["user"] as? String == "failed-recovery" && $0["path"] as? String == "/Items/movie-3/PlaybackInfo"
            }
        }
        func cleanup() async {
            controller.stop()
            // Await a cancellation-independent cleanup job; never leave recovery armed for the next test.
            await Task { @MainActor in
                await controller.flushReports()
                do { try await api.post("qa/control", body: ["recoveryAllowed": false]) }
                catch { XCTFail("Owned retry fixture cleanup failed: \(error)") }
            }.value
        }
        do {
            try await api.post("qa/control", body: ["recoveryAllowed": false])
            try await api.post("Sessions/Playing/Stopped", body: ["ItemId": "movie-3", "PositionTicks": Int64(60_000_000)])
            controller.present(try await api.item("movie-3"), mediaSourceID: "movie-3-source")
            controller.start(api: api, quality: .dataSaver)
            for _ in 0..<250 { if controller.error != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
            XCTAssertNotNil(controller.error, "Invalid media must exercise AVPlayer's failed fallback path.")
            let failedItem = try XCTUnwrap(controller.player.currentItem)
            XCTAssertEqual(failedItem.status, .failed)
            try await api.post("qa/control", body: ["recoveryAllowed": true])
            let beforeRetry = try await negotiations().count
            controller.retry(api: api, quality: .original)
            let deadline = ContinuousClock.now.advanced(by: .seconds(15))
            var recovered = false
            while ContinuousClock.now < deadline {
                let item = controller.player.currentItem, seconds = controller.player.currentTime().seconds
                if !controller.resolvingReplacement, !controller.preparing, let item, item !== failedItem,
                   item.status == .readyToPlay, item.presentationSize.width > 0, seconds.isFinite, seconds >= 5.8,
                   controller.player.rate > 0 { recovered = true; break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard recovered else {
                XCTFail("Original retry never reached a new decoded item: resolving=\(controller.resolvingReplacement), preparing=\(controller.preparing), oldItem=\(controller.player.currentItem === failedItem), status=\(String(describing: controller.player.currentItem?.status)), method=\(controller.method), time=\(controller.player.currentTime().seconds), error=\(String(describing: controller.error)), selectionError=\(String(describing: controller.audioSelectionError))")
                throw URLError(.timedOut)
            }
            let recoveredItem = try XCTUnwrap(controller.player.currentItem), position = controller.player.currentTime().seconds
            let advancingDeadline = ContinuousClock.now.advanced(by: .seconds(3))
            while ContinuousClock.now < advancingDeadline && controller.player.currentTime().seconds <= position + 0.1 {
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTAssertTrue(controller.player.currentItem === recoveredItem)
            XCTAssertGreaterThan(controller.player.currentTime().seconds, position + 0.1)
            let afterRetry = try await negotiations()
            XCTAssertEqual(afterRetry.count, beforeRetry + 1, "The assertions must refer to one fresh explicit Original negotiation.")
            let fresh = try XCTUnwrap(afterRetry.dropFirst(beforeRetry).first?["body"] as? [String: Any])
            XCTAssertEqual(fresh["StartTimeTicks"] as? Int64, 60_000_000)
            XCTAssertEqual(fresh["MaxStreamingBitrate"] as? Int, StreamQuality.original.rawValue)
            XCTAssertEqual(fresh["EnableDirectPlay"] as? Bool, true)
            XCTAssertEqual(fresh["MediaSourceId"] as? String, "movie-3-source")
            XCTAssertNil(controller.error); XCTAssertNil(controller.audioSelectionError)
            XCTAssertFalse(controller.preparing); XCTAssertFalse(controller.resolvingReplacement)
            XCTAssertEqual(controller.method, "DirectPlay")
            XCTAssertGreaterThanOrEqual(controller.player.currentTime().seconds, 5.8)
        } catch {
            await cleanup()
            throw error
        }
        await cleanup()
    }

    @MainActor func testAcknowledgedHistoryKeepsFailedCleanupJournalAndReplaysPrivately() async throws {
        let user = "cleanup-journal-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "cleanup-journal")
        try await api.post("qa/control", body: ["failCleanup": true])
        let reporter = PlaybackReporter()
        reporter.enqueue(api: api, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "channel-1", "PositionTicks": 99, "PlaySessionId": "session", "LiveStreamId": "tuner", "CleanupEncoder": true], cleanup: true)
        await reporter.flush()
        let entries = try JSONDecoder().decode([PlaybackReporter.Stored].self, from: UserDefaults.standard.data(forKey: "pendingWatchReports")!)
        let owned = try XCTUnwrap(entries.first { $0.userID == user })
        XCTAssertTrue(owned.endpoint.isEmpty); XCTAssertTrue(owned.cleanup)
        XCTAssertFalse(String(decoding: owned.body, as: UTF8.self).contains("PositionTicks"))
        try await api.post("qa/control", body: ["failCleanup": false])
        let privateAPI = JellyfinAPI(server: api.server, token: api.token, userID: user, deviceID: api.deviceID, historyEnabled: false)
        await PlaybackReporter().retryStored(api: privateAPI)
        let data = try await api.send(api.request("qa/state"))
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let reports = (state["reports"] as! [[String: Any]]).filter { $0["user"] as? String == user }
        XCTAssertEqual(reports.filter { $0["path"] as? String == "/Sessions/Playing/Stopped" }.count, 1)
        XCTAssertEqual(reports.filter { $0["path"] as? String == "/LiveStreams/Close" }.count, 1)
        XCTAssertEqual(reports.filter { $0["path"] as? String == "/Videos/ActiveEncodings" }.count, 1)
        let remaining = try JSONDecoder().decode([PlaybackReporter.Stored].self, from: UserDefaults.standard.data(forKey: "pendingWatchReports")!)
        XCTAssertFalse(remaining.contains { $0.userID == user })
    }

    @MainActor func testTurningPrivateViewingOnStopsQueuedHistoryRetries() async throws {
        let user = "privacy-policy-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "policy-tests")
        try await api.post("qa/control", body: ["failReports": true])
        let reporter = PlaybackReporter()
        reporter.enqueue(api: api, endpoint: "Sessions/Playing/Stopped", body: ["ItemId": "movie-1", "PositionTicks": 55])
        try await Task.sleep(for: .milliseconds(150))
        let privateAPI = JellyfinAPI(server: api.server, token: api.token, userID: user, deviceID: api.deviceID, historyEnabled: false)
        PlaybackReporter.updatePrivacy(api: privateAPI)
        try await api.post("qa/control", body: ["failReports": false])
        await reporter.flush()
        let data = try await api.send(api.request("qa/state"))
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertFalse((state["reports"] as! [[String: Any]]).contains { $0["user"] as? String == user })
        PlaybackReporter.updatePrivacy(api: api)
        await reporter.retryStored(api: api)
    }

    @MainActor func testLiveRenegotiationReusesOneTunerConsumer() async throws {
        let user = "tuner-reuse-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "tuner-reuse", historyEnabled: false)
        var item = try await api.item("channel-1")
        item.MediaSources?[0].MediaStreams?.append(MediaStream(Index: 3, Type: "Audio", Codec: "aac"))
        let controller = PlaybackController()
        controller.present(item); controller.start(api: api, quality: .original)
        for _ in 0..<150 { if !controller.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertNil(controller.error); XCTAssertFalse(controller.preparing)
        controller.stop(); await controller.flushReports()
        let data = try await api.send(api.request("qa/state"))
        let state = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let negotiations = (state["reports"] as! [[String: Any]]).filter { $0["user"] as? String == user && ($0["path"] as? String)?.hasSuffix("/PlaybackInfo") == true }
        XCTAssertEqual(negotiations.count, 2)
        XCTAssertEqual((negotiations.last?["body"] as? [String: Any])?["LiveStreamId"] as? String, "fixture-tuner")
        XCTAssertEqual((state["tunerConsumers"] as? [String: Int])?[user], 0)
    }

}

/// Layouts on a book-style foldable iPhone, which reports the phone idiom on both screens.
/// Widths in points: outer 466x678, inner portrait 669x951 (simulator profile) and 626x890
/// (Apple's published panel), inner landscape 951x669, a Split View half of 313.
@MainActor final class FoldableLayoutTests: XCTestCase {
    func testOpenInnerScreenGetsTabletLayoutsAndOuterScreenGetsPhoneLayouts() {
        for width: CGFloat in [626, 669, 890, 951] {
            XCTAssertTrue(AdaptiveLayout.detailsSideBySide(.regular, accessibility: false, width: width), "Details at \(width)")
            XCTAssertTrue(AdaptiveLayout.homeBand(.regular, accessibility: false, width: width), "Home at \(width)")
        }
        for width: CGFloat in [313, 386, 466, 669] {
            XCTAssertFalse(AdaptiveLayout.detailsSideBySide(.compact, accessibility: false, width: width), "Compact details at \(width)")
            XCTAssertFalse(AdaptiveLayout.homeBand(.compact, accessibility: false, width: width), "Compact Home at \(width)")
            XCTAssertFalse(AdaptiveLayout.connectSideBySide(.compact, accessibility: false, width: width), "Compact sign-in at \(width)")
        }
        XCTAssertFalse(AdaptiveLayout.detailsSideBySide(.regular, accessibility: true, width: 951), "Accessibility sizes keep one column")
    }

    func testSignInStacksOnTheOpenPortraitScreenAndSitsSideBySideInLandscape() {
        XCTAssertFalse(AdaptiveLayout.connectSideBySide(.regular, accessibility: false, width: 626))
        XCTAssertFalse(AdaptiveLayout.connectSideBySide(.regular, accessibility: false, width: 669))
        XCTAssertTrue(AdaptiveLayout.connectSideBySide(.regular, accessibility: false, width: 890))
        XCTAssertTrue(AdaptiveLayout.connectSideBySide(.regular, accessibility: false, width: 951))
    }

    func testAnOpenBookCreaseSplitsHomeAndDetailsIntoTwoPages() {
        // The open inner screen in landscape, its crease down the middle, with the right-edge
        // strip outside the view's safe area.
        let view = CGRect(x: 0, y: 0, width: 866, height: 669)
        let spread = FoldSpread(crease: CGRect(x: 471, y: 0, width: 9, height: 669), in: view)
        XCTAssertEqual(spread?.leadingWidth, 471)
        XCTAssertEqual(spread?.trailingStart, 480)
        // A view that starts right of the window's origin measures the crease from its own edge.
        let inset = FoldSpread(crease: CGRect(x: 471, y: 0, width: 9, height: 669), in: CGRect(x: 20, y: 50, width: 846, height: 619))
        XCTAssertEqual(inset?.leadingWidth, 451)
        XCTAssertEqual(inset?.crease.minY, -50)
    }

    func testFoldsThatLeaveNoTwoPagesMakeNoSpread() {
        let view = CGRect(x: 0, y: 0, width: 951, height: 669)
        XCTAssertNil(FoldSpread(crease: nil, in: view))
        // Tabletop: a horizontal fold is the player's business, not a page split.
        XCTAssertNil(FoldSpread(crease: CGRect(x: 0, y: 330, width: 951, height: 9), in: view))
        // Too close to an edge for a readable page.
        XCTAssertNil(FoldSpread(crease: CGRect(x: 200, y: 0, width: 9, height: 669), in: view))
        XCTAssertNil(FoldSpread(crease: CGRect(x: 700, y: 0, width: 9, height: 669), in: view))
        // The folded outer screen is too narrow for two pages wherever a crease is reported.
        XCTAssertNil(FoldSpread(crease: CGRect(x: 229, y: 0, width: 9, height: 678), in: CGRect(x: 0, y: 0, width: 466, height: 678)))
        XCTAssertNil(FoldSpread(crease: CGRect(x: 471, y: 0, width: 9, height: 678), in: CGRect(x: 0, y: 0, width: 466, height: 678)))
    }

    func testListsKeepAReadableColumnAndStayOnTheLeftPageOfAnOpenFold() throws {
        // Phones and the folded outer screen keep the system's own margins.
        for width: CGFloat in [402, 440, 466, 669, 760] { XCTAssertNil(ReadableColumn.layout(width: width, spread: nil), "\(width)") }
        // An iPad centers a 680 point column inside the list's own 20 point margins.
        XCTAssertEqual(ReadableColumn.layout(width: 1032, spread: nil), .column(720))
        // The open inner screen keeps every row left of the crease, on the system's leading edge.
        let view = CGRect(x: 0, y: 0, width: 866, height: 669)
        let spread = FoldSpread(crease: CGRect(x: 471, y: 0, width: 9, height: 669), in: view)
        XCTAssertEqual(ReadableColumn.layout(width: view.width, spread: spread), .leftPage(trailing: 415))
    }

    func testNarrowRegularWindowsUseTighterMargins() {
        XCTAssertEqual(AdaptiveLayout.margin(regular: false, width: 466), 20)
        XCTAssertEqual(AdaptiveLayout.margin(regular: true, width: 626), 28)
        XCTAssertEqual(AdaptiveLayout.margin(regular: true, width: 1024), 40)
    }

    func testClosedAndOpenFlatPlayersUseTheWholeScreen() {
        for size in [CGSize(width: 466, height: 678), CGSize(width: 678, height: 466), CGSize(width: 669, height: 951),
                     CGSize(width: 626, height: 890), CGSize(width: 951, height: 669)] {
            let stage = PlayerStage.resolve(container: size, divisions: [])
            XCTAssertEqual(stage.posture, .flat, "\(size)")
            XCTAssertEqual(stage.video, CGRect(origin: .zero, size: size))
            XCTAssertNil(stage.panel); XCTAssertNil(stage.fold)
            XCTAssertEqual(stage.transportCenter, CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    func testTabletopPutsThePictureAboveTheFoldAndTheControlsBelow() {
        let size = CGSize(width: 951, height: 669)
        let stage = PlayerStage.resolve(container: size, divisions: [CGRect(x: 0, y: 330, width: 951, height: 9)])
        XCTAssertEqual(stage.posture, .tabletop)
        XCTAssertEqual(stage.video, CGRect(x: 0, y: 0, width: 951, height: 330))
        XCTAssertEqual(stage.panel, CGRect(x: 0, y: 339, width: 951, height: 330))
        // 16:9 fits the top half 587 points wide, letterboxed by the layer.
        XCTAssertEqual((stage.video.height * 16 / 9).rounded(), 587)

        let published = PlayerStage.resolve(container: CGSize(width: 890, height: 626), divisions: [CGRect(x: 0, y: 309, width: 890, height: 8)])
        XCTAssertEqual(published.posture, .tabletop)
        XCTAssertEqual(published.video.height, 309)
        XCTAssertEqual(published.panel?.height, 309)
    }

    func testBookPostureKeepsTheWholePictureAndMovesTheTransportOffTheFold() {
        for (size, fold) in [(CGSize(width: 951, height: 669), CGRect(x: 471, y: 0, width: 9, height: 669)),
                             (CGSize(width: 669, height: 951), CGRect(x: 330, y: 0, width: 9, height: 951)),
                             (CGSize(width: 626, height: 890), CGRect(x: 309, y: 0, width: 8, height: 890))] {
            let stage = PlayerStage.resolve(container: size, divisions: [fold])
            XCTAssertEqual(stage.posture, .book, "\(size)")
            XCTAssertEqual(stage.video, CGRect(origin: .zero, size: size))
            XCTAssertNil(stage.panel)
            XCTAssertEqual(stage.fold, fold)
            // Held like a book the picture spans both pages, so the transport stays centered on it.
            XCTAssertEqual(stage.transportCenter, CGPoint(x: size.width / 2, y: size.height / 2))
        }
    }

    func testAFoldThatLeavesTooLittleRoomOrLiesOutsideIsIgnored() {
        let size = CGSize(width: 951, height: 669)
        XCTAssertEqual(PlayerStage.resolve(container: size, divisions: [CGRect(x: 0, y: 560, width: 951, height: 9)]).posture, .flat)
        XCTAssertEqual(PlayerStage.resolve(container: size, divisions: [CGRect(x: 0, y: 100, width: 951, height: 9)]).posture, .flat)
        XCTAssertEqual(PlayerStage.resolve(container: size, divisions: [CGRect(x: 0, y: 800, width: 951, height: 9)]).posture, .flat)
        // A short band across part of the width is an occlusion-like notch, not a fold.
        XCTAssertEqual(PlayerStage.resolve(container: size, divisions: [CGRect(x: 300, y: 330, width: 200, height: 9)]).posture, .flat)
    }

    func testSkipButtonsUseTheNumberedArrowOnlyWhereOneExists() {
        XCTAssertEqual(PlayerView.skipSymbol(forward: false, seconds: 10), "gobackward.10")
        XCTAssertEqual(PlayerView.skipSymbol(forward: true, seconds: 30), "goforward.30")
        XCTAssertEqual(PlayerView.skipSymbol(forward: true, seconds: 20), "goforward")
    }
}

/// Lays out real screens at a book-style foldable iPhone's screen sizes and asks the host to
/// capture each one, for review on simulators that cannot fold. Inner sizes get a regular size
/// class, the outer one compact; the tabletop and book players get a simulated fold band.
/// Run it on a portrait iPad big enough to hold 951x669 points; each capture is the whole
/// screen with the layout in its top-left corner.
///
/// Runs only when the test runner receives `REEL_RENDER_DIR` (a folder a host script answers,
/// as for the screen tour) and `REEL_RENDER_SERVER` (a loopback demo library).
@MainActor final class FoldableRenderTests: XCTestCase {
    private final class Vault: AccountVaultStorage {
        var value: AccountVault
        init(_ value: AccountVault) { self.value = value }
        func read() throws -> AccountVault { value }
        func save(_ value: AccountVault) throws { self.value = value }
        func clear() throws { value = AccountVault() }
    }

    /// Pins the hosted screen to the top-left corner at the size under test.
    private final class Frame: UIViewController {
        let content: UIViewController
        let size: CGSize
        init(_ content: UIViewController, size: CGSize) {
            self.content = content; self.size = size
            super.init(nibName: nil, bundle: nil)
        }
        required init?(coder: NSCoder) { fatalError("Not used from a storyboard") }
        override func viewDidLoad() {
            super.viewDidLoad()
            view.backgroundColor = .darkGray
            addChild(content); view.addSubview(content.view); content.didMove(toParent: self)
        }
        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            content.view.frame = CGRect(origin: .zero, size: size)
        }
    }

    private struct Screen {
        let label: String
        let size: CGSize
        let sizeClass: UIUserInterfaceSizeClass
        /// The fold band for the posture this size is folded into, if any.
        let fold: (name: String, band: CGRect)?
        /// The crease Home and Details lay their two pages around, when the screen is open flat.
        var spread: CGRect?
        /// A phone-sized screen for Home and Details only; the player and sign-in are rendered
        /// at the foldable sizes.
        var browseOnly = false
        /// A text size other than the default, for the large text layouts.
        var contentSize: UIContentSizeCategory?
    }

    func testRenderFoldableScreens() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Renders run only on simulators.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["REEL_RENDER_DIR"], let address = environment["REEL_RENDER_SERVER"],
              let server = URL(string: address), server.host == "127.0.0.1" else {
            throw XCTSkip("Set TEST_RUNNER_REEL_RENDER_DIR and a loopback TEST_RUNNER_REEL_RENDER_SERVER to render.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        XCTAssertGreaterThanOrEqual(scene.effectiveGeometry.coordinateSpace.bounds.width, 951, "Use a portrait iPad wide enough for 951 points.")
        let suite = "Reel.FoldableRenderTests"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let account = Account(server: server, token: "fixture-render", userID: "render", name: "Alex", serverName: "Demo library")
        let session = Session(storage: Vault(AccountVault(accounts: [account], activeID: account.id)), defaults: defaults)
        let signedOut = Session(storage: Vault(AccountVault()), defaults: defaults)
        let api = try XCTUnwrap(session.api)
        let movie = try await api.item("movie-saltwater-kings")
        let series = try await api.item("series-pier-seventeen")
        let downloads = Downloads(), preferences = ServerPreferences(defaults: defaults)
        let mediaHub = MediaHub(), remoteSessions = RemoteSessions(), syncPlay = SyncPlayClient()

        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        defer { window.isHidden = true; window.rootViewController = nil }

        func show(_ view: some View, on screen: Screen, as name: String, settle: Double) async throws {
            let root = view.environment(downloads).environment(preferences).environment(mediaHub)
                .environment(remoteSessions).environment(syncPlay)
                .preferredColorScheme(.dark).tint(Color.reelBlue).foregroundStyle(Color.reelText)
            let hosting = UIHostingController(rootView: root)
            hosting.traitOverrides.horizontalSizeClass = screen.sizeClass
            hosting.traitOverrides.verticalSizeClass = .regular
            if let contentSize = screen.contentSize { hosting.traitOverrides.preferredContentSizeCategory = contentSize }
            window.rootViewController = Frame(hosting, size: screen.size)
            window.makeKeyAndVisible()
            try await Task.sleep(for: .seconds(settle))
            try await capture("\(name)-\(screen.label)", in: folder)
        }

        let screens = [
            Screen(label: "outer-466x678", size: CGSize(width: 466, height: 678), sizeClass: .compact, fold: nil),
            Screen(label: "inner-669x951", size: CGSize(width: 669, height: 951), sizeClass: .regular,
                   fold: ("book", CGRect(x: 330, y: 0, width: 9, height: 951))),
            Screen(label: "inner-626x890", size: CGSize(width: 626, height: 890), sizeClass: .regular,
                   fold: ("book", CGRect(x: 309, y: 0, width: 8, height: 890))),
            Screen(label: "inner-951x669", size: CGSize(width: 951, height: 669), sizeClass: .regular,
                   fold: ("tabletop", CGRect(x: 0, y: 330, width: 951, height: 9)),
                   spread: CGRect(x: 471, y: 0, width: 9, height: 669)),
            Screen(label: "inner-890x626", size: CGSize(width: 890, height: 626), sizeClass: .regular,
                   fold: ("tabletop", CGRect(x: 0, y: 309, width: 890, height: 8)),
                   spread: CGRect(x: 441, y: 0, width: 8, height: 626)),
            Screen(label: "phone-402x874", size: CGSize(width: 402, height: 874), sizeClass: .compact, fold: nil, browseOnly: true),
            Screen(label: "phone-largetext-402x874", size: CGSize(width: 402, height: 874), sizeClass: .compact, fold: nil,
                   browseOnly: true, contentSize: .accessibilityExtraExtraExtraLarge),
        ]
        // REEL_RENDER_BROWSE_ONLY skips the player and sign-in, for a quick look at Home and Details.
        let browseRun = environment["REEL_RENDER_BROWSE_ONLY"] != nil
        for screen in screens {
            try await show(MainView().environment(session).environment(\.simulatedFoldDivisions, screen.spread.map { [$0] }),
                           on: screen, as: "home", settle: 5)
            try await show(NavigationStack { DetailView(item: movie) }.environment(session).environment(PlaybackController())
                .environment(\.foldCrease, screen.spread), on: screen, as: "detail-movie", settle: 4)
            try await show(NavigationStack { DetailView(item: series) }.environment(session).environment(PlaybackController())
                .environment(\.foldCrease, screen.spread), on: screen, as: "detail-series", settle: 4)
            if screen.browseOnly || browseRun { continue }
            try await show(ConnectView().environment(signedOut), on: screen, as: "connect", settle: 2)
            var folds: [(name: String, band: CGRect)?] = [nil]
            if let fold = screen.fold { folds.append(fold) }
            for fold in folds {
                let playback = PlaybackController()
                // From the start: the demo clip is shorter than a saved resume position.
                playback.present(movie, fromBeginning: true, startPositionTicks: 0)
                let player = PlayerView(item: movie).environment(session).environment(playback)
                    .environment(\.simulatedFoldDivisions, fold.map { [$0.band] })
                // The demo clip is 14 seconds long: hold it paused near the start, where the
                // controls stay up, then let it play for the idle capture.
                try await show(player, on: screen, as: "player-" + (fold?.name ?? "flat") + "-loading", settle: 0.2)
                for _ in 0..<40 where playback.preparing { try await Task.sleep(for: .milliseconds(250)) }
                playback.seek(to: Int64(2 * ticksPerSecond))
                if playback.isPlaying { playback.togglePause() }
                try await Task.sleep(for: .seconds(1.5))
                try await capture("player-" + (fold?.name ?? "flat") + "-\(screen.label)", in: folder)
                if fold?.name == "tabletop" {
                    // Playing, the panel dims after four idle seconds.
                    playback.togglePause()
                    try await Task.sleep(for: .seconds(5.5))
                    try await capture("player-tabletop-idle-\(screen.label)", in: folder)
                }
                playback.stop(); playback.activeItem = nil
            }
        }
        #endif
    }

    /// The player draws video on a layer it owns instead of AVPlayerViewController. This checks
    /// that a WebVTT subtitle rendition still appears on screen through that surface, and goes
    /// away when subtitles are turned off. Needs `REEL_RENDER_DIR` (answered by the host, as
    /// above) and `REEL_CAPTION_MEDIA`, a loopback HLS master with a WebVTT rendition named
    /// "Synthetic multi-audio captions" whose cue reads "REEL TV MULTI AUDIO CAPTION".
    func testPlayerSurfaceDrawsWebVTTCaptions() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Caption checks run only on simulators.")
        #else
        let environment = ProcessInfo.processInfo.environment
        guard let path = environment["REEL_RENDER_DIR"], let address = environment["REEL_CAPTION_MEDIA"],
              let media = URL(string: address), media.host == "127.0.0.1" else {
            throw XCTSkip("Set TEST_RUNNER_REEL_RENDER_DIR and a loopback TEST_RUNNER_REEL_CAPTION_MEDIA to check captions.")
        }
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let player = AVPlayer(url: media)
        player.isMuted = true
        let window = UIWindow(windowScene: scene)
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.windowLevel = .normal + 1
        defer { player.pause(); window.isHidden = true; window.rootViewController = nil }
        let surface = PlayerSurface(player: player, pictureInPicture: PictureInPicture(), allowsPictureInPicture: false)
        window.rootViewController = UIHostingController(rootView: surface.ignoresSafeArea())
        window.makeKeyAndVisible()

        let item = try XCTUnwrap(player.currentItem)
        let legible = try await item.asset.loadMediaSelectionGroup(for: .legible)
        let group = try XCTUnwrap(legible)
        print("Legible options:", group.options.map { "\($0.displayName) \($0.mediaType.rawValue) forced=\($0.hasMediaCharacteristic(.containsOnlyForcedSubtitles))" })
        let captions = try XCTUnwrap(group.options.first { $0.mediaType == .subtitle && !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles) })
        item.select(captions, in: group)
        player.play()
        try await Task.sleep(for: .seconds(4))
        let shown = try await screenText("captions-on", in: folder)
        XCTAssertTrue(shown.contains("REEL TV MULTI AUDIO CAPTION"), "The WebVTT cue must render on the player surface; read: \(shown)")

        item.select(nil, in: group)
        try await Task.sleep(for: .seconds(2))
        let hidden = try await screenText("captions-off", in: folder)
        XCTAssertFalse(hidden.contains("REEL TV MULTI AUDIO CAPTION"), "Turning subtitles off must remove the cue; read: \(hidden)")
        #endif
    }

    /// Captures the simulator screen through the host and reads its text.
    private func screenText(_ name: String, in folder: URL) async throws -> String {
        try await capture(name, in: folder)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(url: folder.appendingPathComponent(name + ".png"), options: [:]).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ").uppercased()
    }

    /// Asks the host for a simulator screenshot and waits until it lands.
    private func capture(_ name: String, in folder: URL) async throws {
        let request = folder.appendingPathComponent(name + ".request")
        let image = folder.appendingPathComponent(name + ".png")
        try? FileManager.default.removeItem(at: image)
        try Data(name.utf8).write(to: request)
        let deadline = Date().addingTimeInterval(30)
        while !FileManager.default.fileExists(atPath: image.path) && Date() < deadline { try await Task.sleep(for: .milliseconds(250)) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: image.path), "The host did not capture \(name).")
    }
}
