# [Traccar Client app](https://www.traccar.org/client)

[![Get it on Google Play](http://www.tananaev.com/badges/google-play.svg)](https://play.google.com/store/apps/details?id=org.traccar.client) [![Download on the App Store](http://www.tananaev.com/badges/app-store.svg)](https://itunes.apple.com/app/traccar-client/id843156974)

> ## ⚠️ Fork Notice
>
> This repository (`NexembleAI/nexapp`) is a **fork of [`traccar/traccar-client`](https://github.com/traccar/traccar-client)** that has been **detached from the original parent**. It is now a standalone repository under the NexembleAI organization.
>
> **Pull requests** stay within `NexembleAI/nexapp` and do **not** target the upstream traccar repository.
>
> **Syncing with upstream:** because the fork relationship has been removed, there is no "Sync fork" button. To pull updates from the original project, add it as a remote and merge manually:
>
> ```bash
> # Add the original repository as an upstream remote (one-time setup)
> git remote add upstream https://github.com/traccar/traccar-client.git
>
> # Fetch and merge upstream changes
> git fetch upstream
> git merge upstream/main   # upstream's default branch
> ```

## Building & Running (Nexapp)

The Android build has **product flavors** (`dev` / `prod`) so each environment ships its
own Firebase config (`android/app/src/{dev,prod}/google-services.json`). Because a flavored
Android project has no default flavor, **`flutter run` must be given a `--flavor`** — a plain
`flutter run` fails with *"Gradle build failed to produce an .apk file"*.

```bash
flutter pub get

# Android — a flavor is REQUIRED
flutter run --flavor dev      # nexemble-tracker-dev Firebase
flutter run --flavor prod     # nexemble-tracker-prod Firebase

# iOS — schemes handle the environment; no --flavor needed
flutter run
```

VS Code users can pick **nexapp (dev)** / **nexapp (prod)** from the Run panel
(`.vscode/launch.json`) instead of passing the flag by hand.

> If a stale unflavored `app-debug.apk` exists from before the flavor migration, `flutter run`
> may silently install *that* instead of your build. Run `flutter clean` once if the app on the
> device doesn't reflect your latest code.

## Overview

Traccar Client is a GPS tracking app for Android and iOS. It runs in the background and sends location updates to your own server using the open-source Traccar platform.

- **Real-time Tracking**: See your device’s location on your private server in real time.
- **Open-Source**: 100% free and open-source, with no ads or tracking.
- **Customizable**: Configure update intervals, accuracy, and data usage to fit your needs.
- **Privacy First**: Your location data is sent only to your chosen server—never to third parties.
- **Easy Integration**: Designed to work seamlessly with the Traccar server and many third-party GPS tracking platforms.

Just enter your server address, grant location permissions, and the app will automatically send periodic location reports in the background.

## Team

- Anton Tananaev ([anton@traccar.org](mailto:anton@traccar.org))

## License

    Apache License, Version 2.0

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
