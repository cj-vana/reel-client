import Foundation
import Observation

struct DownloadedItem: Codable, Identifiable, Sendable {
    let id: UUID
    let accountID: String
    let item: MediaItem
    let filename: String
    let bytes: Int64
    var packagePath: String?
    var isOptimized: Bool { packagePath != nil }
}

private struct OriginalDownloadIntent: Codable {
    let accountID: String
    let item: MediaItem
    var key: String { accountID + "|" + item.id }
}

@MainActor @Observable final class Downloads {
    private(set) var items: [DownloadedItem] = []
    private(set) var active: Set<String> = []
    private(set) var requested: [String: MediaItem] = [:]
    private(set) var errors: [String: String] = [:]
    private(set) var progress: [String: Double] = [:]
    private(set) var optimized: Set<String> = []
    private(set) var storageReady = false
    @ObservationIgnored private var tasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var hls: HLSDownloads?
    @ObservationIgnored private var hlsOwners: [String: UUID] = [:]
    @ObservationIgnored private var originals: [String: OriginalDownloadIntent] = [:]
    let directory: URL
    private var manifest: URL { directory.appendingPathComponent("library.json") }
    private var removals: URL { directory.appendingPathComponent("hls-removals.json") }
    private var originalManifest: URL { directory.appendingPathComponent("original-tasks.json") }

    init(directory: URL = URL.applicationSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)) {
        self.directory = directory
        recoverStorage()
        if directory.standardizedFileURL == HLSDownloads.defaultDirectory.standardizedFileURL
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent("hls-tasks.json").path) {
            _ = hlsEngine()
        }
    }
    func recoverStorage() {
        storageReady = false
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var location = directory
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try location.setResourceValues(values)
            let decoded = FileManager.default.fileExists(atPath: manifest.path)
                ? try JSONDecoder().decode([DownloadedItem].self, from: Data(contentsOf: manifest)) : []
            let valid = decoded.filter {
                !$0.filename.contains("/") && !$0.filename.hasPrefix(".")
                    && ($0.packagePath == nil || (try? HLSPackageLocation.resolve($0.packagePath!)) != nil)
            }
            guard valid.count == decoded.count, Set(valid.map(\.id)).count == valid.count,
                  Set(valid.map(\.filename)).count == valid.count else { throw HLSDownloadError.storage }
            let intents = FileManager.default.fileExists(atPath: originalManifest.path)
                ? try JSONDecoder().decode([OriginalDownloadIntent].self, from: Data(contentsOf: originalManifest)) : []
            guard Set(intents.map(\.key)).count == intents.count else { throw HLSDownloadError.storage }
            for path in try readPackageRemovals() { _ = try HLSPackageLocation.resolve(path) }
            // All authoritative files must be readable before any recovery can remove media.
            storageReady = true
            let referenced = Set(valid.map(\.filename))
            for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                if file.lastPathComponent.hasSuffix(".removing") {
                    let originalName = String(file.lastPathComponent.dropLast(".removing".count))
                    let original = directory.appendingPathComponent(originalName)
                    if referenced.contains(originalName), !FileManager.default.fileExists(atPath: original.path) { try FileManager.default.moveItem(at: file, to: original) }
                    else { try FileManager.default.removeItem(at: file) }
                } else if ["mp4", "m4v", "mov"].contains(file.pathExtension), UUID(uuidString: file.deletingPathExtension().lastPathComponent) != nil, !referenced.contains(file.lastPathComponent) {
                    try FileManager.default.removeItem(at: file)
                }
            }
            items = valid.filter { FileManager.default.fileExists(atPath: url($0).path) }
            if !intents.isEmpty {
                for intent in intents
                    where !items.contains(where: { $0.accountID == intent.accountID && $0.item.id == intent.item.id }) {
                    originals[intent.key] = intent
                    requested[intent.key] = intent.item
                    errors[intent.key] = "An earlier original download didn’t finish. Tap retry and keep Reel open until it finishes."
                }
            }
            try recoverPackageRemovals(referenced: Set(valid.compactMap(\.packagePath)))
            errors["storage"] = nil
            hls?.retryStorageCleanup()
        } catch {
            storageReady = false
            errors["storage"] = "Downloads couldn’t be opened or cleaned up. Existing files are preserved. Retry storage recovery before changing downloads."
        }
    }
    static func key(account: Account, item: MediaItem) -> String { account.id + "|" + item.id }
    func saved(account: Account, item: MediaItem) -> DownloadedItem? { items.first { $0.accountID == account.id && $0.item.id == item.id } }
    func url(_ item: DownloadedItem) -> URL {
        if let path = item.packagePath, let location = try? HLSPackageLocation.resolve(path) { return location }
        return directory.appendingPathComponent(item.filename)
    }
    nonisolated static func snapshot(_ item: MediaItem) -> MediaItem {
        var snapshot = item
        snapshot.MediaSources = nil
        return snapshot
    }
    static func canOptimize(_ item: MediaItem) -> Bool { ["Movie", "Episode", "Video", "MusicVideo"].contains(item.Type ?? "") }
    static func compatible(_ item: MediaItem) -> Bool {
        guard let source = item.MediaSources?.first, ["mp4", "m4v", "mov"].contains(source.Container?.lowercased() ?? "") else { return false }
        let streams = source.MediaStreams ?? []
        return streams.filter { $0.Type == "Video" }.allSatisfy { ["h264", "hevc"].contains($0.Codec?.lowercased() ?? "") }
            && streams.filter { $0.Type == "Audio" }.allSatisfy { ["aac", "alac", "ac3", "eac3", "mp3"].contains($0.Codec?.lowercased() ?? "") }
    }
    /// `size` applies to an optimized download, which Jellyfin converts for this device.
    func download(_ item: MediaItem, account: Account, api: JellyfinAPI, optimized: Bool = false, size: DownloadSize = .standard) {
        let key = Self.key(account: account, item: item)
        guard storageReady else { errors[key] = HLSDownloadError.storage.localizedDescription; return }
        guard !active.contains(key), saved(account: account, item: item) == nil else { return }
        guard !api.isSimulatorPreview else { errors[key] = ReelError.previewProtected.localizedDescription; return }
        guard account.server == api.server, account.userID == api.userID, account.token == api.token else {
            errors[key] = ReelError.unauthorized.localizedDescription; return
        }
        guard (try? JellyfinAPI.normalize(account.server.absoluteString)) == account.server else {
            errors[key] = ReelError.invalidServer.localizedDescription; return
        }
        if optimized {
            guard Self.canOptimize(item) else { return }
            do {
                let engine = hlsEngine()
                if engine.retryCompleted(key) { return }
                try engine.start(item, account: account, api: api, size: size)
                if originals[key] != nil { finishOriginal(key) }
            }
            catch { requested[key] = item; errors[key] = error.localizedDescription; self.optimized.insert(key) }
            return
        }
        guard Self.compatible(item) else { return }
        hls?.cancel(key)
        hlsOwners[key] = nil; self.optimized.remove(key); progress[key] = nil
        var requestSnapshot = item
        requestSnapshot.MediaSources = item.MediaSources?.map {
            MediaSource(Id: $0.Id, Container: $0.Container, MediaStreams: $0.MediaStreams)
        }
        let intent = OriginalDownloadIntent(accountID: account.id, item: requestSnapshot)
        do {
            var updated = originals; updated[key] = intent
            try persistOriginals(updated)
            originals = updated
        } catch {
            requested[key] = item; errors[key] = HLSDownloadError.storage.localizedDescription
            return
        }
        active.insert(key); errors[key] = nil; requested[key] = item
        tasks[key] = Task {
            defer { active.remove(key); tasks[key] = nil }
            var destination: URL?
            do {
                var request = api.request("Items/\(item.id)/Download")
                request.timeoutInterval = 300
                let (temporary, response) = try await JellyfinAPI.transport.download(for: request, delegate: api.redirects)
                defer { try? FileManager.default.removeItem(at: temporary) }
                try Task.checkCancellation()
                try requireStorage()
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url.map({ JellyfinAPI.sameOrigin($0, api.server) }) == true else {
                    if (response as? HTTPURLResponse)?.statusCode == 403 { throw ReelError.unauthorized }
                    throw ReelError.unavailable
                }
                let id = UUID()
                let filename = id.uuidString + "." + (item.MediaSources?.first?.Container?.lowercased() ?? "mp4")
                let target = directory.appendingPathComponent(filename)
                destination = target
                try FileManager.default.moveItem(at: temporary, to: target)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: target.path)
                let bytes = (try target.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
                guard bytes > 0 else { throw ReelError.invalidResponse }
                let entry = DownloadedItem(id: id, accountID: account.id, item: Self.snapshot(item), filename: filename, bytes: Int64(bytes))
                let updated = items + [entry]
                try persist(updated)
                items = updated
                destination = nil
                requested[key] = nil
                finishOriginal(key)
            } catch is CancellationError { requested[key] = nil; finishOriginal(key) }
            catch let error as URLError where error.code == .cancelled { requested[key] = nil; finishOriginal(key) }
            catch { errors[key] = "Download failed. Check storage, network and your server’s download permission, then try again." }
            if let destination { try? FileManager.default.removeItem(at: destination) }
        }
    }
    func cancel(_ key: String) {
        tasks[key]?.cancel(); hls?.cancel(key)
        if tasks[key] == nil, !active.contains(key) {
            requested[key] = nil; errors[key] = nil; progress[key] = nil; optimized.remove(key)
            if originals[key] != nil { finishOriginal(key) }
        }
    }
    func remove(_ item: DownloadedItem) throws {
        try requireStorage()
        let updated = items.filter { $0.id != item.id }
        let original = url(item)
        if let packagePath = item.packagePath {
            _ = try HLSPackageLocation.resolve(packagePath)
            var pending = try readPackageRemovals()
            if !pending.contains(packagePath) { pending.append(packagePath) }
            try persistPackageRemovals(pending)
            do { try persist(updated) }
            catch {
                // The row is still committed, so recovery preserves its system-owned package.
                throw error
            }
            items = updated
            do { try recoverPackageRemovals(referenced: Set(updated.compactMap(\.packagePath))) }
            catch { errors["storage"] = "The download was removed, but storage cleanup needs another attempt." }
            UserDefaults.standard.removeObject(forKey: "offline-" + item.filename)
            return
        }
        let tombstone = directory.appendingPathComponent(item.filename + ".removing")
        try FileManager.default.moveItem(at: original, to: tombstone)
        do { try persist(updated) }
        catch { try FileManager.default.moveItem(at: tombstone, to: original); throw error }
        items = updated
        do { try FileManager.default.removeItem(at: tombstone) }
        catch { errors["storage"] = "The download was removed, but storage cleanup needs another attempt." }
        UserDefaults.standard.removeObject(forKey: "offline-" + item.filename)
    }
    func removeAccount(_ id: String) {
        hls?.cancelAccount(id)
        for key in requested.keys where key.hasPrefix(id + "|") { requested[key] = nil; errors[key] = nil }
        for key in active where key.hasPrefix(id + "|") { tasks[key]?.cancel() }
        for item in items where item.accountID == id { do { try remove(item) } catch { errors["storage"] = error.localizedDescription } }
        let retained = originals.filter { $0.value.accountID != id }
        do { try persistOriginals(retained); originals = retained }
        catch { errors["storage"] = HLSDownloadError.storage.localizedDescription }
    }
    func waitForDownloads() async {
        for task in Array(tasks.values) { await task.value }
        await hls?.waitForDownloads()
    }
    @discardableResult func flushCleanup(accountID: String, api: JellyfinAPI? = nil) async -> Bool {
        let matching = tasks.filter { $0.key.hasPrefix(accountID + "|") }.map(\.value)
        for task in matching { task.cancel() }
        for task in matching { await task.value }
        return await hls?.flushCleanup(accountID: accountID, api: api) ?? true
    }

    private func hlsEngine() -> HLSDownloads {
        if let hls { return hls }
        let engine = HLSDownloads.shared(directory: directory)
        hls = engine
        engine.observe { [weak self] event in self?.receive(event) }
        return engine
    }

    private func receive(_ event: HLSDownloads.Event) {
        switch event {
        case .changed(let record):
            let key = record.key
            hlsOwners[key] = record.id
            optimized.insert(key); requested[key] = record.item; errors[key] = record.error
            progress[key] = record.progress
            if record.stage == .preparing || record.stage == .downloading { active.insert(key) }
            else { active.remove(key) }
        case .completed(let record):
            hlsOwners[record.key] = record.id; optimized.insert(record.key)
            active.remove(record.key); requested[record.key] = record.item
            guard storageReady else { errors[record.key] = HLSDownloadError.storage.localizedDescription; return }
            guard let packagePath = record.packagePath, let location = try? HLSPackageLocation.resolve(packagePath),
                  FileManager.default.fileExists(atPath: location.path) else {
                errors[record.key] = HLSDownloadError.invalidLocation.localizedDescription; return
            }
            if let existing = items.first(where: { $0.accountID == record.accountID && $0.item.id == record.item.id }) {
                if existing.id == record.id {
                    requested[record.key] = nil; errors[record.key] = nil; progress[record.key] = nil
                    optimized.remove(record.key); hlsOwners[record.key] = nil
                    hls?.acknowledge(record.id)
                }
                else { hls?.cancel(record.key) }
                return
            }
            let bytes = Self.packageBytes(location)
            let entry = DownloadedItem(id: record.id, accountID: record.accountID, item: Self.snapshot(record.item),
                                       filename: record.id.uuidString + ".movpkg", bytes: bytes, packagePath: packagePath)
            do {
                try persist(items + [entry])
                items.append(entry)
                active.remove(record.key); requested[record.key] = nil; errors[record.key] = nil
                progress[record.key] = nil; optimized.remove(record.key); hlsOwners[record.key] = nil
                hls?.acknowledge(record.id)
            } catch {
                active.remove(record.key); requested[record.key] = record.item
                errors[record.key] = "The video finished downloading, but its library entry couldn’t be saved. Reopen Reel after freeing storage."
            }
        case .removed(let id, let key):
            guard hlsOwners[key] == id else { return }
            active.remove(key); requested[key] = nil; errors[key] = nil
            optimized.remove(key); progress[key] = nil; hlsOwners[key] = nil
        case .storageError(let message): errors["storage"] = message
        }
    }

    private static func packageBytes(_ location: URL) -> Int64 {
        guard let enumerator = FileManager.default.enumerator(at: location, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in enumerator {
            if let values = try? file.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true {
                total += Int64(values.fileSize ?? 0)
            }
        }
        return total
    }

    private func readPackageRemovals() throws -> [String] {
        guard FileManager.default.fileExists(atPath: removals.path) else { return [] }
        return try JSONDecoder().decode([String].self, from: Data(contentsOf: removals))
    }
    private func persistPackageRemovals(_ paths: [String]) throws {
        try requireStorage()
        try JSONEncoder().encode(paths).write(to: removals, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func recoverPackageRemovals(referenced: Set<String>) throws {
        try requireStorage()
        let pending = try readPackageRemovals()
        guard !pending.isEmpty else { return }
        var remaining: [String] = []
        var failed = false
        for path in pending where !referenced.contains(path) {
            guard let location = try? HLSPackageLocation.resolve(path) else { continue }
            do { if FileManager.default.fileExists(atPath: location.path) { try FileManager.default.removeItem(at: location) } }
            catch { remaining.append(path); failed = true }
        }
        try persistPackageRemovals(remaining)
        if failed { throw HLSDownloadError.storage }
    }
    private func persistOriginals(_ intents: [String: OriginalDownloadIntent]) throws {
        try requireStorage()
        try JSONEncoder().encode(Array(intents.values)).write(to: originalManifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func finishOriginal(_ key: String) {
        var updated = originals; updated[key] = nil
        do { try persistOriginals(updated); originals = updated }
        catch { errors["storage"] = "The video transfer ended, but its request entry still needs storage cleanup." }
    }
    private func requireStorage() throws { guard storageReady else { throw HLSDownloadError.storage } }
    private func persist(_ items: [DownloadedItem]) throws {
        try requireStorage()
        try JSONEncoder().encode(items).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
