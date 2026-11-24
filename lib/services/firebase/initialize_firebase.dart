import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

import '../security/app_attestation.dart';
import 'firebase_environment.dart';

Future<void>? _initialization;
bool _emulatorsConfigured = false;

Future<void> initializeFirebase() async {
  final initialization = _initialization ??= _initialize();
  try {
    await initialization;
  } catch (_) {
    if (identical(_initialization, initialization)) _initialization = null;
    rethrow;
  }
}

Future<void> _initialize() async {
  final environment = FirebaseEnvironment.current;
  final options = environment.options;
  final app = await Firebase.initializeApp(options: options);
  if (app.options.projectId != options.projectId ||
      app.options.appId != options.appId ||
      app.options.apiKey != options.apiKey) {
    throw StateError('Native and Dart Firebase environments do not match.');
  }

  if (environment.usesEmulators) {
    // The persisted FCM preference takes precedence over native build defaults.
    await FirebaseMessaging.instance.setAutoInitEnabled(false);
    if (!_emulatorsConfigured) {
      // All clients must be routed before authentication or any data request.
      await FirebaseAuth.instance.useAuthEmulator(
        environment.emulatorHost,
        9099,
        automaticHostMapping: false,
      );
      FirebaseFirestore.instance.useFirestoreEmulator(
        environment.emulatorHost,
        8080,
        automaticHostMapping: false,
      );
      FirebaseFunctions.instance.useFunctionsEmulator(
        environment.emulatorHost,
        5001,
        automaticHostMapping: false,
      );
      _emulatorsConfigured = true;
    }
  } else {
    await activateAppAttestation();
  }
}
