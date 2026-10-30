import Foundation
import Observation
import ImageIO
import UIKit
#if canImport(GoogleCast)
@preconcurrency import GoogleCast
#endif

struct TrickplayInfo: Codable, Hashable, Sendable {
    let Width: Int
    let Height: Int
    let TileWidth: Int
    let TileHeight: Int
    let ThumbnailCount: Int
    let Interval: Int

    var isValid: Bool {
        (1...2048).contains(Width) && (1...2048).contains(Height)
            && (1...50).contains(TileWidth) && (1...50).contains(TileHeight)
            && (1...10_000_000).contains(ThumbnailCount) && Interval > 0
            && Int64(Width) * Int64(Height) * Int64(TileWidth) * Int64(TileHeight) <= 32_000_000
    }
    func frame(at seconds: Double) -> TrickplayFrame? {
        guard isValid, seconds.isFinite else { return nil }
        let index = Int(min(Double(ThumbnailCount - 1), max(0, floor(seconds * 1000 / Double(Interval)))))
        let perSheet = TileWidth * TileHeight
        let cell = index % perSheet
        return TrickplayFrame(sheet: index / perSheet, thumbnail: index,
                              rect: CGRect(x: (cell % TileWidth) * Width, y: (cell / TileWidth) * Height, width: Width, height: Height))
    }
}

struct TrickplayFrame: Equatable, Sendable {
    let sheet: Int
    let thumbnail: Int
    let rect: CGRect
}

struct TrickplayMetadata: Decodable, Sendable {
    let Trickplay: [String: [String: TrickplayInfo]]?

    func selected(sourceID: String?, itemID: String) -> (source: String, info: TrickplayInfo)? {
        guard let Trickplay else { return nil }
        let source: String
        if let sourceID {
            guard Trickplay[sourceID] != nil else { return nil }
            source = sourceID
        } else if Trickplay[itemID] != nil { source = itemID }
        else { guard Trickplay.count == 1, let first = Trickplay.keys.first else { return nil }; source = first }
        let choices = Trickplay[source]?.values.filter(\.isValid).sorted { $0.Width < $1.Width } ?? []
        guard let info = choices.first(where: { $0.Width >= 240 }) ?? choices.last else { return nil }
        return (source, info)
    }
}

@MainActor @Observable final class TrickplayStore {
    private(set) var info: TrickplayInfo?
    private(set) var sourceID: String?
    private(set) var loading = false
    private(set) var unavailable = false
    @ObservationIgnored private var sheets: [Int: Data] = [:]
    @ObservationIgnored private var generation = UUID()

    func load(itemID: String, mediaSourceID: String?, api: JellyfinAPI) async {
        let current = UUID(); generation = current
        info = nil; sourceID = nil; sheets = [:]; loading = true; unavailable = false
        defer { if generation == current { loading = false } }
        do {
            let metadata: TrickplayMetadata = try await api.get("Items/\(itemID)", query: ["userId": api.userID ?? "", "fields": "Trickplay"])
            try Task.checkCancellation()
            guard generation == current else { return }
            if let selected = metadata.selected(sourceID: mediaSourceID, itemID: itemID) { sourceID = selected.source; info = selected.info }
            else { unavailable = true }
        } catch is CancellationError { }
        catch { if generation == current { unavailable = true } }
    }

    func thumbnail(itemID: String, seconds: Double, api: JellyfinAPI) async throws -> UIImage? {
        guard let info, let frame = info.frame(at: seconds), let sourceID else { return nil }
        let current = generation
        let data: Data
        if let cached = sheets[frame.sheet] { data = cached }
        else {
            let request = api.request("Videos/\(itemID)/Trickplay/\(info.Width)/\(frame.sheet).jpg", query: ["mediaSourceId": sourceID])
            data = try await api.send(request)
            try Task.checkCancellation()
            guard generation == current, data.count < 32 * 1024 * 1024 else { throw ReelError.invalidResponse }
            if sheets.count >= 2 { sheets.removeAll(keepingCapacity: true) }
            sheets[frame.sheet] = data
        }
        let rect = frame.rect
        let cropped = await Task.detached(priority: .userInitiated) {
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, Int64(width) * Int64(height) <= 32_000_000,
                  rect.maxX <= CGFloat(width), rect.maxY <= CGFloat(height),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil as CGImage? }
            return image.cropping(to: rect)
        }.value
        try Task.checkCancellation()
        guard generation == current, let cropped else { return nil }
        return UIImage(cgImage: cropped)
    }
}

struct CastPlaybackPlan: Sendable {
    let item: MediaItem
    let source: MediaSource
    let sessionID: String
    let url: URL
    let method: String
    let startPosition: Double
    let audioIndex: Int?
    let subtitleIndex: Int?
}

struct CastUserPermissions: Decodable, Sendable {
    struct UserPolicy: Decodable, Sendable {
        let IsDisabled: Bool?
        let EnableMediaPlayback: Bool?
        let EnableSharedDeviceControl: Bool?
        let EnableLiveTvAccess: Bool?
        let EnableVideoPlaybackTranscoding: Bool?
        let EnableAudioPlaybackTranscoding: Bool?
    }
    let Policy: UserPolicy
    func allows(_ item: MediaItem) -> Bool {
        Policy.IsDisabled != true && Policy.EnableMediaPlayback == true && Policy.EnableSharedDeviceControl == true
            && (item.Type != "TvChannel" || Policy.EnableLiveTvAccess == true)
    }
}

enum CastPlaybackError: LocalizedError {
    case permission, trackUnavailable, gateway, invalidBitrate
    var errorDescription: String? {
        switch self {
        case .invalidBitrate: "The selected stream quality is invalid. Choose another quality before casting."
        case .permission: "Your Jellyfin account doesn’t allow playback on shared devices. Ask your server administrator to enable it."
        case .trackUnavailable: "The selected audio or subtitle track isn’t available on this version. Choose another track in Details."
        case .gateway: "Cast receivers can’t supply this server’s gateway credentials. Play on iPhone or use a direct server connection."
        }
    }
}

enum CastBitratePolicy {
    static func receiverBitrate(_ effectiveBitrate: Int) throws -> Int {
        guard (250_000...120_000_000).contains(effectiveBitrate) else { throw CastPlaybackError.invalidBitrate }
        return min(effectiveBitrate, 20_000_000)
    }
}

enum CastSessionOwnership {
    static func hasPendingLoad(loading: Bool, hasPlan: Bool, established: Bool) -> Bool { loading || (hasPlan && !established) }
    static func mayStop(ownedContentID: String?, receiverContentID: String?, established: Bool,
                        sameSession: Bool, sameClient: Bool, connected: Bool) -> Bool {
        guard established, sameSession, sameClient, connected, let ownedContentID else { return false }
        return receiverContentID == nil || receiverContentID == ownedContentID
    }
    static func startPosition(local: Double, remote: Double?, remembered: Double?) -> Double {
        for candidate in [remote, remembered, local] {
            if let candidate, candidate.isFinite { return max(0, candidate) }
        }
        return 0
    }
}

@MainActor final class CastAccountWork {
    private struct Entry { let accountID: String; let task: Task<Void, Never> }
    private var tasks: [UUID: Entry] = [:]
    private var reporters: [String: PlaybackReporter] = [:]
    private var revision: UInt64 = 0
    private var accountRevisions: [String: UInt64] = [:]
    private func changed(_ id: String) { revision &+= 1; accountRevisions[id, default: 0] &+= 1 }
    private func version(_ id: String?) -> UInt64 { id.map { accountRevisions[$0, default: 0] } ?? revision }

    @discardableResult func track(accountID: String, operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.tasks.removeValue(forKey: id) }
            await operation()
        }
        tasks[id] = Entry(accountID: accountID, task: task)
        changed(accountID)
        return task
    }
    func enqueue(api: JellyfinAPI, endpoint: String, body: [String: any Sendable], cleanup: Bool) {
        let accountID = api.server.absoluteString + "|" + (api.userID ?? "")
        let reporter = reporters[accountID] ?? PlaybackReporter()
        reporters[accountID] = reporter
        changed(accountID)
        reporter.enqueue(api: api, endpoint: endpoint, body: body, cleanup: cleanup)
    }
    func flush(accountID: String? = nil) async {
        while true {
            for entry in tasks.values.filter({ accountID == nil || $0.accountID == accountID }) { await entry.task.value }
            let current = version(accountID)
            for reporter in reporters.filter({ accountID == nil || $0.key == accountID }).values { await reporter.flush() }
            if version(accountID) == current && !tasks.values.contains(where: { accountID == nil || $0.accountID == accountID }) { return }
        }
    }
}

enum CastTrackPolicy {
    static func permitsDirectPlay(source: MediaSource?, audioIndex: Int?, subtitleIndex: Int?) -> Bool {
        guard let source, let streams = source.MediaStreams else { return false }
        let audio = streams.filter { $0.Type == "Audio" }
        let selectedAudio = audioIndex ?? source.DefaultAudioStreamIndex
        let selectedSubtitle = subtitleIndex ?? source.DefaultSubtitleStreamIndex
        let directAudio = (audio.isEmpty && (selectedAudio == nil || selectedAudio == -1))
            || (audio.count == 1 && (selectedAudio == nil || selectedAudio == audio.first?.Index))
        // The default receiver does not honor Jellyfin's stream-index selection in a direct MP4.
        return directAudio && (selectedSubtitle == -1 || (selectedSubtitle == nil && !streams.contains { $0.Type == "Subtitle" }))
    }
}

extension JellyfinAPI {
    func prepareCast(_ item: MediaItem, position: Double, bitrate: Int, mediaSourceID: String? = nil, audioIndex: Int? = nil, subtitleIndex: Int? = nil, selection: PlaybackTrackSelection? = nil) async throws -> CastPlaybackPlan {
        guard !isSimulatorPreview else { throw ReelError.previewProtected }
        let receiverBitrate = try CastBitratePolicy.receiverBitrate(bitrate)
        guard gatewayHeaders.isEmpty else { throw CastPlaybackError.gateway }
        guard position.isFinite, position < Double(Int64.max) / ticksPerSecond else { throw ReelError.invalidResponse }
        async let permissionLoad: CastUserPermissions = get("Users/Me")
        async let itemLoad: MediaItem = self.item(item.id)
        let (permissions, detail) = try await (permissionLoad, itemLoad)
        guard detail.id == item.id else { throw CastPlaybackError.trackUnavailable }
        guard permissions.allows(detail) else { throw CastPlaybackError.permission }
        let selectedSource: MediaSource?
        if let selection {
            guard selection.sourceID == mediaSourceID, selection.audioIndex == audioIndex, selection.subtitleIndex == subtitleIndex else { throw CastPlaybackError.trackUnavailable }
            do { selectedSource = try selection.source(in: detail.MediaSources ?? []) }
            catch { throw CastPlaybackError.trackUnavailable }
        } else {
            selectedSource = detail.MediaSources?.first(where: { $0.Id == mediaSourceID }) ?? (mediaSourceID == nil ? detail.MediaSources?.first : nil)
        }
        if let streams = selectedSource?.MediaStreams {
            if let audioIndex, audioIndex >= 0, !streams.contains(where: { $0.Type == "Audio" && $0.Index == audioIndex }) { throw CastPlaybackError.trackUnavailable }
            if let subtitleIndex, subtitleIndex >= 0, !streams.contains(where: { $0.Type == "Subtitle" && $0.Index == subtitleIndex }) { throw CastPlaybackError.trackUnavailable }
        }
        let selectedAudio = selection != nil ? selection?.audioIndex : audioIndex ?? selectedSource?.DefaultAudioStreamIndex
        let selectedSubtitle = selection != nil ? selection?.subtitleIndex : subtitleIndex ?? selectedSource?.DefaultSubtitleStreamIndex
        let canTranscode = permissions.Policy.EnableVideoPlaybackTranscoding == true || permissions.Policy.EnableAudioPlaybackTranscoding == true
        let transcoding: [String: any Sendable] = ["Container": "ts", "Type": "Video", "Protocol": "hls", "VideoCodec": "h264", "AudioCodec": "aac", "Context": "Streaming", "MaxAudioChannels": "2", "MinSegments": 2, "SegmentLength": 4]
        let profile: [String: any Sendable] = [
            "Name": "Reel Google Cast", "MaxStreamingBitrate": receiverBitrate,
            "DirectPlayProfiles": [["Container": "mp4,m4v", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac,mp3"]],
            "TranscodingProfiles": [transcoding],
            "SubtitleProfiles": [["Format": "vtt", "Method": "Hls"], ["Format": "srt", "Method": "Encode"], ["Format": "ass", "Method": "Encode"], ["Format": "pgssub", "Method": "Encode"]]
        ]
        var body: [String: any Sendable] = ["UserId": userID ?? "", "StartTimeTicks": Int64(max(0, position) * ticksPerSecond),
            "MaxStreamingBitrate": receiverBitrate, "EnableDirectPlay": CastTrackPolicy.permitsDirectPlay(source: selectedSource, audioIndex: selectedAudio, subtitleIndex: selectedSubtitle), "EnableDirectStream": false,
            "EnableTranscoding": canTranscode, "AllowVideoStreamCopy": true, "AllowAudioStreamCopy": false,
            "AutoOpenLiveStream": true, "DeviceProfile": profile]
        body["MediaSourceId"] = mediaSourceID
        body["AudioStreamIndex"] = selectedAudio
        body["SubtitleStreamIndex"] = selectedSubtitle
        let data = try JSONSerialization.data(withJSONObject: body)
        let info: PlaybackInfo = try await decode(request("Items/\(item.id)/PlaybackInfo", method: "POST", body: data))
        let session = info.PlaySessionId ?? UUID().uuidString
        let liveIDs = Set(info.MediaSources.filter { $0.RequiresClosing == true }.compactMap(\.LiveStreamId).filter { !$0.isEmpty })
        var enqueuedLiveIDs: Set<String> = []
        do {
            guard info.ErrorCode == nil else { throw ReelError.noStream }
            let source: MediaSource
            if let selection {
                do { source = try selection.source(in: info.MediaSources, negotiated: true) }
                catch { throw CastPlaybackError.trackUnavailable }
            } else {
                guard let first = info.MediaSources.first else { throw ReelError.noStream }
                source = first
            }
            if selectedSubtitle == -1 {
                do { try PlaybackSubtitlePlan.validateOff(source: source) }
                catch { throw CastPlaybackError.trackUnavailable }
            }
            let stream = try streamURL(item: item, source: source, sessionID: session)
            let unclaimed = liveIDs.subtracting(source.LiveStreamId.map { [$0] } ?? [])
            enqueuedLiveIDs.formUnion(unclaimed)
            await cleanupUnclaimedCast(liveIDs: unclaimed, sessionID: nil)
            try Task.checkCancellation()
            return CastPlaybackPlan(item: item, source: source, sessionID: session, url: stream.url, method: stream.method, startPosition: max(0, position), audioIndex: selectedAudio ?? source.DefaultAudioStreamIndex, subtitleIndex: selectedSubtitle ?? source.DefaultSubtitleStreamIndex)
        } catch {
            let encoder = info.MediaSources.contains { !($0.TranscodingUrl ?? "").isEmpty } ? info.PlaySessionId : nil
            await cleanupUnclaimedCast(liveIDs: liveIDs.subtracting(enqueuedLiveIDs), sessionID: encoder)
            throw error
        }
    }
    @MainActor private func cleanupUnclaimedCast(liveIDs: Set<String>, sessionID: String?) async {
        let reporter = PlaybackReporter()
        for id in liveIDs {
            reporter.enqueue(api: self, endpoint: "", body: ["LiveStreamId": id, "CleanupEncoder": false], cleanup: true)
        }
        if let sessionID, !sessionID.isEmpty {
            reporter.enqueue(api: self, endpoint: "", body: ["PlaySessionId": sessionID, "CleanupEncoder": true], cleanup: true)
        }
        await reporter.flush()
    }

}

@MainActor @Observable final class CastCoordinator: NSObject {
    static let shared = CastCoordinator()
    private(set) var connected = false
    private(set) var receiverName = "Google Cast"
    private(set) var remoteItemID: String?
    private(set) var lastItemID: String?
    private(set) var lastPosition: Double = 0
    private(set) var remoteTitle = ""
    private(set) var isPlaying = false
    private(set) var position: Double = 0
    private(set) var loading = false
    var error: String?
    private(set) var pendingLoadNotice: String?
    @ObservationIgnored private var loadSent = false
    @ObservationIgnored private var configured = false
    @ObservationIgnored private var preparation: Task<Void, Never>?
    @ObservationIgnored private var progress: Task<Void, Never>?
    @ObservationIgnored private var loadDeadline: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var plan: CastPlaybackPlan?
    @ObservationIgnored private var api: JellyfinAPI?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var lastAccountID: String?
    @ObservationIgnored private let accountWork = CastAccountWork()
    @ObservationIgnored private var began = false
    @ObservationIgnored private var onStarted: (() -> Bool)?
    #if canImport(GoogleCast)
    @ObservationIgnored private var loadRequest: GCKRequest?
    @ObservationIgnored private var targetSession: GCKCastSession?
    @ObservationIgnored private var targetClient: GCKRemoteMediaClient?
    @ObservationIgnored private var controlRequests: [GCKRequestID: (request: GCKRequest, generation: UUID)] = [:]
    var sdkAvailable: Bool { true }
    #else
    var sdkAvailable: Bool { false }
    #endif

    func configure() {
        #if canImport(GoogleCast)
        guard !configured else { return }
        let options = GCKCastOptions(discoveryCriteria: GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID))
        options.disableAnalyticsLogging = true
        options.startDiscoveryAfterFirstTapOnCastButton = true
        options.stopReceiverApplicationWhenEndingSession = true
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        GCKCastContext.sharedInstance().sessionManager.add(self)
        configured = true
        refreshConnection()
        #endif
    }

    @discardableResult func cast(_ item: MediaItem, api: JellyfinAPI, position: Double, bitrate: Int, selection: PlaybackTrackSelection, admitted: @escaping () -> Bool, onStarted: @escaping () -> Bool) -> UUID? {
        guard !api.isSimulatorPreview else { error = ReelError.previewProtected.localizedDescription; return nil }
        let receiverBitrate: Int
        do { receiverBitrate = try CastBitratePolicy.receiverBitrate(bitrate) }
        catch { self.error = error.localizedDescription; return nil }
        #if canImport(GoogleCast)
        configure()
        guard connected, let target = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
              target.connectionState == .connected, let client = target.remoteMediaClient else { error = "Choose a Cast receiver first."; return nil }
        if CastSessionOwnership.hasPendingLoad(loading: loading, hasPlan: plan != nil, established: began) { cancelPendingLoad() }
        else { cancelPreparation(); finishOwnedStream() }
        targetSession = target; targetClient = client
        let current = UUID(); generation = current
        accountID = api.server.absoluteString + "|" + (api.userID ?? "")
        loading = true; error = nil
        preparation = accountWork.track(accountID: api.server.absoluteString + "|" + (api.userID ?? "")) { [weak self] in
            guard let self else { return }
            var prepared: CastPlaybackPlan?
            do {
                let result = try await api.prepareCast(item, position: position, bitrate: receiverBitrate, mediaSourceID: selection.sourceID, audioIndex: selection.audioIndex, subtitleIndex: selection.subtitleIndex, selection: selection)
                prepared = result
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                guard admitted() else { throw PlaybackAudioSelection.SelectionError.stale }
                guard GCKCastContext.sharedInstance().sessionManager.currentCastSession === target,
                      target.connectionState == .connected, target.remoteMediaClient === client,
                      self.targetSession === target, self.targetClient === client else { throw CancellationError() }
                self.plan = result; self.api = api; self.onStarted = onStarted
                let metadata = GCKMediaMetadata(metadataType: item.Type == "Episode" ? .tvShow : .movie)
                metadata.setString(item.title, forKey: kGCKMetadataKeyTitle)
                metadata.setString(item.subtitle, forKey: kGCKMetadataKeySubtitle)
                let information = GCKMediaInformationBuilder(contentURL: result.url)
                information.streamType = item.Type == "TvChannel" ? .live : .buffered
                information.contentType = result.method == "DirectPlay" ? "video/mp4" : "application/x-mpegURL"
                information.metadata = metadata
                let request = GCKMediaLoadRequestDataBuilder()
                request.mediaInformation = information.build()
                request.autoplay = NSNumber(value: true)
                request.startTime = result.startPosition
                loadSent = true
                loadRequest = client.loadMedia(with: request.build())
                loadRequest?.delegate = self
                loadDeadline = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(30)) } catch { return }
                    guard let self, self.generation == current, !self.began else { return }
                    self.cancelOwnedCast(current)
                    self.pendingLoadNotice = "The receiver did not confirm this Cast connection. It may still start there; use the receiver controls to stop it."
                    self.error = "The receiver didn’t confirm playback. You can continue on this device."
                }
                remoteItemID = item.id; remoteTitle = item.title; self.position = result.startPosition
                prepared = nil
            } catch {
                if let prepared { cleanup(prepared, api: api) }
                guard generation == current else { return }
                loading = false
                accountID = nil; targetSession = nil; targetClient = nil
                if let permission = error as? CastPlaybackError { self.error = permission.localizedDescription }
                else if let selectionError = error as? PlaybackAudioSelection.SelectionError { self.error = selectionError.localizedDescription }
                else if !(error is CancellationError) { self.error = "The receiver couldn’t load this title. Check that it can reach your Jellyfin server and that the server can convert this format." }
            }
        }
        return current
        #else
        error = "Google Cast is unavailable in this build."
        return nil
        #endif
    }

    func cancelOwnedCast(_ id: UUID) {
        guard generation == id else { return }
        cancelPendingLoad()
    }
    private func cancelPendingLoad() {
        if loadSent { pendingLoadNotice = "This Cast connection was canceled on this device. It may still start on the receiver; use the receiver controls to stop it." }
        generation = UUID(); cancelPreparation()
        finishOwnedStream()
    }

    var hasEstablishedPlayback: Bool { !loading && began && plan != nil }
    func togglePause() {
        #if canImport(GoogleCast)
        guard let client = ownedEstablishedClient() else { return }
        trackControl(isPlaying ? client.pause() : client.play())
        #endif
    }
    func seek(to seconds: Double) {
        guard seconds.isFinite else { return }
        #if canImport(GoogleCast)
        guard let client = ownedEstablishedClient() else { return }
        let options = GCKMediaSeekOptions(); options.interval = max(0, seconds)
        trackControl(client.seek(with: options))
        #endif
    }
    func endCasting() {
        // New local media, account changes and view teardown also arrive here.
        // A sent but unestablished Load grants no authority over the receiver's current media.
        if CastSessionOwnership.hasPendingLoad(loading: loading, hasPlan: plan != nil, established: began) { cancelPendingLoad(); return }
        #if canImport(GoogleCast)
        let expectedSession = targetSession, expectedClient = targetClient
        let ownedContentID = plan?.url.absoluteString, established = began
        #endif
        generation = UUID(); cancelPreparation()
        finishOwnedStream()
        #if canImport(GoogleCast)
        if configured, let expectedSession, let expectedClient {
            let manager = GCKCastContext.sharedInstance().sessionManager
            // Cleanup may clear our UI ownership; it never grants authority over a new SDK context.
            if CastSessionOwnership.mayStop(ownedContentID: ownedContentID,
                receiverContentID: expectedClient.mediaStatus?.mediaInformation?.contentID, established: established,
                sameSession: manager.currentCastSession === expectedSession,
                sameClient: expectedSession.remoteMediaClient === expectedClient,
                connected: expectedSession.connectionState == .connected) {
                manager.endSessionAndStopCasting(true)
                connected = false
            }
        }
        #endif
        error = nil
    }
    func flushReports() async { await accountWork.flush() }
    func finishAccount(_ id: String) async {
        if accountID == id { endCasting() }
        // Canceled preparation and queued reports retain their own account even
        // after the active receiver context has cleared or another account starts.
        await accountWork.flush(accountID: id)
    }
    func ownsAccount(_ id: String) -> Bool { accountID == id }
    func canReturnToLocal(itemID: String, api: JellyfinAPI) -> Bool {
        lastItemID == itemID && lastAccountID == api.server.absoluteString + "|" + (api.userID ?? "")
    }
    func forgetLocalReturn() { lastItemID = nil; lastAccountID = nil }
    private func cancelPreparation() {
        guard let preparation else { return }
        self.preparation = nil
        preparation.cancel()
    }
    private func finishOwnedStream() {
        loadDeadline?.cancel(); loadDeadline = nil
        progress?.cancel(); progress = nil
        if let plan, let api {
            if began { lastItemID = plan.item.id; lastPosition = position; lastAccountID = api.server.absoluteString + "|" + (api.userID ?? "") }
            if began { report("Sessions/Playing/Stopped", plan: plan, api: api, cleanup: true) }
            else { cleanup(plan, api: api) }
        }
        plan = nil; api = nil; accountID = nil; began = false; loading = false; loadSent = false; isPlaying = false; remoteItemID = nil; remoteTitle = ""; onStarted = nil
        #if canImport(GoogleCast)
        loadRequest?.delegate = nil; loadRequest = nil
        for entry in controlRequests.values { entry.request.delegate = nil }
        controlRequests.removeAll()
        targetSession = nil; targetClient = nil
        #endif
    }
    private func cleanup(_ plan: CastPlaybackPlan, api: JellyfinAPI) {
        let body: [String: any Sendable] = ["PlaySessionId": plan.sessionID, "LiveStreamId": plan.source.RequiresClosing == true ? plan.source.LiveStreamId ?? "" : "", "CleanupEncoder": plan.method == "Transcode"]
        accountWork.enqueue(api: api, endpoint: "", body: body, cleanup: true)
    }
    private func report(_ endpoint: String, plan: CastPlaybackPlan, api: JellyfinAPI, cleanup: Bool = false) {
        var body: [String: any Sendable] = ["ItemId": plan.item.id, "MediaSourceId": plan.source.Id, "PlaySessionId": plan.sessionID,
            "PositionTicks": Int64(max(0, position) * ticksPerSecond), "IsPaused": !isPlaying, "CanSeek": plan.item.Type != "TvChannel", "PlayMethod": plan.method,
            "LiveStreamId": plan.source.RequiresClosing == true ? plan.source.LiveStreamId ?? "" : "", "CleanupEncoder": plan.method == "Transcode"]
        body["AudioStreamIndex"] = plan.audioIndex
        body["SubtitleStreamIndex"] = plan.subtitleIndex
        accountWork.enqueue(api: api, endpoint: endpoint, body: body, cleanup: cleanup)
    }
}

#if canImport(GoogleCast)
extension CastCoordinator: @preconcurrency GCKSessionManagerListener, @preconcurrency GCKRequestDelegate {
    private func ownedEstablishedClient() -> GCKRemoteMediaClient? {
        guard began, let plan, let targetSession, let targetClient,
              GCKCastContext.sharedInstance().sessionManager.currentCastSession === targetSession,
              targetSession.connectionState == .connected, targetSession.remoteMediaClient === targetClient,
              targetClient.mediaStatus?.mediaInformation?.contentID == plan.url.absoluteString else { return nil }
        return targetClient
    }
    private func trackControl(_ request: GCKRequest) {
        // Bound sender tracking without claiming cancellation can undo a delivered receiver command.
        if controlRequests.count >= 16, let key = controlRequests.keys.first {
            controlRequests.removeValue(forKey: key)?.request.delegate = nil
        }
        controlRequests[request.requestID] = (request, generation)
        request.delegate = self
    }
    private func refreshConnection() {
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        connected = session?.connectionState == .connected
        receiverName = session?.device.friendlyName ?? "Google Cast"
    }
    func sessionManager(_ manager: GCKSessionManager, didStart session: GCKSession) { refreshConnection() }
    func sessionManager(_ manager: GCKSessionManager, didResumeSession session: GCKSession) { refreshConnection() }
    func sessionManager(_ manager: GCKSessionManager, didEnd session: GCKSession, withError error: Error?) {
        guard session === targetSession else { refreshConnection(); return }
        if loadSent, !began { pendingLoadNotice = "The Cast connection was interrupted. It may still start on the receiver; use the receiver controls to stop it." }
        generation = UUID(); cancelPreparation()
        finishOwnedStream(); refreshConnection()
        if error != nil { self.error = "The Cast receiver disconnected. You can continue watching on this iPhone." }
    }
    func sessionManager(_ manager: GCKSessionManager, didFailToStartSessionWithError error: Error?) {
        if let targetSession, targetSession.connectionState == .connected, manager.currentCastSession === targetSession { return }
        if CastSessionOwnership.hasPendingLoad(loading: loading, hasPlan: plan != nil, established: began) { cancelPendingLoad() }
        loading = false; self.error = "The Cast receiver couldn’t connect. Check Wi-Fi and try again."
    }
    func requestDidComplete(_ request: GCKRequest) {
        guard request === loadRequest else {
            if let entry = controlRequests[request.requestID], entry.request === request { controlRequests.removeValue(forKey: request.requestID) }
            return
        }
        loadRequest?.delegate = nil; loadRequest = nil
        guard let expectedSession = targetSession, let expectedClient = targetClient else { cancelPendingLoad(); return }
        let current = generation
        progress = Task { [weak self] in
            var count = 0
            while !Task.isCancelled {
                guard let self, self.generation == current, let plan = self.plan, let api = self.api else { return }
                guard GCKCastContext.sharedInstance().sessionManager.currentCastSession === expectedSession,
                      expectedSession.connectionState == .connected, expectedSession.remoteMediaClient === expectedClient else {
                    self.cancelPendingLoad(); return
                }
                let client = expectedClient
                let status = client.mediaStatus
                if self.began, status?.playerState == .idle { self.finishOwnedStream(); return }
                if self.began, let identifier = status?.mediaInformation?.contentID, identifier != plan.url.absoluteString {
                    self.finishOwnedStream(); return
                }
                if status?.mediaInformation?.contentID == plan.url.absoluteString {
                    let remotePosition = client.approximateStreamPosition()
                    if remotePosition.isFinite { self.position = max(0, remotePosition) }
                    self.isPlaying = status?.playerState == .playing
                    if !self.began, status?.playerState == .playing || status?.playerState == .paused {
                        let accepted = self.onStarted; self.onStarted = nil
                        guard accepted?() == true, self.generation == current else {
                            if self.generation == current { self.cancelOwnedCast(current) }
                            return
                        }
                        self.began = true; self.loading = false
                        self.loadDeadline?.cancel(); self.loadDeadline = nil
                        self.report("Sessions/Playing", plan: plan, api: api)
                    } else if self.began, count % 10 == 0 { self.report("Sessions/Playing/Progress", plan: plan, api: api) }
                }
                if !self.began, count >= 20 {
                    self.pendingLoadNotice = "The receiver did not confirm this Cast connection. It may still start there; use the receiver controls to stop it."
                    self.error = "The receiver didn’t confirm playback. You can continue on this device."
                    self.finishOwnedStream(); return
                }
                count += 1
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        let isLoad = request === loadRequest
        if !isLoad {
            guard let entry = controlRequests[request.requestID], entry.request === request, entry.generation == generation else { return }
            controlRequests.removeValue(forKey: request.requestID)
        }
        self.error = "The receiver rejected the request. Check its connection and the server’s streaming settings."
        if isLoad {
            if loadSent { pendingLoadNotice = "The receiver did not confirm this Cast connection. It may still start there; use the receiver controls to stop it." }
            finishOwnedStream()
        }
    }
}
#endif
