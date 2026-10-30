import AVFoundation
import Foundation
import Observation

struct RemotePlayState: Decodable, Sendable {
    var PositionTicks: Int64?
    var IsPaused: Bool?
    var CanSeek: Bool?
}

struct RemoteSession: Decodable, Identifiable, Sendable {
    let Id: String
    var DeviceId: String?
    var DeviceName: String?
    var Client: String?
    var UserName: String?
    var SupportsRemoteControl: Bool?
    var SupportsMediaControl: Bool?
    var PlayableMediaTypes: [String]?
    var NowPlayingItem: MediaItem?
    var PlayState: RemotePlayState?
    var id: String { Id }
    var name: String { DeviceName ?? Client ?? "Jellyfin player" }
    var acceptsVideo: Bool { PlayableMediaTypes?.contains("Video") == true }
}

struct RemoteUserProfile: Decodable, Sendable {
    struct UserPolicy: Decodable, Sendable { var SyncPlayAccess: String?; var EnableMediaPlayback: Bool? }
    var Policy: UserPolicy?
}

enum RemoteProtocol {
    static func requireWritable(_ api: JellyfinAPI) throws {
        guard !api.isSimulatorPreview else { throw ReelError.previewProtected }
        guard api.token?.isEmpty == false, api.userID?.isEmpty == false else { throw ReelError.unauthorized }
    }
    static func component(_ value: String) throws -> String {
        guard !value.isEmpty, value.count <= 200,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { throw ReelError.invalidResponse }
        return value
    }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let result = formatter.date(from: value) { return result }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
    static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
    static func socketRequest(api: JellyfinAPI) throws -> URLRequest {
        var request = api.request("socket", query: ["deviceId": api.deviceID])
        guard let endpoint = request.url, var parts = URLComponents(url: endpoint, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(parts.scheme ?? ""), parts.user == nil, parts.password == nil else { throw ReelError.invalidServer }
        parts.scheme = parts.scheme == "https" ? "wss" : "ws"
        guard let url = parts.url else { throw ReelError.invalidServer }
        request.url = url
        request.timeoutInterval = 15
        request.setValue(api.authorization, forHTTPHeaderField: "Authorization")
        return request
    }
}

@MainActor @Observable final class RemoteSessions {
    private(set) var sessions: [RemoteSession] = []
    private(set) var loading = false
    private(set) var busy = false
    var error: String?
    var notice: String?
    private var generation = UUID()
    private var refreshID = UUID()
    private var accountContext: String?

    private func context(_ api: JellyfinAPI) -> String { api.server.absoluteString + "|" + (api.userID ?? "") }

    func reset(api: JellyfinAPI?) {
        generation = UUID(); refreshID = UUID()
        accountContext = api.map(context)
        sessions = []; error = nil; notice = nil; loading = false; busy = false
    }

    func refresh(api: JellyfinAPI) async {
        if accountContext != context(api) {
            reset(api: api)
        }
        let current = generation
        let request = UUID(); refreshID = request
        loading = true; error = nil
        defer { if generation == current && refreshID == request { loading = false } }
        do {
            guard let userID = api.userID else { throw ReelError.unauthorized }
            let result: [RemoteSession] = try await api.get("Sessions", query: ["controllableByUserId": userID])
            try Task.checkCancellation()
            guard current == generation && refreshID == request else { return }
            sessions = result.filter { $0.DeviceId != api.deviceID && $0.SupportsRemoteControl == true }
        } catch is CancellationError { }
        catch { if current == generation && refreshID == request { self.error = error.localizedDescription } }
    }

    func command(_ command: String, session: RemoteSession, api: JellyfinAPI, ticks: Int64? = nil) async {
        guard !busy else { return }
        let current = generation
        busy = true; error = nil; notice = nil
        defer { if generation == current { busy = false } }
        do {
            try RemoteProtocol.requireWritable(api)
            guard accountContext == context(api), sessions.contains(where: { $0.id == session.id }) else { throw ReelError.unauthorized }
            guard session.SupportsMediaControl == true,
                  ["Pause", "Unpause", "Stop", "Seek", "NextTrack", "PreviousTrack"].contains(command) else { throw ReelError.invalidResponse }
            if command == "Seek", session.PlayState?.CanSeek != true { throw RemotePlaybackError.cannotSeek }
            let id = try RemoteProtocol.component(session.id)
            var query = ["controllingUserId": api.userID ?? ""]
            if command == "Seek" { query["seekPositionTicks"] = String(max(0, ticks ?? 0)) }
            try await api.post("Sessions/\(id)/Playing/\(command)", query: query)
            guard generation == current, accountContext == context(api) else { return }
            notice = "Command sent to \(session.name)."
            await refresh(api: api)
        } catch { if generation == current { self.error = error.localizedDescription } }
    }

    func play(_ item: MediaItem, on session: RemoteSession, mode: String, api: JellyfinAPI) async {
        guard !busy else { return }
        let current = generation
        busy = true; error = nil; notice = nil
        defer { if generation == current { busy = false } }
        do {
            try RemoteProtocol.requireWritable(api)
            guard accountContext == context(api), sessions.contains(where: { $0.id == session.id }) else { throw ReelError.unauthorized }
            guard session.acceptsVideo, ["Movie", "Episode", "Video", "MusicVideo", "TvChannel"].contains(item.Type ?? ""),
                  ["PlayNow", "PlayNext", "PlayLast"].contains(mode) else { throw RemotePlaybackError.unsupportedMedia }
            let id = try RemoteProtocol.component(session.id)
            _ = try RemoteProtocol.component(item.id)
            try await api.post("Sessions/\(id)/Playing", query: ["playCommand": mode, "itemIds": item.id,
                "startPositionTicks": String(mode == "PlayNow" ? item.resumeTicks : 0)])
            guard generation == current, accountContext == context(api) else { return }
            notice = mode == "PlayNow" ? "Playback requested on \(session.name)." : "Added to the queue on \(session.name)."
            await refresh(api: api)
        } catch { if generation == current { self.error = error.localizedDescription } }
    }
}

enum RemotePlaybackError: LocalizedError {
    case cannotSeek, unsupportedMedia, denied, socketLost, invalidClock, mediaFailed, noGroup
    var errorDescription: String? {
        switch self {
        case .cannotSeek: "This player cannot seek the current stream."
        case .unsupportedMedia: "Choose a playable movie or episode and a player that accepts video."
        case .denied: "Your Jellyfin account does not have permission for this SyncPlay action."
        case .socketLost: "The live connection was interrupted. Playback is paused. Rejoin the group to synchronize again."
        case .invalidClock: "Jellyfin’s clock response could not be read. SyncPlay needs a synchronized server clock."
        case .mediaFailed: "This group’s media could not be prepared. Check your library access and playback settings, then rejoin."
        case .noGroup: "Join or create a SyncPlay group first."
        }
    }
}

struct SyncPlayGroup: Codable, Identifiable, Equatable, Sendable {
    let GroupId: String
    var GroupName: String
    var State: String
    var Participants: [String]
    var LastUpdatedAt: String?
    var id: String { GroupId }
}

struct SyncPlayQueueEntry: Decodable, Identifiable, Sendable {
    let ItemId: String
    let PlaylistItemId: String
    var id: String { PlaylistItemId }
}

struct SyncPlayQueueUpdate: Decodable, Sendable {
    let LastUpdate: String
    let Playlist: [SyncPlayQueueEntry]
    let PlayingItemIndex: Int
    let StartPositionTicks: Int64
    let IsPlaying: Bool
}

struct SyncPlayServerCommand: Decodable, Equatable, Sendable {
    let GroupId: String
    let PlaylistItemId: String
    let When: String
    let PositionTicks: Int64?
    let Command: String
    let EmittedAt: String

    func position(at serverTime: Date) throws -> Int64 {
        guard let when = RemoteProtocol.date(When) else { throw RemotePlaybackError.invalidClock }
        let advance = Command == "Unpause" ? max(0, serverTime.timeIntervalSince(when)) * ticksPerSecond : 0
        let total = Double(max(0, PositionTicks ?? 0)) + advance
        guard total.isFinite, total < Double(Int64.max) else { throw ReelError.invalidResponse }
        return Int64(total)
    }
}

struct SyncPlayClockSample: Sendable {
    let offset: TimeInterval
    let roundTrip: TimeInterval
    init(sent: Date, received: Date, requestReception: Date, responseTransmission: Date) throws {
        let elapsed = received.timeIntervalSince(sent)
        let processing = responseTransmission.timeIntervalSince(requestReception)
        guard elapsed >= 0, elapsed < 15, processing >= 0, processing <= elapsed + 0.1 else { throw RemotePlaybackError.invalidClock }
        offset = (requestReception.timeIntervalSince(sent) + responseTransmission.timeIntervalSince(received)) / 2
        roundTrip = max(0, elapsed - processing)
    }
}

private final class SyncPlaySocketRedirects: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        // WebSocket upgrades must stay on the configured endpoint; never forward the sign-in on redirects.
        completionHandler(nil)
    }
}

@MainActor @Observable final class SyncPlayClient {
    private(set) var groups: [SyncPlayGroup] = []
    private(set) var group: SyncPlayGroup?
    private(set) var queue: [SyncPlayQueueEntry] = []
    private(set) var currentEntry: SyncPlayQueueEntry?
    private(set) var loading = false
    private(set) var busy = false
    private(set) var connected = false
    private(set) var clockOffset: TimeInterval = 0
    private(set) var latency: TimeInterval = 0
    private(set) var access = "None"
    private(set) var state = "Idle"
    var error: String?
    @ObservationIgnored private var api: JellyfinAPI?
    @ObservationIgnored private weak var playback: PlaybackController?
    @ObservationIgnored private var socketSession: URLSession?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var monitorTask: Task<Void, Never>?
    @ObservationIgnored private var mediaTask: Task<Void, Never>?
    @ObservationIgnored private var commandTask: Task<Void, Never>?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var mediaGeneration = UUID()
    @ObservationIgnored private var lastCommand: SyncPlayServerCommand?
    @ObservationIgnored private var lastQueueDate: Date?
    @ObservationIgnored private var ready = false
    @ObservationIgnored private var buffering = false
    @ObservationIgnored private var requestedNext = false
    var canJoin: Bool { access == "CreateAndJoinGroups" || access == "JoinGroups" }
    var canCreate: Bool { access == "CreateAndJoinGroups" }

    func ownsAccount(_ id: String) -> Bool {
        guard let api, group != nil || connected else { return false }
        return id == api.server.absoluteString + "|" + (api.userID ?? "")
    }

    func detach() {
        let previousAPI = api
        let wasJoined = group != nil
        disconnect()
        if wasJoined, let previousAPI {
            Task {
                do { try RemoteProtocol.requireWritable(previousAPI); try await previousAPI.post("SyncPlay/Leave") }
                catch { /* This membership belongs to the detached account. */ }
            }
        }
    }

    func configure(api: JellyfinAPI?, playback: PlaybackController) {
        if self.api?.server == api?.server && self.api?.userID == api?.userID && self.api?.token == api?.token {
            self.playback = playback
            return
        }
        let oldAPI = self.api
        let wasJoined = group != nil
        disconnect()
        if wasJoined, let oldAPI {
            Task {
                do { try RemoteProtocol.requireWritable(oldAPI); try await oldAPI.post("SyncPlay/Leave") }
                catch { /* Cleanup belongs to the previous account; do not show its error in the new account. */ }
            }
        }
        self.api = api; self.playback = playback
        groups = []; access = "None"; error = nil
    }

    func refresh() async {
        guard let api else { return }
        loading = true; error = nil
        let current = generation
        defer { if generation == current { loading = false } }
        do {
            async let fetchedGroups: [SyncPlayGroup] = api.get("SyncPlay/List")
            async let profile: RemoteUserProfile = api.get("Users/Me")
            let result = try await (fetchedGroups, profile)
            try Task.checkCancellation()
            guard generation == current else { return }
            groups = result.0
            access = result.1.Policy?.EnableMediaPlayback == false ? "None" : result.1.Policy?.SyncPlayAccess ?? "None"
        } catch is CancellationError { }
        catch { if generation == current { self.error = error.localizedDescription } }
    }

    func create(name: String) async {
        await membership { api in
            guard self.canCreate else { throw RemotePlaybackError.denied }
            let trimmed = String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            let data = try JSONSerialization.data(withJSONObject: ["GroupName": trimmed.isEmpty ? "Watch together" : trimmed])
            let current = self.generation
            let created: SyncPlayGroup = try await api.decode(api.request("SyncPlay/New", method: "POST", body: data))
            guard self.generation == current else {
                Task { try? await api.post("SyncPlay/Leave") }
                throw CancellationError()
            }
            self.group = created; self.state = created.State
        }
    }

    func join(_ group: SyncPlayGroup) async {
        await membership { api in
            guard self.canJoin else { throw RemotePlaybackError.denied }
            _ = try RemoteProtocol.component(group.id)
            self.group = group; self.state = group.State
            try await api.post("SyncPlay/Join", body: ["GroupId": group.id])
        }
    }

    private func membership(_ action: @MainActor (JellyfinAPI) async throws -> Void) async {
        guard !busy, let api else { return }
        busy = true; error = nil
        var operation = generation
        defer { if generation == operation { busy = false } }
        do {
            try RemoteProtocol.requireWritable(api)
            if group != nil {
                try await api.post("SyncPlay/Leave")
                guard generation == operation else { throw CancellationError() }
                disconnect()
                busy = true
            }
            operation = generation
            try await openSocket(api: api)
            guard generation == operation else { throw CancellationError() }
            try await calibrateClock(api: api)
            guard generation == operation else { throw CancellationError() }
            try await action(api)
            guard generation == operation else {
                Task { try? await api.post("SyncPlay/Leave") }
                throw CancellationError()
            }
            try await api.post("SyncPlay/Ping", body: ["Ping": Int64(latency * 1_000)])
            guard generation == operation else { throw CancellationError() }
            playback?.syncPlayManaged = true
            playback?.player.allowsExternalPlayback = false
            playback?.syncPlayCommand = { [weak self] command, ticks in
                Task { await self?.request(command, ticks: ticks) }
            }
            startMonitor()
        } catch {
            guard generation == operation else { return }
            let message = error.localizedDescription
            disconnect()
            self.error = message
        }
    }

    func leave(stopLocal: Bool = true) async {
        guard let api else { disconnect(); return }
        let wasJoined = group != nil
        disconnect(stopLocal: stopLocal)
        let operation = generation
        if wasJoined {
            do {
                try RemoteProtocol.requireWritable(api)
                // disconnect can cancel the monitoring task that initiated this leave.
                let cleanup = Task { try await api.post("SyncPlay/Leave") }
                try await cleanup.value
            }
            catch { if generation == operation { self.error = "Playback left locally. Jellyfin could not confirm the group leave: " + error.localizedDescription } }
        }
    }

    func disconnect(stopLocal: Bool = true) {
        generation = UUID(); mediaGeneration = UUID()
        receiveTask?.cancel(); receiveTask = nil
        monitorTask?.cancel(); monitorTask = nil
        mediaTask?.cancel(); mediaTask = nil
        commandTask?.cancel(); commandTask = nil
        socket?.cancel(with: .goingAway, reason: nil); socket = nil
        socketSession?.invalidateAndCancel(); socketSession = nil
        let managed = playback?.syncPlayManaged == true
        playback?.syncPlayCommand = nil; playback?.syncPlayManaged = false
        playback?.player.allowsExternalPlayback = api.map { !$0.isSimulatorPreview && $0.gatewayHeaders.isEmpty } ?? false
        if managed && stopLocal { playback?.stop(); playback?.activeItem = nil }
        group = nil; queue = []; currentEntry = nil; connected = false
        busy = false; loading = false
        lastCommand = nil; lastQueueDate = nil; ready = false; buffering = false; requestedNext = false; state = "Idle"
    }

    func setQueue(_ item: MediaItem) async {
        await perform {
            guard ["Movie", "Episode", "Video", "MusicVideo"].contains(item.Type ?? "") else { throw RemotePlaybackError.unsupportedMedia }
            try await $0.post("SyncPlay/SetNewQueue", body: ["PlayingQueue": [item.id], "PlayingItemPosition": 0, "StartPositionTicks": item.resumeTicks])
        }
    }

    func enqueue(_ item: MediaItem, next: Bool = false) async {
        await perform { api in
            guard ["Movie", "Episode", "Video", "MusicVideo"].contains(item.Type ?? "") else { throw RemotePlaybackError.unsupportedMedia }
            try await api.post("SyncPlay/Queue", body: ["ItemIds": [item.id], "Mode": next ? "QueueNext" : "Queue"])
        }
    }

    func request(_ command: String, ticks: Int64? = nil) async {
        await perform { api in
            guard ["Pause", "Unpause", "Stop", "Seek", "NextItem", "PreviousItem"].contains(command) else { throw ReelError.invalidResponse }
            var body: [String: any Sendable] = [:]
            if command == "Seek" { body["PositionTicks"] = max(0, ticks ?? 0) }
            if command == "NextItem" || command == "PreviousItem", let currentEntry = self.currentEntry { body["PlaylistItemId"] = currentEntry.id }
            try await api.post("SyncPlay/" + command, body: body)
        }
    }

    private func perform(_ action: @MainActor (JellyfinAPI) async throws -> Void) async {
        guard let api else { return }
        let operation = generation
        do {
            try RemoteProtocol.requireWritable(api)
            guard group != nil, connected else { throw RemotePlaybackError.noGroup }
            try await action(api)
        } catch { if generation == operation { self.error = error.localizedDescription } }
    }

    private func openSocket(api: JellyfinAPI) async throws {
        let current = generation
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        let session = URLSession(configuration: config, delegate: SyncPlaySocketRedirects(), delegateQueue: nil)
        socketSession = session
        let socket = session.webSocketTask(with: try RemoteProtocol.socketRequest(api: api))
        self.socket = socket
        socket.maximumMessageSize = 1_048_576
        socket.resume()
        // A completed send requires the WebSocket upgrade; group events cannot precede our receiver.
        try await socket.send(.string("{\"MessageType\":\"KeepAlive\"}"))
        guard generation == current else { socket.cancel(with: .goingAway, reason: nil); throw CancellationError() }
        connected = true
        receiveTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard let self, self.generation == current else { return }
                    let data: Data
                    switch message { case .data(let bytes): data = bytes; case .string(let text): data = Data(text.utf8); @unknown default: continue }
                    try await self.receive(data)
                }
            } catch {
                guard let self, self.generation == current, !Task.isCancelled else { return }
                self.disconnect()
                self.error = RemotePlaybackError.socketLost.localizedDescription
                // Leaving is scoped to this authenticated session; it never issues a group Stop.
                Task { try? await api.post("SyncPlay/Leave") }
            }
        }
    }

    private func calibrateClock(api: JellyfinAPI) async throws {
        let current = generation
        struct ClockReply: Decodable, Sendable { let RequestReceptionTime: String; let ResponseTransmissionTime: String }
        var best: SyncPlayClockSample?
        for _ in 0..<3 {
            let sent = Date()
            let reply: ClockReply = try await api.get("GetUtcTime")
            guard generation == current else { throw CancellationError() }
            let received = Date()
            guard let reception = RemoteProtocol.date(reply.RequestReceptionTime), let transmission = RemoteProtocol.date(reply.ResponseTransmissionTime) else { throw RemotePlaybackError.invalidClock }
            let sample = try SyncPlayClockSample(sent: sent, received: received, requestReception: reception, responseTransmission: transmission)
            if best == nil || sample.roundTrip < best!.roundTrip { best = sample }
        }
        guard let best else { throw RemotePlaybackError.invalidClock }
        clockOffset = best.offset; latency = best.roundTrip
        if group != nil { try await api.post("SyncPlay/Ping", body: ["Ping": Int64(best.roundTrip * 1_000)]) }
    }

    func receive(_ data: Data) async throws {
        struct Header: Decodable { let MessageType: String }
        struct Envelope<T: Decodable>: Decodable { let Data: T }
        struct UpdateHeader: Decodable { let GroupId: String; let `Type`: String }
        struct Update<T: Decodable>: Decodable { let GroupId: String; let `Type`: String; let Data: T }
        let decoder = JSONDecoder()
        let header = try decoder.decode(Header.self, from: data)
        switch header.MessageType {
        case "ForceKeepAlive": try await socket?.send(.string("{\"MessageType\":\"KeepAlive\"}"))
        case "SyncPlayCommand":
            let command = try decoder.decode(Envelope<SyncPlayServerCommand>.self, from: data).Data
            guard command.GroupId == group?.id, command.PlaylistItemId == currentEntry?.id else { return }
            guard RemoteProtocol.date(command.When) != nil, let emitted = RemoteProtocol.date(command.EmittedAt) else { throw ReelError.invalidResponse }
            if let previous = lastCommand, let lastDate = RemoteProtocol.date(previous.EmittedAt), emitted < lastDate { return }
            guard command != lastCommand else { return }
            lastCommand = command
            if ready { schedule(command) }
        case "SyncPlayGroupUpdate":
            let update = try decoder.decode(Envelope<UpdateHeader>.self, from: data).Data
            if let group, group.id != update.GroupId { return }
            switch update.Type {
            case "GroupJoined":
                let joined = try decoder.decode(Envelope<Update<SyncPlayGroup>>.self, from: data).Data.Data
                group = joined; state = joined.State
            case "GroupLeft", "NotInGroup", "GroupDoesNotExist": disconnect()
            case "LibraryAccessDenied", "CreateGroupDenied", "JoinGroupDenied", "SyncPlayIsDisabled":
                disconnect(); error = RemotePlaybackError.denied.localizedDescription
            case "PlayQueue":
                let queue = try decoder.decode(Envelope<Update<SyncPlayQueueUpdate>>.self, from: data).Data.Data
                try updateQueue(queue)
            case "StateUpdate":
                struct StateUpdate: Decodable { let State: String }
                state = try decoder.decode(Envelope<Update<StateUpdate>>.self, from: data).Data.Data.State
            case "UserJoined", "UserLeft":
                let name = try decoder.decode(Envelope<Update<String>>.self, from: data).Data.Data
                if update.Type == "UserJoined" { group?.Participants.append(name) }
                else { group?.Participants.removeAll { $0 == name } }
            default: break
            }
        default: break
        }
    }

    private func updateQueue(_ update: SyncPlayQueueUpdate) throws {
        guard let date = RemoteProtocol.date(update.LastUpdate) else { throw ReelError.invalidResponse }
        guard lastQueueDate == nil || date > lastQueueDate! else { return }
        lastQueueDate = date; queue = update.Playlist
        guard update.PlayingItemIndex >= 0, update.PlayingItemIndex < queue.count else {
            mediaGeneration = UUID()
            mediaTask?.cancel(); mediaTask = nil
            commandTask?.cancel(); commandTask = nil
            lastCommand = nil; buffering = false; requestedNext = false
            currentEntry = nil; ready = false; playback?.stop(); playback?.activeItem = nil
            return
        }
        let entry = queue[update.PlayingItemIndex]
        guard entry.id != currentEntry?.id else { return }
        currentEntry = entry; ready = false; buffering = false; requestedNext = false; lastCommand = nil
        mediaGeneration = UUID()
        let current = mediaGeneration
        mediaTask?.cancel(); commandTask?.cancel()
        guard let api, let playback else { return }
        mediaTask = Task { [weak self] in
            guard let self else { return }
            do {
                let item = try await api.item(entry.ItemId)
                try Task.checkCancellation()
                guard current == mediaGeneration, group != nil else { return }
                var selection = item
                if selection.UserData == nil { selection.UserData = UserData() }
                selection.UserData?.PlaybackPositionTicks = max(0, update.StartPositionTicks)
                playback.syncPlayManaged = true
                playback.present(selection, fromBeginning: true)
                // PlayerView starts the prepared item when its full-screen presentation appears.
                for _ in 0..<400 {
                    try await Task.sleep(for: .milliseconds(100))
                    guard current == mediaGeneration, group != nil else { return }
                    if playback.error != nil { throw RemotePlaybackError.mediaFailed }
                    if !playback.preparing, playback.player.currentItem?.status == .readyToPlay { break }
                }
                guard !playback.preparing else { throw RemotePlaybackError.mediaFailed }
                playback.player.pause()
                ready = true
                try await reportReadiness(buffering: false)
                if let command = lastCommand { schedule(command) }
            } catch is CancellationError { }
            catch {
                guard current == mediaGeneration else { return }
                self.error = error.localizedDescription
                await leave()
            }
        }
    }

    private func reportReadiness(buffering: Bool) async throws {
        guard let api, let entry = currentEntry, let playback else { return }
        let seconds = playback.player.currentTime().seconds
        let ticks = seconds.isFinite ? Int64(max(0, seconds) * ticksPerSecond) : 0
        try await api.post(buffering ? "SyncPlay/Buffering" : "SyncPlay/Ready", body: [
            "When": RemoteProtocol.timestamp(Date().addingTimeInterval(clockOffset)), "PositionTicks": ticks,
            "IsPlaying": playback.player.rate > 0, "PlaylistItemId": entry.id])
    }

    private func schedule(_ command: SyncPlayServerCommand) {
        commandTask?.cancel()
        guard let playback, let when = RemoteProtocol.date(command.When) else { return }
        let current = generation
        commandTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard ["Unpause", "Pause", "Seek", "Stop"].contains(command.Command) else { throw ReelError.invalidResponse }
                try Task.checkCancellation()
                guard generation == current, group?.id == command.GroupId, currentEntry?.id == command.PlaylistItemId else { return }
                if command.Command == "Unpause" {
                    playback.player.pause()
                    let position = try command.position(at: Date().addingTimeInterval(clockOffset))
                    try await playback.seekForManagedPlayback(to: position)
                    try Task.checkCancellation()
                    guard generation == current, group?.id == command.GroupId, currentEntry?.id == command.PlaylistItemId else { return }
                }
                let delay = when.timeIntervalSince(Date().addingTimeInterval(clockOffset))
                guard delay < 120 else { throw ReelError.invalidResponse }
                if delay > 0 { try await Task.sleep(for: .seconds(delay)) }
                try Task.checkCancellation()
                guard generation == current, group?.id == command.GroupId, currentEntry?.id == command.PlaylistItemId else { return }
                switch command.Command {
                case "Unpause": requestedNext = false; playback.player.playImmediately(atRate: 1)
                case "Pause", "Seek":
                    playback.player.pause()
                    try await playback.seekForManagedPlayback(to: max(0, command.PositionTicks ?? 0))
                    try Task.checkCancellation()
                    guard generation == current, group?.id == command.GroupId, currentEntry?.id == command.PlaylistItemId else { return }
                    requestedNext = false
                    if command.Command == "Seek" { try await reportReadiness(buffering: false) }
                case "Stop":
                    currentEntry = nil; ready = false
                    playback.stop(); playback.activeItem = nil
                default: break
                }
            } catch is CancellationError { }
            catch { if generation == current { self.error = error.localizedDescription } }
        }
    }

    private func startMonitor() {
        monitorTask?.cancel()
        let current = generation
        monitorTask = Task { [weak self] in
            var clockAt = Date(); var driftAt = Date()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .milliseconds(500))
                    guard let self, current == self.generation, self.group != nil, let api = self.api, let playback = self.playback else { return }
                    if Date().timeIntervalSince(clockAt) > 20 {
                        try await self.calibrateClock(api: api); clockAt = Date()
                        try await self.socket?.send(.string("{\"MessageType\":\"KeepAlive\"}"))
                    }
                    guard self.ready, let entry = self.currentEntry else { continue }
                    if playback.activeItem?.id != entry.ItemId {
                        await self.leave(stopLocal: false)
                        return
                    }
                    if playback.ended, !playback.restartingEnded, !self.requestedNext {
                        self.requestedNext = true
                        await self.request("NextItem")
                    }
                    let stalled = playback.preparing || playback.restartingEnded || playback.player.timeControlStatus == .waitingToPlayAtSpecifiedRate || playback.player.currentItem?.isPlaybackBufferEmpty == true
                    if stalled != self.buffering {
                        self.buffering = stalled
                        try await self.reportReadiness(buffering: stalled)
                    }
                    if !playback.ended, !playback.restartingEnded, !playback.preparing, Date().timeIntervalSince(driftAt) > 2, let command = self.lastCommand,
                       command.Command == "Unpause", self.state == "Playing", !stalled,
                       let due = RemoteProtocol.date(command.When), due <= Date().addingTimeInterval(self.clockOffset) {
                        let target = try command.position(at: Date().addingTimeInterval(self.clockOffset))
                        let position = playback.player.currentTime().seconds
                        if position.isFinite, abs(Double(target) / ticksPerSecond - position) > 0.5 {
                            await playback.player.seek(to: CMTime(seconds: Double(target) / ticksPerSecond, preferredTimescale: 600))
                        }
                        driftAt = Date()
                    }
                } catch is CancellationError { return }
                catch {
                    guard let self, current == self.generation else { return }
                    self.error = error.localizedDescription
                    await self.leave()
                    return
                }
            }
        }
    }
}
