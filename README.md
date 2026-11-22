# Nadia (iOS wrapper)

Small WKWebView app that plays an RPG Maker MV web game stored on the device.
The game files are NOT part of this repo or the IPA.

## Build
GitHub Actions (`.github/workflows/build.yml`) generates the Xcode project with XcodeGen,
builds without code signing and uploads `Nadia.ipa` as an artifact. Sign it with your own sideloading tool.

## Use
1. Install the signed app.
2. In the Files app open **On My iPhone > Nadia** and copy the game's `www` folder there
   (result: `Nadia/www/index.html`).
3. Open the app.

## Notes
- A local HTTP server on `127.0.0.1:38080` serves the files (Range requests supported for video/audio).
  The port is fixed so that saves in localStorage stay tied to the same origin.
- Use the game's own save slots often; localStorage can be lost if the app is deleted/reinstalled.
