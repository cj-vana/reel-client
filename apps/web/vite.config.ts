import { defineConfig } from 'vite';
import { reelPWA } from './src/pwa-build.mjs';

export default defineConfig({
  base: './',
  plugins: [reelPWA()],
  define: { __REEL_NATIVE_HLS_ONLY__: 'false' },
  build: { target: ['es2017', 'chrome87'], cssTarget: 'chrome87', sourcemap: false },
  server: { strictPort: true, port: 18770 },
  preview: { strictPort: true, port: 18770 }
});
