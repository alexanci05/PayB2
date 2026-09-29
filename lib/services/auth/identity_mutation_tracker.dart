import 'dart:async';

class IdentityMutationTracker {
  IdentityMutationTracker._();

  static final IdentityMutationTracker shared = IdentityMutationTracker._();

  int _pendingOperations = 0;
  Completer<void>? _idleCompleter;
  Future<void>? _exclusiveOperation;

  Future<T> track<T>(Future<T> Function() operation) async {
    final exclusiveOperation = _exclusiveOperation;
    if (exclusiveOperation != null) await exclusiveOperation;
    _pendingOperations++;
    _idleCompleter ??= Completer<void>();
    try {
      return await operation();
    } finally {
      _pendingOperations--;
      if (_pendingOperations == 0) {
        _idleCompleter?.complete();
        _idleCompleter = null;
      }
    }
  }

  Future<void> waitUntilIdle() async {
    final pending = _idleCompleter?.future;
    if (pending != null) await pending;
  }

  Future<T> runExclusively<T>(Future<T> Function() operation) async {
    while (_exclusiveOperation != null) {
      await _exclusiveOperation;
    }

    final completer = Completer<void>();
    _exclusiveOperation = completer.future;
    try {
      await waitUntilIdle();
      return await operation();
    } finally {
      _exclusiveOperation = null;
      completer.complete();
    }
  }
}
