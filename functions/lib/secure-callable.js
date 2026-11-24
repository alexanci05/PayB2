'use strict';

const functions = require('firebase-functions/v1');
const { CALLABLE_OPTIONS } = require('./security-policy');
const { consumeCallableQuota } = require('./usage-limits');

function isDemoEmulator(projectId, environment = process.env) {
  return projectId === 'demo-payb2'
    && environment.GCLOUD_PROJECT === projectId
    && environment.FUNCTIONS_EMULATOR === 'true'
    && /^(127\.0\.0\.1|localhost):\d+$/.test(environment.FIRESTORE_EMULATOR_HOST || '')
    && /^(127\.0\.0\.1|localhost):\d+$/.test(environment.FIREBASE_AUTH_EMULATOR_HOST || '');
}

function secureCallable(db, operation, handler) {
  // App Check has no emulator; only the isolated demo suite can omit it.
  const localDemo = process.env.FUNCTIONS_EMULATOR === 'true'
    && isDemoEmulator(db.projectId);
  const options = { ...CALLABLE_OPTIONS, enforceAppCheck: !localDemo };
  return functions.runWith(options).https.onCall(async (data, context) => {
    if (!context.auth) {
      throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
    }
    if (!localDemo && !context.app?.appId) {
      throw new functions.https.HttpsError('failed-precondition', 'No se pudo verificar la aplicación');
    }
    await consumeCallableQuota(db, context.auth.uid, operation);
    return handler(data, context);
  });
}

module.exports = { secureCallable, isDemoEmulator };
