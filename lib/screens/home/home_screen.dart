import 'dart:async';

import 'package:flutter/material.dart';
import 'package:payb2/screens/account/account_access_sheet.dart';
import 'package:payb2/screens/home/main_screen.dart';
import 'package:payb2/services/notifications/notification_service.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  void _onCrearGrupo(BuildContext context) {
    Navigator.pushNamed(context, '/crearGrupo');
  }

  void _onUnirseGrupo(BuildContext context) {
    Navigator.pushNamed(context, '/unirseGrupo');
  }

  Future<void> _onIniciarSesion(BuildContext context) async {
    final result = await AccountAccessSheet.show(context);
    if (result == null || !context.mounted) return;

    unawaited(NotificationService.shared.refreshRegistration());
    Navigator.of(context).pushAndRemoveUntil(
      MaterialPageRoute(builder: (_) => const MainScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('PayB2'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.start,
          children: [
            const Text(
              '¡Bienvenido a PayB2!',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 40),
            ElevatedButton.icon(
              onPressed: () => _onCrearGrupo(context),
              icon: const Icon(Icons.group_add),
              label: const Text('Crear Grupo'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: () => _onUnirseGrupo(context),
              icon: const Icon(Icons.meeting_room),
              label: const Text('Unirse a Grupo'),
              style: ElevatedButton.styleFrom(
                minimumSize: const Size.fromHeight(50),
              ),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              onPressed: () => _onIniciarSesion(context),
              icon: const Icon(Icons.login),
              label: const Text('Iniciar sesión'),
            ),
          ],
        ),
      ),
    );
  }
}
