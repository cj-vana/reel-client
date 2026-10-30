# iPhone, iPad and Apple TV

[Choose another platform](README.md)

You build the Apple apps yourself with Xcode 27.1 and run them on iOS or iPadOS 27 or tvOS 27. The repository includes no signing team, certificate or provisioning profile. Use your own Apple developer account and a bundle identifier you control, and keep both the same for every update.

Install [XcodeGen](https://github.com/yonaskolb/XcodeGen) first (`brew install xcodegen`).

## iPhone and iPad

1. In Xcode, add your Apple Account under Settings > Accounts.
2. From the repository root, run `cd apps/apple && xcodegen generate`, then open `Reel.xcodeproj`.
3. Select the Reel target, open Signing & Capabilities, and choose your team. Change the bundle identifier to one you control.
4. Connect your iPhone or iPad with a cable and tap Trust on the device. In Settings > Privacy & Security, turn on Developer Mode and restart when asked.
5. Choose your device as the run destination and press Run. If iOS blocks the launch, check Settings > General > VPN & Device Management and trust only your own developer profile.
6. Allow Local Network access if your Jellyfin server is on your home network.

A free Personal Team works for personal testing, but Apple expires those provisioning profiles after 7 days, so you have to rebuild and reinstall. A paid membership lasts longer. See Apple's guides to [running an app on a device](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html) and [enabling Developer Mode](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).

### From the command line

After signing is set up in Xcode, you can build and install without opening it. Replace the placeholders with your own values:

```sh
cd apps/apple
xcodegen generate
xcodebuild -project Reel.xcodeproj -scheme Reel -configuration Debug \
  -destination 'id=YOUR_DEVICE_ID' -derivedDataPath build-device \
  DEVELOPMENT_TEAM=YOUR_TEAM_ID PRODUCT_BUNDLE_IDENTIFIER=YOUR_BUNDLE_ID \
  CODE_SIGN_STYLE=Automatic -allowProvisioningUpdates build
xcrun devicectl device install app --device YOUR_DEVICE_ID \
  build-device/Build/Products/Debug-iphoneos/Reel.app
xcrun devicectl device process launch --device YOUR_DEVICE_ID YOUR_BUNDLE_ID
```

Find the device id with `xcrun devicectl list devices`. Do not run the UI tests on a device you use. They clear saved accounts.

## Apple TV

1. Put the Mac and Apple TV on the same network. On the Apple TV, open Settings > Remotes and Devices > Remote App and Devices.
2. In Xcode, open Window > Devices and Simulators, select the Apple TV, choose Pair, and enter the code shown on the TV. Apple TV has no separate Developer Mode switch.
3. Run `cd apps/tvos && xcodegen generate`, then open `ReelTV.xcodeproj`.
4. Select the ReelTV target, choose your team, and set a bundle identifier you control.
5. Choose the Apple TV as the destination and press Run. Use the Release configuration for a build that behaves like the finished app.

The command line works the same way as for iPhone, with scheme `ReelTV`, the `Debug-appletvos` products folder and `ReelTV.app`.

Debug builds use the bundle identifier `app.reelclient.tv.qa` and Release builds use `app.reelclient.tv`. Changing the identifier creates a separate app with separate saved data.

## Saved connections

Credentials live in the Keychain under your bundle identifier. If you replace an app that used a different credential namespace, set the `REEL_CREDENTIAL_NAMESPACE` build setting to the old value so the new build can still read it. Changing the namespace does not move or delete old data.

## Updating and removing

Install the new build over the old one with the same team and bundle identifier. Deleting first removes saved connections and downloads. Changing the team or identifier makes a second app or locks you out of old credentials. If a profile expires, reinstall from Xcode.

To remove Reel, sign out, then delete the app from the Home Screen (iPhone and iPad) or from the Apple TV Home screen. Deleting removes its local data and offline files. See Apple's instructions for [iPhone and iPad](https://support.apple.com/en-us/101550) and [Apple TV](https://support.apple.com/guide/tv/atvbaa1a9524/tvos).
