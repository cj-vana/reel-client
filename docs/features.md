# Features

Reel connects directly to your Jellyfin servers. Your server controls the available library, permissions, metadata and playable versions. See [platform support](platforms.md) and [installation](install/README.md) before choosing a build.

## Find something to watch

- Home brings together Continue Watching, Up Next and recently added titles.
- Browse movies, series and individual episodes, with search, filters and sorting.
- Save favorites and update watched status. Series and season actions make their scope explicit before changing multiple titles.
- Keep separate connections and browsing preferences for different servers and accounts.

## Stay in the player

Video fills the playback window. Overlay controls provide seeking, chapters, speed, quality, audio and subtitle choices where the platform and stream support them.

For shows, use Previous and Next, open the season browser, or enable automatic next episode. The countdown can be cancelled. Skip Intro uses the server's intro markers when they exist. Without them, every app except Roku finds the intro and the credits by matching the theme music an episode shares with the next or previous one, and offers Next episode once the credits start. Reel never guesses from elapsed time or chapter names, and shows nothing when the audio does not match. On the web, desktop and TV web apps, turn on Skip intros automatically in Settings to skip without pressing anything; a Watch it button takes you back. The Apple apps follow the intro and outro settings saved on your Jellyfin server.

TV layouts support directional navigation and visible focus. Phone and tablet layouts use touch targets, native sheets and adaptive navigation. Desktop supports keyboard and pointer input.

On iPhone Duo, open screens lay out as two pages either side of the crease. In the player, a half-open Duo stood like a laptop plays the video above the fold with the controls below it, and one held like a book keeps the controls clear of the fold.

## Offline and installation

| Capability | Availability |
| --- | --- |
| Offline video downloads | Native iPhone and iPad app; compatible original files and supported optimized downloads |
| Installable web app | Supported desktop and mobile browsers |
| Offline web launch | PWA application shell; server media still requires a connection |
| Self-hosting | Static web files or Docker |
| AirPlay and Picture in Picture | Native Apple playback, subject to device and media support |

## More from your library

The native iPhone and iPad app also includes music and audiobook queues, photos, supported books, Live TV/DVR, Seerr requests, remote sessions and SyncPlay. These features depend on server configuration and permissions. The shared web client provides simpler music, photo, book and Live TV browsing; it does not have the same queue, offline, DVR or service-integration features as the native Apple app.

Codec support, HDR and surround output are platform-dependent. See [platform support](platforms.md) for the current limits.
