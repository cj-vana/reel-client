# Desktop

[Choose another platform](README.md)

The desktop app runs Reel in its own window, with keyboard playback controls, fullscreen video, episode browsing, audio and subtitle selection, and optional saved connections.

## Get a package

Each release has a ZIP for macOS (Apple silicon), Linux (x64) and Windows (x64). Check it against `SHA256SUMS` as described in the [installation guide](README.md#check-your-download). For another processor or system, build from source below.

The ZIP holds the complete application. Keep all the files together. The app needs macOS 13, Windows 10 or a current Linux distribution.

## macOS

Unzip the package and move **Reel.app** to Applications. The release notes say whether that release's Mac app is signed with a Developer ID and notarized. A signed copy opens without a warning and installs later releases itself. An unsigned copy may be blocked by Gatekeeper; a copy you build yourself runs without that warning. If you choose to open an unsigned download, follow [Apple's instructions](https://support.apple.com/en-us/102445) and keep macOS protections on.

## Windows

Unzip the whole package into a folder you control and open **Reel.exe**. There is no Authenticode signature, so SmartScreen or your organization's policy may block it. Do not turn those protections off.

## Linux

Unzip the whole package and run **Reel** as your normal user. You need a graphical desktop with a working Chromium sandbox. Do not run it as root or disable the sandbox to get past a launch error.

Remembered connections are not available on Linux yet. Sign in each session.

## Connect to Jellyfin

Enter your server address and account in Reel. Include a path such as `/jellyfin` if your server uses one. Where it is supported, **Remember this connection** keeps your access token in the operating system's secure storage. Passwords are never saved. If secure storage is unavailable, Reel offers a session-only connection. Quit and reopen Reel to try storage again.

## Update or remove

Reel checks this project's GitHub releases for a newer version shortly after it opens and then twice a day. Settings shows the result:

- A signed Mac app downloads the update in the background and offers **Restart to update**. Keep Reel in Applications; macOS cannot update it while it runs from the Downloads folder.
- Windows, Linux and unsigned Mac apps show **Download**, which opens the release page. Quit Reel, then replace its folder with the newer package. Keep the old package so you can go back.

Turn off **Check for updates automatically** in Settings to stop the checks; **Check now** still works. Saved connections and settings live outside the application folder.

To remove Reel, sign out, quit, and delete the application folder. This does not end your Jellyfin sessions.

## Build from source

Install Node.js 22.12 or newer, then:

```sh
cd apps/desktop
npm ci --ignore-scripts
npm run check
npm test
npm run build
npm run package -- --platform=darwin --arch=arm64
```

Use `--platform=darwin`, `win32` or `linux` and `--arch=arm64` or `x64` to match your computer. The package appears in `.cache/packages/production/`. Packaging downloads the Electron runtime from GitHub and checks it against a checksum stored in `scripts/electron-checksums.json`.

See [desktop security](../../apps/desktop/docs/security.md) for how storage and permissions work.
