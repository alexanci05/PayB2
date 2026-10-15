import 'package:flutter/material.dart';
import 'package:payb2/services/network/connection_status.dart';

class ConnectionBanner extends StatelessWidget {
  const ConnectionBanner({required this.condition, super.key});

  final ConnectionCondition condition;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final (icon, message) = switch (condition) {
      ConnectionCondition.offline => (
        Icons.wifi_off,
        'Sin conexión. Solo datos guardados; pueden estar desactualizados.',
      ),
      ConnectionCondition.cached => (
        Icons.cloud_off,
        'Sin sincronizar con el servidor. Los datos pueden estar desactualizados.',
      ),
      ConnectionCondition.serviceError => (
        Icons.cloud_off,
        'La última operación no pudo completarse. Los datos pueden estar desactualizados.',
      ),
      ConnectionCondition.checking => (
        Icons.sync,
        'Comprobando conexión y sincronizando datos…',
      ),
      ConnectionCondition.online => (Icons.cloud_done, ''),
    };
    if (condition == ConnectionCondition.online) return const SizedBox.shrink();

    return Material(
      color: colors.secondaryContainer,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Row(
            children: [
              Icon(icon, size: 20, color: colors.onSecondaryContainer),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(color: colors.onSecondaryContainer),
                ),
              ),
              if (condition == ConnectionCondition.serviceError)
                IconButton(
                  tooltip: 'Cerrar aviso',
                  onPressed: ConnectionStatus.shared.dismissServiceError,
                  icon: const Icon(Icons.close),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
