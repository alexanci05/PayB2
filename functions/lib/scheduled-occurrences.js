'use strict';

const DAY_MS = 24 * 60 * 60 * 1000;

function centsFromAmount(cantidadCentimos, cantidad) {
  if (cantidadCentimos !== undefined && cantidadCentimos !== null) {
    if (!Number.isSafeInteger(cantidadCentimos) || cantidadCentimos <= 0) {
      throw new TypeError('cantidadCentimos must be a positive safe integer');
    }
    return cantidadCentimos;
  }

  if (typeof cantidad !== 'number' || !Number.isFinite(cantidad) || cantidad <= 0) {
    throw new TypeError('cantidad must be a positive finite number');
  }

  const cents = Math.round((cantidad + Number.EPSILON) * 100);
  if (!Number.isSafeInteger(cents)) {
    throw new RangeError('cantidad is outside the supported money range');
  }
  return cents;
}

function splitCents(totalCents, payerId, participantes) {
  if (!Number.isSafeInteger(totalCents) || totalCents <= 0) {
    throw new TypeError('totalCents must be a positive safe integer');
  }
  if (typeof payerId !== 'string' || payerId.length === 0) {
    throw new TypeError('payerId must be a non-empty string');
  }
  if (!Array.isArray(participantes)) {
    throw new TypeError('participantes must be an array');
  }

  const debtors = new Set(participantes.filter((memberId) => memberId !== payerId));
  if (debtors.size === 0) {
    throw new TypeError('At least one participant besides the payer is required');
  }

  const memberIds = [...new Set([payerId, ...debtors])].sort();
  if (memberIds.some((memberId) => typeof memberId !== 'string' || memberId.length === 0)) {
    throw new TypeError('member ids must be non-empty strings');
  }
  if (totalCents < memberIds.length) {
    throw new RangeError('totalCents must assign at least one cent to every member');
  }

  const baseCents = Math.floor(totalCents / memberIds.length);
  const remainderCents = totalCents % memberIds.length;
  return memberIds.map((memberId, index) => {
    const cantidadCentimos = baseCents + (index < remainderCents ? 1 : 0);
    return {
      memberId,
      cantidadCentimos,
      cantidad: cantidadCentimos / 100,
    };
  });
}

function nextScheduledDate(scheduledDate, frecuencia) {
  const date = validDate(scheduledDate);

  switch (frecuencia) {
    case 'Cada 7 días':
      return new Date(date.getTime() + 7 * DAY_MS);
    case 'Cada 15 días':
      return new Date(date.getTime() + 15 * DAY_MS);
    case 'Cada 30 días':
      return new Date(date.getTime() + 30 * DAY_MS);
    case 'Cada 365 días':
      return new Date(date.getTime() + 365 * DAY_MS);
    case 'Mensual (mismo día todos los meses)':
      return addMonthsClamped(date, 1);
    case 'Trimestral (mismo día cada 3 meses)':
      return addMonthsClamped(date, 3);
    case 'Anual (mismo día cada año)':
      return addYearsClamped(date, 1);
    default:
      throw new RangeError(`Unsupported frecuencia: ${frecuencia}`);
  }
}

function scheduledOccurrenceId(scheduleId, scheduledAt) {
  if (typeof scheduleId !== 'string' || scheduleId.length === 0 || scheduleId.includes('/')) {
    throw new TypeError('scheduleId must be a non-empty Firestore document id');
  }
  return `${scheduleId}_${timestampKey(scheduledAt)}`;
}

function divisionId(memberId) {
  if (typeof memberId !== 'string' || memberId.length === 0 || memberId.includes('/')) {
    throw new TypeError('memberId must be a non-empty Firestore document id');
  }
  return memberId;
}

function addMonthsClamped(date, monthsToAdd) {
  const year = date.getUTCFullYear();
  const month = date.getUTCMonth() + monthsToAdd;
  const target = new Date(Date.UTC(
    year,
    month,
    1,
    date.getUTCHours(),
    date.getUTCMinutes(),
    date.getUTCSeconds(),
    date.getUTCMilliseconds(),
  ));
  target.setUTCDate(Math.min(date.getUTCDate(), daysInUtcMonth(target.getUTCFullYear(), target.getUTCMonth())));
  return target;
}

function addYearsClamped(date, yearsToAdd) {
  const target = new Date(Date.UTC(
    date.getUTCFullYear() + yearsToAdd,
    date.getUTCMonth(),
    1,
    date.getUTCHours(),
    date.getUTCMinutes(),
    date.getUTCSeconds(),
    date.getUTCMilliseconds(),
  ));
  target.setUTCDate(Math.min(date.getUTCDate(), daysInUtcMonth(target.getUTCFullYear(), target.getUTCMonth())));
  return target;
}

function daysInUtcMonth(year, month) {
  return new Date(Date.UTC(year, month + 1, 0)).getUTCDate();
}

function validDate(value) {
  if (!(value instanceof Date) || Number.isNaN(value.getTime())) {
    throw new TypeError('scheduledDate must be a valid Date');
  }
  return new Date(value.getTime());
}

function timestampKey(value) {
  if (value instanceof Date) {
    return (BigInt(validDate(value).getTime()) * 1000n).toString();
  }
  if (Number.isSafeInteger(value) && value >= 0) {
    return (BigInt(value) * 1000n).toString();
  }
  if (
    value &&
    Number.isSafeInteger(value.seconds) &&
    Number.isSafeInteger(value.nanoseconds) &&
    value.nanoseconds >= 0 &&
    value.nanoseconds < 1000000000
  ) {
    return (BigInt(value.seconds) * 1000000n + BigInt(Math.floor(value.nanoseconds / 1000))).toString();
  }
  throw new TypeError('scheduledAt must be a valid Date, millisecond timestamp, or Firestore Timestamp');
}

module.exports = {
  centsFromAmount,
  splitCents,
  nextScheduledDate,
  scheduledOccurrenceId,
  divisionId,
};
