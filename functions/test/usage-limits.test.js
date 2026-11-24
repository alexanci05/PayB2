'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { nextUsage, consumeCallableQuota, reserveProjectCapacity } = require('../lib/usage-limits');
const { PROJECT_CREATION_LIMITS } = require('../lib/security-policy');
const { secureCallable, isDemoEmulator } = require('../lib/secure-callable');

test('solo la suite demo completa y local puede omitir la acreditacion real', () => {
  const environment = {
    GCLOUD_PROJECT: 'demo-payb2',
    FUNCTIONS_EMULATOR: 'true',
    FIRESTORE_EMULATOR_HOST: '127.0.0.1:8080',
    FIREBASE_AUTH_EMULATOR_HOST: '127.0.0.1:9099',
  };
  assert.equal(isDemoEmulator('demo-payb2', environment), true);
  assert.equal(isDemoEmulator('payb2-5e89e', environment), false);
  for (const key of Object.keys(environment)) {
    assert.equal(isDemoEmulator('demo-payb2', { ...environment, [key]: undefined }), false);
  }
  assert.equal(isDemoEmulator('demo-payb2', { ...environment, GCLOUD_PROJECT: 'payb2-5e89e' }), false);
  assert.equal(isDemoEmulator('demo-payb2', { ...environment, FIRESTORE_EMULATOR_HOST: 'firestore.googleapis.com:443' }), false);
  assert.equal(isDemoEmulator('demo-payb2', { ...environment, FIREBASE_AUTH_EMULATOR_HOST: 'example.com:9099' }), false);
});

test('una callable exige sesión y App Check antes de consultar la base de datos', async () => {
  const fn = secureCallable({}, 'crearGrupo', () => assert.fail('No debe ejecutar el handler'));
  await assert.rejects(fn.run({}, { app: { appId: 'test-app' } }), { code: 'unauthenticated' });
  await assert.rejects(fn.run({}, { auth: { uid: 'test-user' } }), { code: 'failed-precondition' });
  assert.equal(fn.__endpoint.minInstances, 0);
  assert.equal(fn.__endpoint.maxInstances, 2);
});

test('las cuotas respetan el minuto, el día y el tipo de operación', () => {
  const now = Date.UTC(2026, 9, 21, 12);
  const first = nextUsage({}, 'crearGrupo', now, 2, 5, 1);
  assert.equal(first.minuteCount, 1);
  assert.throws(() => nextUsage(first, 'crearGrupo', now, 2, 5, 1), { code: 'resource-exhausted' });
  const second = nextUsage(first, 'crearGasto', now, 2, 5);
  assert.throws(() => nextUsage(second, 'crearGasto', now, 2, 5), { code: 'resource-exhausted' });
  assert.equal(nextUsage(second, 'crearGasto', now + 60_000, 2, 5).minuteCount, 1);
  const tomorrow = nextUsage(second, 'crearGrupo', now + 86400_000, 2, 5, 1);
  assert.equal(tomorrow.dayCount, 1);
  assert.equal(tomorrow.operations.crearGrupo, 1);
  assert.throws(() => nextUsage({ ...first, dayCount: 5 }, 'crearGasto', now, 2, 5), { code: 'resource-exhausted' });
  const laterWindow = nextUsage({}, 'crearGasto', now + 60_000, 1, 5);
  assert.throws(() => nextUsage(laterWindow, 'crearGasto', now, 1, 5), { code: 'resource-exhausted' });
});

test('las peticiones solo consumen la cuota de su cuenta, sin consultar un contador compartido', async () => {
  const now = Date.UTC(2026, 9, 21, 12);
  const writes = [];
  const db = {
    collection: () => ({ doc: (id) => ({ id }) }),
    runTransaction: (callback) => callback({
      get: async (ref) => {
        assert.match(ref.id, /^user_[a-f0-9]{64}$/);
        return { data: () => ({}) };
      },
      set: (...args) => writes.push(args),
    }),
  };
  await consumeCallableQuota(db, 'test-user', 'crearGrupo', now);
  assert.equal(writes.length, 1);
  assert.equal(writes[0][1].dayCount, 1);
});

test('la reserva de una creacion respeta el cupo global y no escribe si esta agotado', async () => {
  const now = Date.UTC(2026, 9, 21, 12);
  const writes = [];
  const db = { collection: () => ({ doc: (id) => ({ id }) }) };
  const transaction = {
    get: async (ref) => {
      assert.equal(ref.id, 'project');
      return { data: () => ({ minute: Math.floor(now / 60_000), minuteCount: PROJECT_CREATION_LIMITS.perMinute }) };
    },
    set: (...args) => writes.push(args),
  };
  await assert.rejects(reserveProjectCapacity(transaction, db, 'crearGrupo', now), { code: 'resource-exhausted' });
  assert.deepEqual(writes, []);
});
