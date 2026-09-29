import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:payb2/providers/theme_provider.dart';
import 'package:payb2/screens/account/account_access_sheet.dart';
import 'package:payb2/services/notifications/notification_service.dart';
import 'package:provider/provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({this.onAccountRestored, super.key});

  final VoidCallback? onAccountRestored;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with WidgetsBindingObserver {
  bool _changingNotifications = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(NotificationService.shared.refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(NotificationService.shared.refreshStatus());
    }
  }

  Future<void> _openAccountAccess() async {
    final result = await AccountAccessSheet.show(context);
    if (result == null || !mounted) return;

    unawaited(NotificationService.shared.refreshRegistration());
    widget.onAccountRestored?.call();
  }

  Future<void> _setNotificationsEnabled(bool value) async {
    setState(() => _changingNotifications = true);
    bool enabled;
    try {
      enabled = await NotificationService.shared.setEnabled(value);
    } catch (error, stackTrace) {
      debugPrint(
        'No se pudo cambiar el estado de notificaciones: $error\n$stackTrace',
      );
      if (!mounted) return;
      setState(() => _changingNotifications = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No se pudo cambiar esta opción.')),
      );
      return;
    }

    if (!mounted) return;
    setState(() => _changingNotifications = false);
    if (value && !enabled) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'Activa las notificaciones en los ajustes del sistema.',
          ),
          action: SnackBarAction(
            label: 'Ajustes',
            onPressed: () {
              unawaited(openAppSettings());
            },
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final user = FirebaseAuth.instance.currentUser;
    final isAnonymous = user?.isAnonymous ?? true;
    final email = user?.email;

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 12),
      children: [
        ListTile(
          leading: Icon(
            isAnonymous ? Icons.person_outline : Icons.verified_user,
          ),
          title: Text(isAnonymous ? 'Sin iniciar sesión' : 'Sesión iniciada'),
          subtitle: Text(
            isAnonymous
                ? 'Inicia sesión para recuperar tus datos en otros dispositivos.'
                : email ?? 'Tus datos están vinculados a esta cuenta.',
          ),
        ),
        if (isAnonymous) ...[
          ListTile(
            leading: const Icon(Icons.login),
            title: const Text('Iniciar sesión'),
            trailing: const Icon(Icons.chevron_right),
            onTap: _openAccountAccess,
          ),
        ],
        const Divider(),
        ValueListenableBuilder<bool>(
          valueListenable: NotificationService.shared.enabled,
          builder: (context, enabled, _) {
            return SwitchListTile(
              secondary: const Icon(Icons.notifications_outlined),
              title: const Text('Notificaciones'),
              value: enabled,
              onChanged: _changingNotifications
                  ? null
                  : _setNotificationsEnabled,
            );
          },
        ),
        ListTile(
          leading: const Icon(Icons.brightness_6_outlined),
          title: const Text('Cambiar tema'),
          onTap: () {
            Provider.of<ThemeProvider>(context, listen: false).toggleTheme();
          },
        ),
      ],
    );
  }
}
