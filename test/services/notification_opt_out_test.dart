import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/notifications/notification_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('opting out works offline and retries an unconfirmed removal', () async {
    SharedPreferences.setMockInitialValues({'notifications.enabled': true});
    final firstRemoval = Completer<void>();
    var attempts = 0;
    final autoInit = <bool>[];
    final service = NotificationService.forTesting(
      setAutoInitEnabled: (enabled) async => autoInit.add(enabled),
      removeRegistration: () async {
        attempts++;
        if (attempts == 1) await firstRemoval.future;
      },
    );

    expect(await service.setEnabled(false), isTrue);
    await Future<void>.delayed(Duration.zero);
    final preferences = await SharedPreferences.getInstance();
    expect(service.isEnabled, isFalse);
    expect(preferences.getBool('notifications.enabled'), isFalse);
    expect(preferences.getBool('notifications.removalPending'), isTrue);

    firstRemoval.completeError(StateError('Offline'));
    await Future<void>.delayed(Duration.zero);
    expect(preferences.getBool('notifications.removalPending'), isTrue);

    await service.setEnabled(false);
    await Future<void>.delayed(Duration.zero);
    expect(attempts, 2);
    expect(autoInit, [false, false]);
    expect(preferences.getBool('notifications.removalPending'), isFalse);
  });
}
