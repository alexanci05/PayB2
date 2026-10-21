import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/auth/account_auth_service.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
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

  test(
    'recovered merge removes a registration restored after opt-out',
    () async {
      SharedPreferences.setMockInitialValues({
        'pendingAccountMergeTicket': 'ticket',
        'notifications.enabled': true,
      });
      final devices = <String>{'other-device'};
      final autoInit = <bool>[];
      final reconciled = Completer<void>();
      var mergeAttempts = 0;
      var removals = 0;
      final notifications = NotificationService.forTesting(
        setAutoInitEnabled: (enabled) async => autoInit.add(enabled),
        removeRegistration: () =>
            IdentityMutationTracker.shared.track(() async {
              removals++;
              devices.remove('this-device');
              if (mergeAttempts == 2) reconciled.complete();
            }),
      );
      final service = AccountAuthService(
        auth: _TargetAuth(),
        functions: _MergeFunctions(() async {
          if (++mergeAttempts == 1) {
            throw FirebaseFunctionsException(
              code: 'unavailable',
              message: 'Retry',
            );
          }
          devices.add('this-device');
        }),
        notifications: notifications,
      );

      await expectLater(
        service.resumePendingMerge(),
        throwsA(isA<FirebaseFunctionsException>()),
      );
      await notifications.setEnabled(false);
      await Future<void>.delayed(Duration.zero);
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getBool('notifications.removalPending'), isFalse);
      expect(preferences.getString('pendingAccountMergeTicket'), 'ticket');
      expect(removals, 1);

      await service.resumePendingMerge();
      await reconciled.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(mergeAttempts, 2);
      expect(removals, 2);
      expect(devices, {'other-device'});
      expect(autoInit, [false, false]);
      expect(notifications.isEnabled, isFalse);
      expect(preferences.getBool('notifications.enabled'), isFalse);
      expect(preferences.getString('pendingAccountMergeTicket'), isNull);
      expect(
        preferences.getInt('notifications.removalAcknowledgedRevision'),
        preferences.getInt('notifications.registrationRevision'),
      );
    },
  );

  test(
    'restart reconciles an already committed merge with a stale ack',
    () async {
      SharedPreferences.setMockInitialValues({
        'pendingAccountMergeTicket': 'committed-ticket',
        'notifications.enabled': false,
        'notifications.removalPending': false,
        'notifications.registrationRevision': 4,
        'notifications.removalAcknowledgedRevision': 4,
      });
      final preferences = await SharedPreferences.getInstance();
      final devices = <String>{'this-device', 'other-device'};
      final removed = Completer<void>();
      final notifications = NotificationService.forTesting(
        setAutoInitEnabled: (enabled) async => expect(enabled, isFalse),
        removeRegistration: () =>
            IdentityMutationTracker.shared.track(() async {
              devices.remove('this-device');
              removed.complete();
            }),
      );
      final service = AccountAuthService(
        auth: _TargetAuth(),
        functions: _MergeFunctions(() async {
          // The server's idempotent retry does not transfer devices again.
          expect(preferences.getInt('notifications.registrationRevision'), 5);
          expect(
            preferences.getInt('notifications.removalAcknowledgedRevision'),
            4,
          );
        }),
        notifications: notifications,
      );

      await service.resumePendingMerge();
      await removed.future.timeout(const Duration(seconds: 1));
      await Future<void>.delayed(Duration.zero);

      expect(devices, {'other-device'});
      expect(preferences.getBool('notifications.enabled'), isFalse);
      expect(preferences.getString('pendingAccountMergeTicket'), isNull);
      expect(preferences.getInt('notifications.registrationRevision'), 6);
      expect(
        preferences.getInt('notifications.removalAcknowledgedRevision'),
        6,
      );
    },
  );

  test('late removal ack cannot consume a merge invalidation', () async {
    SharedPreferences.setMockInitialValues({'notifications.enabled': true});
    final preferences = await SharedPreferences.getInstance();
    final oldAcknowledgement = Completer<void>();
    final reconciled = Completer<void>();
    var removals = 0;
    final notifications = NotificationService.forTesting(
      setAutoInitEnabled: (_) async {},
      removeRegistration: () async {
        if (++removals == 1) {
          await oldAcknowledgement.future;
        } else {
          expect(preferences.getBool('notifications.removalPending'), isFalse);
          expect(
            preferences.getInt('notifications.removalAcknowledgedRevision'),
            isNot(preferences.getInt('notifications.registrationRevision')),
          );
          reconciled.complete();
        }
      },
    );
    await notifications.setEnabled(false);
    await Future<void>.delayed(Duration.zero);
    expect(removals, 1);

    await notifications.reconcileAccountMerge(() async {});
    oldAcknowledgement.complete();
    await reconciled.future.timeout(const Duration(seconds: 1));
    await Future<void>.delayed(Duration.zero);

    expect(removals, 2);
    expect(preferences.getBool('notifications.enabled'), isFalse);
    expect(
      preferences.getInt('notifications.removalAcknowledgedRevision'),
      preferences.getInt('notifications.registrationRevision'),
    );
  });
}

class _TargetAuth implements FirebaseAuth {
  @override
  User get currentUser => _TargetUser();

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _TargetUser implements User {
  @override
  bool get isAnonymous => false;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MergeFunctions implements FirebaseFunctions {
  _MergeFunctions(this.merge);

  final Future<void> Function() merge;

  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) {
    expect(name, 'fusionarCuentaAnonima');
    return _MergeCallable(merge);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MergeCallable implements HttpsCallable {
  _MergeCallable(this.merge);

  final Future<void> Function() merge;

  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async {
    await merge();
    return _MergeResult<T>();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _MergeResult<T> implements HttpsCallableResult<T> {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
