'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { notificationEventRejection, MAX_NOTIFICATION_EVENT_AGE_MS } = require('../lib/notification-event-policy');
const { reminderClock } = require('../lib/debt-reminders');

test('payment notifications expire after 24 hours and reject invalid or future timestamps', () => {
  const now = Date.parse('2026-11-04T16:00:00Z');
  assert.equal(notificationEventRejection(new Date(now - MAX_NOTIFICATION_EVENT_AGE_MS).toISOString(), now), null);
  assert.equal(notificationEventRejection(new Date(now - MAX_NOTIFICATION_EVENT_AGE_MS - 1).toISOString(), now), 'expired-event');
  assert.equal(notificationEventRejection(new Date(now + 1).toISOString(), now), 'future-event');
  for (const invalid of [undefined, null, '', 'invalid', 0]) {
    assert.equal(notificationEventRejection(invalid, now), 'invalid-timestamp');
  }
});

test('reminder window begins at 15:15 Madrid across summer and winter offsets', () => {
  for (const [before, after, period] of [
    ['2026-11-04T14:14:59Z', '2026-11-04T14:15:00Z', '2026-11-04'],
    ['2026-07-04T13:14:59Z', '2026-07-04T13:15:00Z', '2026-07-04'],
  ]) {
    assert.deepEqual(reminderClock(new Date(before)), { period, ready: false });
    assert.deepEqual(reminderClock(new Date(after)), { period, ready: true });
  }
});
