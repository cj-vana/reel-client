import Foundation
import Observation

struct LiveTVProgram: Codable, Hashable, Identifiable, Sendable {
    let Id: String
    let Name: String
    var Overview: String?
    var ChannelId: String?
    var ChannelName: String?
    var StartDate: String?
    var EndDate: String?
    var EpisodeTitle: String?
    var IsSeries: Bool?
    var IsRepeat: Bool?
    var TimerId: String?
    var SeriesTimerId: String?
    var ImageTags: [String: String]?
    var id: String { Id }
    var start: Date? { LiveTVDate.parse(StartDate) }
    var end: Date? { LiveTVDate.parse(EndDate) }
    func isAiring(at now: Date = .now) -> Bool {
        guard let start, let end else { return false }
        return start <= now && now < end
    }
    func canRecord(at now: Date = .now) -> Bool {
        guard let channel = ChannelId, !channel.isEmpty, let start, let end else { return false }
        return end > now && end > start
    }
    var artworkItem: MediaItem { MediaItem(Id: Id, Name: Name, Type: "Program", Overview: Overview, ImageTags: ImageTags) }
}

struct LiveTVProgramPage: Decodable, Sendable {
    var Items: [LiveTVProgram]
    var TotalRecordCount: Int?
}

struct LiveTVPolicy: Decodable, Sendable {
    var EnableLiveTvAccess: Bool?
    var EnableLiveTvManagement: Bool?
}

struct LiveTVUser: Decodable, Sendable {
    var Policy: LiveTVPolicy?
}

struct LiveTVTimer: Decodable, Hashable, Identifiable, Sendable {
    let Id: String
    var Name: String?
    var ChannelName: String?
    var ChannelId: String?
    var ProgramId: String?
    var SeriesTimerId: String?
    var StartDate: String?
    var EndDate: String?
    var Status: String?
    var RecordNewOnly: Bool?
    var RecordAnyChannel: Bool?
    var RecordAnyTime: Bool?
    var id: String { Id }
    var start: Date? { LiveTVDate.parse(StartDate) }
    var end: Date? { LiveTVDate.parse(EndDate) }
    var isCancelled: Bool { Status == "Cancelled" || Status == "Aborted" }
}

struct LiveTVTimerPage: Decodable, Sendable {
    var Items: [LiveTVTimer]
    var TotalRecordCount: Int?
}

enum LiveTVDate {
    static func parse(_ value: String?) -> Date? {
        guard let value else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
    static func string(_ value: Date) -> String { ISO8601DateFormatter().string(from: value) }
    static func interval(for date: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: date)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }
}

// Keep provider defaults, including fields added by a newer Jellyfin version.
indirect enum LiveTVValue: Codable, Equatable, Sendable {
    case string(String), number(Double), bool(Bool), array([LiveTVValue]), object([String: LiveTVValue]), null
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([LiveTVValue].self) { self = .array(value) }
        else { self = .object(try container.decode([String: LiveTVValue].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

struct LiveTVRecordingDraft: Codable, Equatable, Sendable {
    var values: [String: LiveTVValue]
    init(values: [String: LiveTVValue] = [:]) { self.values = values }
    init(from decoder: any Decoder) throws { values = try decoder.singleValueContainer().decode([String: LiveTVValue].self) }
    func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(values) }
    var prePaddingMinutes: Int {
        get { number("PrePaddingSeconds") / 60 }
        set { values["PrePaddingSeconds"] = .number(Double(max(0, newValue) * 60)) }
    }
    var postPaddingMinutes: Int {
        get { number("PostPaddingSeconds") / 60 }
        set { values["PostPaddingSeconds"] = .number(Double(max(0, newValue) * 60)) }
    }
    var newEpisodesOnly: Bool {
        get { boolean("RecordNewOnly", fallback: true) }
        set { values["RecordNewOnly"] = .bool(newValue) }
    }
    var anyChannel: Bool {
        get { boolean("RecordAnyChannel", fallback: false) }
        set { values["RecordAnyChannel"] = .bool(newValue) }
    }
    var anyTime: Bool {
        get { boolean("RecordAnyTime", fallback: true) }
        set { values["RecordAnyTime"] = .bool(newValue) }
    }
    var skipExisting: Bool {
        get { boolean("SkipEpisodesInLibrary", fallback: true) }
        set { values["SkipEpisodesInLibrary"] = .bool(newValue) }
    }
    private func number(_ key: String) -> Int {
        guard case let .number(value) = values[key], value.isFinite, value >= 0, value <= Double(Int.max / 2) else { return 0 }
        return Int(value)
    }
    private func boolean(_ key: String, fallback: Bool) -> Bool {
        if case let .bool(value) = values[key] { return value }
        return fallback
    }
    func creating(program: LiveTVProgram, series: Bool) throws -> LiveTVRecordingDraft {
        guard program.canRecord(), let channel = program.ChannelId, let start = program.StartDate, let end = program.EndDate else { throw LiveTVError.programEnded }
        if series && program.IsSeries != true { throw LiveTVError.notSeries }
        var result = self
        result.values.removeValue(forKey: "Id")
        result.values["Type"] = .string(series ? "SeriesTimer" : "Timer")
        result.values["ProgramId"] = .string(program.id)
        result.values["ChannelId"] = .string(channel)
        result.values["Name"] = .string(program.Name)
        result.values["StartDate"] = .string(start)
        result.values["EndDate"] = .string(end)
        if series {
            result.values["RecordNewOnly"] = .bool(newEpisodesOnly)
            result.values["RecordAnyChannel"] = .bool(anyChannel)
            result.values["RecordAnyTime"] = .bool(anyTime)
            result.values["SkipEpisodesInLibrary"] = .bool(skipExisting)
        }
        return result
    }
}

enum LiveTVError: LocalizedError {
    case programEnded, notSeries, managementDenied
    var errorDescription: String? {
        switch self {
        case .programEnded: "This program has ended or its schedule is unavailable. Refresh the guide before recording."
        case .notSeries: "This program has no series information. You can record this airing instead."
        case .managementDenied: "Your Jellyfin account does not have permission to manage recordings."
        }
    }
}

struct LiveTVAPI: Sendable {
    let api: JellyfinAPI
    func permissions() async throws -> LiveTVUser { try await api.get("Users/Me") }
    func channels(startIndex: Int = 0) async throws -> ItemPage {
        try await api.page("LiveTv/Channels", query: ["addCurrentProgram": "true", "sortBy": "SortName", "sortOrder": "Ascending", "limit": "100", "startIndex": String(startIndex)])
    }
    func guide(date: Date, channelID: String = "", startIndex: Int = 0) async throws -> LiveTVProgramPage {
        let interval = LiveTVDate.interval(for: date)
        var query = ["userId": api.userID ?? "", "minEndDate": LiveTVDate.string(interval.start), "maxStartDate": LiveTVDate.string(interval.end), "sortBy": "StartDate", "sortOrder": "Ascending", "fields": "Overview", "limit": "200", "startIndex": String(startIndex)]
        if !channelID.isEmpty { query["channelIds"] = channelID }
        return try await api.get("LiveTv/Programs", query: query)
    }
    func program(_ id: String) async throws -> LiveTVProgram { try await api.get("LiveTv/Programs/\(id)", query: ["userId": api.userID ?? ""]) }
    func timers() async throws -> [LiveTVTimer] {
        let page: LiveTVTimerPage = try await api.get("LiveTv/Timers")
        return page.Items.filter { !$0.isCancelled }.sorted { ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
    }
    func series() async throws -> [LiveTVTimer] {
        let page: LiveTVTimerPage = try await api.get("LiveTv/SeriesTimers", query: ["sortBy": "SortName", "sortOrder": "Ascending"])
        return page.Items
    }
    func recordings(startIndex: Int = 0) async throws -> ItemPage {
        try await api.page("LiveTv/Recordings", query: ["limit": "60", "startIndex": String(startIndex), "enableTotalRecordCount": "true"])
    }
    func defaults(program: LiveTVProgram) async throws -> LiveTVRecordingDraft {
        try await api.get("LiveTv/Timers/Defaults", query: ["programId": program.id])
    }
    func schedule(program: LiveTVProgram, draft: LiveTVRecordingDraft, series: Bool) async throws {
        let prepared = try draft.creating(program: program, series: series)
        let data = try JSONEncoder().encode(prepared)
        _ = try await api.send(api.request(series ? "LiveTv/SeriesTimers" : "LiveTv/Timers", method: "POST", body: data))
    }
    func cancel(_ timer: LiveTVTimer, series: Bool) async throws {
        try await api.post((series ? "LiveTv/SeriesTimers/" : "LiveTv/Timers/") + timer.id, method: "DELETE")
    }
}

enum LiveTVSection: String, CaseIterable, Identifiable {
    case channels = "Channels", guide = "Guide", recordings = "Recordings", scheduled = "Scheduled", series = "Series rules"
    var id: String { rawValue }
}

@MainActor @Observable final class LiveTVStore {
    private(set) var channels: [MediaItem] = []
    private(set) var programs: [LiveTVProgram] = []
    private(set) var recordings: [MediaItem] = []
    private(set) var timers: [LiveTVTimer] = []
    private(set) var seriesRules: [LiveTVTimer] = []
    private(set) var policy: LiveTVPolicy?
    private(set) var policyError: String?
    private(set) var loading = false
    private(set) var error: String?
    private(set) var hasMore = false
    private(set) var mutating = false
    private var generation = UUID()

    func loadPermissions(api: JellyfinAPI) async {
        guard !Task.isCancelled else { return }
        do {
            let user = try await LiveTVAPI(api: api).permissions()
            try Task.checkCancellation()
            policy = user.Policy; policyError = nil
        } catch is CancellationError { }
        catch { policy = nil; policyError = "Recording permissions couldn’t be checked. Refresh Live TV to try again." }
    }
    func canManage(api: JellyfinAPI) -> Bool { policy?.EnableLiveTvAccess == true && policy?.EnableLiveTvManagement == true && !api.isSimulatorPreview }
    func load(api: JellyfinAPI, section: LiveTVSection, date: Date, channelID: String, append: Bool = false) async {
        guard !Task.isCancelled else { return }
        let current = UUID(); generation = current
        loading = true; error = nil
        if !append { hasMore = false }
        defer { if generation == current { loading = false } }
        let service = LiveTVAPI(api: api)
        do {
            switch section {
            case .channels:
                let page = try await service.channels(startIndex: append ? channels.count : 0)
                try Task.checkCancellation(); guard generation == current else { return }
                channels = append ? Self.merging(channels, page.Items) : page.Items
                hasMore = channels.count < (page.TotalRecordCount ?? channels.count)
            case .guide:
                let page = try await service.guide(date: date, channelID: channelID, startIndex: append ? programs.count : 0)
                try Task.checkCancellation(); guard generation == current else { return }
                let existing = append ? programs : []
                let ids = Set(existing.map(\.id))
                programs = existing + page.Items.filter { !ids.contains($0.id) }
                hasMore = programs.count < (page.TotalRecordCount ?? programs.count)
            case .recordings:
                let page = try await service.recordings(startIndex: append ? recordings.count : 0)
                try Task.checkCancellation(); guard generation == current else { return }
                recordings = append ? Self.merging(recordings, page.Items) : page.Items
                hasMore = recordings.count < (page.TotalRecordCount ?? recordings.count)
            case .scheduled:
                let result = try await service.timers()
                try Task.checkCancellation(); guard generation == current else { return }
                timers = result; hasMore = false
            case .series:
                let result = try await service.series()
                try Task.checkCancellation(); guard generation == current else { return }
                seriesRules = result; hasMore = false
            }
        } catch is CancellationError { }
        catch { if generation == current { self.error = Self.message(error) } }
    }
    func cancel(api: JellyfinAPI, timer: LiveTVTimer, series: Bool) async throws {
        guard canManage(api: api) else {
            if api.isSimulatorPreview { throw ReelError.previewProtected }
            throw LiveTVError.managementDenied
        }
        guard !mutating else { return }
        mutating = true
        defer { mutating = false }
        try await LiveTVAPI(api: api).cancel(timer, series: series)
        if series { seriesRules.removeAll { $0.id == timer.id }; timers.removeAll { $0.SeriesTimerId == timer.id } }
        else { timers.removeAll { $0.id == timer.id } }
    }
    static func message(_ error: any Error) -> String {
        if let error = error as? ReelError, error == .unauthorized { return "Live TV isn’t available to this account, or your sign-in expired. Check your server permissions or sign in again from Servers." }
        return error.localizedDescription
    }
    private static func merging(_ existing: [MediaItem], _ incoming: [MediaItem]) -> [MediaItem] {
        let ids = Set(existing.map(\.id))
        return existing + incoming.filter { !ids.contains($0.id) }
    }
}
