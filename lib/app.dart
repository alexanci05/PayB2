import 'dart:async';

import 'package:flutter/material.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:payb2/services/auth/account_auth_service.dart';
import 'package:payb2/services/firebase/initialize_firebase.dart';
import 'package:payb2/services/network/connection_status.dart';
import 'package:payb2/services/notifications/notification_service.dart';
import 'package:payb2/services/security/app_attestation.dart';
import 'package:payb2/widgets/connection_banner.dart';
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
  bool _starting = true;
  bool _restoring = false;
  bool _firebaseReady = false;
  Future<UserCredential>? _anonymousSignIn;

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
    if (state != AppLifecycleState.resumed || _starting || !_firebaseReady) {
      return;
    }

    unawaited(_restoreExternalState());
  }

  Future<void> _restoreExternalState({bool refreshNotifications = true}) async {
    if (_restoring) return;
    _restoring = true;
    try {
      await ConnectionStatus.shared.refreshNetwork();
      try {
        await AccountAuthService.shared.resumePendingMerge();
      } catch (error, stackTrace) {
        ConnectionStatus.shared.reportFailure(error);
        debugPrint(
          'No se pudo reanudar la fusión de cuenta: $error\n$stackTrace',
        );
      }

      if (refreshNotifications) {
        try {
          await NotificationService.shared.refreshRegistration();
        } catch (error, stackTrace) {
          debugPrint(
            'No se pudo actualizar el registro de notificaciones: '
            '$error\n$stackTrace',
          );
        }
      }
    } finally {
      _restoring = false;
    }
  }

  Future<Widget> _getInitialScreen() async {
    _starting = true;
    _firebaseReady = false;
    try {
      await initializeFirebase();
      _firebaseReady = true;
      await ConnectionStatus.shared.start();
      if (FirebaseAuth.instance.currentUser == null) {
        final request = _anonymousSignIn ??= runBackendRequest(
          () => FirebaseAuth.instance.signInAnonymously(),
        );
        unawaited(
          request.then<void>(
            (_) => _anonymousSignIn = null,
            onError: (Object error, StackTrace stackTrace) {
              _anonymousSignIn = null;
            },
          ),
        );
        await request.timeout(const Duration(seconds: 15));
      }
      await _restoreExternalState(refreshNotifications: false);
      unawaited(
        NotificationService.shared.initialize().catchError((
          Object error,
          StackTrace stackTrace,
        ) {
          debugPrint(
            'No se pudieron iniciar las notificaciones: $error\n$stackTrace',
          );
        }),
      );
      final prefs = await SharedPreferences.getInstance();
      final hasOpened = prefs.getBool('hasOpened') ?? false;

      if (!hasOpened) {
        await prefs.setBool('hasOpened', true);
        return const HomeScreen();
      } else {
        return const MainScreen();
      }
    } finally {
      _starting = false;
    }
  }

  void _retryStartup() {
    setState(() => _initialScreenFuture = _getInitialScreen());
  }

  Widget _withConnectionBanner(BuildContext context, Widget? child) {
    return ListenableBuilder(
      listenable: ConnectionStatus.shared,
      builder: (context, _) {
        final condition = ConnectionStatus.shared.condition;
        final showBanner = condition != ConnectionCondition.online;
        return Column(
          children: [
            if (showBanner) ConnectionBanner(condition: condition),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: showBanner,
                child: child ?? const SizedBox.shrink(),
              ),
            ),
          ],
        );
      },
    );
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
                return MaterialApp(
                  debugShowCheckedModeBanner: false,
                  builder: _withConnectionBanner,
                  home: const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  ),
                );
              }

              if (snapshot.hasError) {
                return MaterialApp(
                  debugShowCheckedModeBanner: false,
                  builder: _withConnectionBanner,
                  home: Scaffold(
                    body: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              snapshot.error is AppAttestationException
                                  ? 'No se pudo verificar la seguridad de la app. Comprueba la conexión e inténtalo de nuevo.'
                                  : 'No se pudo iniciar la sesión. Comprueba la conexión e inténtalo de nuevo.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 16),
                            FilledButton.icon(
                              onPressed: _retryStartup,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Reintentar'),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }

              return MaterialApp(
                title: 'PayB2',
                debugShowCheckedModeBanner: false,
                builder: _withConnectionBanner,
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
