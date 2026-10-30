import Foundation

let ticksPerSecond: Double = 10_000_000

struct Account: Codable, Equatable, Identifiable, Sendable {
    var id: String { server.absoluteString + "|" + userID }
    let server: URL
    let token: String
    let userID: String
    let name: String
    let serverName: String
}

struct ServerInfo: Decodable, Sendable {
    let ServerName: String
    let Version: String?
}

struct User: Codable, Sendable {
    let Id: String
    let Name: String
}

struct Authentication: Decodable, Sendable {
    let AccessToken: String
    let User: User
}

struct ItemPage: Codable, Sendable {
    var Items: [MediaItem]
    var TotalRecordCount: Int?
}

struct UserData: Codable, Hashable, Sendable {
    var PlaybackPositionTicks: Int64?
    var PlayedPercentage: Double?
    var IsFavorite: Bool?
    var Played: Bool?
    var PlayCount: Int?
    var LastPlayedDate: String?
    var UnplayedItemCount: Int?
}

enum WatchedItemKind: String, Sendable {
    case leaf, container, unknown
}

struct MediaItem: Codable, Hashable, Identifiable, Sendable {
    let Id: String
    let Name: String
    var `Type`: String?
    var IsFolder: Bool?
    var Overview: String?
    var ProductionYear: Int?
    var DateCreated: String?
    var DateLastMediaAdded: String?
    var OfficialRating: String?
    var CommunityRating: Double?
    var RunTimeTicks: Int64?
    var ImageTags: [String: String]?
    var BackdropImageTags: [String]?
    var ParentBackdropItemId: String?
    var ParentBackdropImageTags: [String]?
    var SeriesId: String?
    var SeriesName: String?
    var SeriesPrimaryImageTag: String?
    var IndexNumber: Int?
    var ParentIndexNumber: Int?
    var UserData: UserData?
    var Genres: [String]?
    var MediaSources: [MediaSource]?
    var People: [Person]?
    var Chapters: [Chapter]?
    var CurrentProgram: Program?
    var PlaylistItemId: String?
    var listingID: String { PlaylistItemId ?? Id }

    var id: String { Id }
    var title: String { Type == "Episode" ? (SeriesName ?? Name) : Name }
    var isContainer: Bool { ["BoxSet", "Playlist", "Folder", "CollectionFolder"].contains(Type ?? "") }
    var isSeries: Bool { Type == "Series" }
    // Watched mutation scope is broader than the video browser's navigation
    // container list. A Played flag alone never establishes leaf semantics.
    var watchedKind: WatchedItemKind {
        if IsFolder == true { return .container }
        switch Type {
        case "Series", "Season", "BoxSet", "Playlist", "Folder", "CollectionFolder",
             "MusicAlbum", "MusicArtist", "PhotoAlbum", "AggregateFolder", "BasePluginFolder",
             "ChannelFolderItem", "ManualPlaylistsFolder", "PlaylistsFolder", "UserRootFolder", "UserView":
            return .container
        case "Movie", "Episode", "Video", "MusicVideo", "Audio", "AudioBook", "Book", "Photo", "Trailer":
            return .leaf
        default: return .unknown
        }
    }
    var supportsWatchedMutation: Bool { watchedKind != .unknown }
    var isAggregate: Bool { watchedKind == .container }
    var serverPlayed: Bool? { UserData?.Played }
    var itemWatched: Bool? { watchedKind == .leaf ? serverPlayed : nil }
    var aggregateUnplayedCount: Int? {
        guard isAggregate, let count = UserData?.UnplayedItemCount, count >= 0 else { return nil }
        return count
    }
    var isFavorite: Bool { UserData?.IsFavorite == true }
    var resumeTicks: Int64 { max(0, UserData?.PlaybackPositionTicks ?? 0) }
    var progress: Double {
        if let total = RunTimeTicks, total > 0 { return min(1, max(0, Double(resumeTicks) / Double(total))) }
        return min(1, max(0, (UserData?.PlayedPercentage ?? 0) / 100))
    }
    var subtitle: String {
        if Type == "Episode" {
            return [episodeNumberText, Name].filter { !$0.isEmpty }.joined(separator: " ")
        }
        return [ProductionYear.map(String.init), Type == "Series" ? "Series" : duration].compactMap { $0 }.joined(separator: " · ")
    }
    var episodeNumberText: String {
        [ParentIndexNumber.flatMap { $0 >= 0 ? "S\($0)" : nil }, IndexNumber.flatMap { $0 >= 0 ? "E\($0)" : nil }].compactMap { $0 }.joined(separator: " ")
    }
    var addedDateText: String? { Self.catalogueDate(DateCreated).map { "Added \($0)" } }
    var lastMediaAddedDateText: String? { Self.catalogueDate(DateLastMediaAdded).map { "Content added \($0)" } }
    private static func catalogueDate(_ value: String?) -> String? {
        guard let value, value.utf8.count <= 64,
              value.range(of: #"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}(\.[0-9]{1,9})?(Z|[+-][0-9]{2}:[0-9]{2})\z"#, options: .regularExpression) != nil else { return nil }
        let stamp = Array(value.utf8)
        func number(_ range: Range<Int>) -> Int? { Int(String(decoding: stamp[range], as: UTF8.self)) }
        guard let year = number(0..<4), year > 1,
              let month = number(5..<7), (1...12).contains(month),
              let day = number(8..<10),
              let hour = number(11..<13), (0...23).contains(hour),
              let minute = number(14..<16), (0...59).contains(minute),
              let second = number(17..<19), (0...59).contains(second) else { return nil }
        if stamp.last != 90 {
            let offset = stamp.count - 6
            guard let zoneHour = number((offset + 1)..<(offset + 3)), (0...23).contains(zoneHour),
                  let zoneMinute = number((offset + 4)..<(offset + 6)), (0...59).contains(zoneMinute) else { return nil }
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let first = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              calendar.range(of: .day, in: .month, for: first)?.contains(day) == true else { return nil }
        let date = (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(value))
            ?? (try? Date.ISO8601FormatStyle().parse(value))
        return date?.formatted(date: .abbreviated, time: .omitted)
    }
    var duration: String? {
        guard let ticks = RunTimeTicks, ticks > 0 else { return nil }
        return Self.durationText(ticks: ticks)
    }
    /// Time left for a resumable title, such as "42m left".
    var remainingText: String? {
        guard let total = RunTimeTicks, resumeTicks > 0, resumeTicks < total else { return nil }
        return Self.durationText(ticks: total - resumeTicks) + " left"
    }
    static func durationText(ticks: Int64) -> String {
        let seconds = Int(Double(ticks) / ticksPerSecond)
        if seconds < 60 { return "\(max(1, seconds))s" }
        let minutes = seconds / 60
        if minutes < 60 { return "\(minutes)m" }
        return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m"
    }
    var metadata: String {
        [ProductionYear.map(String.init), OfficialRating, isSeries ? "Series" : duration].compactMap { $0 }.joined(separator: "   ·   ")
    }
    /// The item to draw in a landscape thumbnail: an episode's own still when
    /// it has one, otherwise the item itself (whose backdrop is the series art).
    var thumbnailItem: MediaItem {
        guard Type == "Episode", ImageTags?["Primary"] != nil else { return self }
        var still = self
        still.ParentBackdropItemId = nil; still.ParentBackdropImageTags = nil
        return still
    }

    func imageReference(backdrop: Bool) -> (id: String, type: String, tag: String?) {
        if backdrop {
            if let tag = BackdropImageTags?.first { return (id, "Backdrop", tag) }
            if let parent = ParentBackdropItemId, let tag = ParentBackdropImageTags?.first { return (parent, "Backdrop", tag) }
            if let tag = ImageTags?["Thumb"] { return (id, "Thumb", tag) }
        }
        if Type == "Episode", let series = SeriesId, let tag = SeriesPrimaryImageTag, !backdrop {
            return (series, "Primary", tag)
        }
        return (id, "Primary", ImageTags?["Primary"])
    }
}

extension UserData {
    private enum CodingKeys: String, CodingKey {
        case PlaybackPositionTicks, PlayedPercentage, IsFavorite, Played, PlayCount, LastPlayedDate, UnplayedItemCount
    }
    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        PlaybackPositionTicks = try values.decodeIfPresent(Int64.self, forKey: .PlaybackPositionTicks)
        PlayedPercentage = try values.decodeIfPresent(Double.self, forKey: .PlayedPercentage)
        IsFavorite = try values.decodeIfPresent(Bool.self, forKey: .IsFavorite)
        Played = try values.decodeIfPresent(Bool.self, forKey: .Played)
        PlayCount = try values.decodeIfPresent(Int.self, forKey: .PlayCount)
        LastPlayedDate = try values.decodeIfPresent(String.self, forKey: .LastPlayedDate)
        UnplayedItemCount = try? values.decodeIfPresent(Int.self, forKey: .UnplayedItemCount)
    }
}

struct MediaSource: Codable, Hashable, Sendable {
    let Id: String
    var Name: String?
    var LiveStreamId: String?
    var RequiresClosing: Bool?
    var Container: String?
    var SupportsDirectPlay: Bool?
    var TranscodingUrl: String?
    var RunTimeTicks: Int64?
    var DefaultAudioStreamIndex: Int?
    var DefaultSubtitleStreamIndex: Int?
    var MediaStreams: [MediaStream]?

    /// Badges for what the server reports about this version: resolution,
    /// dynamic range, surround or spatial audio, and captions.
    var badges: [String] {
        let streams = MediaStreams ?? []
        let video = streams.first { $0.Type == "Video" }
        let audio = streams.filter { $0.Type == "Audio" }
        var result: [String] = []
        if let video {
            if (video.Width ?? 0) >= 3800 || (video.Height ?? 0) >= 2100 { result.append("4K") }
            let range = video.VideoRangeType ?? ""
            if range.hasPrefix("DOVI") { result.append("Dolby Vision") }
            else if range.hasPrefix("HDR10") || range == "HLG" { result.append(range == "HLG" ? "HLG" : "HDR") }
        }
        if audio.contains(where: { $0.AudioSpatialFormat == "DolbyAtmos" }) { result.append("Atmos") }
        else if let channels = audio.compactMap(\.Channels).max(), channels >= 6 { result.append(channels >= 8 ? "7.1" : "5.1") }
        if streams.contains(where: { $0.Type == "Subtitle" }) { result.append("CC") }
        return result
    }
}

struct MediaStream: Codable, Hashable, Sendable {
    let Index: Int
    let `Type`: String
    var DisplayTitle: String?
    var Codec: String?
    var Language: String?
    var IsExternal: Bool?
    var DeliveryMethod: String?
    var Title: String?
    var IsOriginal: Bool?
    var IsDefault: Bool?
    var IsForced: Bool?
    var IsHearingImpaired: Bool?
    var BitRate: Int?
    var BitDepth: Int?
    var Channels: Int?
    var SampleRate: Int?
    var Width: Int?
    var Height: Int?
    var VideoRangeType: String?
    var DvProfile: Int?
    var AudioSpatialFormat: String?
    var Profile: String?
    var DvBlSignalCompatibilityId: Int?
    var Hdr10PlusPresentFlag: Bool?
}

// New descriptive metadata is optional; malformed new fields must not break otherwise playable older DTOs.
extension MediaStream {
    enum CodingKeys: String, CodingKey { case Index, `Type`, DisplayTitle, Codec, Language, IsExternal, DeliveryMethod, Title, IsOriginal, IsDefault, IsForced, IsHearingImpaired, BitRate, BitDepth, Channels, SampleRate, Width, Height, VideoRangeType, DvProfile, AudioSpatialFormat, Profile, DvBlSignalCompatibilityId, Hdr10PlusPresentFlag }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        Index = try values.decode(Int.self, forKey: .Index)
        Type = try values.decode(String.self, forKey: .Type)
        DisplayTitle = try values.decodeIfPresent(String.self, forKey: .DisplayTitle)
        Codec = try values.decodeIfPresent(String.self, forKey: .Codec)
        Language = try values.decodeIfPresent(String.self, forKey: .Language)
        IsExternal = try values.decodeIfPresent(Bool.self, forKey: .IsExternal)
        DeliveryMethod = try values.decodeIfPresent(String.self, forKey: .DeliveryMethod)
        Title = try? values.decodeIfPresent(String.self, forKey: .Title)
        IsOriginal = try? values.decodeIfPresent(Bool.self, forKey: .IsOriginal)
        IsDefault = try? values.decodeIfPresent(Bool.self, forKey: .IsDefault)
        IsForced = try? values.decodeIfPresent(Bool.self, forKey: .IsForced)
        IsHearingImpaired = try? values.decodeIfPresent(Bool.self, forKey: .IsHearingImpaired)
        BitRate = try? values.decodeIfPresent(Int.self, forKey: .BitRate)
        BitDepth = try? values.decodeIfPresent(Int.self, forKey: .BitDepth)
        Channels = try? values.decodeIfPresent(Int.self, forKey: .Channels)
        SampleRate = try? values.decodeIfPresent(Int.self, forKey: .SampleRate)
        Width = try? values.decodeIfPresent(Int.self, forKey: .Width)
        Height = try? values.decodeIfPresent(Int.self, forKey: .Height)
        VideoRangeType = try? values.decodeIfPresent(String.self, forKey: .VideoRangeType)
        DvProfile = try? values.decodeIfPresent(Int.self, forKey: .DvProfile)
        AudioSpatialFormat = try? values.decodeIfPresent(String.self, forKey: .AudioSpatialFormat)
        Profile = try? values.decodeIfPresent(String.self, forKey: .Profile)
        DvBlSignalCompatibilityId = try? values.decodeIfPresent(Int.self, forKey: .DvBlSignalCompatibilityId)
        Hdr10PlusPresentFlag = try? values.decodeIfPresent(Bool.self, forKey: .Hdr10PlusPresentFlag)
    }
}

struct PlaybackInfo: Decodable, Sendable {
    let MediaSources: [MediaSource]
    let PlaySessionId: String?
    let ErrorCode: String?
}

enum StreamQuality: Int, CaseIterable, Identifiable {
    case original = 120_000_000
    case high = 20_000_000
    case balanced = 8_000_000
    case dataSaver = 2_000_000
    var id: Int { rawValue }
    var label: String {
        switch self {
        case .original: "Original / auto"
        case .high: "High · 20 Mbps"
        case .balanced: "Balanced · 8 Mbps"
        case .dataSaver: "Data saver · 2 Mbps"
        }
    }
}

enum ReelError: LocalizedError, Equatable {
    case invalidServer, insecureRemote, unauthorized, server(Int), unavailable, invalidResponse, unsafeStream, noStream, storage, previewProtected
    var errorDescription: String? {
        switch self {
        case .invalidServer: "Enter a complete server address, such as https://jellyfin.example.com."
        case .insecureRemote: "Use HTTPS for a remote server. HTTP is supported on local networks and your Tailscale network."
        case .unauthorized: "Your sign-in was not accepted or has expired. Check your username and password, then sign in again."
        case .server(let status): "Jellyfin returned an error (\(status)). Try again in a moment."
        case .unavailable: "Your server couldn’t be reached. Check Wi-Fi or Tailscale and try again."
        case .invalidResponse: "The server returned a response Reel couldn’t read. Check that this is a Jellyfin server."
        case .unsafeStream: "The server returned a stream on a different server. Reel didn’t send your credentials."
        case .noStream: "Jellyfin couldn’t prepare a playable stream. Check your server’s transcoding settings."
        case .previewProtected: "Simulator preview protects your library. Changes to your real server are disabled."
        case .storage: "Reel couldn’t securely save your sign-in. Unlock your device and try again."
        }
    }
}

struct Person: Codable, Hashable, Identifiable, Sendable {
    let Id: String
    let Name: String
    var Role: String?
    var PrimaryImageTag: String?
    var id: String { Id }
}
struct Chapter: Codable, Hashable, Sendable {
    var Name: String?
    let StartPositionTicks: Int64
    var ImageTag: String?
}
struct Program: Codable, Hashable, Sendable {
    var Name: String?
    var Overview: String?
    var StartDate: String?
    var EndDate: String?
}

struct MediaSegmentPage: Decodable, Sendable { let Items: [MediaSegment] }
struct MediaSegment: Decodable, Identifiable, Sendable {
    let Id: String
    let `Type`: String
    let StartTicks: Int64
    let EndTicks: Int64
    var id: String { Id }
}
