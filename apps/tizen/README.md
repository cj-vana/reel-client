# Reel for Samsung TV

The Samsung adapter brings Reel's shared interface to Tizen TVs, with remote navigation, media keys, Back and text entry. It uses the same library, title details and episode controls as the web client.

Samsung support is experimental. There is no signed download, and playback has not been verified on a physical TV. The target is Tizen 7.0 or newer.

## Build from source

Requires Node 22.12 or newer and Python 3. The adapter wraps the web client's TV bundle, so stage that first:

```sh
(cd ../web && npm ci --ignore-scripts && npm run webos:stage)
npm ci --ignore-scripts
npm test
npm run build -- --web-root ../web
npm run package
```

`build` copies the staged TV bundle into `.cache/stage`, adds the Tizen adapter and configuration, and checks the files against the web stage's manifest. `package` writes `.cache/packages/reel-tv-preview-<source-prefix>.unsigned.wgt`.

The package is unsigned and a TV will not install it. Sign it with your own author and distributor certificate in Tizen Studio, with the Samsung TV and Certificate extensions. Certificates, profiles and device identifiers stay out of the repository. The [TV install guide](../../docs/install/televisions.md#samsung-tizen) walks through signing and installing.

The application id is `ReelClient.Reel` and the package id is `ReelClient`. Keep both, and the same author certificate, when you update an installed copy so its data is retained.

## Configuration and tests

`src/reel-config.js` holds the platform's runtime settings. No server address or account is bundled. Watch-progress sync is optional. Set `previewMode` to true for read-only testing against a personal library.

`npm test` runs the media-key and adapter policy checks and a set of source checks on `config.xml` and the package contents. Remote input, playback, captions and updates also need testing on a TV. For browsing and player controls, see the [web client](../web/README.md).
