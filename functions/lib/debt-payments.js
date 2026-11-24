'use strict';

const { FieldValue, Timestamp } = require('firebase-admin/firestore');
const { https: { HttpsError } } = require('firebase-functions/v1');

function validId(value) {
  return typeof value === 'string' && value.length > 0 &&
    value.length <= 1500 && !value.includes('/');
}

async function registerDebtPayment(db, uid, data = {}) {
  const { groupId, gastoId, divisionId, pagado, pagoRegistradoPor, pagoEsperado } = data;
  if (![groupId, gastoId, divisionId].every(validId) || typeof pagado !== 'boolean' ||
      (pagado && !validId(pagoRegistradoPor)) ||
      (!pagado && (!Number.isSafeInteger(pagoEsperado?.pagadoEn?.seconds) ||
        !Number.isInteger(pagoEsperado?.pagadoEn?.nanoseconds) ||
        pagoEsperado.pagadoEn.nanoseconds < 0 || pagoEsperado.pagadoEn.nanoseconds >= 1e9 ||
        !validId(pagoEsperado.pagoRegistradoPor)))) {
    throw new HttpsError('invalid-argument', 'Los datos del pago no son válidos');
  }

  const groupRef = db.collection('groups').doc(groupId);
  const debtRef = groupRef.collection('gastos').doc(gastoId).collection('divisiones').doc(divisionId);
  return db.runTransaction(async (transaction) => {
    const [merge, membership, debt] = await transaction.getAll(
      db.collection('accountMerges').doc(uid),
      db.collection('groupMembers').doc(`${groupId}_${uid}`),
      debtRef,
    );
    if (merge.exists) {
      throw new HttpsError('failed-precondition', 'La cuenta está terminando un inicio de sesión');
    }
    if (!membership.exists || membership.get('groupId') !== groupId ||
        membership.get('deviceId') !== uid || !debt.exists || debt.get('groupId') !== groupId ||
        debt.get('memberId') === debt.get('pagadoPor')) {
      throw new HttpsError('permission-denied', 'No puedes modificar esta deuda');
    }
    const actorId = pagado ? pagoRegistradoPor : debt.get('pagadoPor');
    if (pagado && actorId !== debt.get('memberId') && actorId !== debt.get('pagadoPor')) {
      throw new HttpsError('permission-denied', 'No puedes registrar este pago');
    }
    const actor = await transaction.get(groupRef.collection('members').doc(actorId));
    if (!actor.exists || actor.get('reclamadoPor') !== uid) {
      throw new HttpsError('permission-denied', 'No puedes modificar esta deuda');
    }

    if (pagado) {
      if (debt.get('pagado') === true) return { changed: false };
      transaction.update(debtRef, {
        pagado: true,
        pagadoEn: FieldValue.serverTimestamp(),
        pagoRegistradoPor: actorId,
      });
    } else {
      const paidAt = debt.get('pagadoEn');
      if (debt.get('pagado') !== true || !(paidAt instanceof Timestamp) ||
          paidAt.seconds !== pagoEsperado.pagadoEn.seconds ||
          paidAt.nanoseconds !== pagoEsperado.pagadoEn.nanoseconds ||
          debt.get('pagoRegistradoPor') !== pagoEsperado.pagoRegistradoPor) {
        throw new HttpsError('failed-precondition',
          'El pago ha cambiado. Revisa el historial antes de corregirlo.',
          { reason: 'payment-changed' });
      }
      transaction.update(debtRef, {
        pagado: false,
        pagadoEn: FieldValue.delete(),
        pagoRegistradoPor: FieldValue.delete(),
      });
    }
    return { changed: true };
  });
}

module.exports = { registerDebtPayment };
