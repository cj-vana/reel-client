import AVFoundation
import Foundation

/// An intro and the start of the credits, in seconds, found from an episode's audio.
struct FoundMarkers: Equatable, Sendable {
    var intro: ClosedRange<Double>?
    var credits: Double?

    /// The markers as media segments, for the player's existing Skip Intro and credits handling. Server segments
    /// of the same kind win.
    func segments(runtimeTicks: Int64?, server: [MediaSegment]) -> [MediaSegment] {
        var result: [MediaSegment] = []
        if let intro, !server.contains(where: { $0.Type == "Intro" }) {
            result.append(MediaSegment(Id: "reel-found-intro", Type: "Intro", StartTicks: Int64(intro.lowerBound * ticksPerSecond), EndTicks: Int64(intro.upperBound * ticksPerSecond)))
        }
        if let credits, let runtimeTicks, Int64(credits * ticksPerSecond) < runtimeTicks, !server.contains(where: { $0.Type == "Outro" }) {
            result.append(MediaSegment(Id: "reel-found-credits", Type: "Outro", StartTicks: Int64(credits * ticksPerSecond), EndTicks: runtimeTicks))
        }
        return result
    }
}

/// What has been learned per account and episode, kept on the device. Times only; never audio.
final class MarkerStore: @unchecked Sendable {
    static let shared = MarkerStore(defaults: .standard)
    private static let key = "reel.markers.v1"
    private static let limit = 600
    private static let day: Double = 86_400
    /// i: the intro, or an empty list when none was found. c: where the credits start, or 0 when none were found.
    struct Entry: Codable, Equatable { var i: [Double]?; var c: Double?; var t: Double }

    private let defaults: UserDefaults
    private let lock = NSLock()
    private var entries: [String: Entry]

    init(defaults: UserDefaults) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode([String: Entry].self, from: $0) } ?? [:]
        entries = saved.filter { Self.valid($0.value) }
    }

    private static func valid(_ entry: Entry) -> Bool {
        let seconds = { (value: Double) in value.isFinite && value >= 0 && value < 86_400 }
        guard entry.t.isFinite, entry.t > 0 else { return false }
        if let i = entry.i, !(i.isEmpty || i.count == 2 && seconds(i[0]) && seconds(i[1]) && i[1] > i[0]) { return false }
        if let c = entry.c, !seconds(c) { return false }
        return true
    }

    func get(_ key: String, now: Date = .now) -> Entry? {
        lock.withLock {
            guard let entry = entries[key] else { return nil }
            let found = entry.i?.count == 2 || (entry.c ?? 0) > 0
            return now.timeIntervalSince1970 - entry.t > (found ? 180 : 14) * Self.day ? nil : entry
        }
    }

    func update(_ key: String, now: Date = .now, _ change: (inout Entry) -> Void) {
        lock.withLock {
            var entry = entries[key].flatMap { now.timeIntervalSince1970 - $0.t <= 180 * Self.day ? $0 : nil } ?? Entry(t: 0)
            change(&entry)
            entry.t = now.timeIntervalSince1970
            entries[key] = entry
            if entries.count > Self.limit {
                for old in entries.sorted(by: { $0.value.t < $1.value.t }).prefix(entries.count - Self.limit) { entries[old.key] = nil }
            }
            save()
        }
    }

    /// Drops what was learned under an account when it signs out or is removed.
    func forget(accountID: String) {
        lock.withLock {
            entries = entries.filter { !$0.key.hasPrefix(accountID + "|") }
            save()
        }
    }

    private func save() { if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: Self.key) } }
}

/// Finds intros and credits when the server has no markers for them: the opening (or closing) minutes of an
/// episode and of a neighboring episode are fingerprinted, and the longest stretch of audio they share is the
/// theme. Jellyfin transcodes any video's audio on request; 32 kbps mono MP3 keeps ten minutes near 2.4 MB.
///
/// The audio request carries its own play session id and no device id. Jellyfin stops transcodes by play session
/// id, so the scan and the video never stop each other, and the session's transcoding details stay as they were.
/// The web client does the same (`apps/web/src/intro-detection.ts`).
actor MarkerDetector {
    static let shared = MarkerDetector(store: .shared)
    typealias Fetch = @Sendable (JellyfinAPI, MediaItem, Double, Double) async throws -> Data
    typealias Decode = @Sendable (Data) throws -> [Float]

    private enum Part: String { case head, tail }
    private static let bitrate = 32_000.0
    private static let printLimit = 8

    private let store: MarkerStore
    private let fetch: Fetch
    private let decode: Decode
    private var prints: [String: AudioFingerprint.Print?] = [:]
    private var printOrder: [String] = []
    private var refused: Set<String> = []

    init(store: MarkerStore, fetch: @escaping Fetch = MarkerDetector.download, decode: @escaping Decode = MarkerDetector.decodeMP3) {
        self.store = store; self.fetch = fetch; self.decode = decode
    }

    static func accountID(_ api: JellyfinAPI) -> String { api.server.absoluteString + "|" + (api.userID ?? "") }

    static func runtime(_ item: MediaItem) -> Double? {
        guard let ticks = item.RunTimeTicks, ticks > 0 else { return nil }
        return Double(ticks) / ticksPerSecond
    }

    /// The opening minutes to scan: 30% of the episode, between three and ten minutes.
    static func headWindow(_ item: MediaItem) -> (start: Double, seconds: Double) {
        guard let length = runtime(item) else { return (0, 600) }
        return (0, min(length, max(180, min(600, length * 0.3))))
    }

    /// The closing minutes to scan: 20% of the episode, between 90 seconds and five minutes.
    static func tailWindow(_ item: MediaItem) -> (start: Double, seconds: Double)? {
        guard let length = runtime(item), length >= 300 else { return nil }
        let seconds = max(90, min(300, length * 0.2))
        return (length - seconds, seconds)
    }

    /// What has already been found for this item, without scanning anything.
    nonisolated func known(accountID: String, item: MediaItem) -> FoundMarkers {
        let entry = store.get(accountID + "|" + item.id), length = Self.runtime(item)
        var markers = FoundMarkers()
        if let i = entry?.i, i.count == 2, length == nil || i[1] <= length! { markers.intro = i[0]...i[1] }
        if let c = entry?.c, c > 0, length == nil || c < length! { markers.credits = c }
        return markers
    }

    /// Scans this episode against its neighbors for whatever is not yet known, and returns all that is.
    func detect(api: JellyfinAPI, item: MediaItem, neighbors: [MediaItem], intro: Bool, credits: Bool) async throws -> FoundMarkers {
        let accountID = Self.accountID(api), entry = store.get(accountID + "|" + item.id)
        var seen: Set<String> = [item.id]
        let others = Array(neighbors.filter { $0.Type == "Episode" && seen.insert($0.id).inserted }.prefix(2))
        if item.Type == "Episode", !others.isEmpty, !refused.contains(api.server.absoluteString) {
            if intro, entry?.i == nil { try await compare(api, accountID, item, others, .head) }
            if credits, entry?.c == nil, Self.tailWindow(item) != nil { try await compare(api, accountID, item, others.filter { Self.tailWindow($0) != nil }, .tail) }
        }
        try Task.checkCancellation()
        return known(accountID: accountID, item: item)
    }

    private func key(_ api: JellyfinAPI, _ item: MediaItem, _ part: Part) -> String { api.server.absoluteString + "|" + item.id + "|" + part.rawValue }

    private func compare(_ api: JellyfinAPI, _ accountID: String, _ item: MediaItem, _ others: [MediaItem], _ part: Part) async throws {
        guard !others.isEmpty else { return }
        // Neighbors already fingerprinted this session come first: comparing with them downloads nothing more.
        let ordered = others.enumerated().sorted { first, second in
            let a = prints[key(api, first.element, part)] != nil, b = prints[key(api, second.element, part)] != nil
            return a != b ? a : first.offset < second.offset
        }.map(\.element)
        guard let mine = try await print(api, item, part) else { return }
        var compared = false
        for other in ordered {
            guard let theirs = try await print(api, other, part) else { continue }
            compared = true
            let found = AudioFingerprint.sharedRun(mine, theirs, minSeconds: 15, maxSeconds: part == .head ? 150 : .infinity)
            try Task.checkCancellation()
            guard let run = found else { continue }
            let mineKey = accountID + "|" + item.id, otherKey = accountID + "|" + other.id
            if part == .head {
                store.update(mineKey) { $0.i = [run.aStart, run.aEnd] }
                if store.get(otherKey)?.i == nil { store.update(otherKey) { $0.i = [run.bStart, run.bEnd] } }
                return
            }
            // The credits must leave at least ten seconds; a match in the last moments is a closing logo.
            let mineStart = Self.tailWindow(item)!.start + run.aStart, theirStart = Self.tailWindow(other)!.start + run.bStart
            store.update(mineKey) { $0.c = Self.runtime(item)! - mineStart >= 10 ? mineStart : 0 }
            if store.get(otherKey)?.c == nil, Self.runtime(other)! - theirStart >= 10 { store.update(otherKey) { $0.c = theirStart } }
            return
        }
        if compared { store.update(accountID + "|" + item.id) { if part == .head { $0.i = [] } else { $0.c = 0 } } }
    }

    private func print(_ api: JellyfinAPI, _ item: MediaItem, _ part: Part) async throws -> AudioFingerprint.Print? {
        let key = key(api, item, part)
        if let cached = prints[key] { printOrder.removeAll { $0 == key }; printOrder.append(key); return cached }
        guard !refused.contains(api.server.absoluteString),
              let window = part == .head ? Self.headWindow(item) : Self.tailWindow(item) else { return nil }
        let data: Data
        do { data = try await fetch(api, item, window.start, window.seconds) }
        catch is CancellationError { throw CancellationError() }
        catch ReelError.unauthorized { refused.insert(api.server.absoluteString); return nil }
        catch ReelError.server(let status) {
            // A server that will not transcode audio for this account is not asked again this session.
            if [400, 415].contains(status) { refused.insert(api.server.absoluteString) }
            remember(key, nil); return nil
        }
        // A dropped connection is tried again next time.
        catch { return nil }
        let decode = self.decode
        // A server that sends a lower bitrate than asked fits more audio into the same bytes. Past the opening
        // window it would reach the credits music, which would then be taken for the intro.
        let most = Int((window.seconds * AudioFingerprint.sampleRate).rounded(.up))
        let made = try await Task.detached(priority: .utility) { () throws -> AudioFingerprint.Print? in
            guard let samples = try? decode(data) else { return nil }
            try Task.checkCancellation()
            return AudioFingerprint.make(samples.count > most ? Array(samples.prefix(most)) : samples)
        }.value
        try Task.checkCancellation()
        remember(key, made)
        return made
    }

    private func remember(_ key: String, _ print: AudioFingerprint.Print?) {
        prints[key] = .some(print); printOrder.append(key)
        while printOrder.count > Self.printLimit { prints[printOrder.removeFirst()] = nil }
    }

    // MARK: Download and decode

    private static func scanSession() -> String {
        "reel-scan-" + (0..<12).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    @Sendable static func download(_ api: JellyfinAPI, _ item: MediaItem, _ start: Double, _ seconds: Double) async throws -> Data {
        var query = ["audioCodec": "mp3", "audioChannels": "1", "maxAudioChannels": "1", "audioSampleRate": "16000",
                     "audioBitRate": String(Int(bitrate)), "playSessionId": scanSession()]
        if start > 0 { query["startTimeTicks"] = String(Int64((start * ticksPerSecond).rounded())) }
        if let source = item.MediaSources?.first?.Id { query["mediaSourceId"] = source }
        var request = api.request("Audio/\(item.id)/stream.mp3", query: query)
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 20
        let (bytes, response) = try await JellyfinAPI.transport.bytes(for: request, delegate: api.redirects)
        defer { bytes.task.cancel() }
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw ReelError.invalidResponse }
        guard (200..<300).contains(status) else { throw status == 401 || status == 403 ? ReelError.unauthorized : ReelError.server(status) }
        let limit = Int((seconds * bitrate / 8).rounded(.up)) + 16_384
        var data = Data(); data.reserveCapacity(limit)
        for try await byte in bytes {
            data.append(byte)
            if data.count >= limit { break }
        }
        return data
    }

    private static let layer3Kbps: [Int: [Int]] = [1: [0, 32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320],
                                                   2: [0, 8, 16, 24, 32, 40, 48, 56, 64, 80, 96, 112, 128, 144, 160]]
    private static let layer3Rates: [Int: [Int]] = [3: [44100, 48000, 32000], 2: [22050, 24000, 16000], 0: [11025, 12000, 8000]]

    /// The length of the MPEG Layer III frame whose header starts at `at`, or 0 when no such header is there.
    static func frameLength(_ bytes: [UInt8], at: Int) -> Int {
        guard at + 4 <= bytes.count, bytes[at] == 0xff, bytes[at + 1] & 0xe0 == 0xe0, (bytes[at + 1] >> 1) & 3 == 1 else { return 0 }
        let version = Int((bytes[at + 1] >> 3) & 3), index = Int(bytes[at + 2] >> 4), rateIndex = Int((bytes[at + 2] >> 2) & 3)
        guard let kbps = layer3Kbps[version == 3 ? 1 : 2]?[safe: index], kbps > 0, let rate = layer3Rates[version]?[safe: rateIndex] else { return 0 }
        return (version == 3 ? 144 : 72) * kbps * 1000 / rate + Int((bytes[at + 2] >> 1) & 1)
    }

    /// Cuts a partial MP3 frame off the end of a download stopped mid-stream, stepping from frame to frame by each
    /// header's own length so bytes inside the audio that look like a header are never visited.
    static func wholeFrames(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var at = 0
        if bytes.count > 10, bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 {
            at = 10 + (Int(bytes[6] & 0x7f) << 21 | Int(bytes[7] & 0x7f) << 14 | Int(bytes[8] & 0x7f) << 7 | Int(bytes[9] & 0x7f))
        }
        guard frameLength(bytes, at: at) > 0 else { return data }
        var length = frameLength(bytes, at: at)
        while length > 0, at + length <= bytes.count { at += length; length = frameLength(bytes, at: at) }
        return data.prefix(at)
    }

    /// Decodes MP3 to mono samples at the fingerprint rate.
    @Sendable static func decodeMP3(_ data: Data) throws -> [Float] {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("reel-scan-\(UUID().uuidString).mp3")
        try wholeFrames(data).write(to: url, options: .atomic)
        defer { try? FileManager.default.removeItem(at: url) }
        let file = try AVAudioFile(forReading: url)
        guard let output = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioFingerprint.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: file.processingFormat, to: output),
              let input = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384) else { throw ReelError.invalidResponse }
        var samples: [Float] = []
        var finished = false
        while true {
            guard let buffer = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 16_384) else { throw ReelError.invalidResponse }
            var failure: NSError?
            let status = converter.convert(to: buffer, error: &failure) { _, state in
                if finished { state.pointee = .endOfStream; return nil }
                do { try file.read(into: input, frameCount: 16_384) } catch { finished = true; state.pointee = .endOfStream; return nil }
                if input.frameLength == 0 { finished = true; state.pointee = .endOfStream; return nil }
                state.pointee = .haveData
                return input
            }
            if let channel = buffer.floatChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) }
            if status == .endOfStream || status == .error || buffer.frameLength == 0 && finished { break }
        }
        return samples
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
