# Universal Links setup (SettleBro)

This document describes how HTTPS invites open the iOS app via **Associated Domains** + **Apple App Site Association (AASA)**.

## Current Runner bundle identifier

The Xcode **Runner** target uses:

**`app.settlebro.ios`**

If you change it, update `web/apple-app-site-association` (`appID` must be `TeamID.BundleID`) and `lib/firebase_options.dart` (`iosBundleId`), then re-upload the AASA file.

### Where to change the bundle ID

1. **Xcode:** Open `ios/Runner.xcworkspace` → select **Runner** target → **Signing & Capabilities** / **General** → **Bundle Identifier**.
2. **Project file:** `ios/Runner.xcodeproj/project.pbxproj` → search for `PRODUCT_BUNDLE_IDENTIFIER` on the **Runner** target (Debug / Release / Profile).

Keep **Signing** in sync with the same identifier in [Apple Developer](https://developer.apple.com/account/resources/identifiers/list). Register the iOS app in [Firebase Console](https://console.firebase.google.com) with the same bundle ID if you use `DefaultFirebaseOptions` for iOS.

For Universal Links, the App ID in the Developer portal must have the **Associated Domains** capability enabled (Identifiers → your App ID → Capabilities).

## Apple Team ID

Team ID used in the repo AASA template: **NVM9U68L88**.

AASA `appID` (Team ID + dot + bundle ID):

**`NVM9U68L88.app.settlebro.ios`**

## Host the AASA file on the domain

Apple loads Universal Links from your website (not from the app bundle).

1. Upload the project template **`web/apple-app-site-association`** to your web server so it is available at:

   **`https://settlebro.app/apple-app-site-association`**

2. **No `.json` extension** on the filename.

3. **HTTPS required.**

4. Serve with **`Content-Type: application/json`** (recommended). Avoid redirects on this URL.

5. After deployment, validate with Apple’s tools or by opening the URL in a browser (you should see the JSON).

## iOS app configuration (already in repo)

- **Associated Domains:** `applinks:settlebro.app` in `ios/Runner/Runner.entitlements`.
- **Entitlements in build settings:** `CODE_SIGN_ENTITLEMENTS = Runner/Runner.entitlements` (Runner Debug / Release / Profile in `project.pbxproj`).
- **Custom URL scheme:** `settlebro://` in `ios/Runner/Info.plist` (`CFBundleURLTypes`) for fallback links and `settlebro://join?...` deep links.

## Flutter deep links

The app uses **`app_links`** and parses:

- `https://settlebro.app/join?groupId=...&code=...`
- `settlebro://join?groupId=...&code=...`

See `parseJoinInviteUri` and `handleIncomingJoinLink` in `lib/main.dart`.

## Test link

After hosting AASA and installing a build signed with the matching bundle ID + team:

`https://settlebro.app/join?groupId=test&code=test`

Notes:

- Universal Links only trigger when opening the URL from another app (Mail, Messages, Safari in some cases). Testing from Notes or Messages is common.
- If the link opens in Safari instead of the app, check AASA hosting, bundle ID / team ID match, and reinstall the app after entitlement changes.
