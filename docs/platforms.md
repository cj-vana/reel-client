# Platform support

Reel shares its look across the Apple apps, the web player and the TV clients. Each client uses the navigation and playback controls that suit its device. See the [installation guide](install/README.md) for how to get each one and the [feature guide](features.md) for what each can do.

## Clients and requirements

| Client | Requirements | Notes |
| --- | --- | --- |
| iPhone, iPhone Duo and iPad | iOS or iPadOS 27 or later | Native playback, downloads and touch controls. Layouts adapt to each screen, including both screens of iPhone Duo. AirPlay and Picture in Picture depend on the device and the media. |
| Apple TV | tvOS 27 or later | Remote navigation, native playback, season browsing and episode controls. Fewer features than the iPhone and iPad app. |
| Web and Docker | A current browser and a reachable Jellyfin server | Installable as an app on browsers that support it. The interface opens offline, but your library and media do not. Video downloads are in the iPhone, iPad and desktop apps. |
| Desktop | macOS 13, Windows 10 or a current Linux distribution | Electron packages for macOS, Windows and Linux, with downloads for watching offline. See the [desktop guide](install/desktop.md). |
| LG webOS | An LG TV with Developer Mode | Uses the TV's own video decoder. |
| Samsung Tizen | A Tizen 7.0 or newer TV, Tizen Studio and your own certificate | Experimental. |
| Roku | A Roku with developer mode, OS 16 or newer | Experimental. Movies and series only. |

Android is not supported.

On Roku, Skip Intro needs intro markers from your server; every other app also finds intros and credits from the episodes' audio. Audio tracks, subtitles, transcoding, HDR and surround sound depend on your media, your server, the operating system and the playback hardware. Reel does not promise a particular receiver format from codec information alone.

## Known limits

- There is no store release. You sign the Apple, Samsung and Roku apps yourself.
- Windows and Linux desktop packages are unsigned, and Windows SmartScreen may block a downloaded copy. The Mac app is signed and notarized when the release says so; an unsigned one may be blocked by Gatekeeper. Use a build you made yourself, or approve it under your system's own rules.
- Remembered connections are not available in the Linux desktop app yet. Sign-in lasts for the session.
- Some LG MP4 files seek to the keyframe before the requested time, so media with widely spaced keyframes can resume a little early.
- The LG remote's Play, Pause, Stop, Rewind and Fast forward keys are handled by their standard key names and codes, but have not been pressed on a physical TV yet.
- The Samsung app has not been tried on a physical TV yet. Installing it, the on-screen keyboard and playback may need fixes.
- The Roku channel has not been tried on a physical Roku yet, and the Roku simulator cannot test HTTPS servers.
- On iPhone Duo, the player has tabletop and book layouts for a half-folded phone. The book layout has been tried in the simulator, half open. Tabletop has only been tried with a simulated fold, and neither layout on a physical phone.
- The web app's layouts for foldable Android devices have been tried with Chrome's fold emulation, not on a physical foldable. Android itself has no app; these layouts are for the browser and the installed web app. The double tap to seek on a half-folded screen has been tried with emulated touches only.
- In a browser, the screen stays on during playback only on a secure page (HTTPS, or the same computer), because browsers offer that to secure pages only. A plain HTTP address on your home network plays as before, and the device's own sleep timer applies.
- The keyboard's media keys and a headset's buttons are passed on by the browser. Reel sets them up in Chrome, Edge, Safari and Firefox, but they have not been pressed on hardware.
- A link opened while signed out is kept until you sign in on that page. Reloading the sign-in page first forgets it.
- HDR, passthrough and long playback sessions depend on the device and are not guaranteed.

## Build modes

Normal builds can change things on your server: favorites, watched status and watch progress, unless you turn on Private viewing. A read-only preview mode blocks changes on servers that are not on loopback while still allowing sign-in and playback. Apple Debug and simulator builds always protect such servers. Test with a throwaway account. See [privacy](../PRIVACY.md) and [contributing](../CONTRIBUTING.md).
