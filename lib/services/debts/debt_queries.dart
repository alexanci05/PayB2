import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

class DebtQueries {
  DebtQueries({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  static const _whereInLimit = 30;

  final FirebaseFirestore _firestore;

  Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  watchPendingForMembers(String groupId, Iterable<String> memberIds) {
    final ids = memberIds.toSet().toList()..sort();
    if (ids.isEmpty) return Stream.value([]);

    final subscriptions =
        <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    final chunks = <int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
    final chunkCount = (ids.length / _whereInLimit).ceil();
    var cancelled = false;
    late StreamController<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
    controller;
    controller = StreamController(
      onListen: () {
        for (var offset = 0; offset < ids.length; offset += _whereInLimit) {
          final index = offset ~/ _whereInLimit;
          final end = offset + _whereInLimit < ids.length
              ? offset + _whereInLimit
              : ids.length;
          subscriptions.add(
            _firestore
                .collectionGroup('divisiones')
                .where('groupId', isEqualTo: groupId)
                .where('pagado', isEqualTo: false)
                .where('memberId', whereIn: ids.sublist(offset, end))
                .snapshots()
                .listen(
                  (snapshot) {
                    if (cancelled) return;
                    chunks[index] = snapshot.docs;
                    // Do not temporarily drop debts from slower chunks.
                    if (chunks.length != chunkCount) return;
                    controller.add([
                      for (var i = 0; i < chunkCount; i++) ...chunks[i]!,
                    ]);
                  },
                  onError: (Object error, StackTrace stack) {
                    if (!cancelled) controller.addError(error, stack);
                  },
                ),
          );
        }
      },
      onPause: () {
        for (final subscription in subscriptions) {
          subscription.pause();
        }
      },
      onResume: () {
        for (final subscription in subscriptions) {
          subscription.resume();
        }
      },
      onCancel: () async {
        cancelled = true;
        await Future.wait(
          subscriptions.map((subscription) => subscription.cancel()),
        );
      },
    );
    return controller.stream;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchGroupDivisions(
    String groupId,
  ) {
    return _firestore
        .collectionGroup('divisiones')
        .where('groupId', isEqualTo: groupId)
        .snapshots();
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  loadPendingForMembers(String groupId, Iterable<String> memberIds) async {
    final ids = memberIds.toSet().toList()..sort();
    if (ids.isEmpty) return [];

    final queries = <Future<QuerySnapshot<Map<String, dynamic>>>>[];
    for (var offset = 0; offset < ids.length; offset += _whereInLimit) {
      final end = offset + _whereInLimit < ids.length
          ? offset + _whereInLimit
          : ids.length;
      queries.add(
        _firestore
            .collectionGroup('divisiones')
            .where('groupId', isEqualTo: groupId)
            .where('pagado', isEqualTo: false)
            .where('memberId', whereIn: ids.sublist(offset, end))
            .get(),
      );
    }

    final snapshots = await Future.wait(queries);
    return snapshots.expand((snapshot) => snapshot.docs).toList();
  }
}
