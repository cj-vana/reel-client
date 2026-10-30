# Reel with Docker

Run Reel as a self-hosted web app for your Jellyfin server. The browser connects directly to Jellyfin; the container serves Reel's interface.

## Start Reel

Install Docker with Compose v2, then run from the repository root:

```sh
docker compose -p reel -f docker/compose.yml up --build -d
```

Open **http://127.0.0.1:18790** and enter your Jellyfin server address and account. No server address or credentials are bundled with the image.

For access from another device, place the static site behind your HTTPS reverse proxy. Jellyfin must allow the site's origin through CORS, and an HTTPS Reel site needs an HTTPS Jellyfin endpoint. See the [web installation guide](../docs/install/web-docker.md).

## Install as an app

Choose **Install Reel** when your browser offers it, or use the browser's install command. On iPhone and iPad, open Reel in Safari and choose **Share → Add to Home Screen**. Installation requires HTTPS, except for localhost.

After the first online load, the app interface can open offline. Browsing your server and playing media still require a connection. Reel caches the public interface only; server responses, media, remote artwork, passwords, and access tokens are excluded from its offline cache.

New versions show **Update Reel**. Finish playback and any pending changes, then close other Reel windows before updating. **Later** keeps the current version. Remembered connections stay available after an update; session-only connections require sign-in again.

## Run the published image

Each release publishes a multi-architecture image to the GitHub Container Registry. To run it without building, use the release compose file from the repository root:

```sh
docker compose -p reel -f docker/compose.release.yml up -d
```

It runs the same hardened container as the source build, on the same address. Set `REEL_IMAGE` to pin a version, for example `REEL_IMAGE=ghcr.io/cj-vana/reel-client:1.2.0`.

## Automatic updates

Add the `auto-update` profile to also run [Watchtower](https://github.com/nicholas-fedor/watchtower), the maintained fork:

```sh
docker compose -p reel -f docker/compose.release.yml --profile auto-update up -d
```

Every six hours it checks for a newer `latest` image, replaces the Reel container with the same settings, and removes the old image. It only touches containers labelled with the `reel` scope, so the rest of your host is left alone. Browser sessions are not affected; open tabs offer **Update Reel** once the new version is running.

The updater needs the Docker socket to replace containers, which gives it control of Docker on the host. If that is not acceptable, leave the profile off and update by hand:

```sh
docker compose -p reel -f docker/compose.release.yml pull
docker compose -p reel -f docker/compose.release.yml up -d
```

## Update and stop

After updating your checked-out source:

```sh
docker compose -p reel -f docker/compose.yml up --build -d
docker compose -p reel -f docker/compose.yml ps
docker compose -p reel -f docker/compose.yml logs web
```

To stop this deployment:

```sh
docker compose -p reel -f docker/compose.yml down
```

The container has no persistent data volume. Remembered connections and preferences belong to the browser, so stopping or replacing the container does not sign out browser sessions. Sign out in Reel to remove a saved connection.

## Hosting details

- Supports ARM64 and AMD64 container images built from the same Dockerfile.
- Binds to loopback port `18790` by default; `/healthz` checks readiness.
- Runs as UID/GID 101 with a read-only filesystem, dropped capabilities, and a bounded temporary directory.
- Uses pinned Node and nginx image digests and exact npm dependency versions.
- Serves static files only; no Jellyfin proxy, account service, or TLS termination is included.
- HTML and runtime configuration are revalidated. Fingerprinted assets are immutable, while the service worker and manifest check for updates.

Deploy the complete build together. Set `reel-config.js` before building; changing it afterward invalidates the offline cache's integrity check. Keep the prior image available when updating.

To check a running container, start it and run `python3 docker/verify-http.py` from the repository root. It requests the site's pages, headers and health check at `127.0.0.1:18790`.
