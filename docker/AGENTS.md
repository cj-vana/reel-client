# Docker image: notes for agents

The image serves the web client's static build with nginx; there is no server-side code. Read [README.md](README.md) first.

## Where things are

- `../Dockerfile`: builds `apps/web` with pinned Node, then copies `dist/` into a pinned nginx image that runs as UID 101 on port 8080.
- `nginx.conf`: headers, caching (fingerprinted assets immutable, HTML and runtime config revalidated) and `/healthz`.
- `compose.yml`: builds from source and runs it read-only, without capabilities, on `127.0.0.1:18790`.
- `compose.release.yml`: the same container from the published GHCR image, with an optional `auto-update` profile for Watchtower.
- `verify-http.py`: checks a running container's pages, headers and health check.

## Commands

From the repository root: `docker compose -p reel -f docker/compose.yml up --build -d --wait`, then `python3 docker/verify-http.py`, then `docker compose -p reel -f docker/compose.yml down`. CI also runs `docker compose -p reel -f docker/compose.release.yml --profile auto-update config --quiet`.

## Rules the code depends on

- Base images are pinned by digest. Update a digest on purpose, with its tag in the line.
- The release workflow builds both architectures, tests each one, and only then pushes; it adds the OCI labels. Do not push images from anywhere else.
- The container stays read-only with no extra capabilities. Anything that needs a writable path goes on the bounded `/tmp` tmpfs.
