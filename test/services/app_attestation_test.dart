import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/security/app_attestation.dart';

void main() {
  tearDown(() => debugDefaultTargetPlatformOverride = null);

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    test('$platform selects the build-appropriate providers', () async {
      debugDefaultTargetPlatformOverride = platform;
      final appCheck = _AppCheck();

      await activateAppAttestation(appCheck: appCheck);

      expect(appCheck.calls, 1);
      expect(
        appCheck.androidProvider,
        kDebugMode ? AndroidProvider.debug : AndroidProvider.playIntegrity,
      );
      expect(
        appCheck.appleProvider,
        kDebugMode
            ? AppleProvider.debug
            : AppleProvider.appAttestWithDeviceCheckFallback,
      );
    });
  }

  for (final platform in [
    TargetPlatform.linux,
    TargetPlatform.macOS,
    TargetPlatform.windows,
    TargetPlatform.fuchsia,
  ]) {
    test('$platform skips without accessing Firebase', () async {
      debugDefaultTargetPlatformOverride = platform;

      await activateAppAttestation();
    });
  }

  test('activation failure propagates and a later attempt can retry', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final failure = FirebaseException(
      plugin: 'firebase_app_check',
      code: 'unavailable',
    );
    final appCheck = _AppCheck()..failure = failure;

    await expectLater(
      activateAppAttestation(appCheck: appCheck),
      throwsA(
        isA<AppAttestationException>().having(
          (error) => error.cause,
          'cause',
          same(failure),
        ),
      ),
    );

    appCheck.failure = null;
    await activateAppAttestation(appCheck: appCheck);
    expect(appCheck.calls, 2);
  });

  test(
    'missing token stops startup even if provider activation succeeds',
    () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      for (final token in [null, '']) {
        await expectLater(
          activateAppAttestation(appCheck: _AppCheck()..token = token),
          throwsA(isA<AppAttestationException>()),
        );
      }
    },
  );
}

class _AppCheck implements FirebaseAppCheck {
  int calls = 0;
  AndroidProvider? androidProvider;
  AppleProvider? appleProvider;
  Object? failure;
  String? token = 'test-attestation-token';

  @override
  Future<String?> getToken([bool? forceRefresh]) async => token;

  @override
  Future<void> activate({
    Object? webProvider,
    AndroidProvider androidProvider = AndroidProvider.playIntegrity,
    AppleProvider appleProvider = AppleProvider.deviceCheck,
  }) async {
    calls++;
    this.androidProvider = androidProvider;
    this.appleProvider = appleProvider;
    if (failure != null) throw failure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
