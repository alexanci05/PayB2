'use strict';

const { DateTime, IANAZone } = require('luxon');

function centsFromAmount(cantidadCentimos) {
  if (!Number.isSafeInteger(cantidadCentimos) || cantidadCentimos <= 0) {
    throw new TypeError('cantidadCentimos must be a positive safe integer');
  }
  return cantidadCentimos;
}

function parseCalendarDate(value) {
  if (typeof value !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(value)) {
    throw new TypeError('Expected a calendar date in YYYY-MM-DD format');
  }
  const date = DateTime.fromISO(value, { zone: 'UTC' });
  if (!date.isValid || date.year < 1 || date.toISODate() !== value) {
    throw new RangeError('Invalid calendar date');
  }
  return date;
}

function validateTimeZone(value) {
  if (typeof value !== 'string' || value.length > 128 || !IANAZone.isValidZone(value)) {
    throw new RangeError('Expected a valid IANA time zone');
  }
  return value;
}

function todayInZone(timeZone, nowMillis = Date.now()) {
  return DateTime.fromMillis(nowMillis, { zone: validateTimeZone(timeZone) }).toISODate();
}

function scheduleInstant(calendarDate, timeZone) {
  parseCalendarDate(calendarDate);
  // Calendar days are interpreted in the group's fixed zone, including DST.
  return DateTime.fromISO(calendarDate, {
    zone: validateTimeZone(timeZone),
  }).startOf('day').toJSDate();
}

function splitCents(totalCents, payerId, participantes) {
  centsFromAmount(totalCents);
  if (typeof payerId !== 'string' || payerId.length === 0) {
    throw new TypeError('payerId must be a non-empty string');
  }
  if (!Array.isArray(participantes)) throw new TypeError('participantes must be an array');
  const debtors = new Set(participantes.filter((id) => id !== payerId));
  if (debtors.size === 0) throw new TypeError('At least one participant besides the payer is required');
  const memberIds = [...new Set([payerId, ...debtors])].sort();
  if (memberIds.some((id) => typeof id !== 'string' || !id)) {
    throw new TypeError('member ids must be non-empty strings');
  }
  if (totalCents < memberIds.length) {
    throw new RangeError('totalCents must assign at least one cent to every member');
  }
  const base = Math.floor(totalCents / memberIds.length);
  const remainder = totalCents % memberIds.length;
  return memberIds.map((memberId, index) => ({
    memberId, cantidadCentimos: base + (index < remainder ? 1 : 0),
  }));
}

function nextScheduledDate(calendarDate, frecuencia, anchorDay) {
  const date = parseCalendarDate(calendarDate);
  const day = anchorDay ?? date.day;
  if (!Number.isInteger(day) || day < 1 || day > 31) {
    throw new RangeError('anchorDay must be a day between 1 and 31');
  }
  const fixedDays = {
    'Cada 7 días': 7, 'Cada 15 días': 15, 'Cada 30 días': 30, 'Cada 365 días': 365,
  };
  let next;
  if (Object.hasOwn(fixedDays, frecuencia)) {
    next = date.plus({ days: fixedDays[frecuencia] });
  } else {
    const months = {
      'Mensual (mismo día todos los meses)': 1,
      'Trimestral (mismo día cada 3 meses)': 3,
      'Anual (mismo día cada año)': 12,
    };
    if (!Object.hasOwn(months, frecuencia)) throw new RangeError(`Unsupported frecuencia: ${frecuencia}`);
    const target = date.set({ day: 1 }).plus({ months: months[frecuencia] });
    next = target.set({ day: Math.min(day, target.daysInMonth) });
  }
  const result = next.toISODate();
  parseCalendarDate(result);
  return result;
}

function scheduledOccurrenceId(scheduleId, calendarDate) {
  if (typeof scheduleId !== 'string' || !scheduleId || scheduleId.includes('/')) {
    throw new TypeError('scheduleId must be a non-empty Firestore document id');
  }
  parseCalendarDate(calendarDate);
  return `${scheduleId}_${calendarDate}`;
}

function divisionId(memberId) {
  if (typeof memberId !== 'string' || !memberId || memberId.includes('/')) {
    throw new TypeError('memberId must be a non-empty Firestore document id');
  }
  return memberId;
}

module.exports = {
  centsFromAmount, splitCents, parseCalendarDate, validateTimeZone,
  todayInZone, scheduleInstant, nextScheduledDate, scheduledOccurrenceId, divisionId,
};
