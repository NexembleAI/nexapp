# Emulator Authentication — Keycloak OIDC

How to run Nexapp on a local emulator/simulator and complete a **real**
Keycloak login (OIDC Authorization Code + PKCE through the system browser).

The login uses [`flutter_appauth`](https://pub.dev/packages/flutter_appauth):
**Chrome Custom Tabs** on Android, **ASWebAuthenticationSession** on iOS.

---

## Configuration (already in source)

OIDC settings live in [`lib/auth_config.dart`](../lib/auth_config.dart). Only
`NEX_CORE_URL` is a deployment knob and it is **not exposed in the UI** —
inject it at build time, otherwise it defaults to the local environment.

| Setting | Value |
|---|---|
| `NEX_CORE_URL` | `https://app.nexemble.local` (override: `--dart-define=NEX_CORE_URL=https://...`) |
| Issuer | `NEX_CORE_URL` + `/idp/realms/default` |
| Client | `mobile-app` (public, Standard flow, **PKCE S256**) |
| Redirect URI | `com.nexemble.nexapp:/callback` |
| Scopes | `openid profile email` |

**Keycloak client** (`default` realm → Clients → `mobile-app`): Client
authentication **OFF**, Standard flow **ON**, Advanced → PKCE **S256**, and
**Valid redirect URIs** must include `com.nexemble.nexapp:/callback` (the same
value works for both platforms).

Keycloak in the local environment is served over HTTPS with a self-signed
**mkcert** CA (`nexcore/docker/ca/rootCA.pem`). The app already trusts it for
its own HTTPS calls (discovery + token exchange) via
[`android/app/src/main/res/xml/network_security_config.xml`](../android/app/src/main/res/xml/network_security_config.xml)
+ the bundled `res/raw/nexemble_ca.pem`. The emulator/simulator browser needs
the CA trusted separately (below).

> Replace `192.168.1.224` below with the host running the NexCore reverse
> proxy / Keycloak on your LAN.

---

## Android (emulator)

The Android emulator is a separate network namespace and does **not** read the
host's `/etc/hosts`, so the hostname and the browser CA trust must be set up
inside it. These steps persist across reboots (overlay/`/data`) but may need
re-applying after a cold boot or wipe.

```bash
export ANDROID_HOME="$HOME/Library/Android/sdk"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
AVD=Pixel_API36          # any google_apis (rootable) image; >= 3-4 GB RAM
CA=../nexcore/docker/ca/rootCA.pem   # path to the mkcert root CA
```

### 1. Boot with a writable system and enough RAM

`-writable-system` is required to edit `/system/etc/hosts`. Give it **≥ 3–4 GB**
RAM — on a 2 GB image the backgrounded auth activity gets reaped during sign-in
and you'll see `No stored state - unable to handle response`.

```bash
"$ANDROID_HOME/emulator/emulator" -avd "$AVD" -writable-system -memory 4096 -no-snapshot &
adb wait-for-device
adb shell 'while [[ -z $(getprop sys.boot_completed) ]]; do sleep 1; done'
```

### 2. Resolve the Keycloak host → the LAN host

```bash
adb root && adb remount
adb shell 'grep -q app.nexemble.local /system/etc/hosts || \
  echo "192.168.1.224 app.nexemble.local traccar.nexemble.local" >> /system/etc/hosts'
adb shell 'ping -c1 app.nexemble.local'   # should resolve to 192.168.1.224
```

### 3. Trust the mkcert CA in the browser (Chrome user store)

The Custom Tab is Chrome; it must trust the CA or the Keycloak page shows a
certificate warning. Chrome honours user-installed CAs.

```bash
HASH=$(openssl x509 -subject_hash_old -noout -in "$CA")          # e.g. 7ae65fad
{ cat "$CA"; openssl x509 -in "$CA" -text -fingerprint -noout; } > "/tmp/$HASH.0"
adb push "/tmp/$HASH.0" /data/local/tmp/
adb shell "mkdir -p /data/misc/user/0/cacerts-added && \
  cp /data/local/tmp/$HASH.0 /data/misc/user/0/cacerts-added/$HASH.0 && \
  chmod 644 /data/misc/user/0/cacerts-added/$HASH.0 && \
  chown system:system /data/misc/user/0/cacerts-added/$HASH.0 && \
  chcon u:object_r:system_security_cacerts_file:s0 /data/misc/user/0/cacerts-added/$HASH.0"
```

> The CA in the **user** store may not survive a cold boot — re-run step 3 if
> the login page shows a cert warning. (The *app's* own CA trust is bundled and
> always present.)

### 4. Build, install, run

```bash
flutter build apk --debug
adb install -r build/app/outputs/flutter-apk/app-debug.apk
adb shell am start -n com.nexemble.nexapp/com.nexemble.nexapp.MainActivity
# or simply:  flutter run -d emulator-5554
```

### 5. Sign in

Tap **Sign in** → the Custom Tab opens the Keycloak page on `app.nexemble.local`
(no cert warning) → enter credentials → Keycloak redirects to
`com.nexemble.nexapp:/callback` → the app exchanges the code for tokens and the
auth gate swaps to the tracker.

> First run only: Chrome may show a "Welcome to Chrome" screen — tap **Use
> without an account** once.

---

## iOS (simulator)

The iOS simulator shares the **Mac's** network stack and `/etc/hosts`, so the
hostname resolves natively (ensure `192.168.1.224 app.nexemble.local` is in the
Mac's `/etc/hosts`). `ASWebAuthenticationSession` is an in-app sheet, so there
is no task/redirect quirk to work around — the only setup is trusting the CA.

```bash
UDID=$(xcrun simctl list devices booted | grep -oE '[0-9A-F-]{36}' | head -1)
xcrun simctl boot "$UDID" 2>/dev/null; open -a Simulator
xcrun simctl keychain "$UDID" add-root-cert ../nexcore/docker/ca/rootCA.pem
flutter run -d "$UDID"
```

Then tap **Sign in** → **Continue** on the system sign-in prompt → enter
credentials → it returns to the app signed in.

---

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `No stored state - unable to handle response` (Android), stuck on login | The launching activity must not pin a custom `taskAffinity` (it sends AppAuth's redirect to a different task). Already fixed in `AndroidManifest.xml`. Also give the emulator ≥ 3–4 GB RAM so the backgrounded auth activity isn't reaped during sign-in. |
| Cert warning on the Keycloak page (Android) | Re-run **step 3** (CA in Chrome's user store) — it can be lost on a cold boot. |
| Cert error on token exchange / discovery | The app's CA trust is the bundled `res/raw/nexemble_ca.pem` (Android) / the simulator root cert (iOS). Re-add for iOS via `simctl keychain add-root-cert`. |
| Custom Tab never opens after tapping Sign in | OIDC discovery failed (host unreachable or cert). Verify `app.nexemble.local` resolves and Keycloak is up: `curl --cacert <CA> https://app.nexemble.local/idp/realms/default/.well-known/openid-configuration`. |
| Browser opens to a different/old server | Override the core URL: `flutter run --dart-define=NEX_CORE_URL=https://...`. |

---

*Adapted from the team runbook `EmulatorAuthSetup.md`; the emulator-side hosts
and CA steps are local test conveniences — on a real device/CI the CA arrives
via MDM / a proper trust chain.*
