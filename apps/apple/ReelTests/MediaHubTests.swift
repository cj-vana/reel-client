import XCTest
import AVFoundation
import PDFKit
@testable import Reel

final class MediaHubTests: XCTestCase {
    private func connection(_ user: String, privateViewing: Bool = false) -> (Account, JellyfinAPI) {
        let account = Account(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, name: "Fixture", serverName: "Reel Test Library")
        let api = JellyfinAPI(server: account.server, token: account.token, userID: user, deviceID: "media-hub-tests", historyEnabled: !privateViewing)
        return (account, api)
    }

    func testMediaQueriesPreserveAlbumPlaylistAndArtistSemantics() {
        let album = HubItem(Id: "album", Name: "Album", Type: "MusicAlbum")
        let albumQuery = HubAPI.query(section: .albums, parent: album, search: "", start: 60, limit: 500)
        XCTAssertEqual(albumQuery["parentId"], "album")
        XCTAssertEqual(albumQuery["includeItemTypes"], "Audio")
        XCTAssertEqual(albumQuery["sortBy"], "ParentIndexNumber,IndexNumber,SortName")
        XCTAssertEqual(albumQuery["recursive"], "false")
        XCTAssertEqual(albumQuery["startIndex"], "60")
        XCTAssertEqual(albumQuery["limit"], "200")
        let artist = HubItem(Id: "artist", Name: "Artist", Type: "MusicArtist")
        let artistQuery = HubAPI.query(section: .artists, parent: artist, search: "  signal  ", start: 0, limit: 60)
        XCTAssertEqual(artistQuery["artistIds"], "artist")
        XCTAssertNil(artistQuery["parentId"])
        XCTAssertEqual(artistQuery["includeItemTypes"], "MusicAlbum")
        XCTAssertEqual(artistQuery["searchTerm"], "signal")
        let playlist = HubItem(Id: "playlist", Name: "Playlist", Type: "Playlist")
        let playlistQuery = HubAPI.query(section: .playlists, parent: playlist, search: "unsupported search", start: 0, limit: 60)
        XCTAssertNil(playlistQuery["sortBy"], "Playlist sequence belongs to the server.")
        XCTAssertNil(playlistQuery["parentId"])
        XCTAssertNil(playlistQuery["includeItemTypes"])
        XCTAssertNil(playlistQuery["searchTerm"], "Playlist items do not implement server search.")
        XCTAssertEqual(HubAPI.query(section: .photos, parent: nil, search: "", start: 0, limit: 60)["includeItemTypes"], "Photo")
    }

    func testSavedFileNamesCannotTraverseOutsideTheMediaDirectory() {
        XCTAssertTrue(MediaHub.validFilename(UUID().uuidString + ".pdf"))
        for name in ["../book.pdf", "/book.pdf", "book.pdf", UUID().uuidString + ".pdf/other", UUID().uuidString + ".", UUID().uuidString + ".pdf.exe"] {
            XCTAssertFalse(MediaHub.validFilename(name), name)
        }
    }

    @MainActor func testProtectedPreviewRejectsSavedBooksAndAudioBeforeStartingTransfer() {
        let account = Account(server: URL(string: "http://192.0.2.10:8096")!, token: "fixture-not-a-real-token", userID: "preview-test", name: "Preview", serverName: "Preview")
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: "preview-test")
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = MediaHub(directory: directory)
        for item in [HubItem(Id: "protected-book", Name: "Book", Type: "Book", Container: "pdf"), HubItem(Id: "protected-audio", Name: "Song", Type: "Audio", Container: "mp3")] {
            let key = MediaHub.fileKey(accountID: account.id, itemID: item.id)
            hub.save(item, account: account, api: api)
            XCTAssertEqual(hub.fileErrors[key], ReelError.previewProtected.localizedDescription)
            XCTAssertFalse(hub.saving.contains(key))
            XCTAssertNil(hub.saved(item, accountID: account.id))
        }
    }

    func testNestedAudiobookFoldersExpandInOrderAndRejectCycles() async throws {
        let folder = HubItem(Id: "book-folder", Name: "Book", Type: "AudioBook", IsFolder: true)
        let nested = HubItem(Id: "disc", Name: "Disc", Type: "Folder", IsFolder: true)
        let first = HubItem(Id: "first", Name: "First chapter", Type: "Audio")
        let second = HubItem(Id: "second", Name: "Second chapter", Type: "Audio")
        let third = HubItem(Id: "third", Name: "Third chapter", Type: "Audio")
        let pages = ["root": HubPage(Items: [folder, third], TotalRecordCount: 2), "book-folder": HubPage(Items: [first, nested], TotalRecordCount: 2), "disc": HubPage(Items: [second], TotalRecordCount: 1)]
        let tracks = try await HubAPI.gatherAudio(parent: nil) { parent, _ in pages[parent?.id ?? "root"] ?? HubPage(Items: [], TotalRecordCount: 0) }
        XCTAssertEqual(tracks.map(\.id), ["first", "second", "third"])
        let query = HubAPI.query(section: .audiobooks, parent: nested, search: "", start: 0, limit: 60)
        XCTAssertEqual(query["includeItemTypes"], "Audio,AudioBook,Folder")
        XCTAssertEqual(query["sortBy"], "ParentIndexNumber,IndexNumber,SortName")
        do { _ = try await HubAPI.gatherAudio(parent: nil) { _, _ in HubPage(Items: [folder], TotalRecordCount: 1) }; XCTFail("Cyclic provider folders must fail instead of looping.") }
        catch { XCTAssertEqual(error as? ReelError, .invalidResponse) }
    }

    @MainActor func testNativeMusicUsesAndRevokesThePrivateGatewayCapability() async throws {
        let (account, _) = connection("hub-gateway-" + UUID().uuidString, privateViewing: true)
        let previous = try GatewayHeaderStore.read(for: account.server)
        defer { try? GatewayHeaderStore.save(previous, for: account.server) }
        try GatewayHeaderStore.save([GatewayHeader(name: "X-Reel-Fixture-Gateway", value: "fixture-gateway-secret")], for: account.server)
        let api = JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: "media-hub-gateway-test", historyEnabled: false)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = MediaHub(directory: directory)
        defer { hub.stop() }
        let tracks = try await HubAPI.allAudio(api: api, section: .tracks, parent: nil)
        hub.play(tracks, account: account, api: api)
        try await ready(hub)
        let localURL = try XCTUnwrap((hub.player.currentItem?.asset as? AVURLAsset)?.url)
        XCTAssertEqual(localURL.host, "127.0.0.1")
        XCTAssertNotEqual(localURL.port, api.server.port)
        XCTAssertNil(localURL.query)
        XCTAssertFalse(localURL.absoluteString.contains(account.token))
        hub.stop()
        var request = URLRequest(url: localURL); request.timeoutInterval = 2
        do { _ = try await URLSession.shared.data(for: request); XCTFail("Stopped audio must revoke its local capability.") } catch { }
    }

    @MainActor func testPrivateViewingChangesApplyToAlreadyPlayingMusic() async throws {
        let user = "hub-policy-" + UUID().uuidString
        let (account, publicAPI) = connection(user)
        let (_, privateAPI) = connection(user, privateViewing: true)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let hub = MediaHub(directory: directory)
        defer { hub.stop() }
        let tracks = try await HubAPI.allAudio(api: publicAPI, section: .tracks, parent: nil)
        hub.play(tracks, account: account, api: publicAPI)
        try await ready(hub)
        await hub.flushReports()
        let before = try await historyCount(api: publicAPI, user: user)
        XCTAssertGreaterThan(before, 0)
        hub.updatePrivacy(api: privateAPI)
        hub.checkpoint(); hub.pause()
        await hub.flushReports()
        let after = try await historyCount(api: publicAPI, user: user)
        XCTAssertEqual(after, before, "A background music player must immediately use the current privacy policy.")
    }

    @MainActor func testClosingDuringInitialAudioSeekPreservesResumeAndSendsNoZeroHistory() async throws {
        let user = "hub-early-close-" + UUID().uuidString
        let (account, api) = connection(user)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "MediaHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: directory) }
        let books = try await HubAPI.browse(api: api, section: .audiobooks)
        let book = try XCTUnwrap(books.Items.first)
        let key = "hub-progress|" + account.id + "|" + book.id
        defaults.set(8.0, forKey: key)
        let gate = HubSeekGate()
        let hub = MediaHub(directory: directory, defaults: defaults, initialSeek: { player, seconds in
            await gate.wait()
            _ = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600))
        })
        hub.play([book], account: account, api: api)
        for _ in 0..<150 { if gate.waiting || hub.error != nil { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertTrue(gate.waiting)
        XCTAssertTrue(hub.preparing)
        hub.pause(); hub.checkpoint(); hub.stop()
        gate.release()
        try await Task.sleep(for: .milliseconds(100))
        await hub.flushReports()
        XCTAssertEqual(defaults.double(forKey: key), 8.0, accuracy: 0.01)
        let count = try await historyCount(api: api, user: user)
        XCTAssertEqual(count, 0, "Pause/checkpoint/close while initial seeking must not write a zero watch position.")
        XCTAssertNil(hub.player.currentItem)
    }

    @MainActor func testCorruptMediaManifestBlocksChangesAndPreservesExistingFilesUntilRecovery() async throws {
        let (account, api) = connection("hub-storage-" + UUID().uuidString)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let book = HubItem(Id: "existing-book", Name: "Existing book", Type: "Book", Container: "pdf")
        let filename = UUID().uuidString + ".pdf"
        let file = HubFile(id: UUID(), accountID: account.id, item: book, filename: filename, bytes: 22)
        let original = directory.appendingPathComponent(filename)
        let media = Data("existing offline media".utf8)
        try media.write(to: original)
        let manifest = directory.appendingPathComponent("files.json")
        let damaged = Data("incomplete-index".utf8)
        try damaged.write(to: manifest)
        let hub = MediaHub(directory: directory)
        XCTAssertNotNil(hub.fileErrors["storage"])
        hub.save(book, account: account, api: api)
        await hub.waitForFiles()
        XCTAssertEqual(try Data(contentsOf: manifest), damaged)
        XCTAssertEqual(try Data(contentsOf: original), media)
        XCTAssertTrue(hub.files.isEmpty)
        XCTAssertThrowsError(try hub.remove(file))
        try JSONEncoder().encode([file]).write(to: manifest)
        hub.recoverStorage()
        XCTAssertNil(hub.fileErrors["storage"])
        XCTAssertEqual(hub.files.count, 1)
        XCTAssertTrue(hub.requestedFiles.isEmpty)
        try hub.remove(file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
    }

    @MainActor func testReportFlushWaitsForCanceledNegotiationEncoderCleanup() async throws {
        let user = "hub-late-cleanup-" + UUID().uuidString
        let (account, api) = connection(user, privateViewing: true)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let gate = HubSeekGate()
        defer { gate.release() }
        let hub = MediaHub(directory: directory, prepareAudio: { api, item in
            await gate.wait()
            return (api.url("Audio/\(item.id)/stream"), MediaSource(Id: "late-source"), "late-session", "Transcode")
        })
        hub.play([HubItem(Id: "late-audio", Name: "Late audio", Type: "Audio")], account: account, api: api)
        for _ in 0..<100 { if gate.waiting { break }; try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(gate.waiting)
        hub.stop()
        var completed = false
        let flush = Task { await hub.flushReports(); completed = true }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(completed, "Logout must retain credentials until canceled negotiation has enqueued its encoder cleanup.")
        gate.release()
        await flush.value
        let data = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let reports = (json["reports"] as! [[String: Any]]).filter { $0["user"] as? String == user }
        XCTAssertEqual(reports.filter { $0["path"] as? String == "/Videos/ActiveEncodings" }.count, 1)
        XCTAssertFalse(reports.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
    }

    @MainActor private func historyCount(api: JellyfinAPI, user: String) async throws -> Int {
        let data = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return (json["reports"] as! [[String: Any]]).filter { ($0["user"] as? String) == user && ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true }.count
    }

    @MainActor func testRepeatedPlaylistEntriesKeepTheirSelectedQueuePosition() throws {
        let (account, api) = connection("hub-duplicate", privateViewing: true)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let name = "MediaHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name); try? FileManager.default.removeItem(at: directory) }
        let first = HubItem(Id: "hub-track-1", Name: "First", Type: "Audio")
        let second = HubItem(Id: "hub-track-2", Name: "Second", Type: "Audio")
        let hub = MediaHub(directory: directory, defaults: defaults)
        hub.play([first, second, first], at: 2, account: account, api: api)
        XCTAssertEqual(hub.index, 2)
        XCTAssertEqual(hub.queue.count, 3)
        hub.stop()
    }

    func testTypedMusicPhotoAndBookContracts() async throws {
        let (_, api) = connection("hub-contract")
        let albums = try await HubAPI.browse(api: api, section: .albums)
        let album = try XCTUnwrap(albums.Items.first)
        XCTAssertEqual(album.Type, "MusicAlbum")
        let tracks = try await HubAPI.allAudio(api: api, section: .albums, parent: album)
        XCTAssertEqual(tracks.map(\.id), ["hub-track-1", "hub-track-2"])
        let artists = try await HubAPI.browse(api: api, section: .artists)
        let artist = try XCTUnwrap(artists.Items.first)
        let artistAlbums = try await HubAPI.browse(api: api, section: .artists, parent: artist)
        XCTAssertEqual(artistAlbums.Items.first?.id, album.id)
        let playlist = HubItem(Id: "hub-playlist-1", Name: "Playlist", Type: "Playlist")
        let playlistTracks = try await HubAPI.allAudio(api: api, section: .playlists, parent: playlist)
        XCTAssertEqual(playlistTracks.map(\.id), ["hub-track-2", "hub-track-1"])
        let photos = try await HubAPI.browse(api: api, section: .photos)
        XCTAssertEqual(photos.Items.map(\.Type), ["Photo", "Photo"])
        let books = try await HubAPI.browse(api: api, section: .books)
        XCTAssertEqual(books.Items.first?.Container, "pdf")
        let audio = try await HubAPI.audio(api: api, item: tracks[0])
        XCTAssertEqual(audio.0.path, "/Audio/hub-track-1/stream")
        XCTAssertEqual(audio.3, "DirectPlay")
        XCTAssertTrue(JellyfinAPI.sameOrigin(audio.0, api.server))
        let lyrics: HubLyrics = try await api.get("Audio/hub-track-1/Lyrics")
        XCTAssertEqual(lyrics.Lyrics.count, 2)
        XCTAssertEqual(lyrics.Lyrics[1].Start, 100_000_000)
        let audiobooks = try await HubAPI.browse(api: api, section: .audiobooks)
        XCTAssertEqual(audiobooks.Items.first?.Chapters?.last?.StartPositionTicks, 100_000_000)
    }

    @MainActor func testNativeAudioQueuePauseSeekAndAccountSpecificRelaunch() async throws {
        let user = "hub-native-" + UUID().uuidString
        let (account, api) = connection(user, privateViewing: true)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaultsName = "MediaHubTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer { defaults.removePersistentDomain(forName: defaultsName); try? FileManager.default.removeItem(at: directory) }
        let tracks = try await HubAPI.allAudio(api: api, section: .tracks, parent: nil)
        let hub = MediaHub(directory: directory, defaults: defaults)
        hub.play(tracks, account: account, api: api)
        try await ready(hub)
        XCTAssertEqual(hub.current?.id, "hub-track-1")
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertGreaterThan(hub.player.currentTime().seconds, 0)
        hub.pause(); hub.seek(8)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertFalse(hub.playing)
        XCTAssertGreaterThanOrEqual(hub.player.currentTime().seconds, 7.8)
        hub.next(); try await ready(hub)
        XCTAssertEqual(hub.current?.id, "hub-track-2")
        hub.previous(); try await ready(hub)
        XCTAssertEqual(hub.current?.id, "hub-track-1")
        hub.pause(); hub.checkpoint(); hub.stop()
        await hub.flushReports()
        let restored = MediaHub(directory: directory, defaults: defaults)
        restored.bind(account: account, api: api)
        XCTAssertEqual(restored.queue.count, 2)
        XCTAssertEqual(restored.current?.id, "hub-track-1")
        XCTAssertGreaterThanOrEqual(restored.position, 7.8)
        XCTAssertFalse(restored.playing, "Restoring a queue must not start audio unexpectedly.")
        let (otherAccount, otherAPI) = connection("hub-other-" + UUID().uuidString)
        restored.bind(account: otherAccount, api: otherAPI)
        XCTAssertTrue(restored.queue.isEmpty, "Queues must not cross accounts.")
        let data = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let reports = json["reports"] as! [[String: Any]]
        XCTAssertFalse(reports.contains { ($0["user"] as? String) == user && ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true }, "Private music playback must not write server history.")
    }

    @MainActor func testBookSavePDFReaderRelaunchIsolationAndTransactionalRemoval() async throws {
        let (account, api) = connection("hub-book-" + UUID().uuidString)
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let books = try await HubAPI.browse(api: api, section: .books)
        let book = try XCTUnwrap(books.Items.first)
        let hub = MediaHub(directory: directory)
        hub.save(book, account: account, api: api)
        await hub.waitForFiles()
        let file = try XCTUnwrap(hub.saved(book, accountID: account.id))
        XCTAssertEqual(PDFDocument(url: hub.fileURL(file))?.pageCount, 2)
        XCTAssertGreaterThan(file.bytes, 0)
        XCTAssertEqual(MediaHub(directory: directory).files.count, 1)
        XCTAssertNil(hub.saved(book, accountID: account.id + "-other"))
        let manifest = directory.appendingPathComponent("files.json")
        let originalManifest = try Data(contentsOf: manifest)
        XCTAssertFalse(String(decoding: originalManifest, as: UTF8.self).contains(account.token))
        try FileManager.default.removeItem(at: manifest)
        try FileManager.default.createDirectory(at: manifest, withIntermediateDirectories: false)
        XCTAssertThrowsError(try hub.remove(file), "Simulate a manifest commit failure after moving the media.")
        XCTAssertTrue(FileManager.default.fileExists(atPath: hub.fileURL(file).path), "The original must be rolled back when committing removal fails.")
        XCTAssertEqual(hub.files.count, 1)
        try FileManager.default.removeItem(at: manifest)
        try originalManifest.write(to: manifest)
        try hub.remove(file)
        XCTAssertTrue(hub.files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: hub.fileURL(file).path))
        XCTAssertTrue(MediaHub(directory: directory).files.isEmpty)
    }

    @MainActor func testDeniedAndCancelledFilesNeverBecomeAvailableOffline() async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let (account, api) = connection("nodownload")
        let books = try await HubAPI.browse(api: api, section: .books)
        let book = try XCTUnwrap(books.Items.first)
        let hub = MediaHub(directory: directory)
        hub.save(book, account: account, api: api)
        await hub.waitForFiles()
        XCTAssertTrue(hub.files.isEmpty)
        XCTAssertNotNil(hub.fileErrors[MediaHub.fileKey(accountID: account.id, itemID: book.id)])
        XCTAssertNotNil(hub.requestedFiles[MediaHub.fileKey(accountID: account.id, itemID: book.id)], "Failed transfers retain metadata for a reachable retry.")
        hub.dismissSave(MediaHub.fileKey(accountID: account.id, itemID: book.id))
        XCTAssertTrue(hub.requestedFiles.isEmpty)
        let (allowed, allowedAPI) = connection("hub-cancel")
        hub.save(book, account: allowed, api: allowedAPI)
        hub.cancelSave(MediaHub.fileKey(accountID: allowed.id, itemID: book.id))
        await hub.waitForFiles()
        XCTAssertTrue(hub.files.isEmpty)
        XCTAssertTrue(hub.saving.isEmpty)
        XCTAssertTrue(hub.requestedFiles.isEmpty)
    }

    @MainActor private func ready(_ hub: MediaHub) async throws {
        for _ in 0..<150 { if !hub.preparing { break }; try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertFalse(hub.preparing)
        XCTAssertNil(hub.error)
        XCTAssertNotNil(hub.player.currentItem)
    }
    @MainActor func testSavedFileCrashRecoveryRestoresReferencedTombstonesAndPurgesOrphans() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let filename = UUID().uuidString + ".pdf"
        let entry = HubFile(id: UUID(), accountID: "account", item: HubItem(Id: "book", Name: "Book", Type: "Book", Container: "pdf"), filename: filename, bytes: 3)
        let manifest = directory.appendingPathComponent("files.json")
        try JSONEncoder().encode([entry]).write(to: manifest)
        let original = directory.appendingPathComponent(filename)
        let tombstone = directory.appendingPathComponent(filename + ".removing")
        try Data([1, 2, 3]).write(to: tombstone)
        let orphan = directory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data([4]).write(to: orphan)
        let recovered = MediaHub(directory: directory)
        XCTAssertEqual(recovered.files.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphan.path))
        try FileManager.default.moveItem(at: original, to: tombstone)
        try JSONEncoder().encode([HubFile]()).write(to: manifest)
        XCTAssertTrue(MediaHub(directory: directory).files.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: tombstone.path))
    }

}

@MainActor private final class HubSeekGate {
    private(set) var waiting = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { waiting = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
