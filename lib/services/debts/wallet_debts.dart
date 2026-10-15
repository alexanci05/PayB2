import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import 'debt_queries.dart';

/// Owns wallet listeners only; connectivity and bootstrap belong to the app.
class WalletDebts extends ChangeNotifier {
  WalletDebts({FirebaseFirestore? firestore, FirebaseAuth? auth})
    : _firestore = firestore ?? FirebaseFirestore.instance,
      _auth = auth ?? FirebaseAuth.instance {
    _queries = DebtQueries(firestore: _firestore);
    _authSubscription = _auth.authStateChanges().listen(
      (user) => _watchUser(user?.uid),
      onError: (Object error) {
        if (_disposed) return;
        _membershipError = error;
        _membershipReady = true;
        _initialLoading = false;
        notifyListeners();
      },
    );
  }

  final FirebaseFirestore _firestore;
  final FirebaseAuth _auth;
  late final DebtQueries _queries;
  late final StreamSubscription<User?> _authSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _memberships;
  final Map<String, WalletGroupDebts> _groups = {};
  String? _uid;
  int _generation = 0;
  bool _disposed = false;
  bool _membershipReady = false;
  Object? _membershipError;
  bool _initialLoading = true;

  Iterable<WalletGroupDebts> get groups => _groups.values;
  bool get isLoading => _initialLoading;
  Object? get error =>
      _membershipError ??
      _groups.values
          .map((group) => group.error)
          .whereType<Object>()
          .firstOrNull;

  void _watchUser(String? uid) {
    if (_disposed || (_membershipReady && uid == _uid)) return;
    final generation = ++_generation;
    _uid = uid;
    _memberships?.cancel();
    for (final group in _groups.values) {
      group.dispose();
    }
    _groups.clear();
    _membershipError = null;
    _membershipReady = uid == null;
    _initialLoading = uid != null;
    if (uid == null) {
      _membershipError = 'Usuario no autenticado';
      notifyListeners();
      return;
    }
    notifyListeners();
    _memberships = _firestore
        .collection('groupMembers')
        .where('deviceId', isEqualTo: uid)
        .snapshots()
        .listen(
          (snapshot) {
            if (_disposed || generation != _generation) return;
            var changed = !_membershipReady || _membershipError != null;
            _membershipReady = true;
            _membershipError = null;
            final groupIds = snapshot.docs
                .map((doc) => doc.data()['groupId'])
                .whereType<String>()
                .toSet();
            for (final id in _groups.keys.toList()) {
              if (!groupIds.contains(id)) {
                _groups.remove(id)!.dispose();
                changed = true;
              }
            }
            for (final id in groupIds) {
              if (_groups.containsKey(id)) continue;
              final group = WalletGroupDebts(id, uid, _firestore, _queries);
              _groups[id] = group;
              changed = true;
              group.addListener(_changed);
              group.start();
            }
            if (changed) _changed();
          },
          onError: (Object error) {
            if (_disposed || generation != _generation) return;
            _membershipError = error;
            _membershipReady = true;
            _initialLoading = false;
            notifyListeners();
          },
        );
  }

  void _changed() {
    if (_disposed) return;
    if (_membershipReady && _groups.values.every((group) => group.ready)) {
      _initialLoading = false;
    }
    // An error must be visible even if another initial listener is still waiting.
    if (error != null) _initialLoading = false;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _generation++;
    _authSubscription.cancel();
    _memberships?.cancel();
    for (final group in _groups.values) {
      group.dispose();
    }
    super.dispose();
  }
}

class WalletGroupDebts extends ChangeNotifier {
  WalletGroupDebts(this.id, this._uid, this._firestore, this._queries);

  final String id;
  final String _uid;
  final FirebaseFirestore _firestore;
  final DebtQueries _queries;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
  _groupSubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _membersSubscription;
  StreamSubscription<List<QueryDocumentSnapshot<Map<String, dynamic>>>>?
  _pendingSubscription;
  bool _disposed = false;
  int _pendingGeneration = 0;
  bool _groupReady = false;
  bool _membersReady = false;
  bool _pendingReady = false;
  bool _exists = true;
  Set<String> _memberIds = {};
  final Map<String, Object> _errors = {};
  String name = 'Grupo';
  Map<String, String> memberNames = {};
  List<QueryDocumentSnapshot<Map<String, dynamic>>> _pending = [];

  bool get ready => _groupReady && _membersReady && _pendingReady;
  Object? get error => _errors.values.firstOrNull;
  Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> get pending =>
      _exists ? _pending : const [];

  void start() {
    final group = _firestore.collection('groups').doc(id);
    _groupSubscription = group.snapshots().listen((snapshot) {
      if (_disposed) return;
      final nextName = snapshot.data()?['name'] as String? ?? 'Grupo';
      if (_groupReady &&
          name == nextName &&
          _exists == snapshot.exists &&
          !_errors.containsKey('group')) {
        return;
      }
      _groupReady = true;
      _errors.remove('group');
      _exists = snapshot.exists;
      name = nextName;
      notifyListeners();
    }, onError: (Object error) => _failed('group', error));
    _membersSubscription = group.collection('members').snapshots().listen((
      snapshot,
    ) {
      if (_disposed) return;
      final names = {
        for (final doc in snapshot.docs)
          doc.id: doc.data()['name'] as String? ?? '\u2014',
      };
      final ids = snapshot.docs
          .where((doc) => doc.data()['reclamadoPor'] == _uid)
          .map((doc) => doc.id)
          .toSet();
      final changed = !_membersReady || !setEquals(ids, _memberIds);
      if (!changed &&
          mapEquals(names, memberNames) &&
          !_errors.containsKey('members')) {
        return;
      }
      _errors.remove('members');
      memberNames = names;
      _membersReady = true;
      if (changed) _watchPending(ids);
      notifyListeners();
    }, onError: (Object error) => _failed('members', error));
  }

  void _watchPending(Set<String> ids) {
    final generation = ++_pendingGeneration;
    _pendingSubscription?.cancel();
    _memberIds = ids;
    // Keep matching rendered items while the replacement query initializes,
    // but never retain debts for identities that no longer belong to the user.
    _pending = _pending
        .where((doc) => ids.contains(doc.data()['memberId']))
        .toList();
    _errors.remove('pending');
    _pendingReady = ids.isEmpty;
    if (ids.isEmpty) return;
    _pendingSubscription = _queries
        .watchPendingForMembers(id, ids)
        .listen(
          (documents) {
            if (_disposed || generation != _pendingGeneration) return;
            _pending = documents;
            _pendingReady = true;
            // A healthy chunk cannot recover another chunk's terminal error.
            notifyListeners();
          },
          onError: (Object error) {
            if (_disposed || generation != _pendingGeneration) return;
            _failed('pending', error);
          },
        );
  }

  void _failed(String source, Object error) {
    if (_disposed) return;
    _errors[source] = error;
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _pendingGeneration++;
    _groupSubscription?.cancel();
    _membersSubscription?.cancel();
    _pendingSubscription?.cancel();
    super.dispose();
  }
}
