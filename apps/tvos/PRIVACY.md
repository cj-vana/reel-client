# Apple TV privacy model

This describes what the Apple TV app stores and sends.

You choose the Jellyfin server. Reel sends the username and password to that server for authentication, then saves the returned account and session token in this app’s device-only Keychain. The password is not saved. Server addresses, account names and the active connection are part of the saved account vault. An unreadable vault blocks sign-in and durable account changes until Retry can read it successfully.

A random app device identifier, quality and private-viewing preferences remain in app-local settings. Artwork comes from the selected Jellyfin server and uses bounded account-scoped memory caching. The app does not operate an account service, credential relay, analytics service or media-hosting backend.

Normal device Release playback can send start, progress, pause and stop reports to Jellyfin. Failed progress and owned-resource cleanup can persist locally with server/user identity, item/session identifiers and playback position. This journal contains no password or access token and replays through a matching signed-in account. Private viewing suppresses history reports; the server still receives authentication, artwork, browsing, stream negotiation and media requests. Owned encoder cleanup and logout can still run.

When the server has not marked an episode's intro or credits, the app asks it for a low-quality audio copy of the opening and closing minutes of that episode and a neighboring one, and compares them on the device. These requests use their own playback session and are never reported as watched. The times found, not the audio, stay in app-local settings and are removed when you remove that account. Turn off Find intros and credits in Settings to stop it.

Debug builds and every simulator build protect nonloopback servers from history and library mutations. Synthetic loopback fixtures allow mutable tests. This protection does not imply that authentication, browsing or playback requests are invisible to a server.

Removing a connection deletes its saved sign-in locally and attempts server-session revocation after playback/report cleanup. It does not delete the server account, media or existing server-side history. A server may retain its own request logs. Use HTTPS for remote servers; the connection form permits HTTP only for recognized local/private addresses and explains that it is unencrypted.

The Apple TV app has no Cast SDK, Seerr request interface, discovery scanner, offline-library downloader, advertising or first-party tracking backend. Operating-system and selected-server privacy policies still apply.

Report concerns through the repository’s [security policy](../../SECURITY.md), without including personal credentials, media or watch history in a public report.
