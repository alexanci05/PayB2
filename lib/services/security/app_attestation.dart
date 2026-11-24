import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:flutter/foundation.dart';

Future<void> activateAppAttestation({FirebaseAppCheck? appCheck}) async {
  // This app only supports attestation on its Android and iOS targets.
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.android &&
          defaultTargetPlatform != TargetPlatform.iOS)) {
    debugPrint('App Check skipped: only Android and iOS are supported.');
    return;
  }

  try {
    final attestation = appCheck ?? FirebaseAppCheck.instance;
    await attestation.activate(
      androidProvider: kDebugMode
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
      appleProvider: kDebugMode
          ? AppleProvider.debug
          : AppleProvider.appAttestWithDeviceCheckFallback,
    );
    final token = await attestation.getToken().timeout(
      const Duration(seconds: 15),
    );
    if (token == null || token.isEmpty) {
      throw StateError('App Check did not issue a token.');
    }
  } catch (error, stackTrace) {
    Error.throwWithStackTrace(AppAttestationException(error), stackTrace);
  }
}

class AppAttestationException implements Exception {
  const AppAttestationException(this.cause);

  final Object cause;

  @override
  String toString() => 'App Check activation failed: $cause';
}
