# Install Reel

Reel is built from source or installed from the packages attached to each release on this repository's GitHub Releases page. Apple and TV apps use their platform's developer tools. The web app can be hosted directly or with Docker.

Signed store builds are not available. You sign the Apple, Samsung and Roku apps yourself, with your own developer account or device. See [platform support](../platforms.md) for requirements and known limits.

## Choose your platform

| Device | How to install | You need |
|---|---|---|
| iPhone and iPad | [Build in Xcode](apple.md#iphone-and-ipad) | A Mac with Xcode 27.1, an Apple developer account, iOS or iPadOS 27 or later |
| Apple TV | [Build in Xcode](apple.md#apple-tv) | A Mac with Xcode 27.1, an Apple developer account, tvOS 27 or later |
| macOS, Windows, Linux | [Desktop packages](desktop.md) | Download from a release, or build with Node.js 22.12 or newer |
| Web | [Static hosting](web-docker.md#static-hosting) | Any web server with HTTPS |
| Docker | [Docker Compose](web-docker.md#docker) | Docker with Compose v2 |
| LG webOS | [IPK](televisions.md#lg-webos) | An LG TV with Developer Mode and the webOS CLI |
| Samsung Tizen | [Tizen Studio](televisions.md#samsung-tizen) | Tizen Studio, a Samsung certificate, a Tizen 7.0 or newer TV |
| Roku | [Developer ZIP](televisions.md#roku) | A Roku in developer mode with a free development slot |

An LG IPK, Samsung WGT and Roku ZIP are different formats and cannot be swapped.

## Check your download

Every release includes a `SHA256SUMS` file. Check a download against it before installing:

```sh
# macOS
shasum -a 256 -c SHA256SUMS --ignore-missing
# Linux
sha256sum -c SHA256SUMS --ignore-missing
```

```powershell
# Windows PowerShell
Get-FileHash -Algorithm SHA256 -LiteralPath .\your-download.zip
```

On Windows, compare the printed value with the matching line in `SHA256SUMS`. A checksum shows the file arrived intact. It does not prove who published it, so download from this repository's releases page only.

## Connect to your server

Enter your Jellyfin address inside Reel, including any path, for example `https://media.example.com/jellyfin`. Nothing is built into the app.

- `localhost` on a phone or TV means that phone or TV, not your computer.
- A web page served over HTTPS cannot call an HTTP Jellyfin server. Use HTTPS for both.
- A browser needs your Jellyfin server or proxy to allow the site's origin through CORS. See Jellyfin's [networking](https://jellyfin.org/docs/general/post-install/networking/) and [reverse proxy](https://jellyfin.org/docs/general/post-install/networking/reverse-proxy/) guides.
- On Apple devices, allow Local Network access if your server is on your home network.
- A timeout usually means a firewall, guest Wi-Fi isolation, a wrong port or a VPN route.

## Updating and removing

Install a new version over the old one with the same app identity and signing certificate. Deleting first can remove saved connections and downloads. Before removing Reel, sign out inside the app. Removing the app does not end your Jellyfin sessions; manage those in Jellyfin's dashboard.

Playback is a private matter between you and your server. Read [privacy](../../PRIVACY.md) for what Reel stores and which actions change watch history.
