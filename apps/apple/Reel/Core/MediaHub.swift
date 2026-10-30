import AVKit
import Foundation
import MediaPlayer
import Observation
import PDFKit

struct HubItem: Codable, Hashable, Identifiable, Sendable {
    let Id: String
    let Name: String
    var `Type`: String?
    var Overview: String?
    var Container: String?
    var IsFolder: Bool?
    var Artists: [String]?
    var Album: String?
    var AlbumId: String?
    var AlbumArtist: String?
    var IndexNumber: Int?
    var ParentIndexNumber: Int?
    var RunTimeTicks: Int64?
    var ImageTags: [String: String]?
    var UserData: UserData?
    var MediaSources: [MediaSource]?
    var Chapters: [Chapter]?
    var HasLyrics: Bool?
    var id: String { Id }
    var isAudio: Bool { Type == "Audio" || Type == "AudioBook" }
    var isFolder: Bool { IsFolder == true || ["MusicAlbum", "MusicArtist", "PhotoAlbum", "Folder", "Playlist"].contains(Type ?? "") }
    var subtitle: String { Artists?.joined(separator: ", ") ?? AlbumArtist ?? (Type == "Book" ? "Book" : Type == "AudioBook" ? "Audiobook" : "") }
    var duration: Double { max(0, Double(RunTimeTicks ?? 0) / ticksPerSecond) }
    var artworkItem: MediaItem { MediaItem(Id: Id, Name: Name, Type: Type, Overview: Overview, RunTimeTicks: RunTimeTicks, ImageTags: ImageTags, UserData: UserData, MediaSources: MediaSources) }
}

struct HubPage: Decodable, Sendable {
    var Items: [HubItem]
    var TotalRecordCount: Int?
}

struct HubLyrics: Decodable, Sendable {
    struct Line: Decodable, Sendable { let Text: String; var Start: Int64? }
    let Lyrics: [Line]
}

enum HubSection: String, CaseIterable, Identifiable, Sendable {
    case albums = "Albums", artists = "Artists", tracks = "Songs", playlists = "Music playlists", photoAlbums = "Photo albums", photos = "Photos", books = "Books", audiobooks = "Audiobooks"
    var id: String { rawValue }
    var icon: String {
        switch self {
        case .albums: "square.stack"
        case .artists: "person.2"
        case .tracks: "music.note"
        case .playlists: "music.note.list"
        case .photoAlbums: "rectangle.stack"
        case .photos: "photo"
        case .books: "books.vertical"
        case .audiobooks: "headphones"
        }
    }
    var itemTypes: String {
        switch self {
        case .albums: "MusicAlbum"
        case .artists: "MusicArtist"
        case .tracks: "Audio"
        case .playlists: "Playlist"
        case .photoAlbums: "PhotoAlbum"
        case .photos: "Photo"
        case .books: "Book"
        case .audiobooks: "AudioBook"
        }
    }
}

enum HubAPI {
    static func browse(api: JellyfinAPI, section: HubSection, parent: HubItem? = nil, search: String = "", start: Int = 0, limit: Int = 60) async throws -> HubPage {
        let query = query(section: section, parent: parent, search: search, start: start, limit: limit)
        let endpoint = parent?.Type == "Playlist" ? "Playlists/\(parent!.id)/Items" : section == .artists && parent == nil ? "Artists" : "Items"
        return try await api.get(endpoint, query: api.userQuery.merging(query) { _, new in new })
    }

    static func query(section: HubSection, parent: HubItem?, search: String, start: Int, limit: Int) -> [String: String] {
        var query = ["includeItemTypes": section.itemTypes, "recursive": "true", "startIndex": String(max(0, start)), "limit": String(max(1, min(200, limit))), "sortBy": "SortName", "sortOrder": "Ascending", "fields": "Overview,MediaSources,ParentId,Chapters", "enableTotalRecordCount": "true"]
        if section == .playlists { query["mediaTypes"] = "Audio" }
        if let parent {
            if parent.Type == "MusicArtist" {
                query["artistIds"] = parent.id
                query["includeItemTypes"] = "MusicAlbum"
            } else if parent.Type == "Playlist" {
                return ["startIndex": String(max(0, start)), "limit": String(max(1, min(200, limit))), "fields": "Overview,MediaSources,Chapters"]
            } else {
                query["parentId"] = parent.id
                query["includeItemTypes"] = parent.Type == "MusicAlbum" ? "Audio" : parent.Type == "AudioBook" || section == .audiobooks ? "Audio,AudioBook,Folder" : "Photo,PhotoAlbum,Folder"
                query["recursive"] = "false"
                if parent.Type == "MusicAlbum" || parent.Type == "AudioBook" || section == .audiobooks { query["sortBy"] = "ParentIndexNumber,IndexNumber,SortName" }
            }
        }
        let trimmed = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { query["searchTerm"] = trimmed }
        return query
    }

    static func allAudio(api: JellyfinAPI, section: HubSection, parent: HubItem?, search: String = "") async throws -> [HubItem] {
        try await gatherAudio(parent: parent) { parent, start in
            try await browse(api: api, section: section, parent: parent, search: search, start: start, limit: 200)
        }
    }

    static func gatherAudio(parent: HubItem?, ancestors: Set<String> = [], page: @escaping @Sendable (HubItem?, Int) async throws -> HubPage) async throws -> [HubItem] {
        let ancestors = parent.map { ancestors.union([$0.id]) } ?? ancestors
        var items: [HubItem] = []
        var start = 0
        while true {
            try Task.checkCancellation()
            let result = try await page(parent, start)
            for item in result.Items {
                if item.isFolder {
                    guard !ancestors.contains(item.id), ancestors.count < 128 else { throw ReelError.invalidResponse }
                    items += try await gatherAudio(parent: item, ancestors: ancestors, page: page)
                } else if item.isAudio { items.append(item) }
            }
            start += result.Items.count
            if result.Items.isEmpty || start >= (result.TotalRecordCount ?? Int.max) || (result.TotalRecordCount == nil && result.Items.count < 200) { return items }
        }
    }

    static func audio(api: JellyfinAPI, item: HubItem) async throws -> (URL, MediaSource, String, String) {
        let profile: [String: any Sendable] = [
            "Name": "Reel Audio", "MaxStreamingBitrate": 12_000_000,
            "DirectPlayProfiles": [["Container": "mp3,aac,m4a,m4b,mp4,flac,wav", "Type": "Audio", "AudioCodec": "mp3,aac,alac,flac,pcm_s16le,pcm_s24le"]],
            "TranscodingProfiles": [["Container": "mp3", "Type": "Audio", "AudioCodec": "mp3", "Protocol": "http", "Context": "Streaming"]]
        ]
        var body: [String: any Sendable] = ["UserId": api.userID ?? "", "StartTimeTicks": 0, "MaxStreamingBitrate": 12_000_000, "EnableDirectPlay": true, "EnableDirectStream": false, "EnableTranscoding": true, "DeviceProfile": profile]
        body["MediaSourceId"] = item.MediaSources?.first?.Id
        let data = try JSONSerialization.data(withJSONObject: body)
        let info: PlaybackInfo = try await api.decode(api.request("Items/\(item.id)/PlaybackInfo", method: "POST", body: data))
        guard let source = info.MediaSources.first, info.ErrorCode == nil else { throw ReelError.noStream }
        let playSession = info.PlaySessionId ?? UUID().uuidString
        if source.SupportsDirectPlay == true {
            let url = api.url("Audio/\(item.id)/stream", query: ["static": "true", "mediaSourceId": source.Id, "playSessionId": playSession, "deviceId": api.deviceID, "ApiKey": api.token ?? ""])
            return (url, source, playSession, "DirectPlay")
        }
        let stream = try api.streamURL(item: item.artworkItem, source: source, sessionID: playSession)
        return (stream.url, source, playSession, "Transcode")
    }
}

struct HubFile: Codable, Identifiable, Sendable {
    let id: UUID
    let accountID: String
    let item: HubItem
    let filename: String
    let bytes: Int64
    var nativePlayable: Bool?
    var canPlay: Bool { item.isAudio && nativePlayable != false }
}

struct HubQueue: Codable, Sendable {
    var accountID: String
    var items: [HubItem]
    var index: Int
}

enum HubStorageError: LocalizedError {
    case unavailable
    var errorDescription: String? { "Saved media storage needs recovery. Retry storage recovery in Saved music & books before changing saved files." }
}

@MainActor @Observable final class MediaHub {
    private(set) var queue: [HubItem] = []
    private(set) var index = 0
    private(set) var preparing = false
    private(set) var playing = false
    private(set) var position: Double = 0
    private(set) var duration: Double = 0
    private(set) var error: String?
    private(set) var syncError: String?
    private(set) var files: [HubFile] = []
    private(set) var saving: Set<String> = []
    private(set) var requestedFiles: [String: HubItem] = [:]
    private(set) var fileErrors: [String: String] = [:]
    var repeatQueue = false { didSet { defaults.set(repeatQueue, forKey: "hub-repeat") } }
    var onWillPlay: (() -> Void)?
    var speed: Float = 1 { didSet { player.defaultRate = speed; defaults.set(speed, forKey: "hub-speed"); if playing { player.rate = speed }; updateNowPlaying() } }
    var current: HubItem? { queue.indices.contains(index) ? queue[index] : nil }
    let player = AVPlayer()
    let directory: URL
    @ObservationIgnored private var api: JellyfinAPI?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var defaults: UserDefaults
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var prepareTask: Task<Void, Never>?
    @ObservationIgnored private var cleanupTail: Task<Void, Never>?
    @ObservationIgnored private var deadline: Task<Void, Never>?
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var rateObservation: NSKeyValueObservation?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var remoteTargets: [(MPRemoteCommand, Any)] = []
    @ObservationIgnored private var fileTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private let reporter = PlaybackReporter()
    @ObservationIgnored private var source: MediaSource?
    @ObservationIgnored private var playSessionID = ""
    @ObservationIgnored private var method = ""
    @ObservationIgnored private var started = false
    @ObservationIgnored private var initializing = false
    @ObservationIgnored private var playWhenReady = true
    @ObservationIgnored private var storageReady = false
    @ObservationIgnored private let initialSeek: @MainActor @Sendable (AVPlayer, Double) async -> Void
    @ObservationIgnored private let prepareAudio: @MainActor @Sendable (JellyfinAPI, HubItem) async throws -> (URL, MediaSource, String, String)
    @ObservationIgnored private var lastReport = Date.distantPast
    @ObservationIgnored private var gateway: PlaybackGateway?
    @ObservationIgnored private var localAudioURL: URL?
    private var manifest: URL { directory.appendingPathComponent("files.json") }

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("MediaHub", isDirectory: true), defaults: UserDefaults = .standard,
         initialSeek: @escaping @MainActor @Sendable (AVPlayer, Double) async -> Void = { player, seconds in _ = await player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600)) },
         prepareAudio: @escaping @MainActor @Sendable (JellyfinAPI, HubItem) async throws -> (URL, MediaSource, String, String) = { api, item in try await HubAPI.audio(api: api, item: item) }) {
        self.directory = directory
        self.defaults = defaults
        self.initialSeek = initialSeek
        self.prepareAudio = prepareAudio
        repeatQueue = defaults.bool(forKey: "hub-repeat")
        let savedSpeed = defaults.float(forKey: "hub-speed")
        if [Float(0.75), 1, 1.25, 1.5, 2].contains(savedSpeed) { speed = savedSpeed }
        player.defaultRate = speed
        reporter.onFailure = { [weak self] in self?.syncError = $0 }
        recoverStorage()
    }

    func recoverStorage() {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var location = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            let decoded = FileManager.default.fileExists(atPath: manifest.path)
                ? try JSONDecoder().decode([HubFile].self, from: Data(contentsOf: manifest)) : []
            let valid = decoded.filter { Self.validFilename($0.filename) }
            guard valid.count == decoded.count else { throw HubStorageError.unavailable }
            let referenced = Set(valid.map(\.filename))
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = file.lastPathComponent
                if name.hasSuffix(".removing") {
                    let originalName = String(name.dropLast(".removing".count))
                    guard Self.validFilename(originalName) else { continue }
                    let original = directory.appendingPathComponent(originalName)
                    if referenced.contains(originalName), !FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: file, to: original) }
                    else { try FileManager.default.removeItem(at: file) }
                } else if Self.validFilename(name), !referenced.contains(name) { try FileManager.default.removeItem(at: file) }
            }
            // Keep missing book entries reachable for reader recovery; audio retains its existing cleanup behavior.
            files = valid.filter { !$0.item.isAudio || FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.filename).path) }
            storageReady = true; fileErrors["storage"] = nil
            for file in files { let key = Self.fileKey(accountID: file.accountID, itemID: file.item.id); requestedFiles[key] = nil; fileErrors[key] = nil }
        } catch { storageReady = false; fileErrors["storage"] = "Saved media couldn’t be opened. Existing files have been preserved. Check device storage and retry recovery." }
    }

    nonisolated static func validFilename(_ filename: String) -> Bool {
        let parts = filename.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 2 && UUID(uuidString: String(parts[0])) != nil && !parts[1].isEmpty && parts[1].count <= 10 && parts[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }
    nonisolated static func fileKey(accountID: String, itemID: String) -> String { accountID + "|" + itemID }
    private func progressKey(_ item: HubItem) -> String { "hub-progress|" + (accountID ?? "") + "|" + item.id }
    func fileURL(_ file: HubFile) -> URL { directory.appendingPathComponent(file.filename) }
    func saved(_ item: HubItem, accountID: String) -> HubFile? { files.first { $0.accountID == accountID && $0.item.id == item.id } }

    func bind(account: Account, api: JellyfinAPI) {
        if accountID != account.id {
            stop()
            queue = []; index = 0
            accountID = account.id
            if let data = defaults.data(forKey: "hub-queue|" + account.id), let saved = try? JSONDecoder().decode(HubQueue.self, from: data), saved.accountID == account.id, saved.items.indices.contains(saved.index) {
                queue = saved.items; index = saved.index
                position = current.map { defaults.double(forKey: progressKey($0)) } ?? 0
                duration = current?.duration ?? 0
            }
        }
        updatePrivacy(api: api)
    }

    func updatePrivacy(api: JellyfinAPI) {
        guard accountID == api.server.absoluteString + "|" + (api.userID ?? "") else { return }
        PlaybackReporter.updatePrivacy(api: api)
        self.api = api
        player.allowsExternalPlayback = !api.isSimulatorPreview && api.gatewayHeaders.isEmpty
    }

    func play(_ items: [HubItem], at index: Int = 0, account: Account, api: JellyfinAPI, shuffled: Bool = false) {
        guard items.indices.contains(index), items[index].isAudio else { return }
        bind(account: account, api: api)
        stopCurrent()
        queue = shuffled ? items.filter(\.isAudio).shuffled() : items.filter(\.isAudio)
        self.index = shuffled ? 0 : items.prefix(index).filter(\.isAudio).count
        persistQueue()
        startCurrent()
    }

    func playSaved(_ file: HubFile, account: Account, api: JellyfinAPI) {
        guard file.accountID == account.id, file.canPlay else { return }
        bind(account: account, api: api)
        stopCurrent()
        queue = [file.item]; index = 0; localAudioURL = fileURL(file)
        persistQueue(); startCurrent()
    }

    func resume() {
        guard current != nil else { return }
        if preparing { playWhenReady = true; return }
        if player.currentItem == nil { startCurrent() }
        else { player.play(); playing = true; report("Sessions/Playing/Progress"); updateNowPlaying() }
    }
    func pause() { playWhenReady = false; player.pause(); playing = false; saveProgress(); report("Sessions/Playing/Progress"); updateNowPlaying() }
    func toggle() { if playing { pause() } else { resume() } }
    func next() {
        guard !queue.isEmpty else { return }
        let target = index + 1
        stopCurrent()
        if target < queue.count { index = target; persistQueue(); startCurrent() }
        else if repeatQueue { index = 0; persistQueue(); startCurrent() }
    }
    func previous() {
        if position > 3 { seek(0); return }
        guard index > 0 else { seek(0); return }
        stopCurrent(); index -= 1; persistQueue(); startCurrent()
    }
    func seek(_ seconds: Double) {
        guard seconds.isFinite, started, !preparing else { return }
        let target = max(0, min(duration > 0 ? duration : seconds, seconds))
        let run = generation
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] finished in
            Task { @MainActor in if let self, finished, self.generation == run { self.position = target; self.saveProgress(); self.report("Sessions/Playing/Progress"); self.updateNowPlaying() } }
        }
    }
    func stop() {
        stopCurrent()
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets = []
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
    func clearAccount() { stop(); queue = []; accountID = nil; api = nil; position = 0; duration = 0 }
    func checkpoint() { saveProgress(); report("Sessions/Playing/Progress"); updateNowPlaying() }
    func flushReports() async { await cleanupTail?.value; await reporter.flush() }
    func waitForFiles() async { for task in Array(fileTasks.values) { await task.value } }

    private func startCurrent() {
        guard let item = current, let api else { return }
        onWillPlay?()
        cancelPreparation(); deadline?.cancel()
        generation = UUID(); let run = generation
        initializing = false; playWhenReady = true
        preparing = true; error = nil; playing = false
        position = max(0, defaults.double(forKey: progressKey(item)))
        if position == 0, item.Type == "AudioBook" { position = max(0, Double(item.UserData?.PlaybackPositionTicks ?? 0) / ticksPerSecond) }
        duration = item.duration
        let resume = position
        let localURL = localAudioURL ?? files.first(where: { $0.accountID == accountID && $0.item.id == item.id && $0.canPlay }).map(fileURL)
        registerRemoteControls()
        deadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == run, self.preparing else { return }
            self.stopCurrent(); self.preparing = false; self.error = "Audio couldn’t start. Check the connection and try Play again."
        }
        prepareTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await PlaybackAudio.activate(mode: .default)
                try Task.checkCancellation()
                let url: URL
                if let localURL { url = localURL; method = "Offline" }
                else {
                    let stream = try await prepareAudio(api, item)
                    if Task.isCancelled || generation != run {
                        if stream.3 == "Transcode" { reporter.enqueue(api: api, endpoint: "", body: ["PlaySessionId": stream.2, "CleanupEncoder": true], cleanup: true) }
                        throw CancellationError()
                    }
                    url = stream.0; source = stream.1; playSessionID = stream.2; method = stream.3
                }
                guard generation == run else { return }
                var playbackURL = url
                if localURL == nil, !api.gatewayHeaders.isEmpty {
                    let lease = try await PlaybackGateway.create(api: api, sourceURL: url)
                    guard generation == run, !Task.isCancelled else { lease.close(); throw CancellationError() }
                    gateway = lease
                    playbackURL = lease.localURL
                }
                let avItem = AVPlayerItem(url: playbackURL)
                observation = avItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                    let status = observed.status
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        if status == .readyToPlay, !self.started, !self.initializing {
                            self.initializing = true
                            if resume > 0 { await self.initialSeek(self.player, resume) }
                            guard self.generation == run else { return }
                            self.started = true; self.initializing = false
                            self.deadline?.cancel(); self.deadline = nil; self.preparing = false
                            let actual = self.player.currentItem?.duration.seconds ?? .nan
                            if actual.isFinite, actual > 0 { self.duration = actual }
                            if self.playWhenReady { self.player.play(); self.playing = true }
                            else { self.player.pause(); self.playing = false }
                            self.report("Sessions/Playing"); self.updateNowPlaying()
                        } else if status == .failed {
                            self.stopCurrent(); self.preparing = false
                            self.error = "This audio file couldn’t be played. Check Jellyfin’s audio transcoding settings or try a compatible original file."
                        }
                    }
                }
                rateObservation = player.observe(\.rate, options: [.new]) { [weak self] observed, _ in
                    let isPlaying = observed.rate > 0
                    Task { @MainActor in guard let self, self.generation == run else { return }; self.playing = isPlaying; self.updateNowPlaying() }
                }
                timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 2, preferredTimescale: 600), queue: .main) { [weak self] time in
                    let seconds = time.seconds
                    Task { @MainActor in
                        guard let self, self.generation == run, seconds.isFinite, self.started else { return }
                        self.position = max(0, seconds); self.saveProgress(); self.updateNowPlaying()
                        if Date().timeIntervalSince(self.lastReport) >= 10 { self.report("Sessions/Playing/Progress") }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: avItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == run else { return }
                        self.position = self.duration
                        self.report("Sessions/Playing/Stopped", cleanup: self.method == "Transcode")
                        self.started = false
                        self.defaults.removeObject(forKey: self.progressKey(item))
                        self.next()
                    }
                }
                player.replaceCurrentItem(with: avItem)
            } catch is CancellationError { }
            catch {
                guard generation == run else { return }
                let message = error.localizedDescription
                stopCurrent()
                self.error = message
            }
        }
    }

    private func stopCurrent() {
        gateway?.close(); gateway = nil
        saveProgress()
        if started { report("Sessions/Playing/Stopped", cleanup: method == "Transcode") }
        else if method == "Transcode", let api { reporter.enqueue(api: api, endpoint: "", body: ["PlaySessionId": playSessionID, "CleanupEncoder": true], cleanup: true) }
        started = false; initializing = false; generation = UUID()
        cancelPreparation(); deadline?.cancel(); deadline = nil
        observation?.invalidate(); observation = nil; rateObservation?.invalidate(); rateObservation = nil
        if let timeObserver { player.removeTimeObserver(timeObserver); self.timeObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
        player.pause(); player.replaceCurrentItem(with: nil)
        preparing = false; playing = false; source = nil; localAudioURL = nil; method = ""
        updateNowPlaying()
        PlaybackAudio.deactivate()
    }
    private func cancelPreparation() {
        guard let task = prepareTask else { return }
        prepareTask = nil; task.cancel()
        let previous = cleanupTail
        cleanupTail = Task { await previous?.value; await task.value }
    }
    private func saveProgress() {
        guard let item = current, started, !preparing, player.currentTime().seconds.isFinite else { return }
        position = max(0, player.currentTime().seconds)
        defaults.set(position, forKey: progressKey(item))
    }
    private func persistQueue() {
        guard let accountID else { return }
        let snapshots = queue.map { item in var snapshot = item; snapshot.MediaSources = nil; return snapshot }
        do { defaults.set(try JSONEncoder().encode(HubQueue(accountID: accountID, items: snapshots, index: index)), forKey: "hub-queue|" + accountID) }
        catch { self.error = "The queue couldn’t be saved on this device." }
    }
    private func report(_ endpoint: String, cleanup: Bool = false) {
        guard started, !preparing, method != "Offline", let api, let item = current, let source else { return }
        let seconds = player.currentTime().seconds
        reporter.enqueue(api: api, endpoint: endpoint, body: ["ItemId": item.id, "MediaSourceId": source.Id, "PlaySessionId": playSessionID, "PositionTicks": Int64(max(0, seconds.isFinite ? seconds : position) * ticksPerSecond), "IsPaused": !playing, "CanSeek": true, "PlayMethod": method, "CleanupEncoder": method == "Transcode"], cleanup: cleanup)
        lastReport = Date()
        if cleanup { self.source = nil }
    }
    private func updateNowPlaying() {
        guard let item = current else { return }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: item.Name, MPMediaItemPropertyArtist: item.subtitle, MPMediaItemPropertyAlbumTitle: item.Album ?? "", MPMediaItemPropertyPlaybackDuration: duration, MPNowPlayingInfoPropertyElapsedPlaybackTime: position, MPNowPlayingInfoPropertyPlaybackRate: playing ? speed : 0, MPNowPlayingInfoPropertyPlaybackQueueIndex: index, MPNowPlayingInfoPropertyPlaybackQueueCount: queue.count]
    }
    private func registerRemoteControls() {
        guard remoteTargets.isEmpty else { return }
        let commands = MPRemoteCommandCenter.shared()
        remoteTargets.append((commands.playCommand, commands.playCommand.addTarget { [weak self] _ in Task { @MainActor in self?.resume() }; return .success }))
        remoteTargets.append((commands.pauseCommand, commands.pauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.pause() }; return .success }))
        remoteTargets.append((commands.togglePlayPauseCommand, commands.togglePlayPauseCommand.addTarget { [weak self] _ in Task { @MainActor in self?.toggle() }; return .success }))
        remoteTargets.append((commands.nextTrackCommand, commands.nextTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.next() }; return .success }))
        remoteTargets.append((commands.previousTrackCommand, commands.previousTrackCommand.addTarget { [weak self] _ in Task { @MainActor in self?.previous() }; return .success }))
        remoteTargets.append((commands.changePlaybackPositionCommand, commands.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let position = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime else { return .commandFailed }
            Task { @MainActor in self?.seek(position) }; return .success
        }))
    }

    func save(_ item: HubItem, account: Account, api: JellyfinAPI) {
        let key = Self.fileKey(accountID: account.id, itemID: item.id)
        guard !saving.contains(key), saved(item, accountID: account.id) == nil else { return }
        requestedFiles[key] = item
        guard !api.isSimulatorPreview else { fileErrors[key] = ReelError.previewProtected.localizedDescription; return }
        guard storageReady else { fileErrors[key] = HubStorageError.unavailable.localizedDescription; return }
        guard account.server == api.server, account.userID == api.userID, account.token == api.token else { fileErrors[key] = ReelError.unauthorized.localizedDescription; return }
        saving.insert(key); fileErrors[key] = nil
        let directory = directory
        fileTasks[key] = Task { [weak self] in
            guard let self else { return }
            defer { saving.remove(key); fileTasks[key] = nil }
            var destination: URL?
            do {
                var request = api.request("Items/\(item.id)/Download")
                request.timeoutInterval = 600
                let (temporary, response) = try await JellyfinAPI.transport.download(for: request, delegate: api.redirects)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url.map({ JellyfinAPI.sameOrigin(api.server, $0) }) == true else { throw ReelError.unavailable }
                let suggested = URL(fileURLWithPath: response.suggestedFilename ?? "").pathExtension.lowercased()
                let container = (item.Container ?? item.MediaSources?.first?.Container ?? suggested).lowercased()
                let allowed = ["pdf", "epub", "txt", "cbz", "cbr", "mobi", "azw", "azw3", "mp3", "m4b", "m4a", "aac", "flac", "wav", "ogg", "opus"]
                guard let ext = allowed.first(where: { $0 == container }) else { throw ReelError.invalidResponse }
                let id = UUID(); let filename = id.uuidString + "." + ext
                let target = directory.appendingPathComponent(filename); destination = target
                let bytes = try await Task.detached(priority: .utility) {
                    try FileManager.default.copyItem(at: temporary, to: target)
                    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                    return Int64((try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0)
                }.value
                try Task.checkCancellation()
                guard bytes > 0 else { throw ReelError.invalidResponse }
                if ext == "pdf" {
                    let valid = await Task.detached(priority: .utility) { PDFDocument(url: target).map { $0.pageCount > 0 } ?? false }.value
                    guard valid else { throw ReelError.invalidResponse }
                }
                let nativePlayable: Bool?
                if item.isAudio { nativePlayable = try await AVURLAsset(url: target).load(.isPlayable) }
                else { nativePlayable = nil }
                try Task.checkCancellation()
                var snapshot = item; snapshot.MediaSources = nil
                let file = HubFile(id: id, accountID: account.id, item: snapshot, filename: filename, bytes: bytes, nativePlayable: nativePlayable)
                let updated = files + [file]
                try persistFiles(updated); files = updated; destination = nil; requestedFiles[key] = nil
            } catch is CancellationError { requestedFiles[key] = nil; fileErrors[key] = nil }
            catch let error as URLError where error.code == .cancelled { requestedFiles[key] = nil; fileErrors[key] = nil }
            catch {
                if Task.isCancelled { requestedFiles[key] = nil; fileErrors[key] = nil }
                else { fileErrors[key] = "The original couldn’t be saved. Check available storage, your download permission and the file format, then try again." }
            }
            if let destination { try? FileManager.default.removeItem(at: destination) }
        }
    }
    func cancelSave(_ key: String) { fileTasks[key]?.cancel() }
    func dismissSave(_ key: String) { guard !saving.contains(key) else { return }; requestedFiles[key] = nil; fileErrors[key] = nil }
    func remove(_ file: HubFile) throws {
        guard storageReady else { throw HubStorageError.unavailable }
        let original = fileURL(file)
        let tombstone = directory.appendingPathComponent(file.filename + ".removing")
        let exists = FileManager.default.fileExists(atPath: original.path)
        if exists { try FileManager.default.moveItem(at: original, to: tombstone) }
        do {
            let updated = files.filter { $0.id != file.id }
            try persistFiles(updated); files = updated
            if exists { try? FileManager.default.removeItem(at: tombstone) }
            defaults.removeObject(forKey: "hub-page|" + file.filename)
        } catch {
            if exists { try? FileManager.default.moveItem(at: tombstone, to: original) }
            throw error
        }
    }
    func removeAccount(_ id: String) throws {
        for key in saving where key.hasPrefix(id + "|") { fileTasks[key]?.cancel() }
        for key in requestedFiles.keys where key.hasPrefix(id + "|") { requestedFiles[key] = nil; fileErrors[key] = nil }
        guard storageReady else { throw HubStorageError.unavailable }
        for file in files where file.accountID == id { try remove(file) }
        defaults.removeObject(forKey: "hub-queue|" + id)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("hub-progress|" + id + "|") { defaults.removeObject(forKey: key) }
        if accountID == id { clearAccount() }
    }
    private func persistFiles(_ files: [HubFile]) throws {
        guard storageReady else { throw HubStorageError.unavailable }
        try JSONEncoder().encode(files).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
