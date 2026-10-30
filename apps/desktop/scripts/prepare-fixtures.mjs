import { spawnSync } from 'node:child_process';
import { mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { root } from './source-revision.mjs';
const output = resolve(root, '.cache/fixture');
await mkdir(resolve(output, 'hls'), { recursive: true });
const commands = [
  ['-f','lavfi','-i','testsrc2=size=1280x720:rate=24','-f','lavfi','-i','sine=frequency=220:sample_rate=48000','-t','14','-c:v','libx264','-preset','veryfast','-pix_fmt','yuv420p','-c:a','aac','-b:a','96k','-movflags','+faststart',resolve(output,'sample.mp4')],
  ['-i',resolve(output,'sample.mp4'),'-c:v','libx264','-g','96','-c:a','copy','-hls_time','4','-hls_playlist_type','vod','-hls_segment_filename',resolve(output,'hls/segment%03d.ts'),resolve(output,'hls/index.m3u8')]
];
for (const command of commands) if (spawnSync('ffmpeg',['-hide_banner','-loglevel','error','-y',...command],{stdio:'inherit'}).status !== 0) throw new Error('Synthetic desktop media generation failed');
console.log('Original synthetic test bars/audio generated in desktop cache only.');
