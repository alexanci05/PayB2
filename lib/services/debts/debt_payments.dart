import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:payb2/services/auth/identity_mutation_tracker.dart';

class DebtPaymentConflict implements Exception {
  const DebtPaymentConflict(this.message);
  final String message;
}

class DebtPayments {
  Future<void> markPaid(
    DocumentReference<Map<String, dynamic>> division,
    String registeredByMemberId,
  ) => IdentityMutationTracker.shared.track(
    () => division.update({
      'pagado': true,
      'pagadoEn': FieldValue.serverTimestamp(),
      'pagoRegistradoPor': registeredByMemberId,
    }),
  );

  Future<void> reopen(
    QueryDocumentSnapshot<Map<String, dynamic>> observed,
  ) => IdentityMutationTracker.shared.track(
    () => observed.reference.firestore.runTransaction((transaction) async {
      final current = await transaction.get(observed.reference);
      final before = observed.data();
      final latest = current.data();
      // A stale confirmation must not reopen a newer payment of the same debt.
      if (latest == null ||
          latest['pagado'] != true ||
          latest['pagadoEn'] != before['pagadoEn'] ||
          latest['pagoRegistradoPor'] != before['pagoRegistradoPor']) {
        throw const DebtPaymentConflict(
          'El pago ha cambiado. Revisa el historial antes de corregirlo.',
        );
      }
      transaction.update(observed.reference, {
        'pagado': false,
        'pagadoEn': FieldValue.delete(),
        'pagoRegistradoPor': FieldValue.delete(),
      });
    }),
  );
}
