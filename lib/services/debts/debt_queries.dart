import 'package:cloud_firestore/cloud_firestore.dart';

class DebtQueries {
  DebtQueries({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  static const _whereInLimit = 30;

  final FirebaseFirestore _firestore;

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
