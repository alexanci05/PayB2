import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/screens/group_history/group_history_screen.dart';
import 'package:payb2/services/debts/debt_payments.dart';
import 'package:payb2/services/debts/debt_queries.dart';

void main() {
  testWidgets(
    'history distinguishes months and creditors can reopen either payment',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final payments = _Payments();
      final queries = _Queries([
        _Debt('november', 'debtor', 'creditor', 11),
        _Debt('december', 'debtor', 'debtor', 12),
        _Debt('self', 'creditor', 'creditor', 12),
      ]);
      Widget screen(Set<String> identities) => MaterialApp(
        home: GroupHistoryScreen(
          groupId: 'group',
          memberNames: const {'creditor': 'Ana', 'debtor': 'Luis'},
          myMemberIds: identities,
          queries: queries,
          payments: payments,
        ),
      );
      await tester.pumpWidget(screen({'creditor'}));
      await tester.pumpAndSettle();
      expect(find.text('Alquiler'), findsNWidgets(2));
      expect(find.textContaining('Gasto: 01/11/2026'), findsOneWidget);
      expect(find.textContaining('Gasto: 01/12/2026'), findsOneWidget);
      expect(find.textContaining('Registrado por Ana'), findsOneWidget);
      expect(
        find.byTooltip('Volver a marcar como pendiente'),
        findsNWidgets(2),
      );
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Volver a marcar como pendiente').first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Alquiler (01/12/2026)'), findsOneWidget);
      await tester.tap(find.widgetWithText(FilledButton, 'Marcar pendiente'));
      await tester.pumpAndSettle();
      expect(payments.reopened, [
        'groups/group/gastos/december/divisiones/debtor',
      ]);

      await tester.pumpWidget(screen({'debtor'}));
      await tester.pumpAndSettle();
      expect(find.text('Alquiler'), findsNWidgets(2));
      expect(find.byTooltip('Volver a marcar como pendiente'), findsNothing);
    },
  );
}

class _Queries extends Fake implements DebtQueries {
  _Queries(this.debts);
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> debts;
  @override
  Stream<QuerySnapshot<Map<String, dynamic>>> watchSettledGroupDivisions(
    String groupId,
  ) => Stream.value(_Snapshot(debts));
}

class _Snapshot extends Fake implements QuerySnapshot<Map<String, dynamic>> {
  _Snapshot(this.docs);
  @override
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> docs;
}

// SDK interfaces are implemented only by isolated test doubles.
// ignore: subtype_of_sealed_class
class _Debt extends Fake
    implements QueryDocumentSnapshot<Map<String, dynamic>> {
  _Debt(this.expense, this.debtor, this.registeredBy, this.month);
  final String expense, debtor, registeredBy;
  final int month;
  @override
  Map<String, dynamic> data() => {
    'nombre': 'Alquiler',
    'memberId': debtor,
    'pagadoPor': 'creditor',
    'pagado': true,
    'pagoRegistradoPor': registeredBy,
    'cantidadCentimos': 1500,
    'fecha': '2026-${month.toString().padLeft(2, '0')}-01',
    'pagadoEn': Timestamp.fromDate(DateTime.utc(2026, month, 2, 12)),
  };
  @override
  DocumentReference<Map<String, dynamic>> get reference =>
      _Reference('groups/group/gastos/$expense/divisiones/$debtor');
  @override
  SnapshotMetadata get metadata => _Metadata();
}

// ignore: subtype_of_sealed_class
class _Reference extends Fake
    implements DocumentReference<Map<String, dynamic>> {
  _Reference(this.path);
  @override
  final String path;
}

class _Metadata extends Fake implements SnapshotMetadata {
  @override
  bool get hasPendingWrites => false;
}

class _Payments extends DebtPayments {
  final reopened = <String>[];
  @override
  Future<void> reopen(
    QueryDocumentSnapshot<Map<String, dynamic>> observed,
  ) async {
    reopened.add(observed.reference.path);
  }
}
