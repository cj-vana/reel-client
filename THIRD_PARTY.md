# Third-party software and assets

The root MIT license covers original Reel Client code. It does not relicense dependencies, platform frameworks or third-party assets.

The Apple project pins the official [Google Cast iOS SDK package](https://github.com/googlecast/google-cast-ios-sdk) and its resolved dependency in `Package.resolved`. Their applicable licenses/terms remain in effect. License notices are preserved in [the app resource](apps/apple/Reel/Resources/ThirdPartyNotices.txt); distributing an application also requires reviewing the upstream SDK's current terms.

Apple frameworks require the relevant Apple development SDKs and distribution agreements. Jellyfin and Seerr are separate upstream projects; this repository communicates through their APIs and does not bundle their servers.

The web and LG webOS client pins hls.js for playback. The complete runtime notices, including its embedded subtitle and UTF decoding components, are included in [THIRD_PARTY_NOTICES.txt](apps/web/public/THIRD_PARTY_NOTICES.txt) and copied into web and TV builds. The notice checker compares these with the installed dependency licenses. Web build and test tools retain their own licenses; see the pinned package lock and dependency packages.

The logo contours, geometric test artwork and other original project assets use the root MIT license. Logo rendering and reproduction tools such as Blender, Pillow and Sharp retain their own licenses and are not bundled into the client.

The included test generators create original geometric artwork, simple tones, video and PDF content locally. Downloaded photographs and media from private development are not distributed. Generated test output is ignored and is not application content. Contributors must provide redistribution rights and attribution for any future assets.

The desktop packages bundle Electron and Chromium, which ship with their own licenses (Electron's `LICENSE` and Chromium's `LICENSES.chromium.html`) inside each package. The Docker image is built on the official Node.js and nginx Alpine images, under their respective licenses. The Google Cast SDK pulls in `gtm-session-fetcher` (Apache 2.0) as a transitive dependency.
