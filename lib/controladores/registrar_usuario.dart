import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> registerUserForNotifications() async {
  final prefs = await SharedPreferences.getInstance();
  final alreadyRegistered = prefs.getBool('userRegistered') ?? false;

  if (alreadyRegistered) return;

  final user = FirebaseAuth.instance.currentUser;
  if (user == null) {
    print("Usuario no autenticado.");
    return;
  }

  final deviceId = user.uid;
  final token = await FirebaseMessaging.instance.getToken();

  if (token == null) {
    print("Token de FCM no disponible.");
    return;
  }

  // Guardar usuario en Firestore
  final userDoc = FirebaseFirestore.instance.collection('usuarios').doc(deviceId);

  await userDoc.set({
    'deviceId': deviceId,
    'fcmToken': token,
    'createdAt': FieldValue.serverTimestamp(),
  });

  await prefs.setBool('userRegistered', true);
  print("Usuario registrado correctamente con token de notificación.");
}
