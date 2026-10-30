import type { MediaSource, MediaStream } from './types.ts';

// Decoder/container probes are not evidence of HDMI, eARC, bit-perfect or spatial output.
export interface EngineCapabilities {
  mp4Video: string[];
  mp4Audio: string[];
  audioFiles: Array<{ container: string; codec: string }>;
  nativeHLS: boolean;
  hdrRanges?: string[];
}
export type TypeProbe = (mime: string) => string;
const videoTypes: Array<[string, string]> = [
  ['h264', 'avc1.640028'], ['hevc', 'hvc1.2.4.L153.B0'], ['av1', 'av01.0.13M.10']
];
const audioTypes: Array<[string, string]> = [
  ['aac', 'mp4a.40.2'], ['mp3', 'mp4a.40.34'], ['ac3', 'ac-3'], ['eac3', 'ec-3'], ['alac', 'alac'], ['flac', 'fLaC']
];
export function probeEngine(probe: TypeProbe): EngineCapabilities {
  const probably = (mime: string): boolean => { try { return probe(mime) === 'probably'; } catch { return false; } };
  const mp4Video = videoTypes.filter(([, codec]) => probably(`video/mp4; codecs="${codec}"`)).map(([codec]) => codec);
  const mp4Audio = audioTypes.filter(([, codec]) => probably(`audio/mp4; codecs="${codec}"`)).map(([codec]) => codec);
  const files: Array<[string, string, string]> = [
    ['mp3', 'mp3', 'audio/mpeg'], ['aac', 'aac', 'audio/aac'], ['flac', 'flac', 'audio/flac'],
    ['ogg', 'vorbis', 'audio/ogg; codecs="vorbis"'], ['ogg,opus', 'opus', 'audio/ogg; codecs="opus"'],
    ['wav', 'pcm_s16le', 'audio/wav; codecs="1"']
  ];
  return { mp4Video, mp4Audio, nativeHLS: probably('application/vnd.apple.mpegurl'),
    audioFiles: files.filter(([, , mime]) => probably(mime)).map(([container, codec]) => ({ container, codec })) };
}

// Probe only the selected HDR source, on demand. No persistent hardware fingerprint or network request.
export async function probeSourceHDR(cap: EngineCapabilities, source: MediaSource | undefined, signal: AbortSignal,
  decode?: (configuration: MediaDecodingConfiguration) => Promise<MediaCapabilitiesDecodingInfo>): Promise<EngineCapabilities> {
  const base = { ...cap, hdrRanges: ['SDR'] };
  const stream = (Array.isArray(source?.MediaStreams) ? source.MediaStreams : []).find(stream => stream && stream.Type === 'Video');
  const range = stream?.VideoRangeType;
  if (!decode || signal.aborted || !stream || !['HDR10', 'HLG', 'HDR10Plus'].includes(range ?? '')) return base;
  const codec = lower(stream.Codec);
  if (!codec || !cap.mp4Video.includes(codec) || !['hevc', 'av1'].includes(codec)) return base;
  if (!positive(stream.Width, 3840) || !positive(stream.Height, 2160) || !positive(stream.BitRate, 200000000) || !positive(stream.RealFrameRate, 60) || stream.BitDepth !== 10) return base;
  const video: VideoConfiguration = {
    contentType: codec === 'hevc' ? 'video/mp4; codecs="hvc1.2.4.L153.B0"' : 'video/mp4; codecs="av01.0.13M.10"',
    width: stream.Width!, height: stream.Height!, bitrate: stream.BitRate!, framerate: stream.RealFrameRate!, colorGamut: 'rec2020', transferFunction: range === 'HLG' ? 'hlg' : 'pq'
  };
  if (range !== 'HLG') video.hdrMetadataType = range === 'HDR10Plus' ? 'smpteSt2094-40' : 'smpteSt2086';
  let timer: ReturnType<typeof setTimeout> | undefined;
  let abort: (() => void) | undefined;
  try {
    const timeout = new Promise<null>(resolve => {
      timer = setTimeout(() => resolve(null), 200);
      abort = () => resolve(null); signal.addEventListener('abort', abort, { once: true });
    });
    const result = await Promise.race([Promise.resolve().then(() => signal.aborted ? null : decode({ type: 'file', video })).catch(() => null), timeout]);
    // Older implementations may ignore new WebIDL members. Require their normalized readback;
    // a bare supported=true is not evidence that the HDR query was understood.
    const normalized = (result as { configuration?: MediaDecodingConfiguration } | null)?.configuration?.video;
    const recognized = normalized?.contentType === video.contentType && normalized?.colorGamut === video.colorGamut
      && normalized?.transferFunction === video.transferFunction
      && (range === 'HLG' || normalized?.hdrMetadataType === video.hdrMetadataType);
    return result?.supported === true && recognized && !signal.aborted ? { ...base, hdrRanges: ['SDR', range!] } : base;
  } finally { if (timer) clearTimeout(timer); if (abort) signal.removeEventListener('abort', abort); }
}

export function playbackProfile(cap: EngineCapabilities, bitrate: number, fallback?: 'audio' | 'video') {
  const video = cap.mp4Video.filter(codec => !fallback || codec !== 'av1').filter(codec => fallback !== 'video' || codec === 'h264');
  // hls.js's MSE path uses the established AVC/AAC fallback; AC-3/E-AC-3 copy is native-HLS only.
  const hlsVideo = cap.nativeHLS && video.includes('hevc') && fallback !== 'video' ? 'h264,hevc' : 'h264';
  const hlsAudio = !fallback && cap.nativeHLS ? ['aac', ...cap.mp4Audio.filter(codec => ['ac3', 'eac3', 'alac', 'flac'].includes(codec))] : ['aac'];
  const direct = [];
  if (video.length && cap.mp4Audio.length) direct.push({ Type: 'Video', Container: 'mp4,m4v', VideoCodec: video.join(','), AudioCodec: cap.mp4Audio.join(',') });
  for (const audio of cap.audioFiles) direct.push({ Type: 'Audio', Container: audio.container, AudioCodec: audio.codec });
  if (cap.mp4Audio.length) direct.push({ Type: 'Audio', Container: 'mp4,m4a,m4b', AudioCodec: cap.mp4Audio.join(',') });
  return {
    Name: 'Reel probed media engine', MaxStreamingBitrate: bitrate, DirectPlayProfiles: direct,
    TranscodingProfiles: [
      { Type: 'Video', Context: 'Streaming', Protocol: 'hls', Container: fallback === 'video' ? 'ts' : 'mp4', VideoCodec: hlsVideo, AudioCodec: hlsAudio.join(','), MaxAudioChannels: hlsAudio.length > 1 ? '8' : '2', MinSegments: 2, SegmentLength: 4, EnableSubtitlesInManifest: true },
      { Type: 'Audio', Context: 'Streaming', Protocol: 'http', Container: 'mp3', AudioCodec: 'mp3' }
    ],
    CodecProfiles: [{ Type: 'Video', Codec: 'h264,hevc,av1', Conditions: [{ Condition: 'EqualsAny', Property: 'VideoRangeType', Value: (cap.hdrRanges ?? ['SDR']).filter(range => ['SDR', 'HDR10', 'HLG', 'HDR10Plus'].includes(range)).join('|'), IsRequired: true }] }],
    SubtitleProfiles: [{ Format: 'vtt', Method: 'Hls' }, { Format: 'srt', Method: 'Encode' }, { Format: 'ass', Method: 'Encode' }, { Format: 'pgssub', Method: 'Encode' }]
  };
}

const codecs: Record<string, string> = { h264: 'H.264', hevc: 'HEVC', av1: 'AV1', aac: 'AAC', ac3: 'Dolby Digital', eac3: 'Dolby Digital Plus', truehd: 'TrueHD', dts: 'DTS', flac: 'FLAC', alac: 'ALAC', mp3: 'MP3', pcm_s16le: 'PCM', pcm_s24le: 'PCM', pcm_s32le: 'PCM', pcm_f32le: 'PCM float 32-bit LE', pcm_f64le: 'PCM float 64-bit LE' };
const ranges: Record<string, string> = { SDR: 'SDR', HDR10: 'HDR10', HLG: 'HLG', DOVI: 'Dolby Vision', DOVIWithHDR10: 'Dolby Vision / HDR10 base', DOVIWithHLG: 'Dolby Vision / HLG base', DOVIWithSDR: 'Dolby Vision / SDR base', DOVIWithEL: 'Dolby Vision with enhancement layer', DOVIWithHDR10Plus: 'Dolby Vision / HDR10+', DOVIWithELHDR10Plus: 'Dolby Vision with enhancement layer / HDR10+', HDR10Plus: 'HDR10+' };
const label = (map: Record<string, string>, value: unknown): string | undefined => typeof value === 'string' && Object.prototype.hasOwnProperty.call(map, value) ? map[value] : undefined;
const lower = (value: unknown): string => typeof value === 'string' ? value.toLowerCase() : '';
const key = (value: unknown): string => typeof value === 'string' ? value : '';
const positive = (value: number | undefined, max: number) => typeof value === 'number' && Number.isFinite(value) && value > 0 && value <= max;
// Stream facts are separate entries so the player can show them as chips, never as one dot-joined line.
function audioFacts(stream?: MediaStream): string[] {
  if (!stream) return ['Details unavailable'];
  const parts = [label(codecs, lower(stream.Codec)) ?? 'Codec unknown'];
  const dtsProfile = label({ 'dts-hd ma': 'DTS-HD Master Audio', 'dts-hd hra': 'DTS-HD High Resolution', 'dts': 'DTS core' }, lower(stream.Profile));
  if (lower(stream.Codec) === 'dts' && dtsProfile) parts[0] = dtsProfile;
  if (positive(stream.Channels, 64)) parts.push(`${stream.Channels} channels`);
  if (positive(stream.SampleRate, 768000)) parts.push(`${Number((stream.SampleRate! / 1000).toFixed(1))} kHz`);
  if (positive(stream.BitDepth, 64)) parts.push(`${stream.BitDepth}-bit`);
  if (stream.AudioSpatialFormat === 'DolbyAtmos') parts.push('Atmos (server metadata)');
  if (stream.AudioSpatialFormat === 'DTSX') parts.push('DTS:X (server metadata)');
  return parts;
}
function videoFacts(stream?: MediaStream): string[] {
  if (!stream) return ['Details unavailable'];
  const parts = [label(codecs, lower(stream.Codec)) ?? 'Codec unknown'];
  if (positive(stream.Width, 16384) && positive(stream.Height, 16384)) parts.push(`${stream.Width} × ${stream.Height}`);
  parts.push(label(ranges, key(stream.VideoRangeType)) ?? 'Dynamic range unknown');
  if (positive(stream.BitDepth, 64)) parts.push(`${stream.BitDepth}-bit`);
  if (positive(stream.DvProfile, 20)) parts.push(`DV profile ${stream.DvProfile}`);
  if (positive(stream.DvBlSignalCompatibilityId, 10)) parts.push(`DV base compatibility ${stream.DvBlSignalCompatibilityId} (server metadata)`);
  if (stream.Hdr10PlusPresentFlag === true) parts.push('HDR10+ metadata reported by server');
  return parts;
}
export interface PlaybackDisclosure { video: string[]; audio: string[]; delivery: string; output: string; warning: string }
export function describePlayback(source: MediaSource, method: string, audioIndex?: number): PlaybackDisclosure {
  const streams = (Array.isArray(source.MediaStreams) ? source.MediaStreams : []).filter(stream => stream && typeof stream === 'object');
  const video = streams.find(stream => stream.Type === 'Video');
  const audios = streams.filter(stream => stream.Type === 'Audio');
  const requested = audioIndex ?? source.DefaultAudioStreamIndex;
  const audio = requested === undefined ? (audios.length === 1 ? audios[0] : undefined) : audios.find(stream => stream.Index === requested);
  let delivery = method === 'DirectPlay' ? 'Original file requested; decoded format and receiver output are not verified.' : 'Server conversion requested; delivered codecs are not verified.';
  let warning = '';
  if (method !== 'DirectPlay') {
    // Only allowlisted scalar plan values leave the authenticated URL. Never return/log the URL or arbitrary provider text.
    let query: URLSearchParams | undefined;
    try { query = new URL(typeof source.TranscodingUrl === 'string' && source.TranscodingUrl.length <= 8192 ? source.TranscodingUrl : '', 'https://plan.invalid/').searchParams; } catch { /* unknown plan */ }
    const get = (key: string) => {
      const values = query && [...query].filter(([name]) => name.toLowerCase() === key.toLowerCase()).map(([, value]) => value.toLowerCase());
      return values?.length === 1 ? values[0] : undefined;
    };
    const planAudio = get('audioCodec'), planVideo = get('videoCodec');
    const text = (codec: string | undefined) => codec === 'copy' ? 'stream copy' : label(codecs, codec) ?? 'unknown';
    delivery = `Requested plan: video ${text(planVideo)}, audio ${text(planAudio)}. Actual delivered format unverified.`;
    if (planAudio && planAudio !== 'copy') warning += ['alac', 'flac'].includes(planAudio) ? 'Lossless audio encoding requested; original PCM identity and spatial object retention are unverified. ' : 'Audio conversion does not preserve Atmos/DTS:X objects or lossless identity. ';
    if (planVideo && planVideo !== 'copy' && video?.VideoRangeType && video.VideoRangeType !== 'SDR') warning += 'Video conversion may tone-map to SDR; HDR preservation is not verified.';
  }
  return { video: videoFacts(video), audio: audioFacts(audio), delivery,
    output: 'Output: display HDR mode, spatial audio, HDMI/eARC format and bit-perfect playback are unverified.', warning: warning.trim() };
}
