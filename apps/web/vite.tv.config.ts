import { defineConfig } from 'vite';

export default defineConfig({
  publicDir: false,
  define: { __REEL_NATIVE_HLS_ONLY__: 'true' },
  build: {
    target: ['es2017', 'chrome87'], cssTarget: 'chrome87', outDir: 'dist-tv',
    lib: { entry: 'src/main.ts', name: 'ReelTV', formats: ['iife'], fileName: () => 'reel.js', cssFileName: 'reel' },
    sourcemap: false
  }
});
