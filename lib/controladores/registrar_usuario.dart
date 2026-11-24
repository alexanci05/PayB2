import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/network/connection_status.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<String>? _installationId;

Future<String> _getInstallationId() async {
  final pending = _installationId ??= _loadInstallationId();
  try {
    return await pending;
  } catch (_) {
    if (identical(_installationId, pending)) _installationId = null;
    rethrow;
  }
}

Future<String> _loadInstallationId() async {
  final preferences = await SharedPreferences.getInstance();
  const key = 'notifications.installationId';
  final existing = preferences.getString(key);
  if (existing != null) return existing;

  final random = Random.secure();
  final id = List.generate(
    24,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
  ).join();
  if (!await preferences.setString(key, id)) {
    throw StateError('No se pudo guardar la identidad del dispositivo');
  }
  return id;
}

Future<String?> registerUserForNotifications() async {
  if (!await _isMessagingTokenReady()) return null;

  final token = await FirebaseMessaging.instance.getToken();
  if (token != null) {
    await IdentityMutationTracker.shared.track(() async {
      final user = FirebaseAuth.instance.currentUser;
      if (user != null) await _saveMessagingToken(token);
    });
  }
  return token;
}

Future<bool> _isMessagingTokenReady() async {
  if (kIsWeb ||
      (defaultTargetPlatform != TargetPlatform.iOS &&
          defaultTargetPlatform != TargetPlatform.macOS)) {
    return true;
  }

  for (var attempt = 0; attempt < 20; attempt += 1) {
    if (await FirebaseMessaging.instance.getAPNSToken() != null) return true;
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

Future<void> saveMessagingTokenForCurrentUser(String token) async {
  await IdentityMutationTracker.shared.track(() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user != null) await _saveMessagingToken(token);
  });
}

Future<void> removeCurrentDeviceMessagingToken() async {
  await IdentityMutationTracker.shared.track(() async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) {
      throw StateError('No hay una sesión para dar de baja el dispositivo');
    }
    final installationId = await _getInstallationId();
    // Firestore queues offline deletes; the timeout releases the identity lock.
    await FirebaseFirestore.instance
        .collection('usuarios')
        .doc(user.uid)
        .collection('devices')
        .doc(installationId)
        .delete()
        .timeout(const Duration(seconds: 10));
  });
}

Future<void> _saveMessagingToken(String token) async {
  final installationId = await _getInstallationId();
  await FirebaseFunctions.instance
      .httpsCallable('registrarDispositivo')
      .callObserved<void>({'installationId': installationId, 'fcmToken': token});
}
