import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';
import 'package:payb2/services/network/connection_status.dart';

class DebtPaymentConflict implements Exception {
  const DebtPaymentConflict(this.message);
  final String message;
}

class DebtPayments {
  DebtPayments({FirebaseFunctions? functions}) : _functions = functions;

  final FirebaseFunctions? _functions;

  Future<void> markPaid(
    DocumentReference<Map<String, dynamic>> division,
    String registeredByMemberId,
  ) => IdentityMutationTracker.shared.track(
    () => _change(division, {
      'pagado': true,
      'pagoRegistradoPor': registeredByMemberId,
    }),
  );

  Future<void> reopen(QueryDocumentSnapshot<Map<String, dynamic>> observed) =>
      IdentityMutationTracker.shared.track(() async {
        final before = observed.data();
        final paidAt = before['pagadoEn'];
        if (before['pagado'] != true || paidAt is! Timestamp) {
          throw const DebtPaymentConflict(
            'El pago ha cambiado. Revisa el historial antes de corregirlo.',
          );
        }
        try {
          await _change(observed.reference, {
            'pagado': false,
            'pagoEsperado': {
              'pagadoEn': {
                'seconds': paidAt.seconds,
                'nanoseconds': paidAt.nanoseconds,
              },
              'pagoRegistradoPor': before['pagoRegistradoPor'],
            },
          });
        } on FirebaseFunctionsException catch (error) {
          if (error.details is Map &&
              error.details['reason'] == 'payment-changed') {
            throw DebtPaymentConflict(error.message ?? 'El pago ha cambiado.');
          }
          rethrow;
        }
      });

  Future<void> _change(
    DocumentReference<Map<String, dynamic>> division,
    Map<String, dynamic> change,
  ) async {
    final expense = division.parent.parent!;
    final group = expense.parent.parent!;
    await (_functions ?? FirebaseFunctions.instance)
        .httpsCallable('registrarPagoDeuda')
        .callObserved<Map<String, dynamic>>({
          'groupId': group.id,
          'gastoId': expense.id,
          'divisionId': division.id,
          ...change,
        });
  }
}
