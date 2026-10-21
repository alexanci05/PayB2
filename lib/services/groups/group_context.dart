import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

class GroupContext extends ChangeNotifier {
  GroupContext(this.groupId, this.uid, {FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final String groupId;
  final String uid;
  final FirebaseFirestore _firestore;
  final List<StreamSubscription<dynamic>> _subscriptions = [];
  final Map<String, Object> _errors = {};
  final Set<String> _ready = {};
  Map<String, dynamic>? _group;
  Map<String, dynamic>? _membership;
  Map<String, Map<String, dynamic>> _members = {};
  int _generation = 0;
  bool _disposed = false;

  bool get ready => _ready.length == 3;
  bool get exists => _group != null;
  Object? get error => _errors.values.firstOrNull;
  String? get name => _group?['name'] as String?;
  Map<String, Map<String, dynamic>> get members => _members;
  bool get isAdmin =>
      _group?['ownerDeviceId'] == uid ||
      (_membership != null && _group?['allMembersAreAdmins'] == true);

  List<String> get myMemberIds {
    final ids =
        _members.entries
            .where((entry) => entry.value['reclamadoPor'] == uid)
            .map((entry) => entry.key)
            .toList()
          ..sort();
    final primary = _membership?['memberId'] as String?;
    if (primary != null && ids.remove(primary)) ids.insert(0, primary);
    return ids;
  }

  void start() {
    if (_disposed) return;
    _generation++;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
    final ref = _firestore.collection('groups').doc(groupId);
    _listen('group', ref.snapshots(), (snapshot) {
      if (snapshot.exists || !snapshot.metadata.isFromCache) {
        _group = snapshot.data();
      }
    });
    _listen('members', ref.collection('members').snapshots(), (snapshot) {
      _members = {for (final doc in snapshot.docs) doc.id: doc.data()};
    });
    _listen(
      'membership',
      _firestore.collection('groupMembers').doc('${groupId}_$uid').snapshots(),
      (snapshot) {
        if (snapshot.exists || !snapshot.metadata.isFromCache) {
          _membership = snapshot.data();
        }
      },
    );
  }

  void _listen<T>(String source, Stream<T> stream, void Function(T) update) {
    final generation = _generation;
    _subscriptions.add(
      stream.listen(
        (snapshot) {
          if (_disposed || generation != _generation) return;
          update(snapshot);
          _ready.add(source);
          _errors.remove(source);
          notifyListeners();
        },
        onError: (Object error) {
          if (_disposed || generation != _generation) return;
          _errors[source] = error;
          notifyListeners();
        },
      ),
    );
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    super.dispose();
  }
}
