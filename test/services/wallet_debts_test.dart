import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/services/debts/debt_queries.dart';
import 'package:payb2/services/debts/wallet_debts.dart';

typedef _Data = Map<String, dynamic>;

void main() {
  test(
    'pending updates retain metadata listeners and disposal stops them',
    () async {
      var groupListens = 0, memberListens = 0, pendingListens = 0;
      final group = StreamController<DocumentSnapshot<_Data>>.broadcast(
        sync: true,
        onListen: () => groupListens++,
      );
      final members = StreamController<QuerySnapshot<_Data>>.broadcast(
        sync: true,
        onListen: () => memberListens++,
      );
      final pending =
          StreamController<List<QueryDocumentSnapshot<_Data>>>.broadcast(
            sync: true,
            onListen: () => pendingListens++,
          );
      addTearDown(() async {
        await Future.wait([group.close(), members.close(), pending.close()]);
      });
      final memberQuery = _Collection({#snapshots: members.stream});
      final reference = _Reference({
        #snapshots: group.stream,
        #collection: memberQuery,
      });
      final firestore = _Firestore({
        #collection: _Collection({#doc: reference}),
      });
      final queries = _Queries({#watchPendingForMembers: pending.stream});
      final wallet = WalletGroupDebts('group', 'uid', firestore, queries);
      var notifications = 0;
      wallet.addListener(() => notifications++);
      wallet.start();
      final groupData = {'name': 'Trip'};
      group.add(_Document({#exists: true, #data: groupData}));
      final identity = {'name': 'Me', 'reclamadoPor': 'uid'};
      final me = _Document({#id: 'me', #data: identity});
      members.add(
        _Snapshot({
          #docs: <QueryDocumentSnapshot<_Data>>[me],
        }),
      );
      final first = _Document({#id: 'first'});
      final second = _Document({#id: 'second'});
      final beforeUpdates = notifications;
      pending.add([first]);
      expect(wallet.pending, [first]);
      pending.add([second]);
      expect(wallet.pending, [second]);
      expect(notifications, beforeUpdates + 2);
      expect(wallet.ready, isTrue);
      expect(wallet.name, 'Trip');
      expect(wallet.memberNames, {'me': 'Me'});
      expect([groupListens, memberListens, pendingListens], [1, 1, 1]);

      final beforeDispose = notifications;
      wallet.dispose();
      expect([
        group.hasListener,
        members.hasListener,
        pending.hasListener,
      ], everyElement(isFalse));
      group.add(_Document({#exists: false}));
      members.add(_Snapshot({#docs: <QueryDocumentSnapshot<_Data>>[]}));
      pending.add([first]);
      await Future<void>.delayed(Duration.zero);
      expect(notifications, beforeDispose);
      expect(wallet.name, 'Trip');
      expect(wallet.pending, [second]);
    },
  );
}

// All unconfigured calls (including .get()) fail instead of returning defaults.
class _Stub extends Fake {
  _Stub(this.answers);
  final Map<Symbol, dynamic> answers;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      answers.containsKey(invocation.memberName)
      ? answers[invocation.memberName]
      : super.noSuchMethod(invocation);
}

class _Firestore extends _Stub implements FirebaseFirestore {
  _Firestore(super.answers);
}

// SDK interfaces are implemented only by isolated test doubles.
// ignore: subtype_of_sealed_class
class _Collection extends _Stub implements CollectionReference<_Data> {
  _Collection(super.answers);
}

// ignore: subtype_of_sealed_class
class _Reference extends _Stub implements DocumentReference<_Data> {
  _Reference(super.answers);
}

// ignore: subtype_of_sealed_class
class _Document extends _Stub implements QueryDocumentSnapshot<_Data> {
  _Document(super.answers);
}

class _Snapshot extends _Stub implements QuerySnapshot<_Data> {
  _Snapshot(super.answers);
}

class _Queries extends _Stub implements DebtQueries {
  _Queries(super.answers);
}
