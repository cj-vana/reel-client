import AVKit
import Observation
import Synchronization

@MainActor final class PlaybackReporter {
    struct Stored: Codable {
        let id: UUID
        let server: String
        let userID: String
        let endpoint: String
        let body: Data
        let cleanup: Bool
        let itemID: String
    }
    private struct Entry { let report: Stored; let api: JellyfinAPI }
    private static var inFlight: Set<UUID> = []
    private static var historyPolicy: [String: Bool] = [:]
    static func updatePrivacy(api: JellyfinAPI) { historyPolicy[api.server.absoluteString + "|" + (api.userID ?? "")] = api.recordsHistory }
    private static func allowsHistory(_ api: JellyfinAPI) -> Bool {
        api.recordsHistory && historyPolicy[api.server.absoluteString + "|" + (api.userID ?? "")] != false
    }
    private let storageKey = "pendingWatchReports"
    private var pending: [Entry] = []
    private var stored: [Stored] {
        get {
            guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [] }
            return (try? JSONDecoder().decode([Stored].self, from: data)) ?? []
        }
        set {
            do { UserDefaults.standard.set(try JSONEncoder().encode(newValue), forKey: storageKey) }
            catch { onFailure?("Watch progress couldn’t be saved on this device.") }
        }
    }
    private var worker: Task<Void, Never>?
    private var workingID: UUID?
    var onFailure: ((String?) -> Void)?

    private static func cleanupBody(_ body: [String: Any]) -> [String: Any] {
        var result: [String: Any] = [:]
        if let id = body["LiveStreamId"] as? String, !id.isEmpty { result["LiveStreamId"] = id }
        if let id = body["PlaySessionId"] as? String, !id.isEmpty, body["CleanupEncoder"] as? Bool != false {
            result["PlaySessionId"] = id; result["CleanupEncoder"] = true
        } else { result["CleanupEncoder"] = false }
        return result
    }
    private static func hasCleanup(_ body: [String: Any]) -> Bool {
        (body["LiveStreamId"] as? String).map { !$0.isEmpty } == true
            || (body["CleanupEncoder"] as? Bool == true && (body["PlaySessionId"] as? String).map { !$0.isEmpty } == true)
    }

    func enqueue(api: JellyfinAPI, endpoint: String, body: [String: any Sendable], cleanup: Bool = false) {
        let history = Self.allowsHistory(api)
        guard history || cleanup else { return }
        do {
            let original = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body)) as? [String: Any] ?? [:]
            let resources = Self.cleanupBody(original)
            let ownsCleanup = cleanup && Self.hasCleanup(resources)
            let endpoint = history ? endpoint : ""
            guard !endpoint.isEmpty || ownsCleanup else { return }
            let outbound = endpoint.isEmpty ? resources : original
            let report = Stored(id: UUID(), server: api.server.absoluteString, userID: api.userID ?? "", endpoint: endpoint,
                                body: try JSONSerialization.data(withJSONObject: outbound), cleanup: ownsCleanup,
                                itemID: endpoint.isEmpty ? "" : body["ItemId"] as? String ?? "")
            pending.removeAll { $0.report.server == report.server && $0.report.userID == report.userID && $0.report.itemID == report.itemID && $0.report.endpoint == "Sessions/Playing/Progress" }
            if ownsCleanup || endpoint == "Sessions/Playing/Progress" || endpoint == "Sessions/Playing/Stopped" {
                var latest = stored
                if !report.itemID.isEmpty {
                    latest = try latest.compactMap { previous in
                        guard previous.server == report.server, previous.userID == report.userID, previous.itemID == report.itemID else { return previous }
                        guard previous.cleanup, let body = try JSONSerialization.jsonObject(with: previous.body) as? [String: Any] else { return nil }
                        return Stored(id: previous.id, server: previous.server, userID: previous.userID, endpoint: "",
                                      body: try JSONSerialization.data(withJSONObject: Self.cleanupBody(body)), cleanup: true, itemID: "")
                    }
                }
                latest.append(report); stored = latest
            }
            pending.append(Entry(report: report, api: api)); drain()
        } catch { onFailure?("Watch progress couldn’t be saved on this device.") }
    }

    func retryStored(api: JellyfinAPI) async {
        for report in stored where report.server == api.server.absoluteString && report.userID == api.userID && (Self.allowsHistory(api) || report.cleanup) {
            if !Self.inFlight.contains(report.id) && workingID != report.id && !pending.contains(where: { $0.report.id == report.id }) { pending.append(Entry(report: report, api: api)) }
        }
        drain(); await flush()
    }
    func flush() async { await worker?.value }
    func pendingPosition(api: JellyfinAPI, itemID: String) -> Int64? {
        guard Self.allowsHistory(api), let entry = stored.last(where: { $0.server == api.server.absoluteString && $0.userID == api.userID && $0.itemID == itemID && !$0.endpoint.isEmpty }),
              let body = try? JSONSerialization.jsonObject(with: entry.body) as? [String: Any] else { return nil }
        return (body["PositionTicks"] as? NSNumber)?.int64Value
    }
    private func historyCompleted(_ id: UUID) {
        var latest = stored
        guard let index = latest.firstIndex(where: { $0.id == id }) else { return }
        let previous = latest[index]
        let body = (try? JSONSerialization.jsonObject(with: previous.body) as? [String: Any]) ?? [:]
        let resources = Self.cleanupBody(body)
        if previous.cleanup && Self.hasCleanup(resources), let data = try? JSONSerialization.data(withJSONObject: resources) {
            latest[index] = Stored(id: previous.id, server: previous.server, userID: previous.userID, endpoint: "", body: data, cleanup: true, itemID: "")
        } else { latest.remove(at: index) }
        stored = latest
    }
    private func cleanupCompleted(_ id: UUID, key: String) {
        var latest = stored
        guard let index = latest.firstIndex(where: { $0.id == id }), var body = try? JSONSerialization.jsonObject(with: latest[index].body) as? [String: Any] else { return }
        if key == "CleanupEncoder" { body[key] = false } else { body.removeValue(forKey: key) }
        let previous = latest[index]
        let remains = Self.hasCleanup(Self.cleanupBody(body))
        if previous.endpoint.isEmpty && !remains { latest.remove(at: index) }
        else if let data = try? JSONSerialization.data(withJSONObject: body) {
            latest[index] = Stored(id: previous.id, server: previous.server, userID: previous.userID, endpoint: previous.endpoint, body: data, cleanup: remains, itemID: previous.itemID)
        }
        stored = latest
    }
    private func drain() {
        guard worker == nil, !pending.isEmpty else { return }
        worker = Task { [weak self] in
            guard let self else { return }
            while !pending.isEmpty {
                let entry = pending.removeFirst()
                guard !Self.inFlight.contains(entry.report.id) else { continue }
                let report = stored.first(where: { $0.id == entry.report.id }) ?? entry.report
                Self.inFlight.insert(report.id); workingID = report.id
                if !report.endpoint.isEmpty && Self.allowsHistory(entry.api) {
                    var succeeded = false
                    for attempt in 0..<3 {
                        guard Self.allowsHistory(entry.api) else { break }
                        do {
                            var outbound = try JSONSerialization.jsonObject(with: report.body) as? [String: Any] ?? [:]
                            outbound.removeValue(forKey: "LiveStreamId"); outbound.removeValue(forKey: "CleanupEncoder")
                            var request = entry.api.request(report.endpoint, method: "POST", body: try JSONSerialization.data(withJSONObject: outbound))
                            request.timeoutInterval = 5
                            _ = try await entry.api.send(request); succeeded = true; break
                        } catch ReelError.unauthorized { break }
                        catch { if attempt < 2 { try? await Task.sleep(for: .seconds(attempt + 1)) } }
                    }
                    if succeeded { historyCompleted(report.id); onFailure?(nil) }
                    else if Self.allowsHistory(entry.api) { onFailure?("Watch progress is saved here and will retry when you reopen Reel or play again.") }
                }
                if report.cleanup, let body = try? JSONSerialization.jsonObject(with: report.body) as? [String: Any] {
                    let resources = Self.cleanupBody(body)
                    if let liveID = resources["LiveStreamId"] as? String {
                        do { try await entry.api.post("LiveStreams/Close", query: ["liveStreamId": liveID]); cleanupCompleted(report.id, key: "LiveStreamId") }
                        catch { onFailure?("Live-stream cleanup is saved and will retry when the server is reachable.") }
                    }
                    if resources["CleanupEncoder"] as? Bool == true, let sessionID = resources["PlaySessionId"] as? String {
                        do {
                            var request = entry.api.request("Videos/ActiveEncodings", query: ["deviceId": entry.api.deviceID, "playSessionId": sessionID], method: "DELETE")
                            request.timeoutInterval = 5
                            _ = try await entry.api.send(request); cleanupCompleted(report.id, key: "CleanupEncoder")
                        } catch { onFailure?("Encoder cleanup is saved and will retry when the server is reachable.") }
                    }
                }
                Self.inFlight.remove(report.id)
            }
            workingID = nil; worker = nil
        }
    }
}

@MainActor enum PlaybackAudio {
    static var tail: Task<Void, Never>?
    static func activate(mode: AVAudioSession.Mode = .moviePlayback) async throws {
        let previous = tail
        let action = Task {
            await previous?.value
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: mode)
            _ = try await AVAudioSession.sharedInstance().activate(options: [])
        }
        tail = Task { _ = try? await action.value }
        try await action.value
    }
    static func deactivate() {
        let previous = tail
        tail = Task {
            await previous?.value
            _ = try? await AVAudioSession.sharedInstance().deactivate(options: .notifyOthersOnDeactivation)
        }
    }
}

@MainActor enum PlaybackSubtitleSelection {
    struct NativeOption: Equatable {
        let titles: [String]
        let language: String?
        let playable: Bool
    }

    enum SelectionError: LocalizedError {
        case unavailable
        var errorDescription: String? {
            "The selected subtitles couldn’t be matched safely. Return to Details and choose another subtitle track or Off."
        }
    }

    @MainActor struct Prepared {
        let group: AVMediaSelectionGroup?
        let option: AVMediaSelectionOption?
        func apply(to item: AVPlayerItem) {
            if let group { item.select(option, in: group) }
        }
    }

    static func optionIndex(requested: Int, streams: [MediaStream], options: [NativeOption]) throws -> Int {
        let subtitles = streams.filter { $0.Type == "Subtitle" }
        let requestedStreams = subtitles.filter { $0.Index == requested }
        guard requestedStreams.count == 1, let requestedStream = requestedStreams.first else { throw SelectionError.unavailable }
        let title = normalizedTitle(requestedStream.DisplayTitle)
        if let title {
            guard subtitles.filter({ normalizedTitle($0.DisplayTitle) == title }).count == 1 else { throw SelectionError.unavailable }
            let matches = options.indices.filter {
                !languagesConflict(requestedStream.Language, options[$0].language)
                    && options[$0].titles.contains(where: { normalizedTitle($0) == title })
            }
            if matches.count == 1 {
                guard options[matches[0]].playable else { throw SelectionError.unavailable }
                return matches[0]
            }
            if matches.count > 1 { throw SelectionError.unavailable }
        }
        // Missing names are safe only with a strict one-to-one source mapping.
        // A conflicting name or language is never replaced by an array guess.
        guard subtitles.count == 1, options.count == 1, options[0].playable,
              !languagesConflict(requestedStream.Language, options[0].language),
              title == nil || options[0].titles.allSatisfy({ normalizedTitle($0) == nil }) else { throw SelectionError.unavailable }
        return 0
    }

    static func languagesConflict(_ left: String?, _ right: String?) -> Bool {
        PlaybackAudioSelection.languagesConflict(left, right)
    }

    private static func normalizedTitle(_ value: String?) -> String? {
        guard let value else { return nil }
        let title = value.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return title.isEmpty ? nil : title
    }

    static func isEncoded(source: MediaSource, selected: MediaStream?) -> Bool {
        PlaybackSubtitlePlan.isEncoded(source: source, selected: selected)
    }

    static func encodedDelivery(source: MediaSource, selected: MediaStream?, requested: Int, route: PlaybackSubtitlePlan.Route = .transcode) throws -> Bool {
        do { return try PlaybackSubtitlePlan.encodedDelivery(source: source, selected: selected, requested: requested, route: route) }
        catch { throw SelectionError.unavailable }
    }

    static func prepare(asset: AVURLAsset, requested: Int?, source: MediaSource, streams: [MediaStream], route: PlaybackSubtitlePlan.Route = .transcode) async throws -> Prepared {
        try Task.checkCancellation()
        guard let requested else { return Prepared(group: nil, option: nil) }
        guard requested >= -1 else { throw SelectionError.unavailable }
        let selectedStreams = streams.filter { $0.Type == "Subtitle" && $0.Index == requested }
        if requested >= 0, selectedStreams.count != 1 { throw SelectionError.unavailable }
        let selected = selectedStreams.count == 1 ? selectedStreams.first : nil
        if try encodedDelivery(source: source, selected: selected, requested: requested, route: route) {
            return Prepared(group: nil, option: nil)
        }
        let group: AVMediaSelectionGroup?
        do { group = try await asset.loadMediaSelectionGroup(for: .legible) }
        catch is CancellationError { throw CancellationError() }
        catch { try Task.checkCancellation(); throw error }
        try Task.checkCancellation()
        guard let group else {
            if requested == -1 { return Prepared(group: nil, option: nil) }
            throw SelectionError.unavailable
        }
        if requested == -1 {
            guard group.allowsEmptySelection else { throw SelectionError.unavailable }
            return Prepared(group: group, option: nil)
        }
        let options = group.options
        var descriptions: [NativeOption] = []
        for option in options {
            var titles: [String] = []
            for metadata in option.commonMetadata where metadata.commonKey == .commonKeyTitle {
                do { if let title = try await metadata.load(.stringValue) { titles.append(title) } }
                catch is CancellationError { throw CancellationError() }
                catch { try Task.checkCancellation(); throw error }
                try Task.checkCancellation()
            }
            descriptions.append(NativeOption(titles: titles, language: option.extendedLanguageTag, playable: option.isPlayable))
        }
        let index = try optionIndex(requested: requested, streams: streams, options: descriptions)
        return Prepared(group: group, option: options[index])
    }
}

private final class PlaybackMediaSelectionRevision: Sendable {
    private let revision = Mutex<Int>(0)
    var value: Int { revision.withLock { $0 } }
    func changed() { revision.withLock { $0 &+= 1 } }
}

@MainActor private enum PlaybackNativeAudio {
    typealias Option = PlaybackAudioSelection.NativeOption
    @MainActor struct Prepared {
        let group: AVMediaSelectionGroup?
        let option: AVMediaSelectionOption?
        func apply(to item: AVPlayerItem) { if let group { item.select(option, in: group) } }
    }
    static func describe(_ option: AVMediaSelectionOption, admitted: () -> Bool) async throws -> Option {
        var titles: [String] = []
        for metadata in option.commonMetadata where metadata.commonKey == .commonKeyTitle {
            try Task.checkCancellation()
            guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
            if let title = try await metadata.load(.stringValue) { titles.append(title) }
            try Task.checkCancellation()
            guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        }
        let characteristics: [(AVMediaCharacteristic, PlaybackAudioSelection.Role)] = [
            (.isAuxiliaryContent, .auxiliary), (.describesVideoForAccessibility, .description),
            (.isOriginalContent, .original), (.languageTranslation, .translation),
            (.dubbedTranslation, .dubbed), (.voiceOverTranslation, .voiceOver),
            (.containsOnlyForcedSubtitles, .forced), (.transcribesSpokenDialogForAccessibility, .sdh),
            (.describesMusicAndSoundForAccessibility, .sdh)
        ]
        return Option(titles: titles, language: option.extendedLanguageTag,
                      roles: Set(characteristics.compactMap { option.hasMediaCharacteristic($0.0) ? $0.1 : nil }),
                      playable: option.isPlayable)
    }
    static func describe(_ group: AVMediaSelectionGroup, admitted: () -> Bool) async throws -> ([AVMediaSelectionOption], [Option]) {
        let options = group.options
        var values: [Option] = []
        for option in options { values.append(try await describe(option, admitted: admitted)) }
        return (options, values)
    }
    static func prepare(asset: AVAsset, requested: Int?, identity: Option?, source: MediaSource?,
                        characteristic: AVMediaCharacteristic = .audible, emptySelection: Bool = false,
                        admitted: () -> Bool) async throws -> Prepared {
        guard requested != nil || identity != nil || emptySelection else { return Prepared(group: nil, option: nil) }
        try Task.checkCancellation()
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        let group = try await asset.loadMediaSelectionGroup(for: characteristic)
        try Task.checkCancellation()
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        guard let group else {
            if identity != nil, source == nil { throw PlaybackAudioSelection.SelectionError.unavailable }
            return Prepared(group: nil, option: nil)
        }
        if emptySelection {
            guard group.allowsEmptySelection else { throw PlaybackSubtitleSelection.SelectionError.unavailable }
            return Prepared(group: group, option: nil)
        }
        let (options, values) = try await describe(group, admitted: admitted)
        let index: Int
        if let source, let requested {
            index = try PlaybackAudioSelection.optionIndex(requested: requested, options: values, source: source)
        } else if let identity {
            index = try PlaybackAudioSelection.optionIndex(identity: identity, options: values)
        } else { throw PlaybackAudioSelection.SelectionError.unavailable }
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        return Prepared(group: group, option: options[index])
    }
}

@MainActor private final class PlaybackItemReference {
    weak var item: AVPlayerItem?
    init(_ item: AVPlayerItem) { self.item = item }
}

fileprivate struct PlaybackAudioAccount: Equatable, Sendable {
    let server: URL
    let userID: String?
    let token: String?
    let deviceID: String
    let headers: [GatewayHeader]
    init(_ api: JellyfinAPI) {
        server = api.server; userID = api.userID; token = api.token; deviceID = api.deviceID; headers = api.gatewayHeaders
    }
}

enum PlaybackStreamChange: Equatable {
    case audio(Int?), subtitle(Int?), version(String)

    func source(in item: MediaItem, currentSourceID: String?) throws -> MediaSource {
        let id: String?
        if case .version(let selected) = self { id = selected } else { id = currentSourceID }
        let matches = item.MediaSources?.filter { $0.Id == id } ?? []
        guard matches.count == 1, let source = matches.first, !source.Id.isEmpty else {
            throw PlaybackAudioSelection.SelectionError.unavailable
        }
        switch self {
        case .audio(let index):
            if let index {
                guard index >= 0, source.MediaStreams?.filter({ $0.Type == "Audio" && $0.Index == index }).count == 1 else {
                    throw PlaybackAudioSelection.SelectionError.unavailable
                }
            }
        case .subtitle(let index):
            if let index, index != -1 {
                guard index >= 0, source.MediaStreams?.filter({ $0.Type == "Subtitle" && $0.Index == index }).count == 1 else {
                    throw PlaybackSubtitleSelection.SelectionError.unavailable
                }
            }
        case .version: break
        }
        return source
    }
}

@MainActor @Observable final class PlaybackController {
    var onWillPresent: (() -> Void)?
    var syncPlayManaged = false
    var syncPlayCommand: ((String, Int64?) -> Void)?
    var activeItem: MediaItem?
    private(set) var preparing = true
    private(set) var error: String?
    private(set) var syncError: String?
    private(set) var audioSelectionError: String?
    private(set) var method = ""
    private(set) var ended = false
    private(set) var endedSessionID: UUID?
    private(set) var restartingEnded = false
    private(set) var isPlaying = false
    let player = AVPlayer()
    var speed: Float = 1 { didSet { player.defaultRate = speed; if player.rate > 0 { player.rate = speed } } }
    private(set) var sleepDeadline: Date?
    private var sleepTask: Task<Void, Never>?
    private var localURL: URL?
    private var requestedSourceID: String?
    private var requestedAudio: Int?
    private var requestedSubtitle: Int?
    var currentAudioDisclosure: PlaybackFormat.AudioDisclosure {
        if validatedAudioAvailable, validatedAudioRevision == audioRevision.value {
            if validatedAudioIsNative, let index = validatedAudioIndex { return .effective(index) }
            if !validatedAudioIsNative { return .serverIntent(validatedAudioIndex) }
        }
        if hasStarted || ended || localURL != nil { return .unresolved }
        return .serverIntent(requestedAudio)
    }
    var currentAudioIndex: Int? {
        switch currentAudioDisclosure {
        case .effective(let index): index
        case .serverIntent(let index): index ?? source?.DefaultAudioStreamIndex
        case .unresolved: nil
        }
    }
    var currentSubtitleIndex: Int? { requestedSubtitle ?? source?.DefaultSubtitleStreamIndex }
    private var gateway: PlaybackGateway?
    var currentMediaSource: MediaSource? { source }
    var currentBitrate: Int? { startContext.map { $0.bitrate ?? $0.quality.rawValue } }
    var currentSourceID: String? { source?.Id ?? requestedSourceID }
    private var source: MediaSource?
    private var playSessionID = ""
    private var api: JellyfinAPI?
    private var generation = UUID()
    private var cancelledPreparation: Task<Void, Never>?
    private var preparation: Task<Void, Never>?
    private var preparationDeadline: Task<Void, Never>?
    private var statusObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var heartbeat: Task<Void, Never>?
    private var periodicObserver: Any?
    private var endObserver: NSObjectProtocol?
    private var jumpObserver: NSObjectProtocol?
    private var contentRequestID = UUID()
    private var explicitRestartTicks: Int64?
    private var endedRestartPriority = -1
    private struct StartContext {
        let api: JellyfinAPI
        let quality: StreamQuality
        let bitrate: Int?
    }
    private var startContext: StartContext?
    private var lastReported = Date.distantPast
    private var offset: Double = 0
    private var hasStarted = false
    private var starting = false
    private var startupPaused = false
    private var didFallback = false
    private var recoveryTicks: Int64?
    private var fromBeginning = false
    private let reporter = PlaybackReporter()
    private let beforeInitialPlayback: (@MainActor () async -> Void)?
    private let beforeAudioCapture: (@MainActor () async -> Void)?
    private let audioOwner = UUID()
    private var audioRevision = PlaybackMediaSelectionRevision()
    private var audioObserver: NSObjectProtocol?
    private var audioRefresh: Task<Void, Never>?
    private var audioRefreshID = UUID()
    private var audioObservedSource: MediaSource?
    private var audioReplacement: Task<Void, Never>?
    private var audioReplacementID: UUID?
    var resolvingReplacement: Bool { audioReplacement != nil }
    private var validatedAudioIndex: Int?
    private var validatedAudioRevision = 0
    private var validatedAudioAvailable = false
    private var validatedAudioIsNative = false
    private var localAudioIdentity: PlaybackAudioSelection.NativeOption?
    private var localSubtitleIdentity: PlaybackAudioSelection.NativeOption?
    private var localSubtitlesOff = false
    private var returnAudioChoice: RetainedAudioChoice?
    private var activeAudioRestore: AudioRestoreIntent?
    private var cancelledAudioWork: Task<Void, Never>?

    init(beforeInitialPlayback: (@MainActor () async -> Void)? = nil,
         beforeAudioCapture: (@MainActor () async -> Void)? = nil) {
        self.beforeInitialPlayback = beforeInitialPlayback
        self.beforeAudioCapture = beforeAudioCapture
        player.automaticallyWaitsToMinimizeStalling = true
        reporter.onFailure = { [weak self] message in self?.syncError = message }
    }

    @MainActor final class CapturedAudioChoice {
        let audioIndex: Int?
        let mediaSourceID: String?
        let subtitleIndex: Int?
        fileprivate let capturesSubtitles: Bool
        fileprivate let subtitleProvider: MediaStream?
        fileprivate let subtitleIdentity: PlaybackAudioSelection.NativeOption?
        fileprivate let subtitlesOff: Bool
        fileprivate let owner: UUID
        fileprivate let generation: UUID
        fileprivate weak var item: AVPlayerItem?
        fileprivate let itemID: String
        fileprivate let source: MediaSource?
        fileprivate let account: PlaybackAudioAccount?
        fileprivate let localURL: URL?
        fileprivate let revision: PlaybackMediaSelectionRevision
        fileprivate let revisionValue: Int
        fileprivate let identity: PlaybackAudioSelection.NativeOption?
        fileprivate let provider: MediaStream?
        fileprivate init(audioIndex: Int?, mediaSourceID: String?, owner: UUID, generation: UUID,
                         item: AVPlayerItem, itemID: String, source: MediaSource?, account: PlaybackAudioAccount?,
                         localURL: URL?, revision: PlaybackMediaSelectionRevision, revisionValue: Int,
                         identity: PlaybackAudioSelection.NativeOption?, provider: MediaStream?,
                         subtitleIndex: Int? = nil, capturesSubtitles: Bool = false, subtitleProvider: MediaStream? = nil,
                         subtitleIdentity: PlaybackAudioSelection.NativeOption? = nil, subtitlesOff: Bool = false) {
            self.subtitleIdentity = subtitleIdentity; self.subtitlesOff = subtitlesOff
            self.subtitleIndex = subtitleIndex; self.capturesSubtitles = capturesSubtitles; self.subtitleProvider = subtitleProvider
            self.audioIndex = audioIndex; self.mediaSourceID = mediaSourceID; self.owner = owner; self.generation = generation
            self.item = item; self.itemID = itemID; self.source = source; self.account = account; self.localURL = localURL
            self.revision = revision; self.revisionValue = revisionValue; self.identity = identity; self.provider = provider
        }
    }
    struct AudioRestoreIntent: Sendable {
        fileprivate let itemID: String
        fileprivate let sourceID: String?
        fileprivate let account: PlaybackAudioAccount?
        fileprivate let index: Int?
        fileprivate let identity: PlaybackAudioSelection.NativeOption?
        fileprivate let provider: MediaStream?
        fileprivate let subtitleIndex: Int?
        fileprivate let capturesSubtitles: Bool
        fileprivate let subtitleProvider: MediaStream?
        fileprivate let subtitleIdentity: PlaybackAudioSelection.NativeOption?
        fileprivate let subtitlesOff: Bool
    }
    private typealias RetainedAudioChoice = AudioRestoreIntent

    func captureCurrentAudioChoice(api expectedAPI: JellyfinAPI? = nil) async throws -> CapturedAudioChoice {
        try await captureAudioChoice(api: expectedAPI, useTestGate: true)
    }
    func captureCurrentPlaybackChoices(api expectedAPI: JellyfinAPI? = nil) async throws -> CapturedAudioChoice {
        try await captureAudioChoice(api: expectedAPI, useTestGate: true, includeSubtitles: true)
    }
    private func captureAudioChoice(api expectedAPI: JellyfinAPI?, useTestGate: Bool, includeSubtitles: Bool = false) async throws -> CapturedAudioChoice {
        try Task.checkCancellation()
        guard !preparing, let item = player.currentItem, let itemID = activeItem?.id,
              item.status == .readyToPlay || item.status == .failed,
              localURL != nil || source != nil || audioObservedSource != nil else { throw PlaybackAudioSelection.SelectionError.stale }
        let account = api.map(PlaybackAudioAccount.init)
        if let expectedAPI, account != PlaybackAudioAccount(expectedAPI) { throw PlaybackAudioSelection.SelectionError.stale }
        let capture = CapturedAudioChoice(audioIndex: requestedAudio, mediaSourceID: source?.Id ?? audioObservedSource?.Id ?? requestedSourceID,
                                         owner: audioOwner, generation: generation, item: item, itemID: itemID,
                                         source: source ?? audioObservedSource, account: account, localURL: localURL,
                                         revision: audioRevision, revisionValue: audioRevision.value, identity: nil, provider: nil)
        let admitted = { [weak self] in self?.ownsAudioCapture(capture) == true }
        if useTestGate, let beforeAudioCapture { await beforeAudioCapture() }
        try Task.checkCancellation()
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        let group = try await item.asset.loadMediaSelectionGroup(for: .audible)
        try Task.checkCancellation()
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        // No audible group preserves the existing server intent; it never invents a native track identity.
        var index = requestedAudio
        var identity: PlaybackAudioSelection.NativeOption?
        var provider: MediaStream?
        if let group {
            guard let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { throw PlaybackAudioSelection.SelectionError.unavailable }
            let (_, options) = try await PlaybackNativeAudio.describe(group, admitted: admitted)
            let selectedIdentity = try await PlaybackNativeAudio.describe(selected, admitted: admitted)
            identity = selectedIdentity
            if let source = capture.source {
                if let served = PlaybackAudioSelection.servedIndex(method: method, nativeOptions: options.count, requested: requestedAudio, source: source) {
                    index = served
                } else {
                    index = try PlaybackAudioSelection.providerIndex(selected: selectedIdentity, options: options, source: source)
                }
                provider = source.MediaStreams?.first(where: { $0.Type == "Audio" && $0.Index == index })
            } else {
                _ = try PlaybackAudioSelection.optionIndex(identity: selectedIdentity, options: options)
                index = nil
            }
        }
        var subtitle = requestedSubtitle
        var subtitleProvider: MediaStream?
        var subtitleIdentity: PlaybackAudioSelection.NativeOption?
        var subtitlesOff = false
        if includeSubtitles {
            (subtitle, subtitleProvider, subtitleIdentity, subtitlesOff) = try await captureSubtitles(item: item, source: capture.source, admitted: admitted)
        }
        try Task.checkCancellation()
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        return CapturedAudioChoice(audioIndex: index, mediaSourceID: capture.mediaSourceID, owner: capture.owner,
                                   generation: capture.generation, item: item, itemID: itemID, source: capture.source,
                                   account: account, localURL: capture.localURL, revision: capture.revision,
                                   revisionValue: capture.revisionValue, identity: identity, provider: provider,
                                   subtitleIndex: subtitle, capturesSubtitles: includeSubtitles, subtitleProvider: subtitleProvider,
                                   subtitleIdentity: subtitleIdentity, subtitlesOff: subtitlesOff)
    }

    private func captureSubtitles(item: AVPlayerItem, source: MediaSource?, admitted: () -> Bool) async throws -> (Int?, MediaStream?, PlaybackAudioSelection.NativeOption?, Bool) {
        let streams = source?.MediaStreams ?? []
        if let source, let index = requestedSubtitle ?? source.DefaultSubtitleStreamIndex, index >= 0 {
            let selected = streams.filter { $0.Type == "Subtitle" && $0.Index == index }
            if selected.count == 1, try PlaybackSubtitleSelection.encodedDelivery(source: source, selected: selected.first, requested: index, route: method == "DirectPlay" ? .directPlay : .transcode) {
                return (index, selected.first, nil, false)
            }
        }
        let group = try await item.asset.loadMediaSelectionGroup(for: .legible)
        try Task.checkCancellation()
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        guard let group else { return (requestedSubtitle, nil, nil, false) }
        guard let selected = item.currentMediaSelection.selectedMediaOption(in: group) else {
            guard group.allowsEmptySelection else { throw PlaybackSubtitleSelection.SelectionError.unavailable }
            return (-1, nil, nil, true)
        }
        let (_, options) = try await PlaybackNativeAudio.describe(group, admitted: admitted)
        let identity = try await PlaybackNativeAudio.describe(selected, admitted: admitted)
        let selectedNative: Int
        do { selectedNative = try PlaybackAudioSelection.optionIndex(identity: identity, options: options) }
        catch { throw PlaybackSubtitleSelection.SelectionError.unavailable }
        guard source != nil else {
            // The local semantic identity is restored on the new file item; this is never a server stream index.
            return (requestedSubtitle, nil, identity, false)
        }
        let descriptors = options.map { PlaybackSubtitleSelection.NativeOption(titles: $0.titles, language: $0.language, playable: $0.playable) }
        let candidates = streams.filter { stream in
            guard stream.Type == "Subtitle" else { return false }
            return (try? PlaybackSubtitleSelection.optionIndex(requested: stream.Index, streams: streams, options: descriptors)) == selectedNative
        }
        guard candidates.count == 1, let candidate = candidates.first,
              !(identity.roles.contains(.forced) && candidate.IsForced == false),
              !(identity.roles.contains(.sdh) && candidate.IsHearingImpaired == false) else {
            throw PlaybackSubtitleSelection.SelectionError.unavailable
        }
        guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
        return (candidate.Index, candidate, identity, false)
    }

    func audioRestoreIntent(from capture: CapturedAudioChoice) throws -> AudioRestoreIntent {
        guard ownsAudioCapture(capture) else { throw PlaybackAudioSelection.SelectionError.stale }
        return AudioRestoreIntent(itemID: capture.itemID, sourceID: capture.mediaSourceID, account: capture.account,
                                  index: capture.audioIndex, identity: capture.identity, provider: capture.provider,
                                  subtitleIndex: capture.subtitleIndex, capturesSubtitles: capture.capturesSubtitles, subtitleProvider: capture.subtitleProvider,
                                  subtitleIdentity: capture.subtitleIdentity, subtitlesOff: capture.subtitlesOff)
    }
    func castSelection(from capture: CapturedAudioChoice) throws -> PlaybackTrackSelection {
        guard ownsAudioCapture(capture), capture.localURL == nil, capture.capturesSubtitles,
              let source = capture.source, source.Id == capture.mediaSourceID else { throw PlaybackAudioSelection.SelectionError.stale }
        var index = capture.audioIndex
        var provider = capture.provider
        if provider == nil {
            let streams = source.MediaStreams?.filter { $0.Type == "Audio" } ?? []
            if let index, index >= 0 {
                let matches = streams.filter { $0.Index == index }
                guard matches.count == 1 else { throw PlaybackAudioSelection.SelectionError.unavailable }
                provider = matches.first
            } else if streams.count == 1, let only = streams.first, only.Index >= 0 {
                // An inline single-audio asset has no selection group. Uniqueness is not a default tie-breaker.
                index = only.Index; provider = only
            } else if !streams.isEmpty { throw PlaybackAudioSelection.SelectionError.unavailable }
        }
        let selection = PlaybackTrackSelection(sourceID: source.Id, audioIndex: index, audio: provider,
                                               subtitleIndex: capture.subtitleIndex, subtitle: capture.subtitleProvider)
        try selection.validate(source)
        return selection
    }
    func isAudioCaptureCurrent(_ capture: CapturedAudioChoice) -> Bool { ownsAudioCapture(capture) }

    @discardableResult func commitHandoff(from capture: CapturedAudioChoice) -> Bool {
        guard capture.account != nil, capture.localURL == nil,
              let intent = try? audioRestoreIntent(from: capture) else { return false }
        stop()
        ended = false
        requestedAudio = intent.index; requestedSourceID = intent.sourceID
        if intent.capturesSubtitles { requestedSubtitle = intent.subtitleIndex }
        returnAudioChoice = intent
        return true
    }

    private func ownsAudioCapture(_ capture: CapturedAudioChoice) -> Bool {
        !Task.isCancelled && capture.owner == audioOwner && capture.generation == generation
            && capture.item != nil && player.currentItem === capture.item && activeItem?.id == capture.itemID
            && (source ?? audioObservedSource) == capture.source && localURL == capture.localURL
            && api.map(PlaybackAudioAccount.init) == capture.account && audioRevision === capture.revision
            && audioRevision.value == capture.revisionValue
    }
    private func installAudioObservation(item: AVPlayerItem, generation current: UUID) {
        let revision = PlaybackMediaSelectionRevision()
        audioRevision = revision; validatedAudioIndex = nil; validatedAudioRevision = 0; validatedAudioAvailable = false
        audioObservedSource = source
        let reference = PlaybackItemReference(item)
        jumpObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.timeJumpedNotification, object: item, queue: nil) { [weak self] _ in
            Task { @MainActor [weak self] in
                await Task.yield()
                guard let self, self.generation == current, self.player.currentItem === reference.item,
                      self.ended, !self.syncPlayManaged, let token = self.endedSessionID, let context = self.startContext else { return }
                let position = self.player.currentTime().seconds
                guard position.isFinite else { return }
                // Play often follows a seek on an ended item at once. Give it a moment to restart the
                // session playing through the rate observer before this restarts it paused.
                if self.player.rate == 0 {
                    try? await Task.sleep(for: .milliseconds(300))
                    guard self.generation == current, self.player.currentItem === reference.item,
                          self.ended, self.endedSessionID == token else { return }
                }
                self.restartEndedSession(token: token, at: position, initiallyPaused: self.player.rate == 0, context: context, priority: 0)
            }
        }
        audioObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.mediaSelectionDidChangeNotification, object: item, queue: nil) { [weak self] _ in
            revision.changed()
            Task { @MainActor [weak self] in
                guard let self, self.generation == current, self.audioRevision === revision else { return }
                self.validatedAudioAvailable = false
                self.refreshAudioSelection()
            }
        }
    }
    private func refreshAudioSelection() {
        guard !preparing, player.currentItem != nil else { return }
        cancelAndDrainAudio(audioRefresh)
        let id = UUID(); audioRefreshID = id
        audioRefresh = Task { [weak self] in
            guard let self else { return }
            defer { if audioRefreshID == id { audioRefresh = nil } }
            do {
                let capture = try await captureAudioChoice(api: api, useTestGate: false)
                guard audioRefreshID == id, ownsAudioCapture(capture) else { return }
                validatedAudioIndex = capture.audioIndex; validatedAudioRevision = capture.revisionValue
                validatedAudioAvailable = true; validatedAudioIsNative = capture.identity != nil
            } catch {
                if audioRefreshID == id, !Task.isCancelled { validatedAudioIndex = nil; validatedAudioRevision = -1; validatedAudioAvailable = false }
            }
        }
    }
    private func clearAudioObservation() {
        audioRefreshID = UUID()
        let refresh = audioRefresh, replacement = audioReplacement
        cancelAndDrainAudio(refresh)
        cancelAndDrainAudio(replacement)
        audioRefresh = nil; audioReplacement = nil; audioReplacementID = nil
        if let audioObserver { NotificationCenter.default.removeObserver(audioObserver) }
        audioObserver = nil; audioObservedSource = nil
        if let jumpObserver { NotificationCenter.default.removeObserver(jumpObserver) }
        jumpObserver = nil
        audioRevision = PlaybackMediaSelectionRevision(); validatedAudioIndex = nil; validatedAudioRevision = 0; validatedAudioAvailable = false
        // This runs only when the old item is being cleared/stopped, never for a nonfatal mapping failure.
        player.currentItem?.asset.cancelLoading()
    }

    private func cancelAndDrainAudio(_ task: Task<Void, Never>?) {
        guard let task else { return }
        task.cancel()
        let previous = cancelledAudioWork
        cancelledAudioWork = Task { await previous?.value; await task.value }
    }

    func present(_ item: MediaItem, audio: Int? = nil, subtitle: Int? = nil, fromBeginning: Bool = false, mediaSourceID: String? = nil,
                 startPositionTicks: Int64? = nil, audioRestore: AudioRestoreIntent? = nil) {
        onWillPresent?()
        stop()
        if let audioRestore { requestedAudio = audioRestore.index } else { requestedAudio = audio }
        requestedSubtitle = audioRestore?.capturesSubtitles == true ? audioRestore?.subtitleIndex : subtitle
        requestedSourceID = audioRestore?.sourceID ?? mediaSourceID
        activeAudioRestore = audioRestore; localAudioIdentity = audioRestore?.identity
        localSubtitleIdentity = audioRestore?.subtitleIdentity; localSubtitlesOff = audioRestore?.subtitlesOff ?? false
        activeItem = item; contentRequestID = UUID()
        preparing = true; error = nil; syncError = nil; ended = false; didFallback = false
        endedSessionID = nil; restartingEnded = false; endedRestartPriority = -1
        recoveryTicks = nil
        explicitRestartTicks = startPositionTicks.map { max(0, $0) }
        startupPaused = false
        self.fromBeginning = fromBeginning || startPositionTicks != nil
    }

    /// Change one stream choice without dismissing the player or resetting its sleep timer.
    func changeStreamSelection(_ change: PlaybackStreamChange, metadata: MediaItem, api expectedAPI: JellyfinAPI,
                               quality: StreamQuality, bitrate: Int? = nil) async throws {
        guard !syncPlayManaged, !preparing, !ended, !resolvingReplacement, error == nil, localURL == nil,
              let activeItem, activeItem.id == metadata.id, let native = player.currentItem,
              native.status == .readyToPlay, api.map(PlaybackAudioAccount.init) == PlaybackAudioAccount(expectedAPI) else {
            throw PlaybackAudioSelection.SelectionError.unavailable
        }
        let current = generation
        let selectedSource = try change.source(in: metadata, currentSourceID: currentSourceID)
        let intent: AudioRestoreIntent
        switch change {
        case .version:
            // Stream indices belong to a version. A new version starts with that version's defaults.
            intent = AudioRestoreIntent(itemID: activeItem.id, sourceID: selectedSource.Id,
                                        account: PlaybackAudioAccount(expectedAPI), index: nil, identity: nil, provider: nil,
                                        subtitleIndex: nil, capturesSubtitles: true, subtitleProvider: nil,
                                        subtitleIdentity: nil, subtitlesOff: false)
        case .audio(let index):
            let capture = try await captureCurrentPlaybackChoices(api: expectedAPI)
            let preserved = try audioRestoreIntent(from: capture)
            intent = AudioRestoreIntent(itemID: preserved.itemID, sourceID: preserved.sourceID, account: preserved.account,
                                        index: index, identity: nil,
                                        provider: selectedSource.MediaStreams?.first { $0.Type == "Audio" && $0.Index == index },
                                        subtitleIndex: preserved.subtitleIndex, capturesSubtitles: true,
                                        subtitleProvider: preserved.subtitleProvider, subtitleIdentity: preserved.subtitleIdentity,
                                        subtitlesOff: preserved.subtitlesOff)
        case .subtitle(let index):
            let capture = try await captureCurrentAudioChoice(api: expectedAPI)
            let preserved = try audioRestoreIntent(from: capture)
            intent = AudioRestoreIntent(itemID: preserved.itemID, sourceID: preserved.sourceID, account: preserved.account,
                                        index: preserved.index, identity: preserved.identity, provider: preserved.provider,
                                        subtitleIndex: index, capturesSubtitles: true,
                                        subtitleProvider: selectedSource.MediaStreams?.first { $0.Type == "Subtitle" && $0.Index == index },
                                        subtitleIdentity: nil, subtitlesOff: index == -1)
        }
        try Task.checkCancellation()
        guard generation == current, player.currentItem === native, !syncPlayManaged, !preparing, !ended,
              api.map(PlaybackAudioAccount.init) == PlaybackAudioAccount(expectedAPI) else {
            throw PlaybackAudioSelection.SelectionError.stale
        }
        let seconds = player.currentTime().seconds + offset
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / ticksPerSecond else {
            throw PlaybackAudioSelection.SelectionError.unavailable
        }
        let paused = player.rate == 0
        // Finish the old report with its original source and track identities before replacing choices.
        if hasStarted {
            report("Sessions/Playing/Stopped", cleanup: method == "Transcode" || source?.RequiresClosing == true)
            hasStarted = false
        }
        self.activeItem?.MediaSources = metadata.MediaSources
        explicitRestartTicks = Int64(seconds * ticksPerSecond)
        recoveryTicks = explicitRestartTicks
        requestedSourceID = intent.sourceID; requestedAudio = intent.index; requestedSubtitle = intent.subtitleIndex
        activeAudioRestore = intent; didFallback = false
        startResolved(api: expectedAPI, quality: quality, forceHLS: false, bitrate: bitrate, initiallyPaused: paused)
    }

    func resumeOnDevice(at seconds: Double, api: JellyfinAPI, quality: StreamQuality, bitrate: Int? = nil, initiallyPaused: Bool = false) {
        guard seconds.isFinite else { return }
        guard max(0, seconds) < Double(Int64.max) / ticksPerSecond else { return }
        recoveryTicks = Int64(max(0, seconds) * ticksPerSecond)
        explicitRestartTicks = recoveryTicks
        retry(api: api, quality: quality, bitrate: bitrate, initiallyPaused: initiallyPaused)
    }

    func retry(api: JellyfinAPI, quality: StreamQuality, bitrate: Int? = nil, initiallyPaused: Bool? = nil) {
        didFallback = false
        start(api: api, quality: quality, bitrate: bitrate, initiallyPaused: initiallyPaused)
    }

    func start(api: JellyfinAPI, quality: StreamQuality, forceHLS: Bool = false, bitrate: Int? = nil, initiallyPaused: Bool? = nil) {
        guard activeItem != nil else { return }
        if ended, explicitRestartTicks == nil, let token = endedSessionID {
            restartEndedSession(token: token, at: 0, initiallyPaused: initiallyPaused ?? true,
                                context: StartContext(api: api, quality: quality, bitrate: bitrate), priority: 2)
            return
        }
        if let retained = returnAudioChoice {
            guard retained.itemID == activeItem?.id, retained.account == PlaybackAudioAccount(api) else {
                audioSelectionError = PlaybackAudioSelection.SelectionError.stale.localizedDescription
                return
            }
            requestedAudio = retained.index; requestedSourceID = retained.sourceID
            if retained.capturesSubtitles { requestedSubtitle = retained.subtitleIndex }
            activeAudioRestore = retained; returnAudioChoice = nil
        }
        if player.currentItem != nil, !preparing, audioObservedSource != nil || localURL != nil {
            beginAudioReplacement(api: api, quality: quality, forceHLS: forceHLS, bitrate: bitrate, initiallyPaused: initiallyPaused)
        } else {
            startResolved(api: api, quality: quality, forceHLS: forceHLS, bitrate: bitrate, initiallyPaused: initiallyPaused)
        }
    }

    private func beginAudioReplacement(api: JellyfinAPI, quality: StreamQuality, forceHLS: Bool, bitrate: Int?, initiallyPaused: Bool?) {
        cancelAndDrainAudio(audioReplacement)
        let id = UUID(), current = generation
        audioReplacementID = id; audioSelectionError = nil
        audioReplacement = Task { [weak self] in
            guard let self else { return }
            defer { if audioReplacementID == id { audioReplacementID = nil; audioReplacement = nil } }
            do {
                let capture = try await captureAudioChoice(api: localURL == nil ? api : nil, useTestGate: true, includeSubtitles: true)
                guard audioReplacementID == id, generation == current else { throw CancellationError() }
                let intent = try audioRestoreIntent(from: capture)
                requestedAudio = intent.index; requestedSourceID = intent.sourceID ?? requestedSourceID
                if intent.capturesSubtitles { requestedSubtitle = intent.subtitleIndex }
                activeAudioRestore = intent; localAudioIdentity = intent.identity
                localSubtitleIdentity = intent.subtitleIdentity; localSubtitlesOff = intent.subtitlesOff
                audioReplacement = nil; audioReplacementID = nil
                startResolved(api: api, quality: quality, forceHLS: forceHLS, bitrate: bitrate, initiallyPaused: initiallyPaused)
            } catch {
                guard audioReplacementID == id, generation == current, !Task.isCancelled else { return }
                let message: String
                if let subtitleError = error as? PlaybackSubtitleSelection.SelectionError { message = subtitleError.localizedDescription }
                else { message = (error as? PlaybackAudioSelection.SelectionError)?.localizedDescription
                    ?? PlaybackAudioSelection.SelectionError.unavailable.localizedDescription }
                restartingEnded = false; endedRestartPriority = -1; explicitRestartTicks = nil
                if player.currentItem?.status == .failed { self.error = message }
                else { audioSelectionError = message }
            }
        }
    }

    private func startResolved(api: JellyfinAPI, quality: StreamQuality, forceHLS: Bool, bitrate: Int?, initiallyPaused: Bool?) {
        guard var item = activeItem else { return }
        if let intent = activeAudioRestore, localURL == nil {
            guard intent.itemID == item.id, intent.account == PlaybackAudioAccount(api),
                  intent.sourceID == requestedSourceID else {
                audioSelectionError = PlaybackAudioSelection.SelectionError.stale.localizedDescription
                return
            }
        }
        audioSelectionError = nil
        startContext = StartContext(api: api, quality: quality, bitrate: bitrate)
        endedSessionID = nil; restartingEnded = false; endedRestartPriority = -1
        if let initiallyPaused { startupPaused = initiallyPaused }
        let pausedChoice = startupPaused
        if let localURL { explicitRestartTicks = nil; startLocal(localURL, initiallyPaused: pausedChoice); return }
        if let explicitRestartTicks {
            if item.UserData == nil { item.UserData = UserData() }
            item.UserData?.PlaybackPositionTicks = explicitRestartTicks
            self.explicitRestartTicks = nil
        } else if source != nil, hasStarted, player.currentTime().seconds.isFinite {
            if item.UserData == nil { item.UserData = UserData() }
            item.UserData?.PlaybackPositionTicks = Int64(max(0, player.currentTime().seconds + offset) * ticksPerSecond)
        } else if let recoveryTicks {
            if item.UserData == nil { item.UserData = UserData() }
            item.UserData?.PlaybackPositionTicks = recoveryTicks
        }
        let baseItem = item
        let subtitleChoice = requestedSubtitle
        let audioChoice = requestedAudio
        let audioIntent = activeAudioRestore
        let refreshResume = source == nil && recoveryTicks == nil && !fromBeginning
        cancelPreparation()
        gateway?.close(); gateway = nil
        player.pause()
        if hasStarted { report("Sessions/Playing/Stopped", cleanup: method == "Transcode" || source?.RequiresClosing == true); hasStarted = false }
        else { cleanupPreparingStream() }
        clearObservers()
        player.replaceCurrentItem(with: nil)
        generation = UUID()
        let current = generation
        self.api = api
        player.allowsExternalPlayback = !syncPlayManaged && !api.isSimulatorPreview && api.gatewayHeaders.isEmpty
        preparing = true; error = nil; ended = false
        preparationDeadline = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, self.generation == current, self.preparing else { return }
            let attemptedContext = self.startContext
            self.stop()
            self.startContext = attemptedContext
            self.preparing = false
            self.error = "Jellyfin couldn’t start this stream. Try Original quality; the server’s transcoder may be unavailable."
        }
        preparation = Task { [weak self] in
            guard let self else { return }
            var unclaimedStreams: [String: MediaSource] = [:]
            var unclaimedEncoders: Set<String> = []
            defer {
                for id in unclaimedEncoders {
                    reporter.enqueue(api: api, endpoint: "", body: ["PlaySessionId": id, "CleanupEncoder": true], cleanup: true)
                }
                for (id, _) in unclaimedStreams {
                    reporter.enqueue(api: api, endpoint: "", body: ["LiveStreamId": id, "CleanupEncoder": false], cleanup: true)
                }
            }
            do {
                await reporter.retryStored(api: api)
                try Task.checkCancellation()
                var refreshed = baseItem
                if refreshResume {
                    let latest = try await api.item(baseItem.id)
                    refreshed.UserData = latest.UserData
                    if let pendingPosition = reporter.pendingPosition(api: api, itemID: baseItem.id) {
                        if refreshed.UserData == nil { refreshed.UserData = UserData() }
                        refreshed.UserData?.PlaybackPositionTicks = pendingPosition
                    }
                }
                let resumeItem = refreshed
                try await PlaybackAudio.activate()
                try Task.checkCancellation()
                var info = try await api.playback(resumeItem, quality: quality, audio: requestedAudio, subtitle: requestedSubtitle,
                                                  mediaSourceID: requestedSourceID ?? resumeItem.MediaSources?.first?.Id, forceHLS: forceHLS || didFallback, compatibilityMode: forceHLS || didFallback, bitrate: bitrate)
                for source in info.MediaSources where source.RequiresClosing == true {
                    if let id = source.LiveStreamId, !id.isEmpty { unclaimedStreams[id] = source }
                }
                if info.MediaSources.contains(where: { !($0.TranscodingUrl ?? "").isEmpty }), let id = info.PlaySessionId, !id.isEmpty { unclaimedEncoders.insert(id) }
                if Task.isCancelled || generation != current { throw CancellationError() }
                guard generation == current, info.ErrorCode == nil else { throw ReelError.noStream }
                let negotiated = try PlaybackAudioSelection.restorationSource(in: info.MediaSources, expectedID: audioIntent?.sourceID)
                let streams = negotiated.MediaStreams ?? resumeItem.MediaSources?.first?.MediaStreams ?? []
                if negotiated.SupportsDirectPlay == true,
                   streams.filter({ $0.Type == "Audio" }).count > 1 || (negotiated.DefaultSubtitleStreamIndex ?? -1) >= 0 {
                    info = try await api.playback(resumeItem, quality: quality, audio: requestedAudio ?? negotiated.DefaultAudioStreamIndex,
                                                  subtitle: requestedSubtitle ?? negotiated.DefaultSubtitleStreamIndex, mediaSourceID: negotiated.Id, forceHLS: true, compatibilityMode: forceHLS || didFallback, bitrate: bitrate, liveStreamID: negotiated.LiveStreamId)
                    for source in info.MediaSources where source.RequiresClosing == true {
                        if let id = source.LiveStreamId, !id.isEmpty { unclaimedStreams[id] = source }
                    }
                    if info.MediaSources.contains(where: { !($0.TranscodingUrl ?? "").isEmpty }), let id = info.PlaySessionId, !id.isEmpty { unclaimedEncoders.insert(id) }
                    if Task.isCancelled || generation != current { throw CancellationError() }
                }
                guard generation == current, info.ErrorCode == nil else { throw ReelError.noStream }
                let source = try PlaybackAudioSelection.restorationSource(in: info.MediaSources, expectedID: audioIntent?.sourceID)
                let sessionID = info.PlaySessionId ?? UUID().uuidString
                let stream = try api.streamURL(item: resumeItem, source: source, sessionID: sessionID)
                if let id = source.LiveStreamId { unclaimedStreams.removeValue(forKey: id) }
                self.source = source; self.playSessionID = sessionID; self.method = stream.method; self.offset = stream.offset
                unclaimedEncoders.remove(sessionID)
                var playbackURL = stream.url
                if !api.gatewayHeaders.isEmpty {
                    let lease = try await PlaybackGateway.create(api: api, sourceURL: stream.url)
                    guard generation == current, !Task.isCancelled else { lease.close(); throw CancellationError() }
                    self.gateway = lease
                    playbackURL = lease.localURL
                }
                let asset = AVURLAsset(url: playbackURL)
                let subtitleStreams = source.MediaStreams ?? resumeItem.MediaSources?.first(where: { $0.Id == source.Id })?.MediaStreams ?? []
                if let previous = audioIntent?.provider {
                    let selected = source.MediaStreams?.filter { $0.Type == "Audio" && $0.Index == previous.Index } ?? []
                    guard selected.count == 1, let next = selected.first,
                          PlaybackAudioSelection.sameProviderIdentity(previous, next) else {
                        throw PlaybackAudioSelection.SelectionError.unavailable
                    }
                }
                if let previous = audioIntent?.subtitleProvider {
                    let selected = source.MediaStreams?.filter { $0.Type == "Subtitle" && $0.Index == previous.Index } ?? []
                    guard selected.count == 1, let next = selected.first,
                          PlaybackAudioSelection.sameProviderIdentity(previous, next) else {
                        throw PlaybackSubtitleSelection.SelectionError.unavailable
                    }
                }
                let initialSubtitles: PlaybackSubtitleSelection.Prepared
                let initialAudio: PlaybackNativeAudio.Prepared
                do {
                    initialSubtitles = try await withTaskCancellationHandler {
                        try await PlaybackSubtitleSelection.prepare(asset: asset, requested: subtitleChoice, source: source, streams: subtitleStreams, route: stream.method == "DirectPlay" ? .directPlay : .transcode)
                    } onCancel: { asset.cancelLoading() }
                    initialAudio = try await withTaskCancellationHandler {
                        try await PlaybackNativeAudio.prepare(asset: asset, requested: audioChoice, identity: audioIntent?.identity, source: source) {
                            !Task.isCancelled && self.generation == current && self.requestedAudio == audioChoice
                                && self.activeItem?.id == resumeItem.id
                                && self.api.map(PlaybackAudioAccount.init) == PlaybackAudioAccount(api)
                        }
                    } onCancel: { asset.cancelLoading() }
                } catch is CancellationError { throw CancellationError() }
                catch let error as PlaybackSubtitleSelection.SelectionError { throw error }
                catch let error as PlaybackAudioSelection.SelectionError { throw error }
                catch {
                    try Task.checkCancellation()
                    guard generation == current else { throw CancellationError() }
                    if !didFallback {
                        recoveryTicks = resumeItem.resumeTicks
                        didFallback = true
                        start(api: api, quality: quality, forceHLS: true, bitrate: bitrate, initiallyPaused: startupPaused)
                        return
                    }
                    throw error
                }
                try Task.checkCancellation()
                guard generation == current, player.currentItem == nil, activeItem?.id == resumeItem.id,
                      self.api?.server == api.server, self.api?.userID == api.userID, self.api?.token == api.token,
                      requestedSubtitle == subtitleChoice, requestedAudio == audioChoice, startupPaused == pausedChoice else { throw CancellationError() }
                let avItem = AVPlayerItem(asset: asset)
                avItem.preferredForwardBufferDuration = 12
                statusObservation = avItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                    let status = observed.status
                    Task { @MainActor [weak observed] in
                        guard let self, let observed, self.generation == current,
                              self.player.currentItem === observed else { return }
                        switch status {
                        case .readyToPlay:
                            guard !self.hasStarted, !self.starting else { return }
                            self.starting = true
                            // Attachment can apply native caption preferences. Finish the
                            // explicit initial choice once, after readiness and resume.
                            self.preparation = Task { @MainActor [weak self, weak observed] in
                                guard let self, let observed else { return }
                                guard self.ownsStartup(observed, generation: current, api: api, itemID: resumeItem.id, subtitle: subtitleChoice, paused: pausedChoice) else { return }
                                if let beforeInitialPlayback = self.beforeInitialPlayback { await beforeInitialPlayback() }
                                guard self.ownsStartup(observed, generation: current, api: api, itemID: resumeItem.id, subtitle: subtitleChoice, paused: pausedChoice) else { return }
                                if resumeItem.resumeTicks > 0 {
                                    await self.player.seek(to: CMTime(seconds: Double(resumeItem.resumeTicks) / ticksPerSecond, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                                }
                                guard self.ownsStartup(observed, generation: current, api: api, itemID: resumeItem.id, subtitle: subtitleChoice, paused: pausedChoice) else { return }
                                initialAudio.apply(to: observed)
                                initialSubtitles.apply(to: observed)
                                self.hasStarted = true; self.starting = false
                                self.preparationDeadline?.cancel(); self.preparationDeadline = nil
                                self.preparing = false
                                self.refreshAudioSelection()
                                self.report("Sessions/Playing", paused: pausedChoice)
                                if self.syncPlayManaged || pausedChoice { self.player.pause(); self.isPlaying = false }
                                else { self.player.play(); self.isPlaying = true }
                            }
                        case .failed:
                            guard !self.ended else { return }
                            if self.hasStarted, self.player.currentTime().seconds.isFinite {
                                self.recoveryTicks = Int64(max(0, self.player.currentTime().seconds + self.offset) * ticksPerSecond)
                            } else { self.recoveryTicks = resumeItem.resumeTicks }
                            if !self.didFallback {
                                self.didFallback = true
                                self.start(api: api, quality: quality, forceHLS: true, bitrate: bitrate, initiallyPaused: self.startupPaused)
                            } else {
                                if self.hasStarted { self.report("Sessions/Playing/Stopped", cleanup: self.method == "Transcode" || self.source?.RequiresClosing == true); self.hasStarted = false }
                                else { self.cleanupPreparingStream() }
                                self.preparing = false
                                self.error = "This stream couldn’t be played. Try again, or choose a different audio or subtitle track in Details."
                            }
                        default: break
                        }
                    }
                }
                installAudioObservation(item: avItem, generation: current)
                player.replaceCurrentItem(with: avItem)
                rateObservation = player.observe(\.rate, options: [.new]) { [weak self] observed, _ in
                    let playing = observed.rate > 0
                    Task { @MainActor in
                        guard let self, self.generation == current else { return }
                        if self.ended, playing, !self.syncPlayManaged, let token = self.endedSessionID, let context = self.startContext {
                            let time = self.player.currentTime().seconds
                            let duration = self.player.currentItem?.duration.seconds ?? .nan
                            let target = time.isFinite && duration.isFinite && time < duration - 0.1 ? time : 0
                            self.restartEndedSession(token: token, at: target, initiallyPaused: false, context: context, priority: 1)
                            return
                        }
                        guard self.hasStarted else { return }
                        self.isPlaying = playing
                        if playing { self.startupPaused = false }
                        self.reportPauseState()
                    }
                }
                heartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .seconds(10)) } catch { return }
                        guard let self, self.generation == current else { return }
                        if self.hasStarted, !self.ended { self.report("Sessions/Playing/Progress") }
                    }
                }
                periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.hasStarted, !self.ended else { return }
                        self.isPlaying = self.player.rate > 0
                        if Date().timeIntervalSince(self.lastReported) >= 10 {
                            self.report("Sessions/Playing/Progress")
                        }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: avItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == current, self.hasStarted, !self.ended else { return }
                        self.endedSessionID = UUID(); self.ended = true; self.isPlaying = false
                        self.report("Sessions/Playing/Stopped", cleanup: self.method == "Transcode" || self.source?.RequiresClosing == true)
                        self.hasStarted = false
                    }
                }
            } catch is CancellationError { }
            catch let error as PlaybackSubtitleSelection.SelectionError {
                guard generation == current else { return }
                gateway?.close(); gateway = nil
                cleanupPreparingStream()
                preparationDeadline?.cancel(); preparationDeadline = nil
                preparing = false; self.error = error.localizedDescription
            }
            catch {
                guard generation == current else { return }
                gateway?.close(); gateway = nil
                cleanupPreparingStream()
                preparationDeadline?.cancel(); preparationDeadline = nil
                preparing = false; self.error = error.localizedDescription
            }
        }
    }

    /// Replay is a new owned playback session. An ended UI must supply its exact token.
    func replay(endedID: UUID? = nil, api: JellyfinAPI, quality: StreamQuality, bitrate: Int? = nil) async {
        if let endedID {
            guard ended, endedSessionID == endedID else { return }
        }
        guard !syncPlayManaged else { return }
        if ended, let token = endedSessionID {
            restartEndedSession(token: token, at: 0, initiallyPaused: false,
                                context: StartContext(api: api, quality: quality, bitrate: bitrate), priority: 2)
        } else {
            explicitRestartTicks = 0; recoveryTicks = 0; didFallback = false
            start(api: api, quality: quality, bitrate: bitrate, initiallyPaused: false)
        }
        let replacement = audioReplacement
        await replacement?.value
        await reporter.flush()
    }

    private func restartEndedSession(token: UUID, at seconds: Double, initiallyPaused: Bool,
                                     context: StartContext, priority: Int, managed: Bool = false) {
        guard ended, endedSessionID == token, !Task.isCancelled, !syncPlayManaged || managed,
              let activeItem, seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / ticksPerSecond,
              let previous = startContext, PlaybackAudioAccount(previous.api) == PlaybackAudioAccount(context.api) else { return }
        if restartingEnded, priority < endedRestartPriority { return }
        let duration = player.currentItem?.duration.seconds ?? Double(activeItem.RunTimeTicks ?? 0) / ticksPerSecond
        guard !duration.isFinite || duration <= 0 || seconds < duration - 0.01 else { return }
        endedRestartPriority = priority; restartingEnded = true
        // A cleaned session must not resume even briefly while its replacement choices are read.
        player.pause(); isPlaying = false
        explicitRestartTicks = Int64(seconds * ticksPerSecond); recoveryTicks = explicitRestartTicks
        didFallback = false
        start(api: context.api, quality: context.quality, bitrate: context.bitrate, initiallyPaused: initiallyPaused)
    }

    /// Called only by the accepted SyncPlay command scheduler, which rechecks its group/entry after this await.
    func seekForManagedPlayback(to ticks: Int64) async throws {
        guard syncPlayManaged, activeItem != nil else { throw CancellationError() }
        let content = contentRequestID, itemID = activeItem?.id
        if ended {
            guard let token = endedSessionID, let context = startContext else { throw ReelError.noStream }
            restartEndedSession(token: token, at: max(0, Double(ticks) / ticksPerSecond), initiallyPaused: true,
                                context: context, priority: 3, managed: true)
        }
        // A newer accepted group command can arrive while a prior fresh session is preparing.
        // Wait for that owned item, then apply only the latest scheduler's target.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ended || preparing || restartingEnded {
            try Task.checkCancellation()
            guard contentRequestID == content, activeItem?.id == itemID, syncPlayManaged else { throw CancellationError() }
            guard error == nil, audioSelectionError == nil, ContinuousClock.now < deadline else { throw ReelError.noStream }
            try await Task.sleep(for: .milliseconds(50))
        }
        try Task.checkCancellation()
        guard contentRequestID == content, activeItem?.id == itemID, syncPlayManaged,
              let currentItem = player.currentItem, currentItem.status == .readyToPlay else { throw CancellationError() }
        let current = generation
        let finished = await player.seek(to: CMTime(seconds: max(0, Double(ticks) / ticksPerSecond), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        try Task.checkCancellation()
        guard finished, generation == current, contentRequestID == content, player.currentItem === currentItem else { throw CancellationError() }
    }

    func reportPauseState() {
        saveLocalProgress()
        if hasStarted { report("Sessions/Playing/Progress") }
    }

    func flushReports() async { await cancelledAudioWork?.value; await cancelledPreparation?.value; await reporter.flush() }
    func retryReports(api: JellyfinAPI) async { await reporter.retryStored(api: api) }

    func togglePause() {
        if let syncPlayCommand { syncPlayCommand(player.rate > 0 ? "Pause" : "Unpause", nil); return }
        if ended, let token = endedSessionID, let context = startContext {
            restartEndedSession(token: token, at: 0, initiallyPaused: false, context: context, priority: 2)
            return
        }
        if player.rate > 0 { player.pause(); isPlaying = false }
        else { player.play(); isPlaying = true }
        reportPauseState()
    }

    func skip(_ seconds: Double) {
        let now = player.currentTime().seconds
        guard now.isFinite else { return }
        let duration = player.currentItem?.duration.seconds ?? .infinity
        let target = min(duration.isFinite ? duration : .infinity, max(0, now + seconds))
        if let syncPlayCommand { syncPlayCommand("Seek", Int64(target * ticksPerSecond)); return }
        seekLocally(to: target)
    }

    func seek(to ticks: Int64) {
        if let syncPlayCommand { syncPlayCommand("Seek", max(0, ticks)); return }
        seekLocally(to: max(0, Double(ticks) / ticksPerSecond))
    }

    private func seekLocally(to seconds: Double) {
        if ended, let token = endedSessionID, let context = startContext {
            restartEndedSession(token: token, at: seconds, initiallyPaused: true, context: context, priority: 2)
            return
        }
        let current = generation
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
            guard finished else { return }
            Task { @MainActor in
                guard let self, self.generation == current else { return }
                self.reportPauseState()
            }
        }
    }

    func setSleepTimer(minutes: Int?) { scheduleSleep(after: minutes.map { Double($0) * 60 }) }

    func scheduleSleep(after seconds: Double?) {
        sleepTask?.cancel(); sleepTask = nil
        sleepDeadline = seconds.map { Date().addingTimeInterval($0) }
        guard let seconds else { return }
        sleepTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            self?.player.pause(); self?.isPlaying = false; self?.sleepDeadline = nil
        }
    }

    func presentDownload(_ item: MediaItem, url: URL) {
        present(item, fromBeginning: true)
        localURL = url
    }

    private func startLocal(_ url: URL, initiallyPaused: Bool) {
        saveLocalProgress()
        cancelPreparation(); clearObservers()
        player.pause()
        self.api = nil; source = nil; method = "Offline"
        generation = UUID()
        let current = generation
        let audioIdentity = localAudioIdentity
        let subtitleIdentity = localSubtitleIdentity, subtitlesOff = localSubtitlesOff
        preparing = true; error = nil; ended = false
        preparation = Task { [weak self] in
            guard let self else { return }
            do {
                try await PlaybackAudio.activate()
                try Task.checkCancellation()
                guard generation == current else { return }
                let initialPosition = recoveryTicks.map { Double($0) / ticksPerSecond } ?? UserDefaults.standard.double(forKey: "offline-" + url.lastPathComponent)
                let asset = AVURLAsset(url: url)
                let audio = try await withTaskCancellationHandler {
                    try await PlaybackNativeAudio.prepare(asset: asset, requested: nil, identity: audioIdentity, source: nil) {
                        !Task.isCancelled && self.generation == current && self.localURL == url
                    }
                } onCancel: { asset.cancelLoading() }
                let subtitles = try await withTaskCancellationHandler {
                    try await PlaybackNativeAudio.prepare(asset: asset, requested: nil, identity: subtitleIdentity, source: nil,
                                                         characteristic: .legible, emptySelection: subtitlesOff) {
                        !Task.isCancelled && self.generation == current && self.localURL == url
                    }
                } onCancel: { asset.cancelLoading() }
                guard generation == current, !Task.isCancelled, localURL == url else { throw CancellationError() }
                let avItem = AVPlayerItem(asset: asset)
                statusObservation = avItem.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
                    let status = observed.status
                    Task { @MainActor [weak observed] in
                        guard let self, let observed, self.generation == current, self.player.currentItem === observed else { return }
                        if status == .readyToPlay {
                            guard self.preparing, !self.starting else { return }
                            self.starting = true
                            self.preparation = Task { @MainActor [weak self, weak observed] in
                                guard let self, let observed else { return }
                                guard self.ownsLocalStartup(observed, generation: current, paused: initiallyPaused) else { return }
                                if let beforeInitialPlayback = self.beforeInitialPlayback { await beforeInitialPlayback() }
                                guard self.ownsLocalStartup(observed, generation: current, paused: initiallyPaused) else { return }
                                var finishedResume = true
                                if initialPosition > 0 { finishedResume = await self.player.seek(to: CMTime(seconds: initialPosition, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) }
                                guard self.ownsLocalStartup(observed, generation: current, paused: initiallyPaused) else { return }
                                if finishedResume { self.recoveryTicks = nil }
                                audio.apply(to: observed)
                                subtitles.apply(to: observed)
                                self.starting = false; self.preparing = false
                                self.refreshAudioSelection()
                                if initiallyPaused { self.player.pause(); self.isPlaying = false }
                                else { self.player.play(); self.isPlaying = true }
                            }
                        } else if status == .failed {
                            self.starting = false
                            self.preparing = false; self.error = "This downloaded file cannot be played. Remove it and download a compatible version."
                        }
                    }
                }
                rateObservation = player.observe(\.rate, options: [.new]) { [weak self] observed, _ in
                    let playing = observed.rate > 0
                    Task { @MainActor in
                        if let self, self.generation == current {
                            if self.ended, playing, let token = self.endedSessionID, let context = self.startContext {
                                let time = self.player.currentTime().seconds
                                let duration = self.player.currentItem?.duration.seconds ?? .nan
                                let target = time.isFinite && duration.isFinite && time < duration - 0.1 ? time : 0
                                self.restartEndedSession(token: token, at: target, initiallyPaused: false, context: context, priority: 1)
                                return
                            }
                            self.isPlaying = playing
                            if playing, !self.preparing { self.startupPaused = false }
                        }
                    }
                }
                endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: avItem, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        guard let self, self.generation == current, !self.ended else { return }
                        self.endedSessionID = UUID(); self.ended = true; self.isPlaying = false
                        UserDefaults.standard.removeObject(forKey: "offline-" + url.lastPathComponent)
                    }
                }
                installAudioObservation(item: avItem, generation: current)
                player.replaceCurrentItem(with: avItem)
                periodicObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 3, preferredTimescale: 600), queue: .main) { [weak self] _ in
                    Task { @MainActor in if let self, self.generation == current { self.saveLocalProgress() } }
                }
            } catch is CancellationError { }
            catch { if generation == current { preparing = false; self.error = error.localizedDescription } }
        }
    }

    private func saveLocalProgress() {
        if let localURL, !preparing, !ended, player.currentItem?.status == .readyToPlay, player.currentTime().seconds.isFinite {
            UserDefaults.standard.set(max(0, player.currentTime().seconds), forKey: "offline-" + localURL.lastPathComponent)
        }
    }

    func stop() {
        if hasStarted, player.currentTime().seconds.isFinite {
            recoveryTicks = Int64(max(0, player.currentTime().seconds + offset) * ticksPerSecond)
        }
        gateway?.close(); gateway = nil
        saveLocalProgress()
        localURL = nil
        setSleepTimer(minutes: nil)
        cancelPreparation()
        generation = UUID()
        player.pause()
        isPlaying = false
        if hasStarted { report("Sessions/Playing/Stopped", cleanup: method == "Transcode" || source?.RequiresClosing == true) }
        else { cleanupPreparingStream() }
        hasStarted = false
        clearObservers()
        player.replaceCurrentItem(with: nil)
        source = nil; api = nil; method = ""
        activeAudioRestore = nil; returnAudioChoice = nil; localAudioIdentity = nil
        contentRequestID = UUID(); startContext = nil; explicitRestartTicks = nil
        endedSessionID = nil; restartingEnded = false; endedRestartPriority = -1
        localSubtitleIdentity = nil; localSubtitlesOff = false; audioSelectionError = nil
        PlaybackAudio.deactivate()
    }

    private func report(_ endpoint: String, cleanup: Bool = false, paused: Bool? = nil) {
        guard let api, let item = activeItem, let source else { return }
        let time = player.currentTime().seconds
        let position = max(0, (time.isFinite ? time : 0) + offset)
        var body: [String: any Sendable] = ["ItemId": item.id, "MediaSourceId": source.Id, "PlaySessionId": playSessionID,
            "PositionTicks": Int64(position * ticksPerSecond), "IsPaused": paused ?? (endpoint == "Sessions/Playing" ? false : player.timeControlStatus == .paused), "CanSeek": true,
            "PlayMethod": method, "Failed": error != nil]
        body["CleanupEncoder"] = method == "Transcode"
        if source.RequiresClosing == true { body["LiveStreamId"] = source.LiveStreamId }
        body["AudioStreamIndex"] = currentAudioIndex
        body["SubtitleStreamIndex"] = requestedSubtitle ?? source.DefaultSubtitleStreamIndex
        reporter.enqueue(api: api, endpoint: endpoint, body: body, cleanup: cleanup)
        if endpoint == "Sessions/Playing/Stopped", cleanup { self.source = nil }
        lastReported = Date()
    }

    private func cleanupPreparingStream() {
        guard method == "Transcode" || source?.RequiresClosing == true, source != nil, let api else { return }
        reporter.enqueue(api: api, endpoint: "", body: ["PlaySessionId": playSessionID, "LiveStreamId": source?.RequiresClosing == true ? source?.LiveStreamId ?? "" : "", "CleanupEncoder": method == "Transcode"], cleanup: true)
        source = nil
    }

    private func cancelPreparation() {
        guard let previous = preparation else { return }
        preparation = nil
        previous.cancel()
        let tail = cancelledPreparation
        cancelledPreparation = Task { await tail?.value; await previous.value }
    }

    private func ownsStartup(_ item: AVPlayerItem, generation: UUID, api: JellyfinAPI, itemID: String, subtitle: Int?, paused: Bool) -> Bool {
        !Task.isCancelled && self.generation == generation && starting && !hasStarted
            && player.currentItem === item && item.status == .readyToPlay && activeItem?.id == itemID
            && self.api?.server == api.server && self.api?.userID == api.userID && self.api?.token == api.token
            && requestedSubtitle == subtitle && startupPaused == paused
    }

    private func ownsLocalStartup(_ item: AVPlayerItem, generation: UUID, paused: Bool) -> Bool {
        !Task.isCancelled && self.generation == generation && starting && preparing
            && player.currentItem === item && item.status == .readyToPlay && startupPaused == paused && localURL != nil
    }

    private func clearObservers() {
        clearAudioObservation()
        starting = false
        preparationDeadline?.cancel(); preparationDeadline = nil
        statusObservation?.invalidate(); statusObservation = nil
        rateObservation?.invalidate(); rateObservation = nil
        heartbeat?.cancel(); heartbeat = nil
        if let periodicObserver { player.removeTimeObserver(periodicObserver); self.periodicObserver = nil }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver); self.endObserver = nil }
    }
}
