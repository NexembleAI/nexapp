# Nexapp — Implementation Log (v1)

High-level log of the **client-side** (Flutter) implementation: what was built,
the important decisions, and a brief on *why*. Append new entries as work lands.

App: `com.nexemble.nexapp` ("Nexapp") — a fork of the Traccar Flutter client.
Location engine: **`traccar_client_sdk`** (Apache-2.0). Backend: NexCore + Traccar.

---

## Log

### Task 1a — Fork & rebrand  *(merged, PR #4)*
Forked the Traccar Flutter client to `com.nexemble.nexapp` / "Nexapp"; stripped
demo bits (QR scanner, log sharing, rate-my-app, Firebase analytics/crashlytics);
tuned fresh-install defaults for field sales; pointed at the Nexemble Traccar
endpoint.
- **Why:** reuse the battle-tested upstream client + `traccar_client_sdk` rather
  than rebuild background location; keep `firebase_core`/`firebase_messaging` for
  the Phase-3 push path.

### Loading screen + app icon  *(merged, PR #5)*
Added the Nexemble bouncing-cube launch animation and a new app icon.
- **Loading screen = trimmed (~3.5 s) faithful port of the "Nexemble Reveal"
  scene** (cube drops in, four decaying bounces with squash-and-stretch + a subtle
  3D wobble, settles, fades to the app). *Why:* honours the brand animation while
  staying app-launch-appropriate — the full ~10 s cinematic (reflections, wordmark
  wipe, sheen) is too long for a splash.
- **Treatment = blue cube on a light floor** (matching the source), with the
  Android/iOS native launch backgrounds matched so there is no white flash before
  Flutter draws.
- **App icon = cube-only spectrum mark**, regenerated for all Android densities and
  iOS sizes via `flutter_launcher_icons`. *Why:* the previous wordmark icon was
  squeezed/clipped at icon size (Task 1a review finding); a clean cube reads well.

### Keycloak SSO login  *(branch `feature/keycloak-login`)*
OIDC **Authorization Code + PKCE** sign-in via the system browser, an auth gate
(login when signed out, tracker when signed in), tokens in secure storage, and a
sign-out action. Verified end-to-end on Android (Custom Tabs) and iOS
(ASWebAuthenticationSession) against the local Keycloak. Runbook:
[`doc/EmulatorAuth.md`](doc/EmulatorAuth.md).
- **Library = `flutter_appauth`** (Custom Tabs on Android, ASWebAuthenticationSession
  on iOS). *Why:* the system-browser pattern mandated by RFC 8252 + Architecture
  §2.3.3 — secure (the app can't read credentials) and SSO-capable. Chosen over an
  embedded WebView, which would lose SSO and the credential-trust guarantee.
- **`NEX_CORE_URL` is the only deployment knob, injected via `--dart-define`,
  not exposed in the UI.** Issuer = `NEX_CORE_URL + /idp/realms/default`; client
  `mobile-app`; redirect `com.nexemble.nexapp:/callback` (one value works for both
  platforms); scopes `openid profile email`. *Why:* matches the validated POC;
  keeps environment config out of the user's hands.
- **Bundled the mkcert CA in Android `network_security_config`.** *Why:* the app's
  own HTTPS (OIDC discovery + token exchange) validates the self-signed Keycloak
  cert without any trust-all. iOS relies on the OS/simulator trust store.
- **Removed `android:taskAffinity=""` from MainActivity.** *Why:* it placed
  flutter_appauth's `RedirectUriReceiverActivity` in a *different* task from the
  activity holding the PKCE state, so the Keycloak redirect could not be matched
  ("No stored state - unable to handle response") and login never completed.
  Removing it keeps AppAuth's activities in the app's task. iOS is unaffected
  (ASWebAuthenticationSession is an in-app sheet).

### Removed inert Transistor config  *(2026-06-29)*
Deleted leftover `flutter_background_geolocation` (Transistor) license config:
`TSLocationManagerLicense` and the `com.transistorsoft.fetch`
`BGTaskSchedulerPermittedIdentifiers` from `ios/Runner/Info.plist`, and the
`com.transistorsoft.locationmanager.license` meta-data from `AndroidManifest.xml`.
- **Why:** verified `flutter_background_geolocation` is **not** a dependency — it's
  absent from the Dart dependency tree, from `traccar_client_sdk`'s own deps (which
  only needs `plugin_platform_interface`), from the iOS Swift Packages
  (`Package.resolved`), and from Android Gradle. The engine is `traccar_client_sdk`
  (Apache-2.0). These keys were read by nothing — inert and misleading, and there is
  **no paid licence to procure**.
- Left `ios/PrivacyInfo.xcprivacy` API-usage declarations intact (still valid for
  current dependencies; only stale comments referenced the old engine — removing the
  declarations could cause App Store rejection).

---

## Key decisions at a glance

| Decision | Why |
|---|---|
| Fork the upstream Traccar client; keep `traccar_client_sdk` | Reuse hardened background-location/offline-sync; Apache-2.0, no paid engine. |
| Bouncing-cube reveal, trimmed to ~3.5 s | Faithful brand animation, but launch-appropriate length. |
| Cube-only app icon | Wordmark was clipped at icon size. |
| `flutter_appauth` (system browser), not WebView | RFC 8252 / §2.3.3: secure + SSO; WebView loses both. |
| `NEX_CORE_URL` via `--dart-define`, hidden from UI | Environment config without exposing it to users. |
| Bundle mkcert CA (Android), OS trust (iOS) | Validate self-signed Keycloak cert without trust-all. |
| Remove `taskAffinity=""` from MainActivity | Kept AppAuth's redirect in the app's task → fixed "No stored state". |
| Remove Transistor license config | Engine is `traccar_client_sdk`; the keys were inert leftovers. |
