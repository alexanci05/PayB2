import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';

Future<String?> registerUserForNotifications() async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return null;

  final token = await FirebaseMessaging.instance.getToken();
  if (token != null) await _saveMessagingToken(user.uid, token);
  return token;
}

Future<void> saveMessagingTokenForCurrentUser(String token) async {
  final user = FirebaseAuth.instance.currentUser;
  if (user == null) return;

  await _saveMessagingToken(user.uid, token);
}

Future<void> removeCurrentDeviceMessagingToken() async {
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
}

Future<void> _saveMessagingToken(String uid, String token) async {
  final userDoc = FirebaseFirestore.instance.collection('usuarios').doc(uid);

  await userDoc.set({
    'deviceId': uid,
    'fcmToken': token,
    'tokenUpdatedAt': FieldValue.serverTimestamp(),
  }, SetOptions(merge: true));
}

Future<void> _removeMessagingTokenIfMatches(String uid, String token) async {
  final userDoc = FirebaseFirestore.instance.collection('usuarios').doc(uid);

  await FirebaseFirestore.instance.runTransaction((transaction) async {
    final snapshot = await transaction.get(userDoc);
    if (!snapshot.exists || snapshot.data()?['fcmToken'] != token) return;

    // A shared user document can be updated by another device after ours.
    transaction.update(userDoc, {
      'fcmToken': FieldValue.delete(),
      'tokenUpdatedAt': FieldValue.serverTimestamp(),
    });
  });
}
