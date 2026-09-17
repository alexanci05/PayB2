'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');

const {
  centsFromAmount,
  splitCents,
  nextScheduledDate,
  scheduledOccurrenceId,
  divisionId,
} = require('../lib/scheduled-occurrences');

test('centsFromAmount prefers exact cent values and converts legacy decimal amounts', () => {
  assert.equal(centsFromAmount(1001, 10.00), 1001);
  assert.equal(centsFromAmount(undefined, 10.01), 1001);
  assert.throws(() => centsFromAmount(10.5, 10.50), /safe integer/);
});

test('splitCents includes the payer, sorts ids, and gives remainder cents to first ids', () => {
  const shares = splitCents(1001, 'payer', ['zoe', 'amy', 'payer']);

  assert.deepEqual(shares, [
    { memberId: 'amy', cantidadCentimos: 334, cantidad: 3.34 },
    { memberId: 'payer', cantidadCentimos: 334, cantidad: 3.34 },
    { memberId: 'zoe', cantidadCentimos: 333, cantidad: 3.33 },
  ]);
  assert.equal(shares.reduce((total, share) => total + share.cantidadCentimos, 0), 1001);
});

test('splitCents requires a positive amount and a debtor besides the payer', () => {
  assert.throws(() => splitCents(0, 'payer', ['debtor']), /positive/);
  assert.throws(() => splitCents(100, 'payer', ['payer']), /participant/);
  assert.throws(() => splitCents(2, 'payer', ['a', 'b']), /one cent/);
});

test('calendar frequencies clamp end-of-month and leap-day occurrences', () => {
  assert.equal(
    nextScheduledDate(new Date('2023-01-31T09:30:00.000Z'), 'Mensual (mismo día todos los meses)').toISOString(),
    '2023-02-28T09:30:00.000Z',
  );
  assert.equal(
    nextScheduledDate(new Date('2024-01-31T09:30:00.000Z'), 'Mensual (mismo día todos los meses)').toISOString(),
    '2024-02-29T09:30:00.000Z',
  );
  assert.equal(
    nextScheduledDate(new Date('2024-02-29T09:30:00.000Z'), 'Anual (mismo día cada año)').toISOString(),
    '2025-02-28T09:30:00.000Z',
  );
});

test('scheduled occurrence and division ids are deterministic', () => {
  assert.equal(scheduledOccurrenceId('schedule-123', new Date('2026-09-17T15:00:00.000Z')), 'schedule-123_1789657200000000');
  assert.equal(scheduledOccurrenceId('schedule-123', 1789657200000), 'schedule-123_1789657200000000');
  assert.equal(
    scheduledOccurrenceId('schedule-123', { seconds: 1789657200, nanoseconds: 123456 }),
    'schedule-123_1789657200000123',
  );
  assert.equal(divisionId('member-123'), 'member-123');
});
