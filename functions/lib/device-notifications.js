'use strict';

const { createHash, randomUUID } = require('node:crypto');
const { FieldValue } = require('firebase-admin/firestore');

const EVENT_LEASE_MS = 60_000;

async function reserveEventDelivery(db, ref, reservation) {
  return db.runTransaction(async (transaction) => {
    const delivery = await transaction.get(ref);
    if (delivery.get('status') === 'sent') return false;
    if (delivery.get('leaseUntil') > Date.now()) {
      const error = new Error('Notification delivery is already in progress');
      error.code = 'notifications/delivery-in-progress';
      throw error;
    }
    transaction.set(ref, {
      status: 'pending', reservation, leaseUntil: Date.now() + EVENT_LEASE_MS,
    });
    return true;
  });
}

async function finishEventDelivery(db, ref, reservation, sent) {
  await db.runTransaction(async (transaction) => {
    const delivery = await transaction.get(ref);
    if (delivery.get('reservation') !== reservation) {
      if (sent) throw new Error('Notification delivery lease was replaced');
      return;
    }
    if (sent) {
      transaction.set(ref, { status: 'sent', sentAt: FieldValue.serverTimestamp() });
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

async function sendNotificationToUser({ db, messaging, uid, title, body, period, eventId }) {
  const userRef = db.collection('usuarios').doc(uid);
  const devices = await userRef.collection('devices').get();
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

      await messaging.send({ token, notification: { title, body } });
      accepted = true;
      // FCM acceptance and this checkpoint cannot be committed atomically.
      if (eventRef) await finishEventDelivery(db, eventRef, reservation, true);
      if (period) {
        await deliveryRef.set({
          period, userUid: uid, installationId: id,
          sentAt: FieldValue.serverTimestamp(),
        });
      }
    } catch (error) {
      if (reserved && !accepted) {
        await finishEventDelivery(db, eventRef, reservation, false).catch((releaseError) => {
          failures.push(releaseError);
        });
      }
      if (error?.code === 'messaging/registration-token-not-registered' ||
          error?.code === 'messaging/invalid-registration-token') {
        await removeInvalidToken(db, ref, token).catch((cleanupError) => {
          failures.push(cleanupError);
        });
      } else {
        failures.push(error);
      }
    }
  }
  if (failures.length) {
    throw new AggregateError(failures, 'No se pudo notificar a todos los dispositivos');
  }
}

module.exports = { sendNotificationToUser };
