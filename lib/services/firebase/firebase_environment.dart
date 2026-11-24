import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart';

import '../../firebase_options.dart';

class FirebaseEnvironment {
  FirebaseEnvironment({
    String name = 'emulator',
    String emulatorHost = '',
    required TargetPlatform platform,
  }) : usesEmulators = name == 'emulator',
       emulatorHost = emulatorHost.isEmpty
           ? (platform == TargetPlatform.android ? '10.0.2.2' : '127.0.0.1')
           : emulatorHost,
       _platform = platform {
    if (name != 'emulator' && name != 'production') {
      throw ArgumentError.value(name, 'FIREBASE_ENV');
    }
    if (platform != TargetPlatform.android && platform != TargetPlatform.iOS) {
      throw UnsupportedError('PayB2 only supports Android and iOS.');
    }
    final address = Uri.tryParse('http://${this.emulatorHost}');
    if (address == null ||
        address.host != this.emulatorHost ||
        address.hasPort ||
        address.userInfo.isNotEmpty ||
        address.path.isNotEmpty ||
        address.hasQuery ||
        address.hasFragment) {
      throw ArgumentError.value(emulatorHost, 'FIREBASE_EMULATOR_HOST');
    }
    if (!usesEmulators && emulatorHost.isNotEmpty) {
      throw ArgumentError('Production cannot use FIREBASE_EMULATOR_HOST.');
    }
  }

  static final current = kIsWeb
      ? throw UnsupportedError('PayB2 only supports Android and iOS.')
      : FirebaseEnvironment(
          name: const String.fromEnvironment(
            'FIREBASE_ENV',
            defaultValue: 'emulator',
          ),
          emulatorHost: const String.fromEnvironment('FIREBASE_EMULATOR_HOST'),
          platform: defaultTargetPlatform,
        );

  static const demoProjectId = 'demo-payb2';

  final bool usesEmulators;
  final String emulatorHost;
  final TargetPlatform _platform;

  FirebaseOptions get options {
    if (!usesEmulators) {
      return _platform == TargetPlatform.android
          ? DefaultFirebaseOptions.android
          : DefaultFirebaseOptions.ios;
    }
    final platform = _platform == TargetPlatform.android ? 'android' : 'ios';
    return FirebaseOptions(
      apiKey: 'AIzaSyAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      appId: '1:1234567890:$platform:0000000000000000000000',
      messagingSenderId: '1234567890',
      projectId: demoProjectId,
      storageBucket: '$demoProjectId.appspot.com',
      iosBundleId: _platform == TargetPlatform.iOS ? 'com.example.payb2' : null,
    );
  }
}
