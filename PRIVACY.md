# Privacy

Reel connects only to the servers you choose. It has no accounts of its own, no analytics and no advertising. This page describes what each client stores and sends. The sections on connections, local information and integrations describe the Apple apps in detail; the table below covers the differences in the other clients.

| Client | Where a remembered sign-in is kept | Notes |
|---|---|---|
| iPhone, iPad, Apple TV | Device-only Keychain | Passwords are never saved. See [Apple TV privacy](apps/tvos/PRIVACY.md). |
| Web and Docker | This browser's storage | Remembering is optional. Sign out on shared devices. The container stores nothing. |
| Desktop | The operating system's secure storage | Not available on Linux yet, where sign-in lasts for the session. |
| LG webOS and Samsung Tizen | The TV's web storage | Same behavior as the web client. |
| Roku | Nothing persistent | Server and account labels are remembered. Tokens last for the session, and watch reports start off. |

## Connections and credentials

You choose the Jellyfin servers to connect to. The app sends sign-in credentials to the selected server and keeps its session token in device-only Keychain. It does not save the password. Optional Seerr sessions/API keys and gateway header values are also stored in device-only Keychain and scoped to their configured connection. A Seerr administrator API key carries administrator authority.

Use HTTPS for remote connections. HTTP is permitted for recognized private/local network addresses and Tailscale addresses, and the connection screen explains that HTTP is unencrypted. Local Network permission enables connections to your server and receiver discovery.

The project does not operate an account, credential relay or media-hosting backend for the Apple client. Your Jellyfin/Seerr server and any configured gateway receive the requests you make and may keep their own logs.

## Local information

Saved account names and server addresses, preferences, queue/reading position and offline media metadata remain on the device. Artwork is cached in bounded account-scoped memory. Requested offline files and native video packages use the app's local storage.

Normal device Release playback can send Jellyfin start/progress/stop reports to update watch history. Failed reports may persist locally with server/account identity, item/session identifiers, playback position and owned-resource cleanup metadata. The pending report journal does not contain a password or token and can replay only through a matching signed-in account.

Private viewing suppresses watch reports. Debug builds and all simulator builds protect nonloopback servers from history and library mutations. The loopback fixtures permit mutable tests. Authentication, stream negotiation, owned encoder/tuner cleanup and logout remain possible in protected previews. Device Release builds permit normal server actions and should be tested with a disposable account first.

Playback of saved offline copies keeps its progress locally. Removing a connection removes its saved credentials from the app and attempts to revoke the Jellyfin session. Local cleanup errors are shown; deleting a local connection does not delete the server account, library or server-side history. Removing the app does not delete anything already stored by your server.

## Optional integrations

- Seerr requests, DVR actions, remote-player commands and SyncPlay group actions communicate with the configured services and can affect their state in normal device Release use.
- Seerr discovery artwork is fetched from TMDB's image service when used. That service receives ordinary image requests.
- Google Cast uses Google's SDK and receiver/discovery services. Reel disables the SDK's diagnostic analytics option. This is not a claim that Google or the receiver collects no information. A receiver chosen by you receives the authorized media URL needed to play the title.
- Gateway-protected playback uses a per-play loopback relay; extra gateway credentials remain scoped to the configured server. Chromecast and Apple's optimized background downloader cannot supply these custom gateway headers and are restricted accordingly.
- AirPlay and Picture in Picture use the operating system's media facilities. Exporting a saved file hands it to the destination you choose.

Reel Client contains no first-party analytics, advertising or tracking backend. Dependency, operating-system, server, gateway and receiver privacy policies still apply. The Apple privacy manifest and third-party notices ship with the app.

Report privacy/security concerns through [SECURITY.md](SECURITY.md). Do not attach personal credentials, watch history or media to a public issue.
