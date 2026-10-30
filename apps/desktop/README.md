# Reel for desktop

Browse your Jellyfin library, continue watching, and play films and series in a dedicated desktop window. Reel includes keyboard playback controls, audio and subtitle selection, quality options, an episode browser, Skip Intro and Next episode at the credits (found from the episodes' audio when your server has no markers), and optional automatic episode playback.

## Build and run

Install Node.js 22.12 or newer. From this directory:

```sh
npm ci --ignore-scripts
npm run check
npm test
npm run build
npm run package
```

- `npm run check` checks script syntax and that every dependency is pinned to the version in `package-lock.json`.
- `npm test` runs the unit tests. One of them runs the real build script on a small sample web client, so install dependencies first.
- `npm run build` compiles the shared web client from `../web` (its `src`, `public`, `index.html` and `vite.config.ts`) with the Vite and hls.js versions pinned here. You do not need to install dependencies in `apps/web`. The build records a hash of those web files and of this folder's sources.
- `npm run package` creates the application for the computer you are on. It refuses to run if this folder's sources or those web files changed after the build. Run `npm run build` again in that case.

Packaging downloads the Electron runtime from GitHub once, checks it against `scripts/electron-checksums.json` and keeps it in `.cache/electron`. Behind an HTTPS proxy, set `NODE_USE_ENV_PROXY=1` so Node.js uses your proxy settings. This needs Node.js 24 or a recent 22.x release.

The application is written to `.cache/packages/production/Reel-<platform>-<arch>/`. By default it targets the computer you are on. You can pass `--platform=darwin`, `win32` or `linux` and `--arch=arm64` or `x64`, for example `npm run package -- --arch=x64` on a Mac to make an Intel Mac copy, but build each system's package on that system. A macOS package needs the Mac's own tools for its icon and its local ad hoc signature. Linux and Windows packages use Electron's default icon.

`npm run package -- --qa` builds a test copy named Reel Desktop QA in `.cache/packages/qa/` for the runtime check below. It runs in preview mode, never uses the system's secure storage, and starts only with the private temporary profile that the runtime check creates.

Open Reel and enter your Jellyfin server address, username, and password. No server or account is included. The server must be reachable from your computer.

## Checking a packaged app

`npm run test:runtime` opens the packaged QA app on a Mac with Apple silicon and walks through sign in, browsing, playback, fullscreen, search and quit against a local sample server. It needs ffmpeg and free local ports 19670 and 19671:

```sh
node scripts/prepare-fixtures.mjs
npm run build
npm run package -- --qa
npm run test:runtime
```

Run `npm run test:runtime -- --visible` to watch the window. Results and screenshots are written to `.cache/runtime/`.

## Playback and connections

Use Space to play or pause and the arrow keys to seek. Playback options contain picture quality, audio, subtitles, chapters, and playback speed. For a series, use the episode controls to move between episodes or choose another season. Escape dismisses the open playback panel before leaving the player.

**Remember this connection** stores your access token using the operating system's secure storage. Your password is never saved. If secure storage is unavailable, Reel offers a session-only connection and leaves existing saved data intact. Quit and reopen Reel to retry. Remember is currently unavailable on Linux.

Use Settings to choose default quality, watch-progress synchronization, and automatic episode playback. Sign out before sharing your computer account with someone else.

## Downloads

On a film or an episode, **Download** offers three sizes: High (1080p, 6 Mbps), Standard (720p, about 1.9 Mbps) and Data saver (480p, 0.9 Mbps), the same as the iPhone and iPad app. Your server converts the title to H.264 and AAC; the main process (`src/offline.mjs`) saves the HLS segments under the app data folder, through its own in-memory session so nothing reaches the HTTP cache, and the page plays them from `reel://app/offline/` with hls.js. **Downloads** in the sidebar lists them with their progress, and a download resumes where you stopped. Signing out of an account removes its downloads. A download cut off by quitting is offered again rather than resumed.

## Distribution

The scripts create portable application folders. Installers and store packages are not included. Current platform availability is listed in the [installation guide](../../docs/install/README.md).

- macOS: when the release workflow has the signing secrets below, the app is signed with a Developer ID and the hardened runtime (`signing/entitlements.mac.plist` allows only what Electron's JavaScript engine needs), notarized and stapled. Local packages stay ad hoc signed, and Gatekeeper may block an unsigned download.
- Windows: packages have no Authenticode signature. SmartScreen may warn on first launch.
- Linux: `chrome-sandbox` is not installed setuid, so the Chromium sandbox needs unprivileged user namespaces. Do not run Reel with the sandbox turned off.

### Updates

`src/updates.mjs` checks for a newer release shortly after launch and every twelve hours, unless Settings turns it off. A signed Mac build uses Electron's `autoUpdater` (Squirrel.Mac) with the `reel-desktop-macos-arm64.json` feed each signed release carries (`scripts/update-feed.mjs` writes it with the ZIP's SHA-256 and size). Every other build asks GitHub's API for the latest release and offers its release page. The page can only ask the main process for the state, a check, a restart into a downloaded update, or the release page (`src/updates-bridge.mjs`). QA builds never check.

### Signing secrets

The release workflow signs and notarizes the Mac app only when all five repository secrets are set:

| Secret | Value |
|---|---|
| `MACOS_CERTIFICATE` | The Developer ID Application certificate and its private key, exported as a .p12 file, base64-encoded |
| `MACOS_CERTIFICATE_PASSWORD` | The password chosen when exporting the .p12 |
| `APPLE_API_KEY` | The contents of an App Store Connect API key (.p8) with the Developer role |
| `APPLE_API_KEY_ID` | That key's ID |
| `APPLE_API_ISSUER` | The issuer ID shown above the keys list in App Store Connect |

The certificate lives only in a temporary keychain for the job, which the job deletes afterwards.

Reel uses pinned Electron and web dependencies. Each package's `app.asar` holds only the shell code, the compiled web client with its asset list, the license and third-party notices. It excludes source maps, development fixtures, test profiles and local settings. See [security](docs/security.md) for storage and permission details.
