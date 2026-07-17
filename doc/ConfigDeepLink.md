# Config deep link (support / debug escape hatch)

The Settings screen exposes only **Location accuracy**, **Minimum distance** and
**Update interval** — the three knobs in the design. The remaining tracking
prefs inherited from the Traccar client lost their UI in the Settings rewrite.

**They are still applied.** `Preferences.buildConfig()` still reads every one of
them, so removing the UI froze them at their stored/default values — it did not
disable them. The config deep link is the supported way to change them on a
device without a rebuild.

## Format

```
org.traccar.client://<host>?<key>=<value>&<key>=<value>
```

- The scheme is **`org.traccar.client`** — registered on Android
  (`AndroidManifest.xml`, MainActivity intent-filter) and iOS
  (`Info.plist` → `CFBundleURLSchemes`).
- **Not** `com.nexemble.nexapp` — that scheme is the OIDC redirect
  (`appAuthRedirectScheme`), consumed by flutter_appauth's redirect receiver.
  It never reaches the app's link handler.
- Host `action` is **reserved** for `org.traccar.client://action/start` and
  `org.traccar.client://action/stop`. Use any other host (e.g. `config`).
- An `http(s)://` URI is a special case: it sets the server `url` from the
  URI's origin + path.

Opening the link prompts for confirmation, then pushes the new values straight
to the SDK via `setConfig` — it takes effect live, no restart.

## Parameters

Keys are the `Preferences` key strings. Booleans must be exactly `true` or
`false`; anything else is ignored.

| Key | Type | Notes |
|---|---|---|
| `id` | string | Device identifier — also the Traccar `uniqueId` and the OsmAnd `id` used to post positions. Changing it re-identifies the device. |
| `url` | string | Traccar OsmAnd ingest endpoint. Normally seeded from the build-time `NEX_TRACCAR_URL`. |
| `accuracy` | `highest` \| `high` \| `medium` \| `low` | Settings shows only 3 (High/Balanced/Battery saver → highest/high/medium). `low` is reachable only here. |
| `distance` | int (metres) | Settings offers 10/25/50/100. |
| `interval` | int (seconds) | Settings offers 10/30/60/300, and only when accuracy is High. |
| `angle` | int (degrees) | No UI. Default 0. |
| `heartbeat` | int (seconds) | Stationary heartbeat. No UI. Default 0. |
| `buffer` | bool | Offline buffering. No UI. Default true. |
| `wakelock` | bool | No UI. Default false. |
| `stop_detection` | bool | No UI. Default true. |
| `prefer_platform_providers` | bool | Use system location providers instead of Google Play Services. **The emulator-debug lever.** Default false. |

`password` is **not** settable here — see the note below.

## Examples

Use the system location provider (emulator debugging):

```
org.traccar.client://config?prefer_platform_providers=true
```

Disable offline buffering and stop detection:

```
org.traccar.client://config?buffer=false&stop_detection=false
```

Point the device at a different Traccar endpoint:

```
org.traccar.client://config?url=https://traccar.example.com:5055
```

### Opening the link

- **Android:** `adb shell am start -a android.intent.action.VIEW -d "org.traccar.client://config?prefer_platform_providers=true"`
- **iOS simulator:** `xcrun simctl openurl booted "org.traccar.client://config?prefer_platform_providers=true"`
- **On a device:** send the link to the user (e.g. in a note/email) and have
  them tap it, then confirm the dialog.

## Note on `password`

The old settings-password gate was dropped in the rewrite. `password` is **not**
handled by the config deep link, and `PasswordService.authenticate()` is no
longer called from anywhere — so the pref can't be set and isn't read. The only
remaining writer is a server push command that clears it. Treat the pref and
`PasswordService` as dead pending cleanup.
