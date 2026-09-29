import 'dart:async';

import 'package:flutter/material.dart';
import 'app.dart';
import 'package:firebase_core/firebase_core.dart';
import 'firebase_options.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'services/auth/account_auth_service.dart';
import 'services/notifications/notification_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);

  await signAnonymus();
  try {
    await AccountAuthService.shared.resumePendingMerge();
  } catch (error, stackTrace) {
    debugPrint('No se pudo reanudar la fusión de cuenta: $error\n$stackTrace');
  }

  runApp(MyApp());

  unawaited(
    NotificationService.shared.initialize().catchError((
      Object error,
      StackTrace stackTrace,
    ) {
      debugPrint(
        'No se pudieron inicializar las notificaciones: $error\n$stackTrace',
      );
    }),
  );
}

// Para login anónimo
Future<void> signAnonymus() async {
  final auth = FirebaseAuth.instance;

  if (auth.currentUser == null) {
    await auth.signInAnonymously();
  }
}
