# Reel for web and TV

Browse your Jellyfin library, pick up an episode, and keep watching without leaving the player. Reel adapts its layout for a mouse, touch screen or TV remote. The same web client powers the desktop app, Docker host, LG webOS app and Samsung TV adapter.

## Run locally

Requires Node 22.12 or newer.

```sh
npm ci --ignore-scripts
npm run dev
```

Open the address printed in the terminal and connect your Jellyfin server. Jellyfin must allow requests from that origin. An HTTPS page also needs an HTTPS server address.

To try Reel without a Jellyfin server, start the demo library in a second terminal. It needs ffmpeg to render the sample clips:

```sh
npm run qa:prepare-demo
npm run qa:demo
```

Then connect to `http://127.0.0.1:18771` with any username and the password `demo`. The demo library is the one in the screenshots: sixteen titles with original artwork, nothing from a real catalog.

For a static deployment, run `npm run build` and serve `dist/`. See the [web and Docker install guide](../../docs/install/web-docker.md) for hosting, TLS and PWA installation. The web app can be installed from a supporting browser; its offline screen helps you reconnect, while streaming still needs your server.

## Using Reel

Home brings together Continue watching, Next up and recent additions. Library and Search offer filters, sorting, grid and list views. Browse choices stay separate for each server, account and collection.

The player has previous and next episode controls, a season browser, a cancellable next-episode countdown, audio and subtitle choices, chapters and playback speed. Skip Intro appears when the server supplies valid intro markers. TVs use one remote-controlled transport; browsers retain their native video controls.

Save adds a title to Jellyfin favorites. Mark watched changes its server status; actions affecting a collection or several titles ask for confirmation. Watch progress syncs automatically; turn on Private viewing in Settings to stop it.

Offline video downloads, DVR scheduling, media requests, casting and group viewing are not currently available in this client. The [feature guide](../../docs/features.md) compares what each client offers.

## Connections and privacy

Reel ships without a server address, account or saved preferences. Remembering a connection is optional and stores its access token in browser storage on that device. Passwords are never saved. Sign out to remove the local connection and end its server session when the server is reachable. Reel has no analytics or telemetry.

Runtime settings live in `public/reel-config.js`. Normal builds allow the server actions you choose. Set `previewMode: true` for a read-only preview against a nonlocal server; this blocks library changes and watch reports while allowing sign-in and playback. Keep that mode on when testing with a personal library.

## LG webOS

Create an IPK with the webOS CLI:

```sh
npm run webos:stage
npm exec --yes --package=@webos-tools/cli@3.2.6 -- ares-package --no-minify webos-package --outdir .cache/packages
python3 scripts/inspect-webos.py
```

The application ID is `app.reelclient.tv`. Follow the [TV install guide](../../docs/install/televisions.md#lg-webos) to install it through your device's developer setup. Use `REEL_PROTECTED_PREVIEW=1 npm run webos:stage` when building a read-only test package.

Keep `--no-minify`: Vite already produces the TV bundle, and package inspection verifies that its bytes are unchanged. The TV build targets Chromium 87 and uses the device's native video and HLS support. Codec, HDR and audio-output support depend on the television.

## Development checks

```sh
npm test
npm run check:static
npm run qa:prepare
```

The media fixtures require ffmpeg. To run the full browser suite, first build and inspect the LG package above, install Chrome, then use the runner:

```sh
node node_modules/playwright/cli.js install chrome
REEL_CI_SYNTHETIC=1 node ../../scripts/run-web-browser-suite.mjs
```

The runner starts and stops its own fixture, app and notice servers on ports 18770, 18771 and 18779. Those ports must be free. Browser checks cover the shared interface; native TV and desktop behavior also need testing on those platforms.

Distributions include `THIRD_PARTY_NOTICES.txt`. The static and package checks verify its license text against the dependency versions in `package-lock.json`.
