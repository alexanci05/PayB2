import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../network/connection_status.dart';

/// Owns only the current user's memberships and one listener per group.
class GroupsList extends ChangeNotifier {
  GroupsList({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    ConnectionStatus? connection,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _connection = connection ?? ConnectionStatus.shared {
    _lastCondition = _connection.condition;
    _connection.addListener(_onConnectionChanged);
    _auth = (auth ?? FirebaseAuth.instance)
        .authStateChanges()
        .map((user) => user?.uid)
        .distinct()
        .listen(
          _watchUser,
          onError: (Object error) {
            if (_disposed) return;
            _authError = error;
            _changed();
          },
        );
  }

  final FirebaseFirestore _firestore;
  final ConnectionStatus _connection;
  late final StreamSubscription<String?> _auth;
  late ConnectionCondition _lastCondition;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _memberships;
  final Map<String, _GroupWatch> _groups = {};
  String? _uid;
  int _membershipGeneration = 0;
  bool _disposed = false;
  bool _membershipReady = false;
  bool _isLoading = true;
  Object? _authError;
  Object? _membershipError;

  bool get isLoading => _isLoading;
  Object? get error =>
      _authError ??
      _membershipError ??
      _groups.values
          .map((group) => group.error)
          .whereType<Object>()
          .firstOrNull;
  List<DocumentSnapshot<Map<String, dynamic>>> get groups => _groups.values
      .map((group) => group.document)
      .whereType<DocumentSnapshot<Map<String, dynamic>>>()
      .toList(growable: false);

  void _watchUser(String? uid) {
    if (_disposed) return;
    _membershipGeneration++;
    unawaited(_memberships?.cancel());
    _memberships = null;
    for (final group in _groups.values) {
      group.dispose();
    }
    _groups.clear();
    _uid = uid;
    _authError = uid == null ? 'Usuario no autenticado' : null;
    _membershipError = null;
    _membershipReady = uid == null;
    _isLoading = uid != null;
    _changed();
    if (uid != null) _watchMemberships(uid);
  }

  void _onConnectionChanged() {
    final condition = _connection.condition;
    final reconnected =
        condition == ConnectionCondition.online &&
        _lastCondition != ConnectionCondition.online;
    _lastCondition = condition;
    if (reconnected) refresh();
  }

  /// Restart the query and failed/missing documents, keeping healthy listeners.
  void refresh() {
    if (_disposed) return;
    final uid = _uid;
    if (uid == null) return;
    for (final group in _groups.values) {
      if (group.error != null || group.document == null) {
        _watchGroup(group);
      }
    }
    _watchMemberships(uid);
  }

  void _watchMemberships(String uid) {
    final generation = ++_membershipGeneration;
    unawaited(_memberships?.cancel());
    _memberships = _firestore
        .collection('groupMembers')
        .where('deviceId', isEqualTo: uid)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            if (_disposed || generation != _membershipGeneration) return;
            _membershipReady = true;
            _membershipError = null;
            final ids = snapshot.docs
                .map((doc) => doc.data()['groupId'])
                .whereType<String>()
                .where((id) => id.isNotEmpty && !id.contains('/'))
                .toSet();
            // A cache-only query may be incomplete after a restart. Only a
            // server result or a local pending write can remove visible groups.
            if (snapshot.metadata.isFromCache &&
                !snapshot.metadata.hasPendingWrites) {
              ids.addAll(_groups.keys);
            }
            for (final id in _groups.keys.toList()) {
              if (!ids.contains(id)) _groups.remove(id)!.dispose();
            }
            for (final id in ids) {
              if (_groups.containsKey(id)) continue;
              final group = _GroupWatch(id);
              _groups[id] = group;
              _watchGroup(group);
            }
            _changed();
          },
          onError: (Object error) {
            if (_disposed || generation != _membershipGeneration) return;
            _membershipError = error;
            _changed();
          },
        );
  }

  void _watchGroup(_GroupWatch group) {
    final generation = ++group.generation;
    unawaited(group.subscription?.cancel());
    bool isCurrent() =>
        !_disposed &&
        identical(_groups[group.id], group) &&
        generation == group.generation;
    group.subscription = _firestore
        .collection('groups')
        .doc(group.id)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (snapshot) {
            if (!isCurrent()) return;
            group.ready = true;
            group.error = null;
            // A missing cached document is not proof of a server deletion.
            if (snapshot.data() != null) {
              group.document = snapshot;
            } else if (!snapshot.metadata.isFromCache ||
                snapshot.metadata.hasPendingWrites) {
              group.document = null;
            }
            _changed();
          },
          onError: (Object error) {
            if (!isCurrent()) return;
            group.error = error;
            _changed();
          },
        );
  }

  void _changed() {
    if (_disposed) return;
    if (error != null ||
        (_membershipReady && _groups.values.every((group) => group.ready))) {
      _isLoading = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _membershipGeneration++;
    _connection.removeListener(_onConnectionChanged);
    unawaited(_auth.cancel());
    unawaited(_memberships?.cancel());
    for (final group in _groups.values) {
      group.dispose();
    }
    super.dispose();
  }
}

class _GroupWatch {
  _GroupWatch(this.id);

  final String id;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? subscription;
  DocumentSnapshot<Map<String, dynamic>>? document;
  int generation = 0;
  bool ready = false;
  Object? error;

  void dispose() {
    generation++;
    unawaited(subscription?.cancel());
  }
}
