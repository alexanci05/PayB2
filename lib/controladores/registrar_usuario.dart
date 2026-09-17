import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';

Future<void> registerUserForNotifications() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  final token = await FirebaseMessaging.instance.getToken();
  if (token != null) await _saveMessagingToken(user.uid, token);

  FirebaseMessaging.instance.onTokenRefresh.listen((newToken) async {
    try {
      await _saveMessagingToken(user.uid, newToken);
    } catch (error, stackTrace) {
      debugPrint('No se pudo renovar el token FCM: $error\n$stackTrace');
    }
  });
}

Future<void> _saveMessagingToken(String uid, String token) async {
  final userDoc = FirebaseFirestore.instance.collection('usuarios').doc(uid);

  await userDoc.set({
    'deviceId': uid,
    'fcmToken': token,
    'tokenUpdatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}
