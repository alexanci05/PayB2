'use strict';

const assert = require('node:assert/strict');
const { after, beforeEach, test } = require('node:test');

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  test('Device registration requires the Firestore emulator', {
    skip: 'Run through firebase emulators:exec --only firestore.',
  }, () => {});
} else {
  const { initializeApp, deleteApp } = require('firebase-admin/app');
  const { getFirestore, Timestamp } = require('firebase-admin/firestore');
  const { registerMessagingDevice } = require('../lib/device-registration');
  const { MAX_REGISTERED_DEVICES } = require('../lib/security-policy');
  const projectId = 'demo-payb2-devices';
  const app = initializeApp({ projectId }, 'device-registration-tests');
  const db = getFirestore(app);
  const uid = 'owner-uid';
  const devices = db.collection('usuarios').doc(uid).collection('devices');
  const registry = db.collection('deviceRegistries').doc(uid);
  const id = (number) => number.toString(16).padStart(48, '0');
  const input = (number, fcmToken = `token-${number}`) => ({
    installationId: id(number), fcmToken,
  });

  beforeEach(async () => {
    const response = await fetch(
      `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
      { method: 'DELETE' },
    );
    assert.equal(response.ok, true);
  });

  after(async () => { await deleteApp(app); });

  async function seedDevices(count, sameTime = false) {
    await Promise.all(Array.from({ length: count }, (_, index) => (
      devices.doc(id(index)).set({
        fcmToken: `old-${index}`,
        tokenUpdatedAt: Timestamp.fromMillis(sameTime ? 1000 : (index + 1) * 1000),
      })
    )));
  }

  test('rejects malformed installation IDs and tokens without writing', async () => {
    for (const installationId of [undefined, null, 123, '', 'a'.repeat(47),
      'a'.repeat(49), 'A'.repeat(48), 'g'.repeat(48), `${id(1)}\n`, '../device']) {
      await assert.rejects(registerMessagingDevice(db, uid, {
        installationId, fcmToken: 'valid-token',
      }), { code: 'invalid-argument' });
    }
    for (const fcmToken of [undefined, null, 123, '', 't'.repeat(4097)]) {
      await assert.rejects(registerMessagingDevice(db, uid, {
        installationId: id(1), fcmToken,
      }), { code: 'invalid-argument' });
    }
    for (const data of [undefined, null, {}]) {
      await assert.rejects(registerMessagingDevice(db, uid, data), { code: 'invalid-argument' });
    }
    assert.equal((await devices.get()).size, 0);
    assert.equal((await registry.get()).exists, false);
  });

  test('registers under the trusted uid with server timestamps and no user parent document', async () => {
    await registerMessagingDevice(db, uid, { ...input(1, 't'.repeat(4096)), uid: 'victim-uid' });
    const device = await devices.doc(id(1)).get();
    const state = await registry.get();
    assert.equal(device.get('fcmToken').length, 4096);
    assert.ok(device.get('tokenUpdatedAt') instanceof Timestamp);
    assert.deepEqual(Object.keys(device.data()).sort(), ['fcmToken', 'tokenUpdatedAt']);
    assert.equal(state.get('revision'), 1);
    assert.ok(state.get('updatedAt').isEqual(device.get('tokenUpdatedAt')));
    assert.equal((await db.collection('usuarios').doc(uid).get()).exists, false);
    assert.equal((await db.collection('usuarios').doc('victim-uid').collection('devices').get()).size, 0);
  });

  test('a new installation evicts the oldest and retains the configured cap', async () => {
    await seedDevices(MAX_REGISTERED_DEVICES);
    await registerMessagingDevice(db, uid, input(99));
    assert.equal((await devices.get()).size, MAX_REGISTERED_DEVICES);
    assert.equal((await devices.doc(id(0)).get()).exists, false);
    assert.equal((await devices.doc(id(99)).get()).get('fcmToken'), 'token-99');
  });

  test('equal registration times are evicted deterministically by installation ID', async () => {
    await seedDevices(MAX_REGISTERED_DEVICES, true);
    await registerMessagingDevice(db, uid, input(99));
    assert.equal((await devices.doc(id(MAX_REGISTERED_DEVICES - 1)).get()).exists, false);
    assert.equal((await devices.get()).size, MAX_REGISTERED_DEVICES);
  });

  test('recency preserves timestamp precision below a millisecond', async () => {
    await seedDevices(MAX_REGISTERED_DEVICES);
    await devices.doc(id(0)).update({ tokenUpdatedAt: new Timestamp(1000, 3000) });
    await devices.doc(id(1)).update({ tokenUpdatedAt: new Timestamp(1000, 1000) });
    await devices.doc(id(2)).update({ tokenUpdatedAt: new Timestamp(1000, 2000) });
    await registerMessagingDevice(db, uid, input(99));
    assert.equal((await devices.doc(id(1)).get()).exists, false);
    assert.equal((await devices.doc(id(0)).get()).exists, true);
    assert.equal((await devices.doc(id(2)).get()).exists, true);
  });

  test('renewals at capacity refresh recency without evicting another device', async () => {
    await seedDevices(MAX_REGISTERED_DEVICES);
    await registerMessagingDevice(db, uid, input(0, 'renewed'));
    assert.equal((await devices.get()).size, MAX_REGISTERED_DEVICES);
    await registerMessagingDevice(db, uid, input(99));
    assert.equal((await devices.doc(id(0)).get()).get('fcmToken'), 'renewed');
    assert.equal((await devices.doc(id(1)).get()).exists, false);
    assert.equal((await registry.get()).get('revision'), 2);
  });

  test('concurrent registrations serialize eviction and both new installations survive', async () => {
    await seedDevices(MAX_REGISTERED_DEVICES);
    await Promise.all([
      registerMessagingDevice(db, uid, input(98)),
      registerMessagingDevice(db, uid, input(99)),
    ]);
    assert.equal((await devices.get()).size, MAX_REGISTERED_DEVICES);
    assert.equal((await devices.doc(id(98)).get()).exists, true);
    assert.equal((await devices.doc(id(99)).get()).exists, true);
    assert.equal((await registry.get()).get('revision'), 2);
  });

  test('oversized prior registries fail clearly without writes or eviction', async () => {
    await seedDevices(MAX_REGISTERED_DEVICES + 1);
    for (const number of [0, 99]) {
      await assert.rejects(registerMessagingDevice(db, uid, input(number)), {
        code: 'resource-exhausted',
      });
    }
    assert.equal((await devices.get()).size, MAX_REGISTERED_DEVICES + 1);
    assert.equal((await devices.doc(id(0)).get()).get('fcmToken'), 'old-0');
    assert.equal((await registry.get()).exists, false);
  });

  test('an account merge blocks both registrations and renewals in the transaction', async () => {
    await seedDevices(1);
    await db.collection('accountMerges').doc(uid).set({ status: 'prepared' });
    for (const number of [0, 99]) {
      await assert.rejects(registerMessagingDevice(db, uid, input(number)), {
        code: 'failed-precondition',
      });
    }
    assert.equal((await devices.get()).size, 1);
    assert.equal((await devices.doc(id(0)).get()).get('fcmToken'), 'old-0');
    assert.equal((await registry.get()).exists, false);
  });

  test('a directly deleted installation can be registered again', async () => {
    await registerMessagingDevice(db, uid, input(1));
    await devices.doc(id(1)).delete();
    await registerMessagingDevice(db, uid, input(1, 'new-token'));
    assert.equal((await devices.get()).size, 1);
    assert.equal((await devices.doc(id(1)).get()).get('fcmToken'), 'new-token');
    assert.equal((await registry.get()).get('revision'), 2);
  });
}
