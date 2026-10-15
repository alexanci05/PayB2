import 'dart:async';

import 'package:flutter/material.dart';
import 'package:payb2/services/auth/account_auth_service.dart';
import 'package:payb2/services/notifications/notification_service.dart';
import 'screens/home/home_screen.dart';
import 'screens/home/main_screen.dart';
import 'screens/crear_grupo/crear_grupo_screen.dart';
import 'screens/unirse_grupo/unirse_grupo_screen.dart';
import 'package:provider/provider.dart';
import 'providers/theme_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> with WidgetsBindingObserver {
  late Future<Widget> _initialScreenFuture;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initialScreenFuture = _getInitialScreen();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;

    unawaited(_restoreExternalState());
  }

  Future<void> _restoreExternalState() async {
    try {
      await AccountAuthService.shared.resumePendingMerge();
    } catch (error, stackTrace) {
      debugPrint(
        'No se pudo reanudar la fusión de cuenta: $error\n$stackTrace',
      );
    }

    try {
      await NotificationService.shared.refreshRegistration();
    } catch (error, stackTrace) {
      debugPrint(
        'No se pudo actualizar el registro de notificaciones: '
        '$error\n$stackTrace',
      );
    }
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
