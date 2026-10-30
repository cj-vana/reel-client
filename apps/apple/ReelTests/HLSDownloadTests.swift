import AVFoundation
import Darwin
import XCTest
@testable import Reel

@MainActor final class HLSDownloadTests: XCTestCase {
    private func temporaryDirectory() -> URL { URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true) }
    private func physicalPath(_ url: URL) throws -> String {
        let path = try XCTUnwrap(realpath(url.path, nil))
        defer { free(path) }
        return String(cString: path)
    }

    private func video() -> MediaItem {
        MediaItem(Id: "movie-1", Name: "Offline film", Type: "Movie", UserData: UserData(PlaybackPositionTicks: 800_000_000),
                  MediaSources: [MediaSource(Id: "source", Container: "mp4", TranscodingUrl: "/Videos/movie-1/master.m3u8?ApiKey=source-secret",
                                             MediaStreams: [MediaStream(Index: 0, Type: "Video", Codec: "h264"), MediaStream(Index: 1, Type: "Audio", Codec: "aac")])])
    }

    func testOptimizedPlanStartsAtBeginningAndPinsEncoding() throws {
        let api = JellyfinAPI(server: URL(string: "https://media.example.com/jellyfin")!, token: "private-token", userID: "user", deviceID: "offline-device", historyEnabled: false)
        let source = MediaSource(Id: "source", SupportsDirectPlay: false,
                                 TranscodingUrl: "/jellyfin/Videos/movie-1/master.m3u8?startTimeTicks=800000000&videoCodec=hevc&maxWidth=3840&api_key=old")
        let url = try HLSDownloadPlan.url(api: api, item: video(), source: source, sessionID: "download-session")
        XCTAssertEqual(url.path, "/jellyfin/Videos/movie-1/master.m3u8")
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        func values(_ name: String) -> [String] { query.filter { $0.name.lowercased() == name.lowercased() }.compactMap(\.value) }
        XCTAssertEqual(values("StartTimeTicks"), ["0"])
        XCTAssertEqual(values("VideoCodec"), ["h264"])
        XCTAssertEqual(values("AudioCodec"), ["aac"])
        XCTAssertEqual(values("MaxWidth"), ["1280"])
        XCTAssertEqual(values("MaxHeight"), ["720"])
        XCTAssertEqual(values("AllowVideoStreamCopy"), ["false"])
        XCTAssertEqual(values("Context"), ["Static"])
        XCTAssertEqual(values("ApiKey"), ["private-token"])
        XCTAssertEqual(values("PlaySessionId"), ["download-session"])
        XCTAssertThrowsError(try HLSDownloadPlan.url(api: api, item: video(), source: MediaSource(Id: "source", SupportsDirectPlay: true), sessionID: "s"))
        XCTAssertThrowsError(try HLSDownloadPlan.url(api: api, item: video(), source: MediaSource(Id: "source", TranscodingUrl: "https://foreign.example/master.m3u8"), sessionID: "s"))
        XCTAssertThrowsError(try HLSDownloadPlan.url(api: api, item: video(), source: MediaSource(Id: "source", TranscodingUrl: "https://media.example.com/another-service/master.m3u8"), sessionID: "s"))
    }

    func testManifestMetadataContainsNoTokensOrRemoteMediaURLs() throws {
        let api = JellyfinAPI(server: URL(string: "https://media.example.com/jellyfin")!, token: "private-token", userID: "user", deviceID: "device")
        let account = Account(server: api.server, token: "private-token", userID: "user", name: "User", serverName: "Server")
        let record = HLSDownloadRecord(account: account, api: api, item: video())
        let data = try JSONEncoder().encode(record)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(json.contains("private-token"))
        XCTAssertFalse(json.contains("source-secret"))
        XCTAssertFalse(json.contains("master.m3u8"))
        XCTAssertNil(record.item.MediaSources)
        XCTAssertEqual(try JSONDecoder().decode(HLSDownloadRecord.self, from: data).accountID, account.id)
    }

    func testPackageReferenceRejectsTraversalAndSymlinkEscapes() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("Library/com.apple.UserManagedAssets.test", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        let package = managed.appendingPathComponent("video.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
        let relative = try HLSPackageLocation.relative(package, root: root)
        XCTAssertEqual(try HLSPackageLocation.resolve(relative, root: root).path, "/.nofollow" + (try physicalPath(package)))
        for value in ["../video.movpkg", "/Library/com.apple.UserManagedAssets/video.movpkg", "Library/com.apple.UserManagedAssets/../Preferences/video.movpkg",
                      "Library/Preferences/video.movpkg", "Library/com.apple.UserManagedAssetsForgery/video.movpkg", "Library/com.apple.UserManagedAssets/video.mp4",
                      "Library/com.apple.UserManagedAssets/%2e%2e/video.movpkg"] {
            XCTAssertThrowsError(try HLSPackageLocation.resolve(value, root: root), value)
        }
        let outside = root.appendingPathComponent("Library/Preferences", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let link = managed.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try HLSPackageLocation.resolve("Library/com.apple.UserManagedAssets.test/escape/video.movpkg", root: root))
        try FileManager.default.createSymbolicLink(at: managed.appendingPathComponent("dangling"), withDestinationURL: root.appendingPathComponent("missing"))
        XCTAssertThrowsError(try HLSPackageLocation.resolve("Library/com.apple.UserManagedAssets.test/dangling/video.movpkg", root: root))
        XCTAssertThrowsError(try HLSPackageLocation.relative(URL(string: "https://example.com/video.movpkg")!, root: root))
    }

    func testNativePackageTitleEscapesRemainLiteralInsideManagedFolder() throws {
        let root = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let managed = root.appendingPathComponent("Library/com.apple.UserManagedAssets.test", isDirectory: true)
        try FileManager.default.createDirectory(at: managed, withIntermediateDirectories: true)
        for filename in ["The%20Quiet%20Earth_123.movpkg", "One%2FTwo%5CThree_123.movpkg", "100%25_123.movpkg"] {
            let package = managed.appendingPathComponent(filename, isDirectory: true)
            let relative = try HLSPackageLocation.relative(package, root: root)
            XCTAssertEqual(relative, "Library/com.apple.UserManagedAssets.test/" + filename)
            XCTAssertEqual(try HLSPackageLocation.resolve(relative, root: root).path, "/.nofollow" + (try physicalPath(managed)) + "/" + filename,
                           "The native callback precedes package creation, and title escapes must not become path separators.")
            try FileManager.default.createDirectory(at: package, withIntermediateDirectories: false)
            XCTAssertEqual(try HLSPackageLocation.resolve(relative, root: root).path, "/.nofollow" + (try physicalPath(package)))
        }
        let outside = root.appendingPathComponent("Library/Preferences/other.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let linkedPackage = managed.appendingPathComponent("Linked%20Title.movpkg", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: linkedPackage, withDestinationURL: outside)
        XCTAssertThrowsError(try HLSPackageLocation.resolve("Library/com.apple.UserManagedAssets.test/Linked%20Title.movpkg", root: root))
        XCTAssertThrowsError(try HLSPackageLocation.relative(linkedPackage, root: root))
        XCTAssertThrowsError(try HLSPackageLocation.resolve("Library/com.apple.UserManagedAssets.test/%2e%2e/video.movpkg", root: root))
    }

    func testNativeNoFollowCallbackRoundTripsExistingPackageWithoutOpeningOtherContainers() throws {
        let root = temporaryDirectory()
        let sibling = URL(fileURLWithPath: root.path + "-other", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: sibling) }
        let relative = "Library/com.apple.UserManagedAssets.test/The%20Quiet%20Earth_6910A6A1CC6411D3.movpkg"
        let package = root.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let content = Data("native package reference".utf8)
        try content.write(to: package.appendingPathComponent("offline.data"))
        let callback = URL(fileURLWithPath: "/.nofollow" + (try physicalPath(package)), isDirectory: true)
        let saved = try HLSPackageLocation.relative(callback, root: root)
        XCTAssertEqual(saved, relative)
        let restored = try HLSPackageLocation.resolve(saved, root: root)
        XCTAssertEqual(restored.path, callback.path)
        XCTAssertEqual(try Data(contentsOf: restored.appendingPathComponent("offline.data")), content)
        let otherPackage = sibling.appendingPathComponent(relative, isDirectory: true)
        try FileManager.default.createDirectory(at: otherPackage, withIntermediateDirectories: true)
        for invalid in ["/.nofollow" + otherPackage.path, "/.nofollow/.nofollow" + package.path,
                        "/.nofollow" + root.appendingPathComponent("Library/Preferences/video.movpkg").path] {
            XCTAssertThrowsError(try HLSPackageLocation.relative(URL(fileURLWithPath: invalid), root: root), invalid)
        }
        let outside = root.appendingPathComponent("Library/Preferences/other.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("outside package".utf8).write(to: outside.appendingPathComponent("offline.data"))
        let link = package.deletingLastPathComponent().appendingPathComponent("Escape.movpkg")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertThrowsError(try HLSPackageLocation.relative(URL(fileURLWithPath: "/.nofollow" + link.path), root: root))
        try FileManager.default.removeItem(at: package)
        try FileManager.default.createSymbolicLink(at: package, withDestinationURL: outside)
        XCTAssertThrowsError(try Data(contentsOf: restored.appendingPathComponent("offline.data")),
                             "A symlink introduced after validation must not retarget the protected package URL.")
    }

    func testPackageRemovalJournalPreservesUncommittedRemovalAndFinishesCommittedRemoval() throws {
        let directory = temporaryDirectory()
        let managed = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/com.apple.UserManagedAssets.reel-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: managed) }
        let package = managed.appendingPathComponent("video.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("offline test data".utf8).write(to: package.appendingPathComponent("segment.ts"))
        let relative = try HLSPackageLocation.relative(package)
        let downloads = Downloads(directory: directory)
        let entry = DownloadedItem(id: UUID(), accountID: "https://example.com|user", item: video(), filename: UUID().uuidString + ".movpkg", bytes: 17, packagePath: relative)
        let library = directory.appendingPathComponent("library.json")
        try JSONEncoder().encode([entry]).write(to: library)
        downloads.recoverStorage()
        XCTAssertEqual(downloads.url(entry).path, "/.nofollow" + (try physicalPath(package)))
        let journal = directory.appendingPathComponent("hls-removals.json")
        try JSONEncoder().encode([relative]).write(to: journal)
        downloads.recoverStorage()
        XCTAssertEqual(downloads.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path), "A removal that never committed must preserve the playable package.")
        try JSONEncoder().encode([relative]).write(to: journal)
        try JSONEncoder().encode([DownloadedItem]()).write(to: library)
        downloads.recoverStorage()
        XCTAssertTrue(downloads.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path), "A committed removal must finish deleting its original system location.")
        XCTAssertEqual(try JSONDecoder().decode([String].self, from: Data(contentsOf: journal)), [])
    }

    func testFailedPackageManifestCommitLeavesPackagePlayable() throws {
        let directory = temporaryDirectory()
        let managed = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/com.apple.UserManagedAssets.reel-test-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory); try? FileManager.default.removeItem(at: managed) }
        let package = managed.appendingPathComponent("video.movpkg", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        let entry = DownloadedItem(id: UUID(), accountID: "https://example.com|user", item: video(), filename: UUID().uuidString + ".movpkg", bytes: 17,
                                   packagePath: try HLSPackageLocation.relative(package))
        let downloads = Downloads(directory: directory)
        let library = directory.appendingPathComponent("library.json")
        let data = try JSONEncoder().encode([entry])
        try data.write(to: library)
        downloads.recoverStorage()
        try FileManager.default.removeItem(at: library)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: false)
        XCTAssertThrowsError(try downloads.remove(entry))
        XCTAssertEqual(downloads.items.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        try FileManager.default.removeItem(at: library)
        try data.write(to: library)
        downloads.recoverStorage()
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
        try downloads.remove(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.path))
    }

    func testOriginalRequestIsDurableBeforeTransferAndCancellationClearsIt() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-slowdownload", userID: "slowdownload", deviceID: "offline-journal-tests")
        let account = Account(server: api.server, token: "fixture-slowdownload", userID: "slowdownload", name: "Slow", serverName: "Test")
        let downloads = Downloads(directory: directory)
        downloads.download(video(), account: account, api: api)
        let journal = directory.appendingPathComponent("original-tasks.json")
        let content = try String(contentsOf: journal, encoding: .utf8)
        XCTAssertTrue(content.contains("movie-1"))
        XCTAssertFalse(content.contains("fixture-slowdownload"))
        XCTAssertFalse(content.contains("source-secret"))
        let recovered = Downloads(directory: directory)
        let key = Downloads.key(account: account, item: video())
        XCTAssertNotNil(recovered.errors[key])
        XCTAssertTrue(Downloads.compatible(try XCTUnwrap(recovered.requested[key])))
        downloads.cancel(key)
        await downloads.waitForDownloads()
        XCTAssertNil(Downloads(directory: directory).requested[key])
        XCTAssertTrue(downloads.items.isEmpty)
    }

    func testCorruptLibraryBlocksNewTransfersAndDeletionUntilRecoverySucceeds() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = directory.appendingPathComponent("library.json")
        let corrupted = Data("{damaged manifest".utf8)
        try corrupted.write(to: library)
        let filename = UUID().uuidString + ".mp4"
        let media = directory.appendingPathComponent(filename)
        let original = Data("preserve this original".utf8)
        try original.write(to: media)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-storage", userID: "storage", deviceID: "storage-gate-tests")
        let account = Account(server: api.server, token: "fixture-storage", userID: "storage", name: "User", serverName: "Test")
        let existing = DownloadedItem(id: UUID(), accountID: account.id, item: video(), filename: filename, bytes: Int64(original.count))
        let downloads = Downloads(directory: directory)
        XCTAssertFalse(downloads.storageReady)
        downloads.download(video(), account: account, api: api)
        downloads.download(video(), account: account, api: api, optimized: true)
        XCTAssertThrowsError(try downloads.remove(existing))
        downloads.removeAccount(account.id)
        await downloads.waitForDownloads()
        XCTAssertTrue(downloads.active.isEmpty)
        XCTAssertEqual(try Data(contentsOf: library), corrupted)
        XCTAssertEqual(try Data(contentsOf: media), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("original-tasks.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("hls-tasks.json").path))
        XCTAssertFalse(Downloads(directory: directory).storageReady)
        XCTAssertEqual(try Data(contentsOf: media), original)
        try JSONEncoder().encode([existing]).write(to: library)
        downloads.recoverStorage()
        XCTAssertTrue(downloads.storageReady)
        XCTAssertNil(downloads.errors["storage"])
        XCTAssertEqual(downloads.saved(account: account, item: video())?.id, existing.id)
        try downloads.remove(existing)
        XCTAssertFalse(FileManager.default.fileExists(atPath: media.path))
    }

    func testCorruptRequestJournalPreventsRecoveryGarbageCollectionAndOverwrite() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = directory.appendingPathComponent("library.json")
        let libraryData = try JSONEncoder().encode([DownloadedItem]())
        try libraryData.write(to: library)
        let journal = directory.appendingPathComponent("original-tasks.json")
        let corrupted = Data("[broken requests".utf8)
        try corrupted.write(to: journal)
        let unreferenced = directory.appendingPathComponent(UUID().uuidString + ".mp4")
        let media = Data("unclassified while recovery is blocked".utf8)
        try media.write(to: unreferenced)
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-journal", userID: "journal", deviceID: "journal-gate-tests")
        let account = Account(server: api.server, token: "fixture-journal", userID: "journal", name: "User", serverName: "Test")
        let downloads = Downloads(directory: directory)
        XCTAssertFalse(downloads.storageReady)
        downloads.download(video(), account: account, api: api)
        XCTAssertEqual(try Data(contentsOf: journal), corrupted)
        XCTAssertEqual(try Data(contentsOf: library), libraryData)
        XCTAssertEqual(try Data(contentsOf: unreferenced), media)
        try Data("[]".utf8).write(to: journal)
        downloads.recoverStorage()
        XCTAssertTrue(downloads.storageReady)
        XCTAssertFalse(FileManager.default.fileExists(atPath: unreferenced.path))
    }

    func testAccountCleanupWaitsForEncoderReceiptBeforeLogoutWithoutHistory() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let user = "download-cleanup-" + UUID().uuidString
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-" + user, userID: user, deviceID: "cleanup-flush-tests", historyEnabled: false)
        let account = Account(server: api.server, token: "fixture-" + user, userID: user, name: "User", serverName: "Test")
        var record = HLSDownloadRecord(account: account, api: api, item: video())
        record.stage = .failed; record.playSessionID = "unfinished-offline-encoder"; record.needsCleanup = true
        try JSONEncoder().encode([record]).write(to: directory.appendingPathComponent("hls-tasks.json"))
        let downloads = Downloads(directory: directory)
        let cleaned = await downloads.flushCleanup(accountID: account.id, api: api)
        XCTAssertTrue(cleaned)
        let state = try await api.send(api.request("qa/state"))
        let json = try JSONSerialization.jsonObject(with: state) as! [String: Any]
        let reports = json["reports"] as! [[String: Any]]
        let mine = reports.filter { ($0["user"] as? String) == user }
        XCTAssertTrue(mine.contains { ($0["path"] as? String) == "/Videos/ActiveEncodings" }, "Flush must await a cleanup response before its caller revokes the token.")
        XCTAssertFalse(mine.contains { ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true })
        try await api.post("Sessions/Logout")
        XCTAssertTrue(try JSONDecoder().decode([HLSDownloadRecord].self, from: Data(contentsOf: directory.appendingPathComponent("hls-tasks.json"))).isEmpty)
    }

    func testLegacyOriginalManifestDecodesWithoutPackageLocation() throws {
        let legacy = Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"accountID\":\"account\",\"item\":{\"Id\":\"film\",\"Name\":\"Film\"},\"filename\":\"film.mp4\",\"bytes\":8}]".utf8)
        let saved = try JSONDecoder().decode([DownloadedItem].self, from: legacy)
        XCTAssertNil(saved.first?.packagePath)
        XCTAssertEqual(saved.first?.isOptimized, false)
    }

    func testOptimizedDownloadHonorsPermissionWithoutHistoryWrites() async throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = JellyfinAPI(server: URL(string: "http://127.0.0.1:18766")!, token: "fixture-nodownload", userID: "nodownload", deviceID: "optimized-permission-tests", historyEnabled: false)
        let account = Account(server: api.server, token: "fixture-nodownload", userID: "nodownload", name: "Denied", serverName: "Test")
        func historyCount(_ data: Data) throws -> Int {
            let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let reports = json["reports"] as! [[String: Any]]
            return reports.filter { ($0["user"] as? String) == "nodownload" && ($0["path"] as? String)?.hasPrefix("/Sessions/Playing") == true }.count
        }
        let before = try historyCount(await api.send(api.request("qa/state")))
        let downloads = Downloads(directory: directory)
        downloads.download(video(), account: account, api: api, optimized: true)
        await downloads.waitForDownloads()
        let key = Downloads.key(account: account, item: video())
        XCTAssertEqual(downloads.errors[key], HLSDownloadError.permission.localizedDescription)
        XCTAssertFalse(downloads.active.contains(key))
        XCTAssertTrue(downloads.optimized.contains(key))
        XCTAssertNotNil(downloads.requested[key])
        XCTAssertTrue(downloads.items.isEmpty)
        let state = try await api.send(api.request("qa/state"))
        XCTAssertEqual(try historyCount(state), before)
    }

    func testSimulatorPreviewCannotStartAnyDownload() throws {
        #if targetEnvironment(simulator)
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let api = JellyfinAPI(server: URL(string: "https://real-server.invalid")!, token: "no-network", userID: "user", deviceID: "preview")
        let account = Account(server: api.server, token: "no-network", userID: "user", name: "User", serverName: "Server")
        let downloads = Downloads(directory: directory)
        downloads.download(video(), account: account, api: api)
        downloads.download(video(), account: account, api: api, optimized: true)
        let key = Downloads.key(account: account, item: video())
        XCTAssertTrue(downloads.active.isEmpty)
        XCTAssertEqual(downloads.errors[key], ReelError.previewProtected.localizedDescription)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("original-tasks.json").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("hls-tasks.json").path))
        #endif
    }
}
