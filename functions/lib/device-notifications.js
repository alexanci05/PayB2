'use strict';

const { createHash, randomUUID } = require('node:crypto');
const { FieldValue, Timestamp } = require('firebase-admin/firestore');
const { MAX_REGISTERED_DEVICES } = require('./security-policy');

const EVENT_LEASE_MS = 60_000;
// Longer than the 24-hour notification retry horizon; TTL only targets delivery metadata.
const DELIVERY_RETENTION_MS = 7 * 24 * 60 * 60 * 1000;

function deliveryExpiry() {
  return Timestamp.fromMillis(Date.now() + DELIVERY_RETENTION_MS);
}
const INVALID_TOKEN_CODES = new Set([
  'messaging/registration-token-not-registered',
  'messaging/invalid-registration-token',
  'messaging/mismatched-credential',
]);
const PERMANENT_MESSAGE_CODES = new Set([
  'messaging/invalid-argument',
  'messaging/invalid-recipient',
  'messaging/invalid-payload',
  'messaging/invalid-data-payload-key',
  'messaging/payload-size-limit-exceeded',
  'messaging/invalid-options',
  'messaging/invalid-package-name',
  'messaging/authentication-error',
  'messaging/invalid-apns-credentials',
  'messaging/third-party-auth-error',
]);

async function reserveEventDelivery(db, ref, reservation) {
  return db.runTransaction(async (transaction) => {
    const delivery = await transaction.get(ref);
    if (['sent', 'terminal'].includes(delivery.get('status'))) return false;
    if (delivery.get('leaseUntil') > Date.now()) {
      const error = new Error('Notification delivery is already in progress');
      error.code = 'notifications/delivery-in-progress';
      throw error;
    }
    transaction.set(ref, {
      status: 'pending', reservation, leaseUntil: Date.now() + EVENT_LEASE_MS,
      expiresAt: deliveryExpiry(),
    });
    return true;
  });
}

async function finishEventDelivery(db, ref, reservation, status, errorCode, daily) {
  await db.runTransaction(async (transaction) => {
    const delivery = await transaction.get(ref);
    if (delivery.get('reservation') !== reservation) {
      if (status) throw new Error('Notification delivery lease was replaced');
      return;
    }
    if (status) {
      transaction.set(ref, errorCode
        ? { status, errorCode, completedAt: FieldValue.serverTimestamp(), expiresAt: deliveryExpiry() }
        : { status, sentAt: FieldValue.serverTimestamp(), expiresAt: deliveryExpiry() });
      if (daily) transaction.set(daily.ref, daily.data);
    } else {
      transaction.delete(ref);
    }
  });
}

async function removeInvalidToken(db, ref, token) {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (snapshot.get('fcmToken') !== token) return;
    transaction.delete(ref);
  });
}

async function sendNotificationToUser({
  db, messaging, uid, title, body, period, eventId,
  maxDevices = MAX_REGISTERED_DEVICES,
}) {
  if (!Number.isInteger(maxDevices) || maxDevices < 1 || maxDevices > MAX_REGISTERED_DEVICES) {
    throw new RangeError('Invalid notification device limit');
  }
  const userRef = db.collection('usuarios').doc(uid);
  const devices = await userRef.collection('devices').limit(maxDevices).get();
  const destinations = devices.docs.map((device) => ({
    ref: device.ref, id: device.id, token: device.get('fcmToken'),
  }));

  const seenTokens = new Set();
  const failures = [];
  for (const destination of destinations) {
    const { ref, id, token } = destination;
    if (typeof token !== 'string' || !token || seenTokens.has(token)) continue;
    seenTokens.add(token);
    const deliveryId = createHash('sha256').update(JSON.stringify([uid, id])).digest('hex');
    const deliveryRef = db.collection('reminderDeliveries').doc(deliveryId);
    const eventRef = eventId ? db.collection('eventNotificationDeliveries').doc(
      createHash('sha256').update(JSON.stringify([eventId, uid, id])).digest('hex'),
    ) : null;
    const reservation = eventRef ? randomUUID() : null;
    let reserved = false;
    let accepted = false;
    try {
      if (period && (await deliveryRef.get()).get('period') === period) continue;
      if (eventRef) {
        reserved = await reserveEventDelivery(db, eventRef, reservation);
        if (!reserved) continue;
      }

      let permanentCode;
      try {
        await messaging.send({ token, notification: { title, body } });
      } catch (error) {
        if (!INVALID_TOKEN_CODES.has(error?.code) && !PERMANENT_MESSAGE_CODES.has(error?.code)) {
          throw error;
        }
        permanentCode = error.code;
        console.warn('Permanent FCM delivery failure', { code: permanentCode });
        if (INVALID_TOKEN_CODES.has(permanentCode)) await removeInvalidToken(db, ref, token);
      }
      accepted = true;
      const status = permanentCode ? 'terminal' : 'sent';
      const daily = period ? {
        ref: deliveryRef,
        data: {
          period, userUid: uid, installationId: id,
          expiresAt: deliveryExpiry(),
          ...(permanentCode
            ? { status, errorCode: permanentCode, completedAt: FieldValue.serverTimestamp() }
            : { sentAt: FieldValue.serverTimestamp() }),
        },
      } : null;
      // FCM acceptance and this checkpoint cannot be committed atomically.
      if (eventRef) {
        await finishEventDelivery(db, eventRef, reservation, status, permanentCode, daily);
      } else if (daily) await daily.ref.set(daily.data);
    } catch (error) {
      if (reserved && !accepted) {
        await finishEventDelivery(db, eventRef, reservation, false).catch((releaseError) => {
          failures.push(releaseError);
        });
      }
      failures.push(error);
    }
  }
  if (failures.length) {
    throw new AggregateError(failures, 'No se pudo notificar a todos los dispositivos');
  }
}

module.exports = { sendNotificationToUser };
