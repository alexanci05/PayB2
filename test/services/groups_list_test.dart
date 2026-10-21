// SDK interfaces are implemented only by isolated test doubles.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/groups/groups_list.dart';
import 'package:payb2/services/network/connection_status.dart';

typedef _Data = Map<String, dynamic>;

void main() {
  late _Harness h;
  setUp(() => h = _Harness());
  tearDown(() => h.dispose());

  test('cached empty recovers without replacing group listeners', () async {
    await h.user('user');
    h.members.add(_Snapshot(false, cached: true));
    expect(h.list.groups, isEmpty);
    h.connection.updateCacheState(false);
    expect(h.membershipListens, 2);
    h.members.add(_Snapshot(true));
    h.group.add(_Document('Trip'));
    expect(h.name, 'Trip');
    h.members.add(_Snapshot(true));
    h.group.add(_Document('Renamed'));
    h.connection.updateCacheState(false);
    expect(h.name, 'Renamed');
    expect(h.groupListens, 1);
    expect(h.membershipListens, 2);
  });

  test('error and retry retain visible groups until a server result', () async {
    await h.user('user');
    h.members.add(_Snapshot(true));
    h.group.add(_Document('Trip'));
    h.members.addError(StateError('Unavailable'));
    expect(h.list.error, isNotNull);
    expect(h.name, 'Trip');
    h.list.refresh();
    h.members.add(_Snapshot(false, cached: true));
    expect(h.name, 'Trip');
    expect(h.list.isLoading, isFalse);
    expect(h.groupListens, 1);
    h.members.add(_Snapshot(false));
    expect(h.list.groups, isEmpty);
    expect(h.list.error, isNull);
    expect(h.group.hasListener, isFalse);
  });

  test('UID switch and disposal cancel old subscriptions', () async {
    await h.user('first');
    h.members.add(_Snapshot(true));
    h.group.add(_Document('Private'));
    await h.user('second');
    expect(h.uids, ['first', 'second']);
    expect(h.list.groups, isEmpty);
    expect(h.group.hasListener, isFalse);
    h.group.add(_Document('Stale'));
    expect(h.list.groups, isEmpty);
    h.members.add(_Snapshot(true));
    h.group.add(_Document('Second'));
    var notifications = 0;
    h.list.addListener(() => notifications++);
    h.stop();
    expect([
      h.auth.hasListener,
      h.members.hasListener,
      h.group.hasListener,
    ], everyElement(isFalse));
    h.connection.updateCacheState(false);
    h.group.add(_Document('Late'));
    expect(notifications, 0);
    expect(h.name, 'Second');
  });
}

class _Harness {
  _Harness() {
    list = GroupsList(
      firestore: _Store(this),
      auth: _Auth(auth.stream),
      connection: connection,
    );
  }
  final auth = StreamController<User?>.broadcast(sync: true);
  final members = StreamController<QuerySnapshot<_Data>>.broadcast(sync: true);
  final group = StreamController<DocumentSnapshot<_Data>>.broadcast(sync: true);
  final connection = ConnectionStatus();
  final uids = <Object?>[];
  late final GroupsList list;
  int membershipListens = 0, groupListens = 0;
  bool stopped = false;
  String? get name => list.groups.single.data()?['name'] as String?;
  Future<void> user(String uid) async {
    auth.add(_User(uid));
    await Future<void>.delayed(Duration.zero);
  }

  void stop() {
    if (stopped) return;
    stopped = true;
    list.dispose();
  }

  Future<void> dispose() async {
    stop();
    connection.dispose();
    await Future.wait([auth.close(), members.close(), group.close()]);
  }
}

// Fake rejects unexpected methods, including .get() and debt queries.
class _Store extends Fake implements FirebaseFirestore {
  _Store(this.h);
  final _Harness h;
  @override
  CollectionReference<_Data> collection(String path) {
    expect(path, anyOf('groupMembers', 'groups'));
    return _Collection(h);
  }
}

class _Collection extends Fake implements CollectionReference<_Data> {
  _Collection(this.h);
  final _Harness h;
  @override
  Query<_Data> where(
    Object field, {
    Object? isEqualTo,
    Object? isNotEqualTo,
    Object? isLessThan,
    Object? isLessThanOrEqualTo,
    Object? isGreaterThan,
    Object? isGreaterThanOrEqualTo,
    Object? arrayContains,
    Iterable<Object?>? arrayContainsAny,
    Iterable<Object?>? whereIn,
    Iterable<Object?>? whereNotIn,
    bool? isNull,
  }) {
    expect(field, 'deviceId');
    h.uids.add(isEqualTo);
    return this;
  }

  @override
  Stream<QuerySnapshot<_Data>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    expect(includeMetadataChanges, isTrue);
    h.membershipListens++;
    return h.members.stream;
  }

  @override
  DocumentReference<_Data> doc([String? path]) => _Reference(h);
}

class _Reference extends Fake implements DocumentReference<_Data> {
  _Reference(this.h);
  final _Harness h;
  @override
  Stream<DocumentSnapshot<_Data>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) {
    expect(includeMetadataChanges, isTrue);
    h.groupListens++;
    return h.group.stream;
  }
}

class _Auth extends Fake implements FirebaseAuth {
  _Auth(this.stream);
  final Stream<User?> stream;
  @override
  Stream<User?> authStateChanges() => stream;
}

class _User extends Fake implements User {
  _User(this.uid);
  @override
  final String uid;
}

class _Snapshot extends Fake implements QuerySnapshot<_Data> {
  _Snapshot(this.hasGroup, {bool cached = false})
    : metadata = _Metadata(cached);
  final bool hasGroup;
  @override
  List<QueryDocumentSnapshot<_Data>> get docs => hasGroup ? [_Member()] : [];
  @override
  final SnapshotMetadata metadata;
}

class _Member extends Fake implements QueryDocumentSnapshot<_Data> {
  @override
  _Data data() => {'groupId': 'group'};
}

class _Document extends Fake implements DocumentSnapshot<_Data> {
  _Document(this.name);
  final String name;
  @override
  String get id => 'group';
  @override
  _Data data() => {'name': name};
}

class _Metadata extends Fake implements SnapshotMetadata {
  _Metadata(this.isFromCache);
  @override
  final bool isFromCache;
  @override
  bool get hasPendingWrites => false;
}
