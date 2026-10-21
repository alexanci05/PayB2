import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/groups/group_management.dart';
import 'package:payb2/services/network/connection_status.dart';

void main() {
  tearDown(() => ConnectionStatus.shared.dismissServiceError());

  test(
    'configuration sends both values and stays tracked until completion',
    () async {
      final functions = _Functions();
      final service = GroupManagement(functions: functions);
      for (final enabled in [true, false]) {
        final response = Completer<Object?>();
        functions.callable.respond = () => response.future;
        final operation = service.configureAdministration(
          groupId: 'trip',
          allMembersAreAdmins: enabled,
        );
        var idle = false;
        final waiting = IdentityMutationTracker.shared.waitUntilIdle().then((
          _,
        ) {
          idle = true;
        });
        await Future<void>.delayed(Duration.zero);
        expect(idle, isFalse);
        expect(functions.names.last, 'configurarAdministracionGrupo');
        expect(functions.callable.parameters.last, {
          'groupId': 'trip',
          'allMembersAreAdmins': enabled,
        });
        response.complete(null);
        await operation;
        await waiting;
        expect(idle, isTrue);
      }
    },
  );

  test(
    'member retry preserves its payload and observes failure and recovery',
    () async {
      final functions = _Functions();
      final service = GroupManagement(functions: functions);
      const requestId = '12345678901234567890';
      functions.callable.respond = () async {
        throw FirebaseFunctionsException(code: 'unavailable', message: 'Retry');
      };
      Future<String> submit() => service.addMember(
        groupId: 'trip',
        nombre: '  Ana  ',
        requestId: requestId,
      );
      await expectLater(submit(), throwsA(isA<FirebaseFunctionsException>()));
      expect(
        ConnectionStatus.shared.condition,
        ConnectionCondition.serviceError,
      );
      functions.callable.respond = () async => {'memberId': 'new-member'};
      expect(await submit(), 'new-member');
      expect(
        ConnectionStatus.shared.condition,
        isNot(ConnectionCondition.serviceError),
      );
      expect(functions.names, ['agregarMiembroGrupo', 'agregarMiembroGrupo']);
      expect(functions.callable.parameters, [
        {'groupId': 'trip', 'nombre': 'Ana', 'requestId': requestId},
        {'groupId': 'trip', 'nombre': 'Ana', 'requestId': requestId},
      ]);
    },
  );
}

class _Functions extends Fake implements FirebaseFunctions {
  final names = <String>[];
  final callable = _Callable();

  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) {
    names.add(name);
    return callable;
  }
}

class _Callable extends Fake implements HttpsCallable {
  final parameters = <dynamic>[];
  late Future<Object?> Function() respond;

  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async {
    this.parameters.add(parameters);
    return _Result<T>(await respond());
  }
}

class _Result<T> extends Fake implements HttpsCallableResult<T> {
  _Result(this.value);
  final Object? value;

  @override
  T get data => value as T;
}
