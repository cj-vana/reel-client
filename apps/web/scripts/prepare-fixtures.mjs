import { mkdir, readdir, stat } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';

const root = resolve('.cache/fixture');
// --demo also renders a short clip for every title in fixtures/demo, so the demo library plays its own picture.
const demo = process.argv.includes('--demo');
await mkdir(resolve(root, 'hls'), { recursive: true });
const commands = [
  ['-f', 'lavfi', '-i', 'testsrc2=size=1280x720:rate=24', '-f', 'lavfi', '-i', 'sine=frequency=220:sample_rate=48000', '-t', '14', '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', '-c:a', 'aac', '-b:a', '96k', '-movflags', '+faststart', resolve(root, 'sample.mp4')],
  ['-i', resolve(root, 'sample.mp4'), '-c:v', 'libx264', '-g', '96', '-c:a', 'copy', '-hls_time', '4', '-hls_playlist_type', 'vod', '-hls_segment_filename', resolve(root, 'hls/segment%03d.ts'), resolve(root, 'hls/index.m3u8')]
];
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
console.log(demo ? `Generated test bars and audio, plus ${commands.length - 2} demo clips from the demo artwork.` : 'Generated original test bars and audio. No household media was used.');
