import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:payb2/services/auth/account_auth_service.dart';

class AccountAccessResult {
  const AccountAccessResult({required this.user});

  final User user;
}

class AccountAccessSheet extends StatefulWidget {
  const AccountAccessSheet({this.authService, super.key});

  final AccountAuthService? authService;

  static Future<AccountAccessResult?> show(
    BuildContext context, {
    AccountAuthService? authService,
  }) {
    return showModalBottomSheet<AccountAccessResult>(
      context: context,
      isScrollControlled: true,
      isDismissible: false,
      enableDrag: false,
      showDragHandle: true,
      builder: (_) => AccountAccessSheet(authService: authService),
    );
  }

  @override
  State<AccountAccessSheet> createState() => _AccountAccessSheetState();
}

class _AccountAccessSheetState extends State<AccountAccessSheet> {
  AccountProvider? _activeProvider;
  String? _error;

  AccountAuthService get _authService =>
      widget.authService ?? AccountAuthService.shared;

  bool get _supportsApple =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;

  Future<void> _submit(AccountProvider provider) async {
    setState(() {
      _activeProvider = provider;
      _error = null;
    });

    try {
      final user = await _authService.signIn(provider);
      if (!mounted) return;
      Navigator.pop(context, AccountAccessResult(user: user));
    } on AccountAuthFailure catch (error) {
      if (!mounted) return;
      if (error.wasCanceled) {
        Navigator.pop(context);
        return;
      }
      setState(() {
        _activeProvider = null;
        _error = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _activeProvider = null;
        _error = 'No se pudo completar la operación. Inténtalo de nuevo.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _activeProvider == null,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            4,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      'Iniciar sesión',
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    onPressed: _activeProvider == null
                        ? () => Navigator.pop(context)
                        : null,
                    tooltip: 'Cerrar',
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Accede a tu cuenta sin perder los grupos de esta sesión.',
              ),
              const SizedBox(height: 24),
              _ProviderButton(
                label: 'Continuar con Google',
                icon: Icons.g_mobiledata,
                busy: _activeProvider == AccountProvider.google,
                enabled: _activeProvider == null,
                onPressed: () => _submit(AccountProvider.google),
              ),
              if (_supportsApple) ...[
                const SizedBox(height: 12),
                _ProviderButton(
                  label: 'Continuar con Apple',
                  icon: Icons.apple,
                  busy: _activeProvider == AccountProvider.apple,
                  enabled: _activeProvider == null,
                  onPressed: () => _submit(AccountProvider.apple),
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProviderButton extends StatelessWidget {
  const _ProviderButton({
    required this.label,
    required this.icon,
    required this.busy,
    required this.enabled,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final bool busy;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.icon(
      onPressed: enabled ? onPressed : null,
      icon: SizedBox.square(
        dimension: 24,
        child: busy
            ? const Padding(
                padding: EdgeInsets.all(3),
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(icon),
      ),
      label: Text(label),
      style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
    );
  }
}
