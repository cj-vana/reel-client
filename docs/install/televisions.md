# LG, Samsung and Roku

[Choose another platform](README.md)

These installs use each maker's developer route. Only change a TV or streaming box you own, and do not replace an app someone else relies on. Reel is not listed in any TV app store.

## LG webOS

### Prepare the TV

Follow LG's guides to [install the webOS CLI](https://webostv.developer.lge.com/develop/tools/cli-installation) and [turn on Developer Mode](https://webostv.developer.lge.com/develop/getting-started/developer-mode-app). You need an LG developer account, the Developer Mode app on the TV, and a computer on the same network.

With Developer Mode and Key Server on, register the TV:

```sh
ares-setup-device
ares-setup-device --list
ares-novacom --device YOUR_TV_NAME --getkey
```

`ares-setup-device` asks for the TV's address. Developer Mode uses port 9922 and the user `prisoner`. Type the passphrase shown on the TV only into that prompt.

### Build the IPK

You can also use the IPK attached to a release. Check it against `SHA256SUMS` first. To build it yourself, install Node.js 22.12 or newer and run this from `apps/web`:

```sh
npm ci --ignore-scripts
npm run webos:stage
ares-package --no-minify webos-package --outdir .cache/packages
python3 scripts/inspect-webos.py
```

Keep `--no-minify`. The inspection script checks that the package holds exactly the files that were staged. The app id is `app.reelclient.tv`.

### Install and launch

```sh
ares-install --device YOUR_TV_NAME .cache/packages/app.reelclient.tv_0.1.0_all.ipk
ares-launch --device YOUR_TV_NAME app.reelclient.tv
```

Sign in on the TV, then check that you can browse and play something. To update, install the newer IPK over the old one. To close the app, run `ares-launch --device YOUR_TV_NAME --close app.reelclient.tv`.

LG's developer sessions expire. Open the Developer Mode app on the TV and choose Extend before the timer runs out.
To remove Reel, sign out, then run `ares-install --device YOUR_TV_NAME --remove app.reelclient.tv`. This also deletes its saved data.

## Samsung Tizen

Samsung support is experimental. The adapter targets Tizen 7.0 and newer and has not been verified on a physical TV.

### Build the package

You need Node.js 22.12 or newer and Python 3. From the repository root:

```sh
cd apps/web
npm ci --ignore-scripts
npm run webos:stage
cd ../tizen
npm ci --ignore-scripts
npm test
npm run build -- --web-root ../web
npm run package
```

This writes an unsigned package to `apps/tizen/.cache/packages/`. A TV will not install an unsigned package. You sign it with your own certificate in Tizen Studio.

### Sign and install

1. Install Tizen Studio with the Samsung TV Extension and the Samsung Certificate Extension.
2. In Certificate Manager, create or choose your author and distributor certificates for your TV. Keep them private and keep the same author certificate for every update.
3. Turn on Developer Mode on the TV from Apps, enter your computer's address, and restart. Then select the TV in Device Manager. See Samsung's [TV setup guide](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/tv-device.html).
4. Copy `apps/tizen/.cache/stage` into a new Tizen project, check that `config.xml` is intact, then build, sign and install from Tizen Studio. The command-line equivalents are in Samsung's [CLI reference](https://developer.samsung.com/smarttv/develop/getting-started/using-sdk/command-line-interface.html).

The application id is `ReelClient.Reel` and the package id is `ReelClient`. Commands such as `tizen run` and `tizen uninstall` take the application id.

To check a signed file against the build, run this from `apps/tizen`:

```sh
python3 scripts/wgt.py inspect .cache/build-receipt.json YOUR_SIGNED_REEL.wgt --signed
```

It compares the file contents and signature documents. It does not prove the signature is trusted.

To update, install the new signed package over the old one. To remove Reel, sign out, then run `tizen uninstall -s YOUR_TV_SERIAL -p ReelClient.Reel`.

## Roku

Roku support is experimental and has not been verified on a physical Roku. The target is Roku OS 16 or newer.

### Build the ZIP

Or take the ZIP from a release. To build it, you need Node.js 22.12 or newer and Python 3:

```sh
cd apps/roku
npm ci --ignore-scripts
npm run check
npm test
npm run package
```

The ZIP is written to `apps/roku/out/reel-client-roku-sideload.zip`.

### Install

Follow Roku's [developer setup](https://developer.roku.com/dev/docs/developer-setup). On the Roku remote, press Home three times, Up twice, then Right, Left, Right, Left, Right to open the developer settings. Accept the agreement and set an installer password. Then open the address the Roku shows in a browser on the same network, sign in as `rokudev` with that password, and upload the ZIP.

A Roku holds only one sideloaded app. Installing Reel replaces whatever is in that slot, so keep the previous package if you want it back.

Reel remembers server and account labels, but sign-in tokens last only for the session, so you sign in again after the app restarts. Watch-history reporting starts off.

To update, upload the new ZIP. To remove Reel, use Delete in the same installer page.
