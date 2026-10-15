import 'dart:async';

import 'package:cloud_functions/cloud_functions.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/auth/account_auth_service.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'pending cancellation runs exclusively and failure preserves its ticket',
    () async {
      const pendingKey = 'pendingAccountMergeTicket';
      SharedPreferences.setMockInitialValues({pendingKey: 'original-ticket'});
      final auth = _Auth();
      final functions = _Functions();
      final service = AccountAuthService(auth: auth, functions: functions);
      final release = Completer<void>();
      final exclusive = IdentityMutationTracker.shared.runExclusively(
        () => release.future,
      );
      final signIn = service.signIn(AccountProvider.apple);
      final failure = expectLater(signIn, throwsA(isA<AccountAuthFailure>()));

      try {
        await Future<void>.delayed(Duration.zero);
        expect(auth.reads, 0);
        expect(functions.names, isEmpty);
      } finally {
        release.complete();
        await exclusive;
        await failure;
      }

      expect(auth.reads, 1);
      expect(functions.names, ['cancelarFusionCuenta']);
      expect(functions.cancellation.parameters, {
        'mergeTicket': 'original-ticket',
      });
      final preferences = await SharedPreferences.getInstance();
      expect(preferences.getString(pendingKey), 'original-ticket');
    },
  );
}

class _Auth implements FirebaseAuth {
  int reads = 0;

  @override
  User get currentUser {
    reads++;
    return _AnonymousUser();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _AnonymousUser implements User {
  @override
  bool get isAnonymous => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Functions implements FirebaseFunctions {
  final names = <String>[];
  final cancellation = _FailedCancellation();

  @override
  HttpsCallable httpsCallable(String name, {HttpsCallableOptions? options}) {
    names.add(name);
    return cancellation;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FailedCancellation implements HttpsCallable {
  dynamic parameters;

  @override
  Future<HttpsCallableResult<T>> call<T>([dynamic parameters]) async {
    this.parameters = parameters;
    throw FirebaseFunctionsException(code: 'unavailable', message: 'Retry');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
