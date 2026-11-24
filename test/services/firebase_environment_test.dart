import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/firebase/firebase_environment.dart';

void main() {
  test('Android and iOS default to demo resources and local hosts', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      final environment = FirebaseEnvironment(platform: platform);
      expect(environment.usesEmulators, isTrue);
      expect(environment.options.projectId, 'demo-payb2');
      expect(environment.options.storageBucket, 'demo-payb2.appspot.com');
      expect(
        environment.emulatorHost,
        platform == TargetPlatform.android ? '10.0.2.2' : '127.0.0.1',
      );
    }
  });

  test(
    'production must be selected explicitly and cannot mix emulator settings',
    () {
      final environment = FirebaseEnvironment(
        name: 'production',
        platform: TargetPlatform.android,
      );
      expect(environment.usesEmulators, isFalse);
      expect(environment.options.projectId, 'payb2-5e89e');
      expect(
        () => FirebaseEnvironment(
          name: 'production',
          emulatorHost: '127.0.0.1',
          platform: TargetPlatform.iOS,
        ),
        throwsArgumentError,
      );
    },
  );

  test(
    'invalid environments or hosts fail instead of selecting production',
    () {
      expect(
        () =>
            FirebaseEnvironment(name: 'prod', platform: TargetPlatform.android),
        throwsArgumentError,
      );
      for (final host in [
        'http://localhost',
        'localhost:8080',
        'host/path',
        'a@host',
      ]) {
        expect(
          () => FirebaseEnvironment(
            emulatorHost: host,
            platform: TargetPlatform.android,
          ),
          throwsArgumentError,
        );
      }
      expect(
        FirebaseEnvironment(
          emulatorHost: '127.0.0.1',
          platform: TargetPlatform.android,
        ).emulatorHost,
        '127.0.0.1',
      );
    },
  );
}
