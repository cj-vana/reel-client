# Desktop security

Reel Desktop is an Electron shell around the web client. This page describes what the shell allows and what it stores.

## What the window can load

The app serves only its own bundled files from `reel://app`. Files are checked against a build-time hash list before the window opens. Unknown paths, methods, hosts, encoded names and symlinks are rejected.

The renderer runs with Chromium sandboxing and context isolation on. It has no Node.js access, no webviews and no popups, and it cannot navigate to external sites. Requests to your Jellyfin server go through normal Chromium networking, so CORS and mixed-content rules apply.

## Permissions

Fullscreen is allowed only when you ask for it from the app window. Camera, microphone, notifications, device access and every other permission are denied.

## What the page can ask the shell to do

A sandboxed preload exposes five fixed operations: initialize, save connections, save preferences, and two for coordinating window close. Each call is checked against the window and page that made it. There is no way to read arbitrary files, run programs or evaluate scripts through it.

## Stored data

- Passwords are never stored.
- Saved accounts (server address and access token) are encrypted with the operating system's credential store through Electron `safeStorage` and written to a private file in the app data folder.
- Preferences and the device identifier are stored separately and contain no tokens or server addresses.
- If the credential store is locked or unavailable, Reel keeps existing data untouched and works for the current session only.
- The browser session itself is not persisted.

## Packaging

Packaged apps run `app.asar` only, with `RunAsNode`, `NODE_OPTIONS` and Node inspector flags disabled. There is no analytics, crash uploader or autostart.

Downloads run in the main process with their own in-memory session, read only from the server the request names (every playlist entry is checked against it), and write only under `offline/` in the app data folder. The page reads a finished download through `reel://app/offline/<id>/<file>`, where the file name must be the playlist, a numbered segment or the artwork.

The update check runs in the main process and talks only to GitHub: the releases API, and on a signed Mac the release's feed and ZIP. The page cannot pass it a URL. Squirrel.Mac installs an update only when the new app is signed by the same Developer ID team, and discards a ZIP whose SHA-256 or size differs from the feed.

Windows and Linux packages are unsigned, and so is the Mac app when a release is built without the signing secrets; macOS and Windows may warn on first launch. See [desktop installation](../../../docs/install/desktop.md).

## Known limits

- Closing the window flushes playback reports on a best-effort basis. A crash or network outage can leave a server session to expire on its own.
- Windows directory metadata durability after a power loss has not been tested.
