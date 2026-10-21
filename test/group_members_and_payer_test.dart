// SDK interfaces are implemented only by isolated test doubles.
// ignore_for_file: subtype_of_sealed_class

import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/screens/crear_gasto/crear_gasto.dart';
import 'package:payb2/screens/grupo_detalles/grupo_detalle_screen.dart';
import 'package:payb2/domain/calendar_date.dart';
import 'package:payb2/services/groups/group_context.dart';

typedef _Data = Map<String, dynamic>;

void main() {
  testWidgets('expenses build lazily with stable section and document keys', (
    tester,
  ) async {
    final store = _Store();
    addTearDown(store.close);
    store.expenses = List.generate(
      80,
      (i) => _Doc('expense-$i', {
        'nombre': 'Expense $i',
        'fecha': '2026-11-01',
        'cantidadCentimos': 1234,
        'pagadoPor': 'ana',
      }),
    );
    store.schedules = [
      _Doc('schedule', {
        'nombre': 'Scheduled',
        'proximaFecha': '2026-12-01',
        'cantidadCentimos': 2500,
        'createdByUid': 'user',
      }),
    ];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: GastosView(
            firestore: store,
            groupId: 'trip',
            memberMap: const {},
            myMemberIds: const {},
            currentUid: 'user',
            isAdmin: false,
            onChanged: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final list = tester.widget<ListView>(find.byType(ListView));
    final delegate = list.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.childCount, 83);
    expect(
      delegate.findChildIndexCallback!(const ValueKey('expense/expense-79')),
      82,
    );
    expect(find.byKey(const ValueKey('schedules-heading')), findsOneWidget);
    expect(find.byKey(const ValueKey('expenses-heading')), findsOneWidget);
    expect(find.text('Expense 79'), findsNothing);
    expect(find.text('01/12/2026'), findsOneWidget);
    expect(find.text('25.00 €'), findsOneWidget);
    await tester.tap(find.byTooltip('Cancelar gasto programado'));
    await tester.pumpAndSettle();
    expect(
      find.text('Se cancelará este gasto si todavía no se ha generado.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Volver'));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('Expense 79'), 500);
    expect(find.byKey(const ValueKey('expense/expense-79')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'unidentified author selects payer without claiming an identity',
    (tester) async {
      final store = _Store();
      addTearDown(store.close);
      await tester.pumpWidget(
        MaterialApp(
          home: CrearGastoScreen(groupId: 'trip', firestore: store),
        ),
      );
      await tester.pumpAndSettle();
      final dateField = tester.widget<TextFormField>(
        find.widgetWithText(TextFormField, 'Fecha del gasto'),
      );
      expect(
        dateField.controller!.text,
        calendarDateString(todayInTimeZone('Pacific/Kiritimati')),
      );
      final payer = find.byKey(const ValueKey('expense-payer'));
      await tester.ensureVisible(find.text('Todos los miembros'));
      await tester.tap(find.text('Todos los miembros'));
      await tester.pump();

      Future<void> choose(String name) async {
        await tester.ensureVisible(payer);
        await tester.tap(payer);
        await tester.pumpAndSettle();
        await tester.tap(find.text(name).last);
        await tester.pumpAndSettle();
      }

      await choose('Luis');
      expect(find.widgetWithText(CheckboxListTile, 'Luis'), findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Ana'),
            )
            .value,
        isTrue,
      );
      await choose('Ana');
      expect(find.widgetWithText(CheckboxListTile, 'Ana'), findsNothing);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.widgetWithText(CheckboxListTile, 'Luis'),
            )
            .value,
        isTrue,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('expense form rejects a group without a time zone', (
    tester,
  ) async {
    final store = _Store()..groupData = {};
    addTearDown(store.close);
    await tester.pumpWidget(
      MaterialApp(
        home: CrearGastoScreen(groupId: 'trip', firestore: store),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('zona horaria del grupo'), findsOneWidget);
    expect(find.byKey(const ValueKey('expense-payer')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'group context updates members, roles and identity and recovers errors',
    () async {
      final store = _Store();
      addTearDown(store.close);
      final context = GroupContext('trip', 'user', firestore: store)..start();
      store.group.add(
        _Doc('trip', {'name': 'Viaje', 'ownerDeviceId': 'owner'}),
      );
      store.members.add(_Snapshot(store.people));
      store.membership.add(_Doc('trip_user', {'memberId': 'ana'}));
      expect(context.ready, isTrue);
      expect(context.myMemberIds, isEmpty);
      expect(context.isAdmin, isFalse);
      store.group.add(
        _Doc('trip', {'ownerDeviceId': 'owner', 'allMembersAreAdmins': true}),
      );
      store.members.add(
        _Snapshot([
          ...store.people,
          _Doc('new', {'name': 'Nueva', 'reclamadoPor': 'user'}),
        ]),
      );
      expect(context.isAdmin, isTrue);
      expect(context.myMemberIds, ['new']);
      store.members.addError(StateError('Unavailable'));
      expect(context.error, isNotNull);
      expect(context.members.length, 4);
      context.start();
      store.members.add(_Snapshot(store.people));
      expect(context.error, isNull);
      expect(context.myMemberIds, isEmpty);
      context.dispose();
      expect([
        store.group.hasListener,
        store.members.hasListener,
        store.membership.hasListener,
      ], everyElement(isFalse));
    },
  );
}

class _Store extends Fake implements FirebaseFirestore {
  _Data groupData = {'timeZone': 'Pacific/Kiritimati'};
  List<QueryDocumentSnapshot<_Data>> expenses = [];
  List<QueryDocumentSnapshot<_Data>> schedules = [];
  final group = StreamController<DocumentSnapshot<_Data>>.broadcast(sync: true);
  final members = StreamController<QuerySnapshot<_Data>>.broadcast(sync: true);
  final membership = StreamController<DocumentSnapshot<_Data>>.broadcast(
    sync: true,
  );
  final people = <QueryDocumentSnapshot<_Data>>[
    _Doc('ana', {'name': 'Ana'}),
    _Doc('luis', {'name': 'Luis'}),
    _Doc('marta', {'name': 'Marta'}),
  ];
  @override
  CollectionReference<_Data> collection(String path) => _Collection(this, path);
  Future<void> close() async {
    await Future.wait([group.close(), members.close(), membership.close()]);
  }
}

class _Collection extends Fake implements CollectionReference<_Data> {
  _Collection(this.store, this.kind);
  final _Store store;
  final String kind;
  @override
  Query<_Data> orderBy(Object field, {bool descending = false}) => this;
  @override
  DocumentReference<_Data> doc([String? path]) => _Reference(store, kind);
  @override
  Future<QuerySnapshot<_Data>> get([GetOptions? options]) async =>
      _Snapshot(store.people);
  @override
  Stream<QuerySnapshot<_Data>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => switch (kind) {
    'gastos' => Stream.value(_Snapshot(store.expenses)),
    'gastosProgramados' => Stream.value(_Snapshot(store.schedules)),
    _ => store.members.stream,
  };
}

class _Reference extends Fake implements DocumentReference<_Data> {
  _Reference(this.store, this.kind);
  final _Store store;
  final String kind;
  @override
  CollectionReference<_Data> collection(String path) =>
      _Collection(store, path);
  @override
  Future<DocumentSnapshot<_Data>> get([GetOptions? options]) async =>
      _Doc('trip', store.groupData);
  @override
  Stream<DocumentSnapshot<_Data>> snapshots({
    bool includeMetadataChanges = false,
    ListenSource source = ListenSource.defaultSource,
  }) => kind == 'groupMembers' ? store.membership.stream : store.group.stream;
}

class _Doc extends Fake implements QueryDocumentSnapshot<_Data> {
  _Doc(this.id, this.value);
  @override
  final String id;
  final _Data value;
  @override
  _Data data() => value;
  @override
  bool get exists => true;
  @override
  SnapshotMetadata get metadata => _Metadata();
}

class _Snapshot extends Fake implements QuerySnapshot<_Data> {
  _Snapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<_Data>> docs;
}

class _Metadata extends Fake implements SnapshotMetadata {
  @override
  bool get isFromCache => false;
}
