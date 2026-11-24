'use strict';

const MAX_NOTIFICATION_EVENT_AGE_MS = 24 * 60 * 60 * 1000;

function notificationEventRejection(timestamp, now = Date.now()) {
  const eventTime = typeof timestamp === 'string' ? Date.parse(timestamp) : NaN;
  if (!Number.isFinite(eventTime)) return 'invalid-timestamp';
  if (eventTime > now) return 'future-event';
  if (now - eventTime > MAX_NOTIFICATION_EVENT_AGE_MS) return 'expired-event';
  return null;
}

module.exports = { MAX_NOTIFICATION_EVENT_AGE_MS, notificationEventRejection };
