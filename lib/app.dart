import 'package:flutter/material.dart';
import 'screens/home/home_screen.dart';
import 'screens/home/main_screen.dart';
import 'screens/crear_grupo/crear_grupo_screen.dart';
import 'screens/unirse_grupo/unirse_grupo_screen.dart';
import 'package:provider/provider.dart';
import 'providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'main.dart'; // para usar flutterLocalNotificationsPlugin
import 'package:flutter_local_notifications/flutter_local_notifications.dart';


class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  late Future<Widget> _initialScreenFuture;

  @override
  void initState() {
    super.initState();
    _initialScreenFuture = _getInitialScreen();
    _initFirebaseAndMessaging(); // <- importante
  }

  Future<void> _initFirebaseAndMessaging() async {
    FirebaseMessaging.onMessage.listen((RemoteMessage message) {
      final notification = message.notification;
      final android = notification?.android;

      if (notification != null && android != null) {
        flutterLocalNotificationsPlugin.show(
          notification.hashCode,
          notification.title,
          notification.body,
          NotificationDetails(
            android: AndroidNotificationDetails(
              'canal_notificaciones', // ID del canal
              'Notificaciones',        // Nombre visible
              importance: Importance.max,
              priority: Priority.high,
            ),
          ),
        );
      }
    });
  }

  Future<Widget> _getInitialScreen() async {
    final prefs = await SharedPreferences.getInstance();
    final hasOpened = prefs.getBool('hasOpened') ?? false;

    if (!hasOpened) {
      await prefs.setBool('hasOpened', true);
      return const HomeScreen();
    } else {
      return const MainScreen();
    }
  }

  @override
  Widget build(BuildContext context) {
    return ChangeNotifierProvider(
      create: (_) => ThemeProvider(),
      child: Consumer<ThemeProvider>(
        builder: (context, themeProvider, _) {
          return FutureBuilder<Widget>(
            future: _initialScreenFuture,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const MaterialApp(
                  home: Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  ),
                );
              }

              return MaterialApp(
                title: 'PayB2',
                debugShowCheckedModeBanner: false,
                theme: ThemeData(primarySwatch: Colors.indigo),
                darkTheme: ThemeData.dark(),
                themeMode: themeProvider.isDarkMode
                    ? ThemeMode.dark
                    : ThemeMode.light,
                home: snapshot.data!,
                routes: {
                  '/crearGrupo': (context) => const CrearGrupoScreen(),
                  '/unirseGrupo': (context) => const UnirseGrupoScreen(),
                },
              );
            },
          );
        },
      ),
    );
  }
}
