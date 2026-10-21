'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  centsFromAmount, splitCents, parseCalendarDate, validateTimeZone,
  todayInZone, scheduleInstant, nextScheduledDate, scheduledOccurrenceId, divisionId,
} = require('../lib/scheduled-occurrences');

test('money accepts only positive integer cents', () => {
  assert.equal(centsFromAmount(1001), 1001);
  for (const amount of [undefined, 10.01, -1, 0]) {
    assert.throws(() => centsFromAmount(amount), /safe integer/);
  }
});

test('splitCents includes the payer and distributes every cent deterministically', () => {
  assert.deepEqual(splitCents(1001, 'payer', ['zoe', 'amy', 'payer']), [
    { memberId: 'amy', cantidadCentimos: 334 },
    { memberId: 'payer', cantidadCentimos: 334 },
    { memberId: 'zoe', cantidadCentimos: 333 },
  ]);
  assert.throws(() => splitCents(0, 'payer', ['debtor']), /positive/);
  assert.throws(() => splitCents(100, 'payer', ['payer']), /participant/);
  assert.throws(() => splitCents(2, 'payer', ['a', 'b']), /one cent/);
});

test('calendar dates and IANA zones reject ambiguous or invalid values', () => {
  for (const date of ['2026-02-30', '2026-1-01', '2026-01-01T12:00Z', new Date()]) {
    assert.throws(() => parseCalendarDate(date));
  }
  assert.equal(parseCalendarDate('2024-02-29').day, 29);
  assert.equal(validateTimeZone('Pacific/Auckland'), 'Pacific/Auckland');
  assert.throws(() => validateTimeZone('UTC+3'));
  assert.throws(() => validateTimeZone(undefined));
});

test('group dates do not depend on the execution host or the viewing device', () => {
  const instant = Date.parse('2026-10-16T12:00:00Z');
  assert.equal(todayInZone('Europe/Madrid', instant), '2026-10-16');
  assert.equal(todayInZone('Pacific/Auckland', instant), '2026-10-17');
  assert.equal(scheduleInstant('2026-10-17', 'Pacific/Auckland').toISOString(), '2026-10-16T11:00:00.000Z');
  assert.equal(scheduledOccurrenceId('schedule', '2026-10-17'), 'schedule_2026-10-17');
});

test('midnight execution follows DST without shifting the occurrence date', () => {
  assert.equal(scheduleInstant('2026-03-29', 'Europe/Madrid').toISOString(), '2026-03-28T23:00:00.000Z');
  assert.equal(scheduleInstant('2026-03-30', 'Europe/Madrid').toISOString(), '2026-03-29T22:00:00.000Z');
  assert.equal(scheduleInstant('2026-10-25', 'Europe/Madrid').toISOString(), '2026-10-24T22:00:00.000Z');
  assert.equal(scheduleInstant('2026-10-26', 'Europe/Madrid').toISOString(), '2026-10-25T23:00:00.000Z');
});

test('monthly and quarterly dates recover their original anchor', () => {
  let date = '2024-01-31';
  for (const expected of ['2024-02-29', '2024-03-31', '2024-04-30']) {
    date = nextScheduledDate(date, 'Mensual (mismo día todos los meses)', 31);
    assert.equal(date, expected);
  }
  date = '2024-03-31';
  for (const expected of ['2024-06-30', '2024-09-30', '2024-12-31']) {
    date = nextScheduledDate(date, 'Trimestral (mismo día cada 3 meses)', 31);
    assert.equal(date, expected);
  }
});

test('annual leap-day dates recover February 29 and fixed-day periods stay calendar based', () => {
  let date = '2024-02-29';
  for (const year of [2025, 2026, 2027, 2028]) {
    date = nextScheduledDate(date, 'Anual (mismo día cada año)', 29);
    assert.equal(date, `${year}-02-${year === 2028 ? 29 : 28}`);
  }
  assert.equal(nextScheduledDate('2026-03-28', 'Cada 7 días'), '2026-04-04');
  assert.equal(nextScheduledDate('2024-01-31', 'Cada 30 días', 31), '2024-03-01');
  assert.equal(divisionId('member'), 'member');
});
