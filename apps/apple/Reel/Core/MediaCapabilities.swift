import Foundation
#if canImport(AVFoundation)
import AVFoundation
#endif

/// Transport selection is independent from an actual compatibility fallback.
struct PlaybackNegotiation: Sendable {
    let forceHLS: Bool
    let compatibility: Bool
    init(forceHLS: Bool, compatibilityMode: Bool, dataSaver: Bool) {
        self.forceHLS = forceHLS
        self.compatibility = compatibilityMode || dataSaver
    }
    var allowsStreamCopy: Bool { !compatibility }
    func allowsDirectPlay(audio: Int?, subtitle: Int?) -> Bool { !forceHLS && audio == nil && subtitle == nil }
}

/// Codec/container likelihood, not a claim about receiver passthrough or rendered spatial/HDR output.
struct PlaybackCapabilities: Sendable {
    let video: [String]
    let audio: [String]
    var hdrRanges: [String] = ["SDR"]
    static func probe(_ supports: (String) -> Bool) -> PlaybackCapabilities {
        let videos = [("h264", "avc1.640028"), ("hevc", "hvc1.2.4.L153.B0"), ("av1", "av01.0.13M.10")]
        let audios = [("aac", "mp4a.40.2"), ("mp3", "mp4a.40.34"), ("ac3", "ac-3"), ("eac3", "ec-3"), ("alac", "alac"), ("flac", "fLaC")]
        return PlaybackCapabilities(video: videos.filter { supports("video/mp4; codecs=\"\($0.1)\"") }.map(\.0),
                                    audio: audios.filter { supports("audio/mp4; codecs=\"\($0.1)\"") }.map(\.0))
    }
    #if canImport(AVFoundation)
    static func current() -> PlaybackCapabilities {
        var result = probe { AVURLAsset.isPlayableExtendedMIMEType($0) }
        #if os(iOS) || os(tvOS)
        if AVPlayer.eligibleForHDRPlayback && result.video.contains("hevc") { result.hdrRanges += ["HDR10", "HLG"] }
        #endif
        return result
    }
    #endif

    func profile(bitrate: Int, compatibility: Bool, dataSaver: Bool) -> [String: any Sendable] {
        let videos = video.filter { !compatibility || $0 == "h264" }
        let copiedAudio = compatibility ? [String]() : audio.filter { ["ac3", "eac3", "alac", "flac"].contains($0) }
        let hlsAudio = ["aac"] + copiedAudio
        let direct: [[String: any Sendable]] = video.isEmpty || audio.isEmpty ? [] : [
            ["Container": "mp4,m4v", "Type": "Video", "VideoCodec": video.joined(separator: ","), "AudioCodec": audio.joined(separator: ",")]
        ]
        let transcode: [String: any Sendable] = ["Container": compatibility ? "ts" : "mp4", "Type": "Video", "VideoCodec": videos.filter { $0 != "av1" }.joined(separator: ",").isEmpty ? "h264" : videos.filter { $0 != "av1" }.joined(separator: ","), "AudioCodec": hlsAudio.joined(separator: ","), "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": copiedAudio.isEmpty ? "2" : "8", "MinSegments": 2, "SegmentLength": 4, "EnableSubtitlesInManifest": true]
        var result: [String: any Sendable] = ["Name": "Reel AVFoundation probes", "MaxStreamingBitrate": bitrate, "DirectPlayProfiles": direct, "TranscodingProfiles": [transcode],
            "SubtitleProfiles": [["Format": "vtt", "Method": "Hls"], ["Format": "srt", "Method": "Encode"], ["Format": "ass", "Method": "Encode"], ["Format": "pgssub", "Method": "Encode"]]]
        var conditions: [[String: any Sendable]] = [
            ["Condition": "EqualsAny", "Property": "VideoRangeType", "Value": hdrRanges.joined(separator: "|"), "IsRequired": true]
        ]
        if dataSaver {
            conditions += [
                ["Condition": "LessThanEqual", "Property": "Width", "Value": "1280", "IsRequired": false],
                ["Condition": "LessThanEqual", "Property": "Height", "Value": "720", "IsRequired": false]
            ]
        }
        let profile: [String: any Sendable] = ["Type": "Video", "Codec": "h264,hevc,av1", "Conditions": conditions]
        result["CodecProfiles"] = [profile]
        return result
    }
}

struct PlaybackFormat: Equatable, Sendable {
    enum AudioDisclosure: Equatable, Sendable {
        case serverIntent(Int?)
        case effective(Int)
        case unresolved
    }
    let source: String
    let delivery: String
    let output: String
    let warning: String
    static let codecs = ["h264": "H.264", "hevc": "HEVC", "av1": "AV1", "aac": "AAC", "ac3": "Dolby Digital", "eac3": "Dolby Digital Plus", "truehd": "TrueHD", "dts": "DTS", "flac": "FLAC", "alac": "ALAC", "mp3": "MP3", "pcm_s16le": "PCM", "pcm_s24le": "PCM", "pcm_s32le": "PCM", "pcm_f32le": "PCM float 32-bit LE", "pcm_f64le": "PCM float 64-bit LE"]
    static let ranges = ["SDR": "SDR", "HDR10": "HDR10", "HLG": "HLG", "DOVI": "Dolby Vision", "DOVIWithHDR10": "Dolby Vision / HDR10 base", "DOVIWithHLG": "Dolby Vision / HLG base", "DOVIWithSDR": "Dolby Vision / SDR base", "DOVIWithEL": "Dolby Vision with enhancement layer", "DOVIWithHDR10Plus": "Dolby Vision / HDR10+", "DOVIWithELHDR10Plus": "Dolby Vision with enhancement layer / HDR10+", "HDR10Plus": "HDR10+"]
    static func valid(_ value: Int?, max: Int) -> Bool { value.map { $0 > 0 && $0 <= max } ?? false }
    static func describe(source: MediaSource?, method: String, audioIndex: Int?) -> PlaybackFormat {
        describe(source: source, method: method, audio: .serverIntent(audioIndex))
    }
    static func describe(source: MediaSource?, method: String, audio disclosure: AudioDisclosure) -> PlaybackFormat {
        let streams = source?.MediaStreams ?? []
        let video = streams.first { $0.Type == "Video" }
        let audios = streams.filter { $0.Type == "Audio" }
        let index: Int?
        let useUniqueFallback: Bool
        switch disclosure {
        case .serverIntent(let requested): index = requested ?? source?.DefaultAudioStreamIndex; useUniqueFallback = index == nil
        case .effective(let selected): index = selected; useUniqueFallback = false
        case .unresolved: index = nil; useUniqueFallback = false
        }
        let matching = index.map { index in audios.filter { $0.Index == index } } ?? []
        let audio = matching.count == 1 ? matching.first : (useUniqueFallback && audios.count == 1 ? audios.first : nil)
        var videoParts = [codecs[video?.Codec?.lowercased() ?? ""] ?? "Video codec unknown"]
        if valid(video?.Width, max: 16384), valid(video?.Height, max: 16384) { videoParts.append("\(video!.Width!) × \(video!.Height!)") }
        videoParts.append(ranges[video?.VideoRangeType ?? ""] ?? "Dynamic range unknown")
        if valid(video?.BitDepth, max: 64) { videoParts.append("\(video!.BitDepth!)-bit") }
        if valid(video?.DvBlSignalCompatibilityId, max: 10) { videoParts.append("DV base compatibility \(video!.DvBlSignalCompatibilityId!) (server metadata)") }
        if video?.Hdr10PlusPresentFlag == true { videoParts.append("HDR10+ metadata reported by server") }
        if valid(video?.DvProfile, max: 20) { videoParts.append("DV profile \(video!.DvProfile!)") }
        var audioParts = [disclosure == .unresolved ? "Current audio selection unknown" : codecs[audio?.Codec?.lowercased() ?? ""] ?? "Audio codec unknown"]
        if let language = PlaybackAudioSelection.languageName(audio?.Language) { audioParts.append(language) }
        let dtsProfiles = ["dts-hd ma": "DTS-HD Master Audio", "dts-hd hra": "DTS-HD High Resolution", "dts": "DTS core"]
        if audio?.Codec?.lowercased() == "dts", let label = dtsProfiles[audio?.Profile?.lowercased() ?? ""] { audioParts[0] = label }
        if valid(audio?.Channels, max: 64) { audioParts.append("\(audio!.Channels!) channels") }
        if valid(audio?.SampleRate, max: 768000) { audioParts.append(String(format: "%g kHz", Double(audio!.SampleRate!) / 1000)) }
        if valid(audio?.BitDepth, max: 64) { audioParts.append("\(audio!.BitDepth!)-bit") }
        if audio?.AudioSpatialFormat == "DolbyAtmos" { audioParts.append("Atmos (server metadata)") }
        if audio?.AudioSpatialFormat == "DTSX" { audioParts.append("DTS:X (server metadata)") }
        var delivery = "Original file requested; decoded format and receiver output are not verified."
        var warnings: [String] = []
        if method == "Offline" { delivery = "Downloaded file; delivered format and receiver output are not verified." }
        else if method != "DirectPlay" {
            // Read only allowlisted plan scalars; never expose authenticated URLs or arbitrary provider labels.
            let plan = source?.TranscodingUrl ?? ""
            let queries = plan.utf8.count <= 8192 ? URLComponents(string: plan)?.queryItems ?? [] : []
            func value(_ name: String) -> String? {
                let values = queries.filter { $0.name.lowercased() == name.lowercased() }
                return values.count == 1 ? values.first?.value?.lowercased() : nil
            }
            func label(_ value: String?) -> String { value == "copy" ? "stream copy" : codecs[value ?? ""] ?? "unknown" }
            let a = value("audioCodec"), v = value("videoCodec")
            delivery = "Requested plan: video \(label(v)), audio \(label(a)). Actual delivered format unverified."
            if let a, a != "copy" { warnings.append(["alac", "flac"].contains(a) ? "Lossless audio encoding requested; original PCM identity and spatial object retention are unverified." : "Audio conversion does not preserve Atmos/DTS:X objects or lossless identity.") }
            if let v, v != "copy", let range = video?.VideoRangeType, range != "SDR" { warnings.append("Video conversion may tone-map to SDR; HDR preservation is not verified.") }
        }
        let audioHeading: String
        switch disclosure {
        case .serverIntent: audioHeading = "Requested source audio: "
        case .effective: audioHeading = "Selected source audio: "
        case .unresolved: audioHeading = ""
        }
        return PlaybackFormat(source: "Source: \(videoParts.joined(separator: " · ")); \(audioHeading)\(audioParts.joined(separator: " · ")).", delivery: delivery,
            output: "Output: display HDR mode, spatial audio, HDMI/eARC format and bit-perfect playback are unverified.", warning: warnings.joined(separator: " "))
    }
}
