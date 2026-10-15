'use strict';

const { createHash } = require('node:crypto');
const { FieldValue } = require('firebase-admin/firestore');

async function removeInvalidToken(db, ref, token, legacy) {
  await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ref);
    if (snapshot.get('fcmToken') !== token) return;
    if (legacy) {
      transaction.update(ref, { fcmToken: FieldValue.delete() });
    } else {
      transaction.delete(ref);
    }
  });
}

async function sendNotificationToUser({ db, messaging, uid, title, body, period }) {
  const userRef = db.collection('usuarios').doc(uid);
  const [user, devices] = await Promise.all([
    userRef.get(), userRef.collection('devices').get(),
  ]);
  const destinations = devices.docs.map((device) => ({
    ref: device.ref, id: device.id, token: device.get('fcmToken'), legacy: false,
  }));
  // Older installations keep working until their next token registration.
  if (user.get('fcmToken')) {
    destinations.push({ ref: userRef, id: 'legacy', token: user.get('fcmToken'), legacy: true });
  }

  const seenTokens = new Set();
  const failures = [];
  for (const destination of destinations) {
    const { ref, id, token, legacy } = destination;
    if (typeof token !== 'string' || !token || seenTokens.has(token)) continue;
    seenTokens.add(token);
    const deliveryId = legacy ? uid : createHash('sha256').update(JSON.stringify([uid, id])).digest('hex');
    const deliveryRef = db.collection('reminderDeliveries').doc(deliveryId);
    try {
      if (period && (await deliveryRef.get()).get('period') === period) continue;

      await messaging.send({ token, notification: { title, body } });
      if (period) {
        await deliveryRef.set({
          period, userUid: uid, installationId: id,
          sentAt: FieldValue.serverTimestamp(),
        });
      }
    } catch (error) {
      if (error?.code === 'messaging/registration-token-not-registered' ||
          error?.code === 'messaging/invalid-registration-token') {
        await removeInvalidToken(db, ref, token, legacy).catch((cleanupError) => {
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
