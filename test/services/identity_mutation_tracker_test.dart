import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';

void main() {
  test('a mutation waits for every exclusive operation ahead of it', () async {
    final tracker = IdentityMutationTracker.shared;
    final releaseFirst = Completer<void>();
    final releaseSecond = Completer<void>();
    final first = tracker.runExclusively(() => releaseFirst.future);
    await Future<void>.delayed(Duration.zero);

    var secondStarted = false;
    final second = tracker.runExclusively(() async {
      secondStarted = true;
      await releaseSecond.future;
    });
    var mutationStarted = false;
    final mutation = tracker.track(() async => mutationStarted = true);

    releaseFirst.complete();
    await Future<void>.delayed(Duration.zero);
    final ranDuringSecond = mutationStarted;
    releaseSecond.complete();
    await Future.wait([first, second, mutation]);

    expect(secondStarted, isTrue);
    expect(ranDuringSecond, isFalse);
    expect(mutationStarted, isTrue);
  });

  test('restoration waits for pending membership operations', () async {
    final operation = Completer<void>();
    final tracked = IdentityMutationTracker.shared.track(
      () => operation.future,
    );

    var becameIdle = false;
    final idle = IdentityMutationTracker.shared.waitUntilIdle().then((_) {
      becameIdle = true;
    });
    await Future<void>.delayed(Duration.zero);

    expect(becameIdle, isFalse);

    operation.complete();
    await tracked;
    await idle;

    expect(becameIdle, isTrue);
  });

  test(
    'new mutations wait while an exclusive identity operation runs',
    () async {
      final releaseExclusive = Completer<void>();
      final exclusive = IdentityMutationTracker.shared.runExclusively(
        () => releaseExclusive.future,
      );
      await Future<void>.delayed(Duration.zero);

      var mutationStarted = false;
      final mutation = IdentityMutationTracker.shared.track(() async {
        mutationStarted = true;
      });
      await Future<void>.delayed(Duration.zero);
      expect(mutationStarted, isFalse);

      releaseExclusive.complete();
      await exclusive;
      await mutation;
      expect(mutationStarted, isTrue);
    },
  );
}
