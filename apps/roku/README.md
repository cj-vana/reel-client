# Reel for Roku

A native SceneGraph and BrightScript client for Jellyfin movies and series. Browse Home, recent episodes and your library; search for a title; then use Roku's video player with audio and subtitle choices, resume, previous and next episode controls, and a season browser. Intro markers from the server enable Skip Intro, and automatic next episode can be cancelled.

Roku support is experimental. Source and a local sideload package are available; compatibility with physical Roku devices has not yet been verified. The current testing target is Roku OS 16 or newer.

## Servers and private viewing

Reel remembers server and account labels, playback preferences and browse choices. Passwords and access tokens remain in memory, so a cold launch requires sign-in again. Private viewing starts on for each account, so watch progress stays on the device until you turn it off in Settings.

Home opens with focus on Play or Resume for the first title on the first shelf. Press Down for the shelves and Up to reach the tab bar. Back steps out of title and library screens to the tab bar, then to Home; Back on Home asks before leaving Reel. Where the header shows Options, the remote's * button opens filters, sorting or refresh for the current page.

## Build from source

Requires Node 22.12 or newer and Python 3.

```sh
npm ci --ignore-scripts
npm run check
npm test
npm run package
```

`npm run check` compiles the channel with BrighterScript, builds the package from the current source and validates its contents. The `docs/` folder holds the pinned asset lists that check reads.

The package is written to `out/reel-client-roku-sideload.zip`. It contains the channel manifest, source, components, images and license. Generated packages and test output are excluded from Git.

Tests run the BrightScript logic and episode handlers with disposable local fixtures. Native video decoding, captions, TLS and registry behavior still need Roku runtime checks.
## Install

Enable Developer Mode on your Roku and use its [Development Application Installer](https://developer.roku.com/dev/docs/developer-setup) to upload the ZIP. Roku has one development-app slot, so keep the previous package if you need to restore it. The [TV install guide](../../docs/install/televisions.md#roku) covers setup and updates.

This client currently focuses on movies and series. Casting, SyncPlay, offline downloads, music, photos, books, Live TV and DVR are not supported. See [platform support](../../docs/platforms.md) for current limits.
