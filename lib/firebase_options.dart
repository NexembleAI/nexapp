// Hand-maintained (originally FlutterFire CLI output), kept in sync with the
// native config files — the runtime source of truth is google-services.json /
// GoogleService-Info.plist (main() initializes Firebase without options):
//   Android: android/app/src/{dev,prod}/google-services.json (per flavor)
//   iOS:     ios/Runner/Firebase/{dev,prod}/GoogleService-Info.plist
//            (copied per scheme by the "Copy Firebase config" build phase)
// The environment here follows NEX_ENV (AuthConfig.isDev), pairing with
// --flavor dev/prod. Projects: nexemble-tracker-dev / nexemble-tracker-prod.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

import 'auth_config.dart';

/// Default [FirebaseOptions] for use with your Firebase apps.
///
/// Example:
/// ```dart
/// import 'firebase_options.dart';
/// // ...
/// await Firebase.initializeApp(
///   options: DefaultFirebaseOptions.currentPlatform,
/// );
/// ```
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      throw UnsupportedError(
        'DefaultFirebaseOptions have not been configured for web - '
        'you can reconfigure this by running the FlutterFire CLI again.',
      );
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for macos - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.windows:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for windows - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      case TargetPlatform.linux:
        throw UnsupportedError(
          'DefaultFirebaseOptions have not been configured for linux - '
          'you can reconfigure this by running the FlutterFire CLI again.',
        );
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static FirebaseOptions get android =>
      AuthConfig.isDev ? _androidDev : _androidProd;

  static FirebaseOptions get ios => AuthConfig.isDev ? _iosDev : _iosProd;

  static const FirebaseOptions _androidDev = FirebaseOptions(
    apiKey: 'AIzaSyB6YP4U_pm0XuE0a3YFUCP_54KmbZfREGY',
    appId: '1:112537386830:android:45f3a05881f37f95bde81f',
    messagingSenderId: '112537386830',
    projectId: 'nexemble-tracker-dev',
    storageBucket: 'nexemble-tracker-dev.firebasestorage.app',
  );

  static const FirebaseOptions _androidProd = FirebaseOptions(
    apiKey: 'AIzaSyAd07828vKfDUM0FgN8SsIUN0GEvdULmh8',
    appId: '1:579083644973:android:0b87e5c61a32d2d142c8a4',
    messagingSenderId: '579083644973',
    projectId: 'nexemble-tracker-prod',
    storageBucket: 'nexemble-tracker-prod.firebasestorage.app',
  );

  static const FirebaseOptions _iosDev = FirebaseOptions(
    apiKey: 'AIzaSyAWeejWJ1mOq5qZe3JeXwTiAJBEskbfybw',
    appId: '1:112537386830:ios:decd056aa4a6f1e9bde81f',
    messagingSenderId: '112537386830',
    projectId: 'nexemble-tracker-dev',
    storageBucket: 'nexemble-tracker-dev.firebasestorage.app',
    iosBundleId: 'com.nexemble.nexapp',
  );

  static const FirebaseOptions _iosProd = FirebaseOptions(
    apiKey: 'AIzaSyB7aUE2NZD-7kzKTC4kiJ30dp-cxunRJdk',
    appId: '1:579083644973:ios:a3c69eeee2d188d142c8a4',
    messagingSenderId: '579083644973',
    projectId: 'nexemble-tracker-prod',
    storageBucket: 'nexemble-tracker-prod.firebasestorage.app',
    iosBundleId: 'com.nexemble.nexapp',
  );
}
