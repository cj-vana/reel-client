import Foundation

/// Value-only matching; native AV objects and lifetime admission stay with PlaybackController.
enum PlaybackAudioSelection {
    enum Role: String, Hashable, Sendable { case auxiliary, description, original, translation, dubbed, voiceOver, forced, sdh }
    struct NativeOption: Equatable, Sendable {
        let titles: [String]
        let language: String?
        let roles: Set<Role>
        let playable: Bool
    }
    enum SelectionError: LocalizedError, Equatable {
        case unavailable, stale
        var errorDescription: String? {
            switch self {
            case .unavailable: "The current audio track couldn’t be matched safely. Continue playback, or choose an audio track in Details and try again."
            case .stale: "Playback changed while reading its audio track. Continue playback and try again."
            }
        }
    }
    private struct Language: Equatable {
        let code: String
        let script: String?
        let region: String?
    }
    private static let knownLanguages = Set(Locale.LanguageCode.isoLanguageCodes.compactMap { $0.identifier(.alpha3) })
    private static func language(_ raw: String?) -> Language? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        // ISO639-2 bibliographic aliases from the Library of Congress code list.
        let aliases = ["alb": "sqi", "arm": "hye", "baq": "eus", "bur": "mya", "chi": "zho", "cze": "ces",
                       "dut": "nld", "fre": "fra", "geo": "kat", "ger": "deu", "gre": "ell", "ice": "isl",
                       "mac": "mkd", "mao": "mri", "may": "msa", "per": "fas", "rum": "ron", "slo": "slk",
                       "tib": "bod", "wel": "cym"]
        var parts = raw.replacingOccurrences(of: "_", with: "-").split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        guard let base = parts.first else { return nil }
        parts[0] = aliases[base.lowercased()] ?? base
        let value = Locale.Language(identifier: parts.joined(separator: "-"))
        guard let code = value.languageCode?.identifier(.alpha3), knownLanguages.contains(code),
              !["und", "mul", "mis", "zxx"].contains(code) else { return nil }
        return Language(code: code, script: value.script?.identifier, region: value.region?.identifier)
    }
    private static func conflicts(_ left: String?, _ right: String?) -> Bool {
        guard let a = language(left), let b = language(right) else { return false }
        if a.code != b.code { return true }
        if let a = a.script, let b = b.script, a != b { return true }
        if let a = a.region, let b = b.region, a != b { return true }
        return false
    }
    private static func sameKnownLanguage(_ left: String?, _ right: String?) -> Bool {
        language(left) != nil && language(right) != nil && !conflicts(left, right)
    }
    private static func title(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        return value.isEmpty ? nil : value
    }
    private static func titles(_ option: NativeOption) -> Set<String> { Set(option.titles.compactMap(title)) }
    private static func titles(_ stream: MediaStream) -> Set<String> { Set([stream.DisplayTitle, stream.Title].compactMap(title)) }
    private static func identityEqual(_ left: NativeOption, _ right: NativeOption) -> Bool {
        titles(left) == titles(right) && language(left.language) == language(right.language) && left.roles == right.roles
    }
    private static func nameMatches(_ stream: MediaStream, _ option: NativeOption) -> Bool {
        !conflicts(stream.Language, option.language) && !titles(stream).intersection(titles(option)).isEmpty
    }
    private static func roleCompatible(_ stream: MediaStream, _ option: NativeOption) -> Bool {
        // Absence of Apple's original-content characteristic is not proof of a non-original track.
        !(option.roles.contains(.original) && stream.IsOriginal == false)
    }
    private static func permitsLanguageFallback(_ stream: MediaStream, _ option: NativeOption) -> Bool {
        let special: Set<Role> = [.auxiliary, .description, .translation, .dubbed, .voiceOver, .forced, .sdh]
        guard option.roles.isDisjoint(with: special), roleCompatible(stream, option) else { return false }
        // A raw file title is authoritative identity. DisplayTitle may be a derived/localized codec label.
        if let rawTitle = title(stream.Title), !titles(option).isEmpty, !titles(option).contains(rawTitle) { return false }
        return true
    }
    private static func audio(_ source: MediaSource) throws -> [MediaStream] {
        let streams = source.MediaStreams?.filter { $0.Type == "Audio" } ?? []
        guard !streams.isEmpty, Set(streams.map(\.Index)).count == streams.count,
              streams.allSatisfy({ $0.Index >= 0 }) else { throw SelectionError.unavailable }
        return streams
    }
    private static func uniqueNativeIdentity(_ selected: NativeOption, options: [NativeOption]) throws {
        // Playability must not hide a second indistinguishable native identity.
        let matches = options.filter { identityEqual($0, selected) }
        guard matches.count == 1, matches.first?.playable == true, selected.playable else { throw SelectionError.unavailable }
    }

    static func languagesConflict(_ left: String?, _ right: String?) -> Bool { conflicts(left, right) }
    static func languageName(_ raw: String?) -> String? {
        guard let language = language(raw) else { return nil }
        return Locale.current.localizedString(forLanguageCode: language.code)
    }

    static func sameProviderIdentity(_ left: MediaStream, _ right: MediaStream) -> Bool {
        left.Type == right.Type && ["Audio", "Subtitle"].contains(left.Type) && left.Index == right.Index
            && titles(left) == titles(right) && language(left.Language) == language(right.Language)
            && left.IsOriginal == right.IsOriginal
            && (left.Type != "Subtitle" || (left.IsForced == right.IsForced && left.IsHearingImpaired == right.IsHearingImpaired))
    }

    static func providerIndex(selected: NativeOption, options: [NativeOption], source: MediaSource) throws -> Int {
        try uniqueNativeIdentity(selected, options: options)
        let streams = try audio(source)
        let named = streams.filter { nameMatches($0, selected) }
        if !named.isEmpty {
            guard named.count == 1, let stream = named.first,
                  options.filter({ nameMatches(stream, $0) }).count == 1,
                  roleCompatible(stream, selected) else { throw SelectionError.unavailable }
            return stream.Index
        }
        let providers = streams.filter { sameKnownLanguage($0.Language, selected.language) }
        let natives = options.filter { sameKnownLanguage($0.language, selected.language) }
        guard providers.count == 1, natives.count == 1, let stream = providers.first,
              permitsLanguageFallback(stream, selected) else { throw SelectionError.unavailable }
        return stream.Index
    }

    /// The audio track a stream the server converts or repackages carries: the one it was asked for, or the
    /// source's default. Nil when the stream plays the source directly or holds more than one track, which
    /// leaves the native track to be matched by `providerIndex`. That match cannot tell two tracks in one
    /// language apart, and a converted stream's single track never needs it.
    static func servedIndex(method: String, nativeOptions: Int, requested: Int?, source: MediaSource) -> Int? {
        guard nativeOptions == 1, method == "Transcode" || method == "DirectStream",
              let served = requested ?? source.DefaultAudioStreamIndex,
              (source.MediaStreams ?? []).filter({ $0.Type == "Audio" && $0.Index == served }).count == 1 else { return nil }
        return served
    }

    static func optionIndex(requested: Int, options: [NativeOption], source: MediaSource) throws -> Int {
        let streams = try audio(source)
        let providers = streams.filter { $0.Index == requested }
        guard providers.count == 1, let stream = providers.first else { throw SelectionError.unavailable }
        let named = options.indices.filter { nameMatches(stream, options[$0]) }
        if !named.isEmpty {
            guard named.count == 1, let index = named.first,
                  streams.filter({ nameMatches($0, options[index]) }).count == 1,
                  options[index].playable, roleCompatible(stream, options[index]) else { throw SelectionError.unavailable }
            try uniqueNativeIdentity(options[index], options: options)
            return index
        }
        let natives = options.indices.filter { sameKnownLanguage(stream.Language, options[$0].language) }
        guard natives.count == 1, let index = natives.first,
              streams.filter({ sameKnownLanguage($0.Language, stream.Language) }).count == 1,
              options[index].playable, permitsLanguageFallback(stream, options[index]) else { throw SelectionError.unavailable }
        try uniqueNativeIdentity(options[index], options: options)
        return index
    }

    static func restorationSource(in sources: [MediaSource], expectedID: String?) throws -> MediaSource {
        guard let expectedID else {
            guard let first = sources.first else { throw SelectionError.unavailable }
            return first
        }
        let matches = sources.filter { $0.Id == expectedID }
        guard !expectedID.isEmpty, matches.count == 1, let source = matches.first else { throw SelectionError.unavailable }
        return source
    }

    static func optionIndex(identity: NativeOption, options: [NativeOption]) throws -> Int {
        let matches = options.indices.filter { identityEqual(options[$0], identity) }
        guard matches.count == 1, let index = matches.first, options[index].playable else { throw SelectionError.unavailable }
        return index
    }
}

/// Semantic provider identities, without an AV object, account token or stream URL.
struct PlaybackTrackSelection: Equatable, Sendable {
    let sourceID: String
    let audioIndex: Int?
    let audio: MediaStream?
    let subtitleIndex: Int?
    let subtitle: MediaStream?

    func source(in sources: [MediaSource], negotiated: Bool = false) throws -> MediaSource {
        let matching = sources.filter { $0.Id == sourceID }
        guard !sourceID.isEmpty, matching.count == 1, let source = matching.first else { throw PlaybackAudioSelection.SelectionError.unavailable }
        try validate(source, negotiated: negotiated)
        return source
    }
    func validate(_ source: MediaSource, negotiated: Bool = false) throws {
        guard source.Id == sourceID, let streams = source.MediaStreams else { throw PlaybackAudioSelection.SelectionError.unavailable }
        for type in ["Audio", "Subtitle"] {
            let typed = streams.filter { $0.Type == type }
            guard typed.allSatisfy({ $0.Index >= 0 }), Set(typed.map(\.Index)).count == typed.count else { throw PlaybackAudioSelection.SelectionError.unavailable }
        }
        func validate(_ expected: MediaStream?, index: Int?, type: String) throws {
            if let index, index >= 0 {
                let matches = streams.filter { $0.Type == type && $0.Index == index }
                guard let expected, expected.Type == type, expected.Index == index,
                      matches.count == 1, let actual = matches.first,
                      PlaybackAudioSelection.sameProviderIdentity(expected, actual) else { throw PlaybackAudioSelection.SelectionError.unavailable }
            } else {
                guard expected == nil else { throw PlaybackAudioSelection.SelectionError.unavailable }
                if type == "Audio" {
                    // No captured native/explicit identity cannot turn into a new default audio choice.
                    guard streams.allSatisfy({ $0.Type != "Audio" }), (source.DefaultAudioStreamIndex ?? -1) < 0 else { throw PlaybackAudioSelection.SelectionError.unavailable }
                } else if index == -1 {
                    // Details advertises a default, not the user's captured selection.
                    // A negotiated response must still confirm that explicit Off survived.
                    if negotiated { try PlaybackSubtitlePlan.validateOff(source: source) }
                } else {
                    guard index == nil, (source.DefaultSubtitleStreamIndex ?? -1) < 0 else { throw PlaybackAudioSelection.SelectionError.unavailable }
                    if negotiated { try PlaybackSubtitlePlan.validateOff(source: source) }
                }
            }
        }
        try validate(audio, index: audioIndex, type: "Audio")
        try validate(subtitle, index: subtitleIndex, type: "Subtitle")
    }
}

/// Only explicit negotiated query facts; catalog renditions are not selected output.
enum PlaybackSubtitlePlan {
    enum Route { case directPlay, transcode }
    private static func fields(_ source: MediaSource) -> (methods: [URLQueryItem], indexes: [URLQueryItem]) {
        let query = URLComponents(string: source.TranscodingUrl ?? "")?.queryItems ?? []
        return (query.filter { $0.name.caseInsensitiveCompare("SubtitleMethod") == .orderedSame },
                query.filter { $0.name.caseInsensitiveCompare("SubtitleStreamIndex") == .orderedSame })
    }
    static func isEncoded(source: MediaSource, selected: MediaStream?) -> Bool {
        if selected?.DeliveryMethod?.caseInsensitiveCompare("Encode") == .orderedSame { return true }
        let methods = fields(source).methods
        return methods.count == 1 && methods[0].value?.caseInsensitiveCompare("Encode") == .orderedSame
    }
    // Shared with local startup: preserve the prior explicit Encode contract.
    static func encodedDelivery(source: MediaSource, selected: MediaStream?, requested: Int, route: Route = .transcode) throws -> Bool {
        // The selected direct route exposes native tracks; its offered transcode URL is not output.
        guard route == .transcode else { return false }
        let (methods, indexes) = fields(source)
        let mentionsEncode = methods.contains { $0.value?.caseInsensitiveCompare("Encode") == .orderedSame }
        if mentionsEncode, methods.count != 1 { throw PlaybackAudioSelection.SelectionError.unavailable }
        guard isEncoded(source: source, selected: selected) else { return false }
        guard requested >= 0 else { throw PlaybackAudioSelection.SelectionError.unavailable }
        if let delivery = selected?.DeliveryMethod, !delivery.isEmpty,
           delivery.caseInsensitiveCompare("Encode") != .orderedSame { throw PlaybackAudioSelection.SelectionError.unavailable }
        if let method = methods.first, method.value?.caseInsensitiveCompare("Encode") != .orderedSame { throw PlaybackAudioSelection.SelectionError.unavailable }
        if indexes.count > 1 { throw PlaybackAudioSelection.SelectionError.unavailable }
        if let index = indexes.first, index.value.flatMap(Int.init) != requested { throw PlaybackAudioSelection.SelectionError.unavailable }
        if let index = source.DefaultSubtitleStreamIndex, index != requested { throw PlaybackAudioSelection.SelectionError.unavailable }
        return true
    }
    static func validateOff(source: MediaSource) throws {
        guard source.DefaultSubtitleStreamIndex == nil || source.DefaultSubtitleStreamIndex == -1 else { throw PlaybackAudioSelection.SelectionError.unavailable }
        // streamURL chooses the direct route in this case, not the offered fallback URL.
        guard source.SupportsDirectPlay != true else { return }
        if let path = source.TranscodingUrl, !path.isEmpty, URLComponents(string: path) == nil { throw PlaybackAudioSelection.SelectionError.unavailable }
        let (methods, indexes) = fields(source)
        guard methods.count <= 1, indexes.count <= 1 else { throw PlaybackAudioSelection.SelectionError.unavailable }
        if let method = methods.first {
            guard let value = method.value?.lowercased(), ["encode", "embed", "external", "hls"].contains(value) else { throw PlaybackAudioSelection.SelectionError.unavailable }
        }
        if let index = indexes.first, index.value.flatMap(Int.init) != -1 { throw PlaybackAudioSelection.SelectionError.unavailable }
        _ = try encodedDelivery(source: source, selected: nil, requested: -1)
    }
}
