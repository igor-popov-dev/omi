// Firebase options for the local_dev profile's Android build.
// `android` holds the real client config for the `omi-jarvis-igor` GCP
// project (Firebase console → Project settings → your Android app;
// non-secret by Firebase's own model, meant to ship inside the app binary).
// ios/macos/web are not registered in that project yet, so they keep the old
// `demo-omi-local` placeholders — fine as long as only Android builds this
// profile. See docs/point-app-to-mini.md.
// ignore_for_file: type=lint
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart' show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) return web;
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return macos;
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.fuchsia:
        throw UnsupportedError('Local Firebase options are not configured for this platform.');
    }
  }

  static const android = FirebaseOptions(
    apiKey: 'AIzaSyB8SMhtdyZhee6sz2UJY2wI78bHPdzaglk',
    appId: '1:1012069752426:android:b8f88f5d6c3b7ad463f413',
    messagingSenderId: '1012069752426',
    projectId: 'omi-jarvis-igor',
    storageBucket: 'omi-jarvis-igor.firebasestorage.app',
  );

  static const ios = FirebaseOptions(
    // Registered 2026-08-25 in the personal project omi-jarvis-igor (auth-only
    // Google dependency). Source of truth: ios/Config/Dev/GoogleService-Info.plist
    // (etalon in ~/.secrets/omi-app/); keep in sync.
    apiKey: 'AIzaSyBrliccXCDA0dJIdqYbnyRiZBlQaeZ5bBc',
    appId: '1:1012069752426:ios:8be44b183c42769163f413',
    messagingSenderId: '1012069752426',
    projectId: 'omi-jarvis-igor',
    storageBucket: 'omi-jarvis-igor.firebasestorage.app',
    iosBundleId: 'com.friend-app-with-wearable.ios12.development',
  );

  static const macos = FirebaseOptions(
    apiKey: 'AIzaSyDEMOOMILOCALFAKEKEY00000000000000',
    appId: '1:000000000000:ios:0000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'demo-omi-local',
    storageBucket: 'demo-omi-local.localhost',
    iosBundleId: 'com.friend-app-with-wearable.ios12.development',
  );

  static const web = FirebaseOptions(
    apiKey: 'AIzaSyDEMOOMILOCALFAKEKEY00000000000000',
    appId: '1:000000000000:web:0000000000000000',
    messagingSenderId: '000000000000',
    projectId: 'demo-omi-local',
    authDomain: 'demo-omi-local.firebaseapp.com',
    storageBucket: 'demo-omi-local.localhost',
  );
}
