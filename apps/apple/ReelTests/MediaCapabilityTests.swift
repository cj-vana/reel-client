import XCTest
@testable import Reel

final class MediaCapabilityTests: XCTestCase {
    private var supported: PlaybackCapabilities { PlaybackCapabilities.probe { _ in true } }
    private func transcode(_ profile: [String: any Sendable]) throws -> [String: any Sendable] {
        try XCTUnwrap((profile["TranscodingProfiles"] as? [[String: any Sendable]])?.first)
    }
    func testUnknownDecoderDoesNotAdvertiseOptionalOriginalCodecs() {
        let cap = PlaybackCapabilities.probe { _ in false }
        XCTAssertTrue(cap.video.isEmpty); XCTAssertTrue(cap.audio.isEmpty)
        XCTAssertFalse(supported.audio.contains("truehd")); XCTAssertFalse(supported.audio.contains("dts"))
        XCTAssertFalse(supported.audio.contains("mat"))
    }
    func testForcedHLSTransportKeepsCopyWithoutCompatibilityFallback() throws {
        let policy = PlaybackNegotiation(forceHLS: true, compatibilityMode: false, dataSaver: false)
        XCTAssertFalse(policy.allowsDirectPlay(audio: nil, subtitle: nil))
        XCTAssertTrue(policy.allowsStreamCopy)
        let tc = try transcode(supported.profile(bitrate: 120_000_000, compatibility: policy.compatibility, dataSaver: false))
        XCTAssertEqual(tc["Container"] as? String, "mp4")
        XCTAssertEqual(tc["AudioCodec"] as? String, "aac,ac3,eac3,alac,flac")
        XCTAssertEqual(tc["MaxAudioChannels"] as? String, "8")
    }
    func testTrueCompatibilityFallbackStaysAVCAACStereo() throws {
        let policy = PlaybackNegotiation(forceHLS: true, compatibilityMode: true, dataSaver: false)
        XCTAssertFalse(policy.allowsStreamCopy)
        let tc = try transcode(supported.profile(bitrate: 20_000_000, compatibility: policy.compatibility, dataSaver: false))
        XCTAssertEqual(tc["Container"] as? String, "ts"); XCTAssertEqual(tc["VideoCodec"] as? String, "h264")
        XCTAssertEqual(tc["AudioCodec"] as? String, "aac"); XCTAssertEqual(tc["MaxAudioChannels"] as? String, "2")
    }
    func testDataSaverKeepsCompatibilityAndSizeConditionsWithoutTransportCoupling() throws {
        let policy = PlaybackNegotiation(forceHLS: false, compatibilityMode: false, dataSaver: true)
        XCTAssertTrue(policy.compatibility); XCTAssertFalse(policy.allowsStreamCopy)
        let profile = supported.profile(bitrate: 2_000_000, compatibility: policy.compatibility, dataSaver: true)
        let tc = try transcode(profile); XCTAssertEqual(tc["AudioCodec"] as? String, "aac")
        let video = try XCTUnwrap((profile["CodecProfiles"] as? [[String: any Sendable]])?.first)
        let conditions = try XCTUnwrap(video["Conditions"] as? [[String: any Sendable]])
        XCTAssertTrue(conditions.contains { $0["Property"] as? String == "Width" && $0["Value"] as? String == "1280" })
        XCTAssertTrue(conditions.contains { $0["Property"] as? String == "Height" && $0["Value"] as? String == "720" })
    }
    func testExplicitTrackSelectionBlocksStaticDirectPlayIndependentlyOfCopy() {
        let policy = PlaybackNegotiation(forceHLS: false, compatibilityMode: false, dataSaver: false)
        XCTAssertTrue(policy.allowsDirectPlay(audio: nil, subtitle: nil)); XCTAssertTrue(policy.allowsStreamCopy)
        XCTAssertFalse(policy.allowsDirectPlay(audio: 3, subtitle: nil)); XCTAssertFalse(policy.allowsDirectPlay(audio: nil, subtitle: -1))
    }
    func testSourceSelectionAndSpatialMetadataDoNotGuessFromChannels() {
        let source = MediaSource(Id: "synthetic", DefaultAudioStreamIndex: 3, MediaStreams: [
            MediaStream(Index: 1, Type: "Audio", Codec: "aac", Channels: 2),
            MediaStream(Index: 3, Type: "Audio", Codec: "eac3", Channels: 8, SampleRate: 48000, AudioSpatialFormat: "DolbyAtmos")
        ])
        XCTAssertTrue(PlaybackFormat.describe(source: source, method: "DirectPlay", audioIndex: nil).source.contains("Atmos (server metadata)"))
        XCTAssertFalse(PlaybackFormat.describe(source: source, method: "DirectPlay", audioIndex: 1).source.contains("Atmos"))
        let channels = MediaSource(Id: "synthetic", MediaStreams: [MediaStream(Index: 0, Type: "Audio", Codec: "eac3", Channels: 8)])
        XCTAssertFalse(PlaybackFormat.describe(source: channels, method: "DirectPlay", audioIndex: nil).source.contains("Atmos"))
    }
    func testHDRAndLosslessSourceFactsDoNotBecomeOutputGuarantees() {
        let source = MediaSource(Id: "synthetic", MediaStreams: [MediaStream(Index: 0, Type: "Video", Codec: "hevc", BitDepth: 10, Width: 3840, Height: 2160, VideoRangeType: "DOVIWithHDR10", DvProfile: 8), MediaStream(Index: 1, Type: "Audio", Codec: "flac", BitDepth: 24, Channels: 2, SampleRate: 96000)])
        let format = PlaybackFormat.describe(source: source, method: "DirectPlay", audioIndex: nil)
        XCTAssertTrue(format.source.contains("DV profile 8")); XCTAssertTrue(format.source.contains("96 kHz")); XCTAssertTrue(format.source.contains("24-bit"))
        XCTAssertTrue(format.output.contains("unverified")); XCTAssertTrue(format.delivery.contains("not verified"))
    }
    func testLossyAndLosslessPlansHaveDifferentLimitations() {
        let lossy = MediaSource(Id: "synthetic", TranscodingUrl: "?videoCodec=copy&audioCodec=aac")
        let lossless = MediaSource(Id: "synthetic", TranscodingUrl: "?videoCodec=copy&audioCodec=flac")
        XCTAssertTrue(PlaybackFormat.describe(source: lossy, method: "Transcode", audioIndex: nil).warning.contains("does not preserve Atmos"))
        let warning = PlaybackFormat.describe(source: lossless, method: "Transcode", audioIndex: nil).warning
        XCTAssertTrue(warning.contains("Lossless audio encoding requested")); XCTAssertTrue(warning.contains("unverified"))
    }
    func testAuthenticatedAndConflictingPlanMetadataDoesNotEscapeDisclosure() {
        let source = MediaSource(Id: "private-id", TranscodingUrl: "https://private.invalid/secret-path?ApiKey=secret-value&audioCodec=copy&AUDIOCODEC=aac&videoCodec=secret-value")
        let format = PlaybackFormat.describe(source: source, method: "Transcode", audioIndex: nil)
        let text = [format.source, format.delivery, format.output, format.warning].joined()
        for secret in ["private-id", "private.invalid", "secret-path", "secret-value", "ApiKey"] { XCTAssertFalse(text.contains(secret)) }
        XCTAssertTrue(format.delivery.contains("video unknown, audio unknown"))
    }
    func testMalformedNewDescriptiveFieldsDoNotBreakOldTrackIdentityContract() throws {
        let data = Data(#"{"Index":0,"Type":"Video","Width":"invalid","VideoRangeType":7,"Hdr10PlusPresentFlag":"invalid"}"#.utf8)
        let value = try JSONDecoder().decode(MediaStream.self, from: data)
        XCTAssertEqual(value.Index, 0); XCTAssertEqual(value.Type, "Video")
        XCTAssertNil(value.Width); XCTAssertNil(value.VideoRangeType); XCTAssertNil(value.Hdr10PlusPresentFlag)
        XCTAssertThrowsError(try JSONDecoder().decode(MediaStream.self, from: Data(#"{"Type":"Video"}"#.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(MediaStream.self, from: Data(#"{"Index":0,"Type":9}"#.utf8)))
    }
    func testUnknownRangeRemainsRequiredAndDTSProfilesStayDistinct() throws {
        let profiles = try XCTUnwrap(supported.profile(bitrate: 120_000_000, compatibility: false, dataSaver: false)["CodecProfiles"] as? [[String: any Sendable]])
        let conditions = try XCTUnwrap(profiles.first?["Conditions"] as? [[String: any Sendable]])
        XCTAssertEqual(conditions.first?["Value"] as? String, "SDR"); XCTAssertEqual(conditions.first?["IsRequired"] as? Bool, true)
        let source = MediaSource(Id: "synthetic", MediaStreams: [MediaStream(Index: 0, Type: "Audio", Codec: "dts", AudioSpatialFormat: "DTSX", Profile: "DTS-HD MA")])
        let text = PlaybackFormat.describe(source: source, method: "DirectPlay", audioIndex: nil).source
        XCTAssertTrue(text.contains("DTS-HD Master Audio")); XCTAssertTrue(text.contains("DTS:X (server metadata)"))
    }
}
