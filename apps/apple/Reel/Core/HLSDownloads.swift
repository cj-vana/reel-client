import AVFoundation
import CryptoKit
import Darwin
import UIKit

enum HLSDownloadError: LocalizedError {
    case permission, unsupportedGateway, invalidLocation, unavailable, storage
    var errorDescription: String? {
        switch self {
        case .permission: "Your Jellyfin account doesn’t allow downloads. Ask your server administrator to enable downloading."
        case .unsupportedGateway: "Optimized downloads aren’t available through a gateway that requires custom headers. Use a direct or Tailscale server connection."
        case .invalidLocation: "iOS returned an unavailable download location. Remove this download and try again."
        case .unavailable: "iOS couldn’t save a complete offline video. Check storage, connection and server transcoding, then try again."
        case .storage: "Download information couldn’t be saved. Check available storage and try again."
        }
    }
}

enum HLSPackageLocation {
    private static let noFollowPrefix = "/.nofollow"

    static func relative(_ url: URL, root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> String {
        guard url.isFileURL else { throw HLSDownloadError.invalidLocation }
        let base = try canonical(root)
        let physical: URL
        if url.path.hasPrefix(noFollowPrefix + "/") {
            let path = String(url.path.dropFirst(noFollowPrefix.count))
            guard !path.hasPrefix(noFollowPrefix + "/") else { throw HLSDownloadError.invalidLocation }
            physical = URL(fileURLWithPath: path, isDirectory: url.hasDirectoryPath)
        } else { physical = url }
        let target = try canonical(physical, allowingMissingComponents: true)
        guard target.path.hasPrefix(base.path + "/") else { throw HLSDownloadError.invalidLocation }
        let relative = String(target.path.dropFirst(base.path.count + 1))
        _ = try resolve(relative, root: base)
        return relative
    }

    static func resolve(_ relative: String, root: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) throws -> URL {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 3, parts[0] == "Library", managedFolder(parts[1]),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") }),
              !parts.dropLast().contains(where: { $0.contains("%") }), relative.hasSuffix(".movpkg") else { throw HLSDownloadError.invalidLocation }
        let base = try canonical(root)
        var target = base
        // iOS can retain percent-escaped title text in the package filename. It is a literal file component, never a URL to decode.
        for part in parts {
            target.appendPathComponent(String(part))
            if (try? FileManager.default.destinationOfSymbolicLink(atPath: target.path)) != nil {
                guard FileManager.default.fileExists(atPath: target.path) else { throw HLSDownloadError.invalidLocation }
                target = try canonical(target)
            }
            guard target.path.hasPrefix(base.path + "/") else { throw HLSDownloadError.invalidLocation }
        }
        let resolvedParts = target.path.hasPrefix(base.path + "/") ? String(target.path.dropFirst(base.path.count + 1)).split(separator: "/") : []
        guard resolvedParts.count >= 3, resolvedParts[0] == "Library", managedFolder(resolvedParts[1]), target.pathExtension == "movpkg" else {
            throw HLSDownloadError.invalidLocation
        }
        // Keep the native kernel no-follow protection when opening or deleting the validated package.
        return URL(fileURLWithPath: noFollowPrefix + target.path, isDirectory: true)
    }
    private static func managedFolder(_ value: Substring) -> Bool {
        value == "com.apple.UserManagedAssets" || value.hasPrefix("com.apple.UserManagedAssets.")
    }

    private static func canonical(_ url: URL, allowingMissingComponents: Bool = false) throws -> URL {
        var ancestor = url.standardizedFileURL
        var missing: [String] = []
        while true {
            if let path = realpath(ancestor.path, nil) {
                defer { free(path) }
                var result = URL(fileURLWithPath: String(cString: path), isDirectory: true)
                for part in missing.reversed() { result.appendPathComponent(part) }
                return result
            }
            guard allowingMissingComponents, errno == ENOENT, ancestor.path != "/",
                  (try? FileManager.default.destinationOfSymbolicLink(atPath: ancestor.path)) == nil else {
                throw HLSDownloadError.invalidLocation
            }
            missing.append(ancestor.lastPathComponent)
            ancestor.deleteLastPathComponent()
        }
    }
}

struct HLSDownloadRecord: Codable, Identifiable, Sendable {
    enum Stage: String, Codable, Sendable { case preparing, downloading, completed, failed, cancelled }
    let id: UUID
    let accountID: String
    let server: URL
    let userID: String
    let deviceID: String
    let item: MediaItem
    let createdAt: Date
    var stage: Stage = .preparing
    var taskID: Int?
    var packagePath: String?
    var playSessionID: String?
    var progress = 0.0
    var error: String?
    var imported = false
    var needsCleanup = false
    /// Missing on downloads saved before sizes existed, which were all standard.
    var size: DownloadSize?
    var key: String { accountID + "|" + item.id }

    init(id: UUID = UUID(), account: Account, api: JellyfinAPI, item: MediaItem) {
        self.id = id; accountID = account.id; server = account.server; userID = account.userID
        deviceID = api.deviceID; self.item = Downloads.snapshot(item); createdAt = Date()
    }
}

struct HLSDownloadUserPolicy: Decodable, Sendable {
    struct Policy: Decodable, Sendable { let EnableContentDownloading: Bool? }
    let Policy: Policy
}

/// How large an optimized download is: Jellyfin converts the video to H.264 at this size and bitrate.
enum DownloadSize: String, Codable, CaseIterable, Identifiable, Sendable {
    case high, standard, small
    static let audioBitRate = 128_000
    var id: String { rawValue }
    var maxWidth: Int { switch self { case .high: 1920; case .standard: 1280; case .small: 854 } }
    var maxHeight: Int { switch self { case .high: 1080; case .standard: 720; case .small: 480 } }
    var videoBitRate: Int { switch self { case .high: 6_000_000; case .standard: 1_872_000; case .small: 900_000 } }
    var title: String { switch self { case .high: "High · 1080p"; case .standard: "Standard · 720p"; case .small: "Data saver · 480p" } }
    /// Storage for an hour of video at this size, from its video and audio bitrates.
    var perHour: String {
        let bytes = Int64(videoBitRate + Self.audioBitRate) * 3600 / 8
        return "About " + ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) + " an hour"
    }
}

enum HLSDownloadPlan {
    static func url(api: JellyfinAPI, item: MediaItem, source: MediaSource, sessionID: String, size: DownloadSize = .standard) throws -> URL {
        guard source.SupportsDirectPlay != true else { throw ReelError.noStream }
        let stream = try api.streamURL(item: item, source: source, sessionID: sessionID)
        guard var parts = URLComponents(url: stream.url, resolvingAgainstBaseURL: false),
              parts.path.lowercased().hasSuffix(".m3u8") else { throw ReelError.noStream }
        let fixed = ["StartTimeTicks": "0", "VideoCodec": "h264", "AudioCodec": "aac", "MaxWidth": String(size.maxWidth), "MaxHeight": String(size.maxHeight),
                     "VideoBitRate": String(size.videoBitRate), "AudioBitRate": String(DownloadSize.audioBitRate), "MaxAudioChannels": "2", "SegmentContainer": "ts",
                     "AllowVideoStreamCopy": "false", "AllowAudioStreamCopy": "false", "EnableAutoStreamCopy": "false",
                     "EnableAdaptiveBitrateStreaming": "false", "EnableTrickplay": "false", "Context": "Static", "SubtitleStreamIndex": "-1",
                     "PlaySessionId": sessionID, "DeviceId": api.deviceID]
        let names = Set(fixed.keys.map { $0.lowercased() })
        parts.queryItems = (parts.queryItems ?? []).filter { !names.contains($0.name.lowercased()) }
            + fixed.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = parts.url, JellyfinAPI.sameOrigin(url, api.server) else { throw ReelError.unsafeStream }
        let base = api.server.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let path = url.standardized.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard base.isEmpty || path == base || path.hasPrefix(base + "/") else { throw ReelError.unsafeStream }
        return url
    }
}

@MainActor final class HLSDownloads: NSObject {
    enum Event {
        case changed(HLSDownloadRecord)
        case completed(HLSDownloadRecord)
        case removed(UUID, String)
        case storageError(String)
    }
    private static var registry: [String: HLSDownloads] = [:]
    static let defaultDirectory = URL.applicationSupportDirectory.appendingPathComponent("Downloads", isDirectory: true)
    static var defaultIdentifier: String { (Bundle.main.bundleIdentifier ?? "app.reelclient.ios") + ".offline.hls" }

    static func shared(directory: URL) -> HLSDownloads {
        let identifier: String
        if directory.standardizedFileURL == defaultDirectory.standardizedFileURL { identifier = defaultIdentifier }
        else {
            let hash = SHA256.hash(data: Data(directory.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            identifier = defaultIdentifier + "." + hash
        }
        if let existing = registry[identifier] { return existing }
        let engine = HLSDownloads(directory: directory, identifier: identifier)
        registry[identifier] = engine
        return engine
    }

    private let directory: URL
    private let identifier: String
    private var manifest: URL { directory.appendingPathComponent("hls-tasks.json") }
    private var records: [UUID: HLSDownloadRecord] = [:]
    private var observers: [UUID: (Event) -> Void] = [:]
    private var nativeTasks: [UUID: AVAssetDownloadTask] = [:]
    private var preparations: [UUID: Task<Void, Never>] = [:]
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private var progressObservations: [UUID: NSKeyValueObservation] = [:]
    private var apis: [UUID: JellyfinAPI] = [:]
    private var restoration: Task<Void, Never>?
    private var storageFailure: String?
    private var backgroundCompletion: (() -> Void)?
    private lazy var session: AVAssetDownloadURLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = false
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        return AVAssetDownloadURLSession(configuration: configuration, assetDownloadDelegate: self, delegateQueue: .main)
    }()

    private init(directory: URL, identifier: String) {
        self.directory = directory; self.identifier = identifier
        super.init()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: manifest.path) {
                let saved = try JSONDecoder().decode([HLSDownloadRecord].self, from: Data(contentsOf: manifest))
                for record in saved {
                    guard record.server == (try? JellyfinAPI.normalize(record.server.absoluteString)),
                          record.accountID == record.server.absoluteString + "|" + record.userID,
                          record.packagePath == nil || (try? HLSPackageLocation.resolve(record.packagePath!)) != nil,
                          records[record.id] == nil else { throw HLSDownloadError.storage }
                    records[record.id] = record
                }
            }
        } catch { records.removeAll(); storageFailure = HLSDownloadError.storage.localizedDescription }
        restoration = Task { [weak self] in guard let self else { return }; await self.restoreTasks() }
    }

    func observe(_ observer: @escaping (Event) -> Void) {
        observers[UUID()] = observer
        if let storageFailure { observer(.storageError(storageFailure)) }
        for record in records.values.sorted(by: { $0.createdAt < $1.createdAt }) {
            if record.stage == .completed, !record.imported { observer(.completed(record)) }
            else if record.stage != .cancelled && !record.imported { observer(.changed(record)) }
        }
    }

    private func emit(_ event: Event) { for observer in observers.values { observer(event) } }
    private func save() throws {
        try JSONEncoder().encode(Array(records.values)).write(to: manifest, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
    private func update(_ record: HLSDownloadRecord) throws {
        let previous = records[record.id]
        records[record.id] = record
        do { try save() }
        catch { records[record.id] = previous; throw error }
    }

    func start(_ item: MediaItem, account: Account, api: JellyfinAPI, size: DownloadSize = .standard) throws {
        guard storageFailure == nil else { throw HLSDownloadError.storage }
        guard !api.isSimulatorPreview else { throw ReelError.previewProtected }
        guard api.server == account.server, api.userID == account.userID, api.token == account.token else { throw ReelError.unauthorized }
        guard (try? JellyfinAPI.normalize(account.server.absoluteString)) == account.server else { throw ReelError.invalidServer }
        guard api.gatewayHeaders.isEmpty else { throw HLSDownloadError.unsupportedGateway }
        let key = Downloads.key(account: account, item: item)
        cancel(key)
        let record = { var record = HLSDownloadRecord(account: account, api: api, item: item); record.size = size; return record }()
        try update(record)
        apis[record.id] = api
        emit(.changed(record))
        let restoring = restoration
        preparations[record.id] = Task { [weak self] in
            guard let self else { return }
            defer { self.preparations[record.id] = nil }
            await restoring?.value
            do {
                try Task.checkCancellation()
                guard self.records[record.id]?.stage == .preparing else { return }
                let user: HLSDownloadUserPolicy = try await api.get("Users/Me")
                try Task.checkCancellation()
                guard user.Policy.EnableContentDownloading == true else { throw HLSDownloadError.permission }
                var beginning = item
                if beginning.UserData == nil { beginning.UserData = UserData() }
                beginning.UserData?.PlaybackPositionTicks = 0
                let info = try await api.playback(beginning, quality: .dataSaver, subtitle: -1,
                                                  mediaSourceID: item.MediaSources?.first?.Id, forceHLS: true)
                guard let source = info.MediaSources.first, info.ErrorCode == nil else { throw ReelError.noStream }
                let sessionID = info.PlaySessionId ?? UUID().uuidString
                guard var current = self.records[record.id] else { return }
                current.playSessionID = sessionID; current.needsCleanup = true
                try self.update(current)
                try Task.checkCancellation()
                guard current.stage == .preparing else { self.cleanup(record.id); return }
                let url = try HLSDownloadPlan.url(api: api, item: beginning, source: source, sessionID: sessionID, size: size)
                let asset = AVURLAsset(url: url)
                let configuration = AVAssetDownloadConfiguration(asset: asset, title: item.title)
                configuration.auxiliaryContentConfigurations = []
                configuration.downloadsInterstitialAssets = false
                let task = self.session.makeAssetDownloadTask(downloadConfiguration: configuration)
                task.taskDescription = record.id.uuidString
                current.stage = .downloading; current.taskID = task.taskIdentifier
                do { try self.update(current) }
                catch { task.cancel(); throw error }
                self.nativeTasks[record.id] = task
                self.track(task, id: record.id)
                self.emit(.changed(current))
                task.resume()
            } catch is CancellationError { self.finishCancelled(record.id) }
            catch let error as URLError where error.code == .cancelled { self.finishCancelled(record.id) }
            catch { self.fail(record.id, message: (error as? HLSDownloadError)?.localizedDescription ?? "Optimized download failed. Check storage, your download permission and server transcoding, then try again.") }
        }
    }

    func cancel(_ key: String) {
        for original in Array(records.values) where original.key == key && !original.imported {
            var record = original; record.stage = .cancelled; record.error = nil
            do { try update(record) }
            catch { records[record.id] = record; emit(.storageError(HLSDownloadError.storage.localizedDescription)) }
            preparations[record.id]?.cancel()
            if let task = nativeTasks[record.id] { task.cancel() }
            else if preparations[record.id] == nil { finishCancelled(record.id) }
            emit(.removed(record.id, key))
        }
    }

    func cancelAccount(_ accountID: String) {
        for key in Set(records.values.filter { $0.accountID == accountID && !$0.imported }.map(\.key)) { cancel(key) }
    }

    func retryCompleted(_ key: String) -> Bool {
        guard let record = records.values.first(where: { $0.key == key && $0.stage == .completed && !$0.imported }),
              let path = record.packagePath, let location = try? HLSPackageLocation.resolve(path),
              AVURLAsset(url: location).assetCache?.isPlayableOffline == true else { return false }
        emit(.completed(record))
        return true
    }

    func retryStorageCleanup() {
        if let storageFailure { emit(.storageError(storageFailure)); return }
        for record in Array(records.values) {
            if record.stage == .cancelled { finishCancelled(record.id) }
            else if record.stage == .failed { removePartial(record); cleanup(record.id) }
            else if record.stage == .completed {
                if !record.imported { emit(.completed(record)) }
                cleanup(record.id)
            }
        }
    }

    func acknowledge(_ id: UUID) {
        guard var record = records[id] else { return }
        record.imported = true
        do {
            if !record.needsCleanup { records[id] = nil; try save() }
            else { try update(record) }
        } catch { emit(.storageError(HLSDownloadError.storage.localizedDescription)) }
    }

    func waitForDownloads() async {
        await restoration?.value
        while !preparations.isEmpty || !nativeTasks.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
        for task in Array(cleanupTasks.values) { await task.value }
    }

    @discardableResult func flushCleanup(accountID: String, api: JellyfinAPI? = nil) async -> Bool {
        if let api, api.server.absoluteString + "|" + (api.userID ?? "") == accountID {
            for record in records.values where record.accountID == accountID { apis[record.id] = api }
        }
        cancelAccount(accountID)
        await restoration?.value
        cancelAccount(accountID)
        let deadline = ContinuousClock.now + .seconds(25)
        func isTransferring() -> Bool {
            records.values.contains { $0.accountID == accountID && (preparations[$0.id] != nil || nativeTasks[$0.id] != nil) }
        }
        while isTransferring(), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        for record in Array(records.values) where record.accountID == accountID { cleanup(record.id) }
        let cleanups = cleanupTasks.filter { records[$0.key]?.accountID == accountID }.map(\.value)
        for task in cleanups { await task.value }
        let finished = storageFailure == nil && !isTransferring() && !records.values.contains { $0.accountID == accountID && $0.needsCleanup }
        if !finished { emit(.storageError("A server download couldn’t be fully stopped. Its encoder will need to expire on the server.")) }
        return finished
    }

    private func restoreTasks() async {
        let tasks: [URLSessionTask] = await withCheckedContinuation { continuation in
            session.getAllTasks { continuation.resume(returning: $0) }
        }
        let accounts = try? SecureAccount.read().accounts
        var attached: Set<UUID> = []
        for task in tasks {
            guard let native = task as? AVAssetDownloadTask, let description = task.taskDescription,
                  let id = UUID(uuidString: description), var record = records[id],
                  record.stage == .downloading || record.stage == .cancelled else {
                task.cancel(); continue
            }
            attached.insert(id)
            nativeTasks[id] = native
            if record.stage == .cancelled || (accounts.map { saved in !saved.contains(where: { $0.id == record.accountID }) } ?? false) {
                record.stage = .cancelled
                do { try update(record) } catch { emit(.storageError(HLSDownloadError.storage.localizedDescription)) }
                native.cancel()
            } else {
                track(native, id: id)
                emit(.changed(record))
                if native.state == .suspended { native.resume() }
            }
        }
        for record in Array(records.values) {
            switch record.stage {
            case .downloading where !attached.contains(record.id):
                if let path = record.packagePath, let location = try? HLSPackageLocation.resolve(path),
                   AVURLAsset(url: location).assetCache?.isPlayableOffline == true {
                    finished(record.id, failed: false, cancelled: false)
                } else { fail(record.id, message: "This optimized download was interrupted. Tap retry while connected to your server.") }
            case .preparing where preparations[record.id] == nil:
                fail(record.id, message: "Download preparation was interrupted. Tap retry while connected to your server.")
            case .cancelled: finishCancelled(record.id)
            case .completed:
                if !record.imported { emit(.completed(record)) }
                cleanup(record.id)
            case .failed: _ = removePartial(record); cleanup(record.id)
            default: break
            }
        }
    }

    private func track(_ task: AVAssetDownloadTask, id: UUID) {
        progressObservations[id] = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { [weak self] value, _ in
            let fraction = value.fractionCompleted
            Task { @MainActor in
                guard let self, fraction.isFinite, var record = self.records[id], record.stage == .downloading else { return }
                let progress = min(0.99, max(0, fraction))
                guard progress - record.progress >= 0.01 else { return }
                record.progress = progress
                do { try self.update(record); self.emit(.changed(record)) }
                catch { self.emit(.storageError(HLSDownloadError.storage.localizedDescription)) }
            }
        }
    }

    private func api(for record: HLSDownloadRecord) -> JellyfinAPI? {
        if let api = apis[record.id] { return api }
        guard let account = (try? SecureAccount.read().accounts)?.first(where: { $0.id == record.accountID }) else { return nil }
        return JellyfinAPI(server: account.server, token: account.token, userID: account.userID, deviceID: record.deviceID, historyEnabled: false)
    }

    private func cleanup(_ id: UUID) {
        guard let record = records[id], record.needsCleanup, let sessionID = record.playSessionID,
              cleanupTasks[id] == nil, let api = api(for: record), !api.isSimulatorPreview else { return }
        cleanupTasks[id] = Task { [weak self] in
            guard let self else { return }
            defer { self.cleanupTasks[id] = nil }
            do {
                var request = api.request("Videos/ActiveEncodings", query: ["deviceId": record.deviceID, "playSessionId": sessionID], method: "DELETE")
                request.timeoutInterval = 10
                _ = try await api.send(request)
                guard var latest = self.records[id] else { return }
                latest.needsCleanup = false
                if latest.imported || (latest.stage == .cancelled && self.nativeTasks[id] == nil && self.preparations[id] == nil && self.removePartial(latest)) { self.records[id] = nil; try self.save(); self.apis[id] = nil }
                else { try self.update(latest) }
            } catch { /* Persisted session metadata allows another cleanup attempt after relaunch. */ }
        }
    }

    @discardableResult private func removePartial(_ record: HLSDownloadRecord) -> Bool {
        guard let path = record.packagePath else { return true }
        guard let url = try? HLSPackageLocation.resolve(path) else { return false }
        do {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
            return true
        } catch {
            emit(.storageError("A partial video still needs storage cleanup. Reopen Reel to try again."))
            return false
        }
    }

    private func finishCancelled(_ id: UUID) {
        guard nativeTasks[id] == nil else { return }
        guard var record = records[id] else { return }
        record.stage = .cancelled
        do { try update(record) }
        catch { emit(.storageError(HLSDownloadError.storage.localizedDescription)); return }
        let removed = removePartial(record)
        cleanup(id)
        if !record.needsCleanup && removed {
            records[id] = nil
            do { try save() } catch { records[id] = record; emit(.storageError(HLSDownloadError.storage.localizedDescription)) }
            apis[id] = nil
        }
        emit(.removed(id, record.key))
    }

    private func fail(_ id: UUID, message: String) {
        guard var record = records[id] else { return }
        if record.stage == .cancelled { finishCancelled(id); return }
        record.stage = .failed; record.error = message
        do { try update(record) }
        catch { emit(.storageError(HLSDownloadError.storage.localizedDescription)); return }
        removePartial(record)
        cleanup(id)
        emit(.changed(record))
    }

    private func receivedLocation(_ location: URL, id: UUID) {
        guard var record = records[id] else { return }
        do {
            record.packagePath = try HLSPackageLocation.relative(location)
            try update(record)
        } catch {
            nativeTasks[id]?.cancel(); fail(id, message: HLSDownloadError.invalidLocation.localizedDescription)
        }
    }

    private func finished(_ id: UUID, failed: Bool, cancelled: Bool) {
        nativeTasks[id] = nil; progressObservations[id] = nil
        guard var record = records[id] else { return }
        if record.stage == .cancelled || (cancelled && record.stage != .failed) { finishCancelled(id); return }
        if record.stage == .failed { removePartial(record); cleanup(id); emit(.changed(record)); return }
        guard !failed, let path = record.packagePath, let location = try? HLSPackageLocation.resolve(path),
              FileManager.default.fileExists(atPath: location.path), AVURLAsset(url: location).assetCache?.isPlayableOffline == true else {
            fail(id, message: HLSDownloadError.unavailable.localizedDescription); return
        }
        record.stage = .completed; record.progress = 1; record.error = nil
        do { try update(record) }
        catch { fail(id, message: HLSDownloadError.storage.localizedDescription); return }
        emit(.completed(record))
        cleanup(id)
    }

    static func handleBackgroundEvents(identifier: String, completion: @escaping () -> Void) {
        let engine: HLSDownloads?
        if identifier == defaultIdentifier { engine = shared(directory: defaultDirectory) }
        else { engine = registry[identifier] }
        guard let engine else { completion(); return }
        engine.backgroundCompletion = completion
    }
}

extension HLSDownloads: AVAssetDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, assetDownloadTask: AVAssetDownloadTask, willDownloadTo location: URL) {
        guard let description = assetDownloadTask.taskDescription, let id = UUID(uuidString: description) else { assetDownloadTask.cancel(); return }
        // This session uses OperationQueue.main; commit its location before processing completion.
        MainActor.assumeIsolated { [weak self] in self?.receivedLocation(location, id: id) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let description = task.taskDescription, let id = UUID(uuidString: description) else { return }
        let nsError = error as NSError?
        let cancelled = (nsError?.domain == NSURLErrorDomain && nsError?.code == NSURLErrorCancelled)
            || (nsError?.domain == NSCocoaErrorDomain && nsError?.code == NSUserCancelledError)
        let failed = error != nil
        MainActor.assumeIsolated { [weak self] in self?.finished(id, failed: failed, cancelled: cancelled) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        MainActor.assumeIsolated { [weak self] in
            guard let self else { return }
            let completion = self.backgroundCompletion; self.backgroundCompletion = nil
            completion?()
        }
    }
}

@MainActor final class DownloadAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        HLSDownloads.handleBackgroundEvents(identifier: identifier, completion: completionHandler)
    }
}
