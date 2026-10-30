# Width and keyboard focus probe

A small XcodeGen project that compiles the shipping `Reel` sources into a blank iPad host. Two XCTest cases show the connect screen with the software keyboard open and resize the hosted container to check that the username field keeps focus. It is simulator only and is not part of CI.

## Run

You need Xcode 27.1 or later, XcodeGen and an iPad simulator on iOS 27 or later with the software keyboard enabled.

```sh
cd apps/apple/qa/layout-probe
xcrun simctl list devices available
export PROBE_SIMULATOR_UDID=YOUR_IPAD_SIMULATOR_UDID
xcodegen generate
xcodebuild test \
  -project ReelLayoutProbe.xcodeproj \
  -scheme ReelLayoutProbe \
  -destination "platform=iOS Simulator,id=$PROBE_SIMULATOR_UDID" \
  -derivedDataPath build \
  -only-testing:WidthFocusTests/WidthFocusTests \
  -parallel-testing-enabled NO \
  CODE_SIGN_IDENTITY=- CODE_SIGNING_ALLOWED=YES
```

The generated project and build output are git-ignored.
