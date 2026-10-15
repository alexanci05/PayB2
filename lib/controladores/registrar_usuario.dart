import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
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
      if (user != null) await _saveMessagingToken(user.uid, token);
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
    if (user != null) await _saveMessagingToken(user.uid, token);
  });
}

Future<void> removeCurrentDeviceMessagingToken() async {
  await IdentityMutationTracker.shared.track(() async {
    final user = FirebaseAuth.instance.currentUser;
    String? token;

    try {
      token = await FirebaseMessaging.instance.getToken();
      if (user != null && token != null) {
        await _removeMessagingTokenIfMatches(user.uid, token);
      }
    } finally {
      await FirebaseMessaging.instance.deleteToken();
    }
  });
}

Future<void> _saveMessagingToken(String uid, String token) async {
  final userDoc = FirebaseFirestore.instance.collection('usuarios').doc(uid);
  final installationId = await _getInstallationId();
  await FirebaseFirestore.instance.runTransaction((transaction) async {
    final user = await transaction.get(userDoc);
    transaction.set(userDoc.collection('devices').doc(installationId), {
      'fcmToken': token,
      'tokenUpdatedAt': FieldValue.serverTimestamp(),
    });
    if (user.data()?['fcmToken'] == token) {
      transaction.update(userDoc, {'fcmToken': FieldValue.delete()});
    }
  });
}

Future<void> _removeMessagingTokenIfMatches(String uid, String token) async {
  final userDoc = FirebaseFirestore.instance.collection('usuarios').doc(uid);
  final installationId = await _getInstallationId();
  final deviceDoc = userDoc.collection('devices').doc(installationId);

  await FirebaseFirestore.instance.runTransaction((transaction) async {
    final snapshot = await transaction.get(userDoc);
    final device = await transaction.get(deviceDoc);
    if (device.data()?['fcmToken'] == token) transaction.delete(deviceDoc);
    if (snapshot.data()?['fcmToken'] == token) {
      transaction.update(userDoc, {'fcmToken': FieldValue.delete()});
    }
  });
}
