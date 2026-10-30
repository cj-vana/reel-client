import { mkdir, readdir, stat, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { INTRO_EPISODES, INTRO_RUNTIME, INTRO_TAIL_START, introEpisodeWAV } from './intro-fixture.mjs';

const root = resolve('.cache/fixture');
// --demo also renders a short clip for every title in fixtures/demo, so the demo library plays its own picture.
const demo = process.argv.includes('--demo');
await mkdir(resolve(root, 'hls'), { recursive: true });
const commands = [
  ['-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=220:sample_rate=48000', '-t', '14', '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', resolve(root, 'sample.mp4')],
  ['-i', resolve(root, 'sample.mp4'), '-c:v', 'libx264', '-g', '96', '-c:a', 'copy', '-hls_time', '4', '-hls_playlist_type', 'vod', '-hls_segment_filename', resolve(root, 'hls/segment%03d.ts'), resolve(root, 'hls/index.m3u8')]
];
// The intro scan episodes: a small picture over each episode's synthetic audio, and that audio as the 32 kbps
// MP3 Jellyfin sends the scan, whole and from the start of the closing minutes.
await mkdir(resolve(root, 'intro'), { recursive: true });
for (const id of INTRO_EPISODES) {
  const wav = resolve(root, 'intro', id + '.wav'), mp3 = ['-ac', '1', '-ar', '16000', '-c:a', 'libmp3lame', '-b:a', '32k'];
  await writeFile(wav, introEpisodeWAV(id));
  commands.push(
    ['-i', wav, ...mp3, resolve(root, 'intro', id + '.mp3')],
    ['-ss', String(INTRO_TAIL_START), '-i', wav, ...mp3, resolve(root, 'intro', id + '-tail.mp3')],
    ['-f', 'lavfi', '-i', 'testsrc2=size=320x180:rate=5', '-i', wav, '-t', String(INTRO_RUNTIME), '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '34', '-g', '50', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '48k', '-movflags', '+faststart', resolve(root, 'intro', id + '.mp4')]
  );
}
if (demo) {
  const artwork = resolve('fixtures/demo');
  await mkdir(resolve(root, 'demo'), { recursive: true });
  for (const entry of await readdir(artwork, { withFileTypes: true })) {
    const backdrop = resolve(artwork, entry.name, 'backdrop.jpg');
    if (!entry.isDirectory() || !await stat(backdrop).then(() => true, () => false)) continue;
    // A 14 second slow push-in on the backdrop, aimed a little above centre where faces usually are. The still
    // is scaled up first so the zoom moves smoothly instead of stepping a whole source pixel at a time. The
    // audio is faint brown noise, like room tone.
    commands.push(['-loop', '1', '-framerate', '24', '-i', backdrop, '-f', 'lavfi', '-i', 'anoisesrc=color=brown:amplitude=0.02:sample_rate=48000',
      '-filter_complex', "[0:v]scale=3840:-2,zoompan=z='1+0.12*on/336':x='(iw-iw/zoom)/2':y='(ih-ih/zoom)*0.35':d=1:s=1280x720:fps=24,format=yuv420p[v];[1:a]lowpass=f=700,volume=0.6[a]",
      '-map', '[v]', '-map', '[a]', '-t', '14', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '22', '-g', '48', '-c:a', 'aac', '-b:a', '64k', '-movflags', '+faststart',
      resolve(root, 'demo', entry.name + '.mp4')]);
  }
}
for (const command of commands) {
  const result = spawnSync('ffmpeg', ['-hide_banner', '-loglevel', 'error', '-y', ...command], { stdio: 'inherit' });
  if (result.status !== 0) throw new Error('ffmpeg fixture preparation failed');
}
const demoClips = commands.length - 2 - 3 * INTRO_EPISODES.length;
console.log(demo ? `Generated test bars, audio and intro scan episodes, plus ${demoClips} demo clips from the demo artwork.` : 'Generated original test bars, audio and intro scan episodes. No household media was used.');
