import Foundation
import Observation

struct ServerSetting<Value: Codable & Equatable & Sendable>: Codable, Equatable, Sendable {
    let value: Value
    let locked: Bool
    init(value: Value, locked: Bool = false) { self.value = value; self.locked = locked }
    private enum CodingKeys: String, CodingKey { case value, locked }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        value = try container.decode(Value.self, forKey: .value)
        locked = try container.decodeIfPresent(Bool.self, forKey: .locked) ?? false
    }
}

enum ServerSegmentMode: String, Codable, Sendable { case none, ask, auto }

struct ImportedServerSettings: Codable, Equatable, Sendable {
    var forwardSkipTime: ServerSetting<Int>?
    var rewindSkipTime: ServerSetting<Int>?
    var defaultPlaybackSpeed: ServerSetting<Double>?
    var defaultBitrate: ServerSetting<Int?>?
    var skipIntro: ServerSetting<ServerSegmentMode>?
    var skipOutro: ServerSetting<ServerSegmentMode>?
    var skipRecap: ServerSetting<ServerSegmentMode>?
    var skipPreview: ServerSetting<ServerSegmentMode>?

    // Decode only settings Reel can apply. Never retain service API keys, custom endpoints or push settings.
    static func decode(_ data: Data) throws -> Self {
        struct Envelope: Decodable { let settings: ImportedServerSettings? }
        guard data.count <= 1_048_576 else { throw ReelError.invalidResponse }
        let settings = try JSONDecoder().decode(Envelope.self, from: data).settings ?? Self()
        return settings.validated()
    }

    func validated() -> Self {
        var result = self
        if let value = forwardSkipTime?.value, !(1...300).contains(value) { result.forwardSkipTime = nil }
        if let value = rewindSkipTime?.value, !(1...300).contains(value) { result.rewindSkipTime = nil }
        if let value = defaultPlaybackSpeed?.value, !value.isFinite || !(0.5...2).contains(value) { result.defaultPlaybackSpeed = nil }
        if let value = defaultBitrate?.value, !(250_000...120_000_000).contains(value) { result.defaultBitrate = nil }
        return result
    }

    var isEmpty: Bool {
        forwardSkipTime == nil && rewindSkipTime == nil && defaultPlaybackSpeed == nil && defaultBitrate == nil
            && skipIntro == nil && skipOutro == nil && skipRecap == nil && skipPreview == nil
    }
}

@MainActor @Observable final class ServerPreferences {
    enum Status: Equatable { case idle, loading, ready, unavailable, failed }
    private(set) var status = Status.idle
    private(set) var enabled = false
    private(set) var settings: ImportedServerSettings?
    private(set) var error: String?
    @ObservationIgnored private var accountID: String?
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    private func enabledKey(_ id: String) -> String { "serverPreferences.enabled|" + id }
    private func settingsKey(_ id: String) -> String { "serverPreferences.settings|" + id }

    func activate(accountID: String, api: JellyfinAPI) async {
        let current = UUID(); generation = current
        self.accountID = accountID
        enabled = defaults.bool(forKey: enabledKey(accountID))
        error = nil
        settings = nil
        if enabled, let data = defaults.data(forKey: settingsKey(accountID)),
           let cached = try? JSONDecoder().decode(ImportedServerSettings.self, from: data) { settings = cached.validated() }
        guard enabled else { status = .idle; return }
        status = .loading
        do {
            let data = try await api.send(api.request("streamyfin/config"))
            let result = try ImportedServerSettings.decode(data)
            try Task.checkCancellation()
            guard generation == current else { return }
            settings = result
            defaults.set(try JSONEncoder().encode(result), forKey: settingsKey(accountID))
            status = .ready
        } catch is CancellationError { }
        catch ReelError.server(404) {
            guard generation == current else { return }
            settings = nil
            defaults.removeObject(forKey: settingsKey(accountID))
            status = .unavailable
        } catch {
            guard generation == current else { return }
            self.error = settings == nil ? "Server preferences couldn’t be loaded. Reel is using your local playback settings." : "Server preferences couldn’t be refreshed. Previously imported playback settings remain active."
            status = .failed
        }
    }

    func setEnabled(_ value: Bool, accountID: String) {
        defaults.set(value, forKey: enabledKey(accountID))
        if self.accountID == accountID {
            enabled = value
            if !value { generation = UUID(); settings = nil; status = .idle; error = nil }
        }
    }

    func clear(accountID: String) {
        defaults.removeObject(forKey: enabledKey(accountID))
        defaults.removeObject(forKey: settingsKey(accountID))
        if self.accountID == accountID { generation = UUID(); self.accountID = nil; enabled = false; settings = nil; status = .idle; error = nil }
    }

    var rateLocked: Bool { enabled && settings?.defaultPlaybackSpeed?.locked == true }
    var bitrateLocked: Bool { enabled && settings?.defaultBitrate?.locked == true }
    func playbackRate(local: Float = 1) -> Float { enabled ? settings?.defaultPlaybackSpeed.map { Float($0.value) } ?? local : local }
    func bitrate(local: Int) -> Int {
        guard enabled, let setting = settings?.defaultBitrate else { return local }
        return setting.value ?? StreamQuality.original.rawValue
    }
    /// Ten seconds unless the server sets a skip length, matching the system player's own skips.
    func forwardSkip(local: Int = 10) -> Int { enabled ? settings?.forwardSkipTime?.value ?? local : local }
    func rewindSkip(local: Int = 10) -> Int { enabled ? settings?.rewindSkipTime?.value ?? local : local }
    func segmentMode(_ type: String) -> ServerSegmentMode {
        guard enabled else { return .ask }
        switch type {
        case "Intro": return settings?.skipIntro?.value ?? .ask
        case "Outro": return settings?.skipOutro?.value ?? .ask
        case "Recap": return settings?.skipRecap?.value ?? .ask
        case "Preview": return settings?.skipPreview?.value ?? .ask
        default: return .ask
        }
    }
}
