# Web and Docker

[Choose another platform](README.md)

Reel runs in a browser or as an installed progressive web app. You need a reachable Jellyfin server and an account on that server.

## Docker

With Docker and Compose v2 installed, run from the repository root:

```sh
docker compose -p reel -f docker/compose.yml up --build -d
```

Open **http://127.0.0.1:18790** on the Docker host. Enter your Jellyfin server address, username, and password in Reel. See the [Docker guide](../../docker/README.md) for updates, logs, and removal.

To run the published image instead of building it, and to have it update itself, use the release compose file:

```sh
docker compose -p reel -f docker/compose.release.yml --profile auto-update up -d
```

The [Docker guide](../../docker/README.md#automatic-updates) explains what the updater can access and how to update by hand instead.

The default address is available only on the Docker host. To use Reel from a phone, tablet, TV, or another computer, publish the static site through your HTTPS reverse proxy. Allow the Reel site's origin in Jellyfin's CORS configuration. An HTTPS site requires an HTTPS Jellyfin address.

## Static hosting

Install Node.js 22.12 or newer. From `apps/web`:

```sh
npm ci --ignore-scripts
npm run check:static
npm test
npm run build
```

Serve the complete `dist/` directory with your HTTPS static host. Keep the runtime configuration, manifest, service worker, assets, and notices together. To try the build locally, run `npm run preview` and open the printed address. Opening `index.html` directly from the filesystem is not supported.

## Install Reel

Use **Install Reel** when available, or your browser's install command. In Safari on iPhone or iPad, choose **Share → Add to Home Screen**. HTTPS is required except on localhost.

The installed app shares the website's origin and remembered connections. Its interface can reopen offline after an initial online load, but your library and media still need a connection to Jellyfin. Offline media downloads are not part of the web app.

## Connections and updates

**Remember this connection** stores an access token in this browser. Your password is never saved. Leave Remember off for a session-only connection, and sign out on shared devices. Watch-progress synchronization is a separate setting.

Use **Update Reel** when a new build is ready. Finish playback and pending changes, and close other Reel windows first. The update preserves remembered connections and settings. Changing the site's scheme, host, or port creates a different browser origin, so saved connections do not automatically move to the new address.

For static hosting, replace complete builds together and keep the previous build for rollback. To remove Reel, sign out, uninstall the browser app, and remove only this site's browser storage if needed. Stopping a container does not clear a browser's saved connection.
