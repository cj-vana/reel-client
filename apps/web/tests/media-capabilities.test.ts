import test from 'node:test';
import assert from 'node:assert/strict';
import { probeEngine, probeSourceHDR, playbackProfile, describePlayback } from '../src/media-capabilities.ts';
import { JellyfinAPI } from '../src/api.ts';
import type { MediaSource } from '../src/types.ts';

const source: MediaSource = { Id: 'private-source', TranscodingUrl: '/Videos/private/master.m3u8?ApiKey=SECRET&videoCodec=copy&audioCodec=aac', DefaultAudioStreamIndex: 3, MediaStreams: [
  { Index: 0, Type: 'Video', Codec: 'hevc', Width: 3840, Height: 2160, VideoRangeType: 'DOVIWithHDR10', DvProfile: 8 },
  { Index: 1, Type: 'Audio', Codec: 'aac', Channels: 2 },
  { Index: 3, Type: 'Audio', Codec: 'eac3', Channels: 8, SampleRate: 48000, AudioSpatialFormat: 'DolbyAtmos' }
] };
test('unknown, maybe, throws and absent capabilities never advertise extended codecs', () => {
  for (const probe of [() => '', () => 'maybe', () => { throw Error('bad engine'); }]) {
    const cap = probeEngine(probe); assert.deepEqual(cap, { mp4Video: [], mp4Audio: [], nativeHLS: false, audioFiles: [] });
    const p = playbackProfile(cap, 120000000); assert.deepEqual(p.DirectPlayProfiles, []);
    assert.equal(p.TranscodingProfiles[0].AudioCodec, 'aac'); assert.equal(p.TranscodingProfiles[0].MaxAudioChannels, '2');
  }
});
test('exact codec/container probes do not invent TrueHD, DTS, PCM float, MAT or object support', () => {
  const cap = probeEngine(() => 'probably');
  const profiles = playbackProfile(cap, 120000000);
  const values = profiles.DirectPlayProfiles.flatMap(p => [p.Container, p.AudioCodec, 'VideoCodec' in p ? p.VideoCodec : '']).join(',').split(',');
  for (const forbidden of ['truehd', 'dts', 'pcm_f32le', 'atmos', 'mat', 'mkv', 'mov']) assert.ok(!values.includes(forbidden), forbidden);
  assert.ok(cap.mp4Audio.includes('eac3')); assert.ok(cap.audioFiles.some(p => p.codec === 'flac'));
});
test('AC3/EAC3 native-HLS copy candidates preserve codec while MSE and recovery stay AAC stereo', () => {
  const cap = probeEngine(() => 'probably');
  assert.equal(playbackProfile(cap, 120000000).TranscodingProfiles[0].AudioCodec, 'aac,ac3,eac3,alac,flac');
  for (const p of [playbackProfile({ ...cap, nativeHLS: false }, 1), playbackProfile(cap, 1, 'audio'), playbackProfile(cap, 1, 'video')]) {
    assert.equal(p.TranscodingProfiles[0].AudioCodec, 'aac'); assert.equal(p.TranscodingProfiles[0].MaxAudioChannels, '2');
  }
  assert.equal(playbackProfile(cap, 1, 'video').TranscodingProfiles[0].VideoCodec, 'h264');
});
const facts = (report: { video: string[]; audio: string[] }) => [...report.video, ...report.audio];
test('only the default or requested audio is described; 8 channels alone never becomes Atmos', () => {
  assert.deepEqual(describePlayback(source, 'DirectPlay').audio, ['Dolby Digital Plus', '8 channels', '48 kHz', 'Atmos (server metadata)']);
  assert.deepEqual(describePlayback(source, 'DirectPlay', 1).audio, ['AAC', '2 channels']);
  assert.deepEqual(describePlayback({ ...source, DefaultAudioStreamIndex: undefined }, 'DirectPlay').audio, ['Details unavailable']);
  const withoutObjects = { ...source, MediaStreams: source.MediaStreams!.map(s => ({ ...s, AudioSpatialFormat: undefined })) };
  assert.ok(!facts(describePlayback(withoutObjects, 'DirectPlay')).some(fact => fact.includes('Atmos')));
});
test('stream details are separate facts for chips, never one line joined by middle dots', () => {
  const report = describePlayback(source, 'Transcode');
  assert.deepEqual(report.video, ['HEVC', '3840 × 2160', 'Dolby Vision / HDR10 base', 'DV profile 8']);
  for (const value of [...facts(report), report.delivery, report.output, report.warning]) assert.ok(!value.includes('·'), value);
  assert.ok(!('source' in report));
});
test('source HDR is distinct from requested copy, encoding, actual output and loss of objects', () => {
  const report = describePlayback(source, 'Transcode');
  assert.ok(report.video.includes('Dolby Vision / HDR10 base')); assert.match(report.delivery, /video stream copy, audio AAC/);
  assert.match(report.warning, /does not preserve Atmos/); assert.ok(!report.warning.includes('tone-map'));
  const encoded = describePlayback({ ...source, TranscodingUrl: '?videoCodec=h264&audioCodec=copy' }, 'Transcode');
  assert.match(encoded.warning, /tone-map/); assert.ok(!encoded.warning.includes('Audio conversion'));
  assert.match(encoded.output, /unverified/);
});
test('malformed, conflicting and attacker-controlled metadata does not become a format label or leak a URL', () => {
  for (const url of ['%not a url', '?audioCodec=copy&AUDIOCODEC=aac', '?videoCodec=SECRET&audioCodec=SECRET', 'x'.repeat(9000)]) {
    const report = describePlayback({ ...source, TranscodingUrl: url }, 'Transcode');
    const text = JSON.stringify(report); assert.ok(!text.includes('SECRET')); assert.ok(!text.includes('private-source')); assert.ok(!text.includes('private/master'));
    assert.match(report.delivery, /unknown/);
  }
  const report = describePlayback({ Id: 'hidden', MediaStreams: [{ Index: 0, Type: 'Video', Codec: 'SECRET', Width: Infinity, Height: -1, VideoRangeType: 'SECRET' }] }, 'DirectPlay');
  assert.ok(!JSON.stringify(report).includes('SECRET')); assert.deepEqual(report.video, ['Codec unknown', 'Dynamic range unknown']);
});
test('API sends runtime-probed profile and removes audio-copy permission on recovery', async () => {
  const original = globalThis.fetch; const bodies: Record<string, any>[] = [];
  globalThis.fetch = async (_input, init) => { bodies.push(JSON.parse(String(init?.body))); return Response.json({ MediaSources: [] }); };
  try {
    const api = new JellyfinAPI(null, 'http://127.0.0.1:18771', 'synthetic', true, false), cap = probeEngine(() => 'probably');
    await api.playback({ Id: 'probe', Name: 'Probe' }, { bitrate: 120000000, capabilities: cap });
    await api.playback({ Id: 'probe', Name: 'Probe' }, { bitrate: 120000000, capabilities: cap, fallback: 'audio' });
    assert.equal(bodies[0].AllowAudioStreamCopy, true); assert.equal(bodies[1].AllowAudioStreamCopy, false);
    assert.equal(bodies[0].DeviceProfile.TranscodingProfiles[0].AudioCodec, 'aac,ac3,eac3,alac,flac');
  } finally { globalThis.fetch = original; }
});

const hdrSource: MediaSource = { Id: 'hdr', MediaStreams: [{ Index: 0, Type: 'Video', Codec: 'hevc', Width: 3840, Height: 2160, BitDepth: 10, BitRate: 20000000, RealFrameRate: 24, VideoRangeType: 'HDR10' }] };
test('HDR query is on-demand, bounded, source-specific and never guesses Dolby Vision from HEVC', async () => {
  const cap = probeEngine(() => 'probably'), signal = new AbortController().signal; let calls = 0;
  const decode = async (config: MediaDecodingConfiguration) => { calls++; assert.equal(config.video?.width, 3840); assert.equal(config.video?.transferFunction, 'pq'); return { supported: true, smooth: true, powerEfficient: false, configuration: config }; };
  assert.deepEqual((await probeSourceHDR(cap, hdrSource, signal, decode)).hdrRanges, ['SDR', 'HDR10']);
  const dv = { ...hdrSource, MediaStreams: hdrSource.MediaStreams!.map(s => ({ ...s, VideoRangeType: 'DOVI', DvProfile: 5 })) };
  assert.deepEqual((await probeSourceHDR(cap, dv, signal, decode)).hdrRanges, ['SDR']); assert.equal(calls, 1);
  const missing = { ...hdrSource, MediaStreams: hdrSource.MediaStreams!.map(s => ({ ...s, RealFrameRate: undefined })) };
  assert.deepEqual((await probeSourceHDR(cap, missing, signal, decode)).hdrRanges, ['SDR']); assert.equal(calls, 1);
  assert.deepEqual((await probeSourceHDR(cap, hdrSource, signal, async () => { throw Error('unavailable'); })).hdrRanges, ['SDR']);
  const start = Date.now(); assert.deepEqual((await probeSourceHDR(cap, hdrSource, signal, () => new Promise(() => {}))).hdrRanges, ['SDR']); assert.ok(Date.now() - start < 1000);
});
test('abort and a late successful decoder result cannot grant HDR; unknown source ranges are required to convert', async () => {
  const abort = new AbortController(); let complete!: (value: MediaCapabilitiesDecodingInfo) => void;
  const pending = probeSourceHDR(probeEngine(() => 'probably'), hdrSource, abort.signal, () => new Promise(resolve => { complete = resolve; }));
  await Promise.resolve(); abort.abort(); const cap = await pending;
  complete({ supported: true, smooth: true, powerEfficient: true }); await Promise.resolve();
  assert.deepEqual(cap.hdrRanges, ['SDR']);
  const conditions = playbackProfile(cap, 1).CodecProfiles[0].Conditions;
  assert.equal(conditions[0].Value, 'SDR'); assert.equal(conditions[0].IsRequired, true);
});
test('DTS-HD extensions, integer/float PCM and source HDR10+ metadata remain distinct', () => {
  const src = { Id: 'private', MediaStreams: [{ Index: 0, Type: 'Audio', Codec: 'dts', Profile: 'DTS-HD MA', AudioSpatialFormat: 'DTSX', Channels: 8 }] };
  assert.deepEqual(describePlayback(src, 'DirectPlay').audio, ['DTS-HD Master Audio', '8 channels', 'DTS:X (server metadata)']);
  src.MediaStreams[0].Codec = 'pcm_f32le'; assert.equal(describePlayback(src, 'DirectPlay').audio[0], 'PCM float 32-bit LE');
  const hdr = { Id: 'private', MediaStreams: [{ Index: 0, Type: 'Video', Codec: 'hevc', Hdr10PlusPresentFlag: true, DvBlSignalCompatibilityId: 1 }] };
  assert.ok(describePlayback(hdr, 'DirectPlay').video.includes('HDR10+ metadata reported by server'));
  assert.match(describePlayback(hdr, 'DirectPlay').output, /unverified/);
});
test('malformed optional provider field types cannot turn disclosure into a playback exception', () => {
  for (const source of [{ Id: 'x', MediaStreams: {} }, { Id: 'x', MediaStreams: [null, { Index: 1, Type: 'Audio', Codec: 123, Profile: 9 }, { Index: 0, Type: 'Video', Codec: {}, VideoRangeType: {} }] }]) {
    const report = describePlayback(source as unknown as MediaSource, 'DirectPlay');
    assert.match(facts(report).join('\n'), /unknown|unavailable/); assert.ok(!facts(report).some(fact => fact.includes('[object Object]')));
  }
});

test('legacy decoder result ignoring HDR dictionary members cannot advertise an HDR range', async () => {
  const cap = probeEngine(() => 'probably'), signal = new AbortController().signal;
  const oldStyle = await probeSourceHDR(cap, hdrSource, signal, async () => ({ supported: true, smooth: true, powerEfficient: true }));
  assert.deepEqual(oldStyle.hdrRanges, ['SDR']);
  const stripped = await probeSourceHDR(cap, hdrSource, signal, async c => ({ supported: true, smooth: true, powerEfficient: true, configuration: { type: c.type, video: { contentType: c.video!.contentType, width: 3840, height: 2160, bitrate: 20000000, framerate: 24 } } }));
  assert.deepEqual(stripped.hdrRanges, ['SDR']);
});
