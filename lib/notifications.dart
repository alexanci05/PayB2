import 'package:flutter_local_notifications/flutter_local_notifications.dart';

final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

Future<void> mostrarNotificacion({
  required String titulo,
  required String cuerpo,
}) async {
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'canal_principal',
    'Notificaciones',
    channelDescription: 'Notificaciones de prueba para deudas pagadas',
    importance: Importance.max,
    priority: Priority.high,
  );

  const NotificationDetails generalNotificationDetails = NotificationDetails(
    android: androidDetails,
  );

  await flutterLocalNotificationsPlugin.show(
    0, // ID de la notificación
    titulo,
    cuerpo,
    generalNotificationDetails,
  );
}
