'use strict';

const { FieldValue } = require('firebase-admin/firestore');
const { https: { HttpsError } } = require('firebase-functions/v1');
const { MAX_REGISTERED_DEVICES } = require('./security-policy');

async function registerMessagingDevice(db, uid, data = {}) {
  const { installationId, fcmToken } = data || {};
  if (typeof installationId !== 'string' || installationId.length !== 48 ||
      !/^[0-9a-f]{48}$/.test(installationId)) {
    throw new HttpsError('invalid-argument', 'La identidad del dispositivo no es valida');
  }
  if (typeof fcmToken !== 'string' || fcmToken.length === 0 || fcmToken.length > 4096) {
    throw new HttpsError('invalid-argument', 'El token de notificaciones no es valido');
  }

  const deviceRef = db.collection('usuarios').doc(uid).collection('devices').doc(installationId);
  const registryRef = db.collection('deviceRegistries').doc(uid);
  const mergeRef = db.collection('accountMerges').doc(uid);

  await db.runTransaction(async (transaction) => {
    // The shared registry serializes registrations even when device IDs differ.
    await transaction.get(registryRef);
    const [merge, device] = await transaction.getAll(mergeRef, deviceRef);
    if (merge.exists) {
      throw new HttpsError('failed-precondition', 'La cuenta esta terminando un inicio de sesion');
    }
    const devices = await transaction.get(deviceRef.parent.limit(MAX_REGISTERED_DEVICES + 1));
    if (devices.size > MAX_REGISTERED_DEVICES) {
      throw new HttpsError('resource-exhausted', 'El registro supera el limite de dispositivos y requiere limpieza');
    }
    if (!device.exists && devices.size === MAX_REGISTERED_DEVICES) {
      const oldest = [...devices.docs].sort((left, right) => {
        const leftTime = left.get('tokenUpdatedAt');
        const rightTime = right.get('tokenUpdatedAt');
        const byTime = (rightTime?.seconds ?? 0) - (leftTime?.seconds ?? 0) ||
          (rightTime?.nanoseconds ?? 0) - (leftTime?.nanoseconds ?? 0);
        return byTime || (left.id < right.id ? -1 : left.id > right.id ? 1 : 0);
      }).at(-1);
      transaction.delete(oldest.ref);
    }

    transaction.set(deviceRef, { fcmToken, tokenUpdatedAt: FieldValue.serverTimestamp() });
    transaction.set(registryRef, {
      revision: FieldValue.increment(1),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
}

module.exports = { registerMessagingDevice };
