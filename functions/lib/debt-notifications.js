'use strict';

function debtNotificationForTransition(before, after) {
  if (before?.pagado === false && after?.pagado === true) {
    if (!validMemberId(after.pagadoPor) || !validMemberId(after.memberId)) {
      return null;
    }
    return {
      targetMemberId: after.pagadoPor,
      title: '¡Una deuda fue pagada!',
      body: `El miembro ${after.memberId} ha marcado su parte como pagada.`,
    };
  }

  if (before?.pagado === true && after?.pagado === false) {
    if (!validMemberId(after.memberId)) return null;
    return {
      targetMemberId: after.memberId,
      title: 'Pago pendiente de revisión',
      body: 'El pago de tu parte se ha vuelto a marcar como pendiente.',
    };
  }

  return null;
}

function validMemberId(value) {
  return typeof value === 'string' && value.length > 0;
}

module.exports = { debtNotificationForTransition };
