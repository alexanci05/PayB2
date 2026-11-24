'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { after, beforeEach, test } = require('node:test');

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  test('account merge security requires the Firestore emulator', {
    skip: 'Run through firebase emulators:exec --only firestore.',
  }, () => {});
} else {
  const { initializeApp, deleteApp } = require('firebase-admin/app');
  const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
  const {
    AccountMergeConflictError,
    activateAccountMerge,
    cancelAccountMerge,
    completeAccountMerge,
    mergeAnonymousAccountData,
    prepareAccountMerge,
  } = require('../lib/account-merge');
  const { registerMessagingDevice } = require('../lib/device-registration');
  const { MAX_REGISTERED_DEVICES } = require('../lib/security-policy');
  // Separate namespace: these tests can run beside the existing integration suite.
  const projectId = 'demo-payb2-merge-security';
  const app = initializeApp({ projectId }, 'account-merge-security');
  const db = getFirestore(app);
  const ticketRef = (ticket) => db.collection('accountMergeTickets')
    .doc(createHash('sha256').update(ticket).digest('hex'));
  const devices = (uid) => db.collection('usuarios').doc(uid).collection('devices');

  beforeEach(async () => {
    const response = await fetch(
      `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
      { method: 'DELETE' },
    );
    assert.equal(response.ok, true);
  });

  after(async () => {
    await db.terminate();
    await deleteApp(app);
  });

  async function activeTicket(source = 'source') {
    const ticket = await prepareAccountMerge(db, source);
    await activateAccountMerge(db, source, ticket);
    return ticket;
  }

  async function seedGroup(id, source = 'source') {
    await db.doc(`groups/${id}`).set({ ownerDeviceId: source });
    await db.doc(`groupMembers/${id}_${source}`).set({ groupId: id, deviceId: source });
  }

  async function seedDevice(uid, id, seconds, nanoseconds = 0) {
    await devices(uid).doc(id).set({
      fcmToken: `${uid}-${id}`,
      tokenUpdatedAt: new Timestamp(seconds, nanoseconds),
    });
  }

  function pauseQueryOnce(context, query) {
    const prototype = Object.getPrototypeOf(query);
    const get = prototype.get;
    let enter;
    let release;
    let reads = 0;
    const reached = new Promise((resolve) => { enter = resolve; });
    const released = new Promise((resolve) => { release = resolve; });
    context.mock.method(prototype, 'get', async function (...args) {
      const snapshot = await get.apply(this, args);
      if (this.isEqual(query)) {
        reads += 1;
        if (reads === 1) {
          enter();
          await released;
        }
      }
      return snapshot;
    });
    return { reached, release, reads: () => reads };
  }

  test('concurrent preparation is singleton and activation/recovery is idempotent', async () => {
    const tickets = await Promise.all(Array.from({ length: 3 }, () => prepareAccountMerge(db, 'source')));
    assert.equal(new Set(tickets).size, 1);
    assert.equal((await db.collection('accountMergeTickets').get()).size, 1);
    const [ticket] = tickets;
    const preparation = await db.doc('accountMergePreparations/source').get();
    assert.equal(preparation.get('ticket'), ticket);
    assert.equal(preparation.get('ticketId'), ticketRef(ticket).id);

    await activateAccountMerge(db, 'source', ticket);
    await ticketRef(ticket).update({ expiresAt: Timestamp.fromMillis(0) });
    const lock = (await db.doc('accountMerges/source').get()).data();
    await activateAccountMerge(db, 'source', ticket);
    assert.equal(await prepareAccountMerge(db, 'source'), ticket);
    assert.deepEqual((await db.doc('accountMerges/source').get()).data(), lock);
    assert.equal(JSON.stringify(lock).includes(ticket), false);
    assert.equal(JSON.stringify((await ticketRef(ticket).get()).data()).includes(ticket), false);
    await assert.rejects(activateAccountMerge(db, 'foreign', ticket), AccountMergeConflictError);
  });

  test('expired and canceled preparations cannot replace or cancel the current ticket', async () => {
    const expired = await prepareAccountMerge(db, 'source');
    await ticketRef(expired).update({ expiresAt: Timestamp.fromMillis(0) });
    const current = await prepareAccountMerge(db, 'source');
    assert.notEqual(current, expired);
    assert.equal((await ticketRef(expired).get()).get('status'), 'expired');
    await assert.rejects(activateAccountMerge(db, 'source', expired), AccountMergeConflictError);
    await assert.rejects(cancelAccountMerge(db, 'foreign', current), AccountMergeConflictError);
    await activateAccountMerge(db, 'source', current);
    await cancelAccountMerge(db, 'source', current);
    await cancelAccountMerge(db, 'source', current);
    const replacement = await prepareAccountMerge(db, 'source');
    await cancelAccountMerge(db, 'source', current);
    assert.equal(await prepareAccountMerge(db, 'source'), replacement);
    assert.equal((await db.doc('accountMerges/source').get()).exists, false);
  });

  test('same-UID completion leaves the ticket untouched and the source can cancel', async () => {
    await seedGroup('group');
    await seedDevice('source', 'device', 1);
    const ticket = await activeTicket();
    const ticketBefore = (await ticketRef(ticket).get()).data();
    const mergeBefore = (await db.doc('accountMerges/source').get()).data();
    const preparationBefore = (await db.doc('accountMergePreparations/source').get()).data();

    await assert.rejects(completeAccountMerge(db, ticket, 'source'), (error) =>
      error instanceof AccountMergeConflictError && error.reason === 'same-account');

    assert.deepEqual((await ticketRef(ticket).get()).data(), ticketBefore);
    assert.deepEqual((await db.doc('accountMerges/source').get()).data(), mergeBefore);
    assert.deepEqual((await db.doc('accountMergePreparations/source').get()).data(), preparationBefore);
    assert.equal((await db.doc('deviceRegistries/source').get()).exists, false);
    assert.equal((await devices('source').get()).size, 1);
    assert.equal((await db.doc('groups/group').get()).get('ownerDeviceId'), 'source');
    assert.equal(await prepareAccountMerge(db, 'source'), ticket);
    await activateAccountMerge(db, 'source', ticket);
    await cancelAccountMerge(db, 'source', ticket);
    assert.equal((await ticketRef(ticket).get()).get('status'), 'canceled');
    assert.equal((await db.doc('accountMerges/source').get()).exists, false);
    assert.equal((await db.doc('accountMergePreparations/source').get()).exists, false);
  });

  test('same-UID rejection still permits completion to a different bound target', async () => {
    await seedGroup('group');
    await seedDevice('source', 'device', 1);
    const ticket = await activeTicket();
    await assert.rejects(completeAccountMerge(db, ticket, 'source'), (error) =>
      error instanceof AccountMergeConflictError && error.reason === 'same-account');
    assert.equal((await ticketRef(ticket).get()).get('targetUid'), undefined);
    assert.equal((await ticketRef(ticket).get()).get('status'), 'active');

    assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 1 });
    const completedTicket = (await ticketRef(ticket).get()).data();
    assert.equal(completedTicket.targetUid, 'target');
    assert.equal(completedTicket.status, 'completed');
    assert.equal((await devices('source').get()).empty, true);
    assert.equal((await devices('target').get()).size, 1);
    assert.equal((await db.doc('groups/group').get()).get('ownerDeviceId'), 'target');
    assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 1 });
    await assert.rejects(completeAccountMerge(db, ticket, 'source'), AccountMergeConflictError);
    await assert.rejects(completeAccountMerge(db, ticket, 'other'), AccountMergeConflictError);
    assert.deepEqual((await ticketRef(ticket).get()).data(), completedTicket);
  });

  test('merge keeps groups and the newest device union; completed replay is read-only', async () => {
    assert.equal(MAX_REGISTERED_DEVICES, 3);
    await seedGroup('group');
    await db.doc('usuarios/source').set({ session: 'source-session' });
    await db.doc('usuarios/target').set({ session: 'target-session' });
    await seedDevice('source', 'a', 1);
    await seedDevice('source', 'b', 6);
    await seedDevice('source', 'c', 7);
    await seedDevice('target', 'b', 5);
    await seedDevice('target', 'd', 2);
    await seedDevice('target', 'e', 8);
    const ticket = await activeTicket();
    assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 1 });
    assert.deepEqual((await devices('target').get()).docs.map((doc) => doc.id), ['b', 'c', 'e']);
    assert.equal((await devices('target').doc('b').get()).get('fcmToken'), 'source-b');
    assert.equal((await devices('source').get()).empty, true);
    assert.equal((await db.doc('groups/group').get()).get('ownerDeviceId'), 'target');
    assert.equal((await db.doc('usuarios/source').get()).get('session'), 'source-session');
    assert.equal((await db.doc('usuarios/target').get()).get('session'), 'target-session');

    const readOnlyReplayDb = {
      collection(name) {
        assert.equal(name, 'accountMergeTickets', 'completed replay must not reserve or migrate');
        return db.collection(name);
      },
      runTransaction(callback) {
        return db.runTransaction((transaction) => callback({
          get: transaction.get.bind(transaction),
          update: () => assert.fail('completed replay must not write'),
        }));
      },
    };
    assert.deepEqual(await completeAccountMerge(readOnlyReplayDb, ticket, 'target'), { mergedGroups: 1 });
    await assert.rejects(completeAccountMerge(db, ticket, 'other'), AccountMergeConflictError);
    await assert.rejects(cancelAccountMerge(db, 'source', ticket), AccountMergeConflictError);
    await assert.rejects(prepareAccountMerge(db, 'source'), AccountMergeConflictError);
    assert.deepEqual((await devices('target').get()).docs.map((doc) => doc.id), ['b', 'c', 'e']);
  });

  test('lost ticket-finalization write recovers the original completed merge result', async () => {
    await seedGroup('group');
    const ticket = await activeTicket();
    await completeAccountMerge(db, ticket, 'target');
    const completedMerge = (await db.doc('accountMerges/source').get()).data();
    await ticketRef(ticket).update({ status: 'running', result: FieldValue.delete() });
    assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 1 });
    assert.deepEqual((await db.doc('accountMerges/source').get()).data(), completedMerge);
    assert.deepEqual((await ticketRef(ticket).get()).get('result'), { mergedGroups: 1 });
  });

  test('partial migration retries preserve the original result and target binding', async () => {
    await seedGroup('a');
    await db.doc('groupMembers/b_source').set({ groupId: 'b', deviceId: 'source' });
    const ticket = await activeTicket();
    await assert.rejects(completeAccountMerge(db, ticket, 'target'), /El grupo b no existe/);
    const failedMerge = await db.doc('accountMerges/source').get();
    assert.equal(failedMerge.get('leaseOwner'), undefined);
    assert.equal(failedMerge.get('leaseExpiresAt'), undefined);
    assert.equal((await db.doc('groupMembers/a_source').get()).exists, false);
    await assert.rejects(prepareAccountMerge(db, 'source'), AccountMergeConflictError);
    await assert.rejects(cancelAccountMerge(db, 'source', ticket), AccountMergeConflictError);
    await assert.rejects(completeAccountMerge(db, ticket, 'other'), AccountMergeConflictError);
    await db.doc('groups/b').set({ ownerDeviceId: 'source' });
    assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 2 });
  });

  test('same-ticket completion reserves one traversal and rejects overlapping callers', async (context) => {
    await seedGroup('group');
    const ticket = await activeTicket();
    const memberships = db.collection('groupMembers').where('deviceId', '==', 'source').limit(450);
    const pause = pauseQueryOnce(context, memberships);
    const first = completeAccountMerge(db, ticket, 'target');
    await pause.reached;
    try {
      const merge = await db.doc('accountMerges/source').get();
      assert.equal(typeof merge.get('leaseOwner'), 'string');
      assert.ok(merge.get('leaseExpiresAt').toMillis() - Date.now() > 60_000);
      await assert.rejects(completeAccountMerge(db, ticket, 'target'), (error) =>
        error instanceof AccountMergeConflictError && error.reason === 'merge-in-progress');
      await assert.rejects(completeAccountMerge(db, ticket, 'other'), AccountMergeConflictError);
      await assert.rejects(cancelAccountMerge(db, 'source', ticket), AccountMergeConflictError);
      assert.equal(pause.reads(), 1, 'the rejected invocation must not scan memberships');
      assert.equal((await db.doc('deviceRegistries/source').get()).get('revision'), 1);
    } finally {
      pause.release();
      assert.deepEqual(await first, { mergedGroups: 1 });
    }
    const merge = await db.doc('accountMerges/source').get();
    assert.equal(merge.get('leaseOwner'), undefined);
    assert.equal(merge.get('leaseExpiresAt'), undefined);
    assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 1 });
  });

  test('an expired lease can be taken over and fences stale migration writes and cleanup', async (context) => {
    await seedGroup('group');
    const expense = db.doc('groups/group/gastos/expense');
    await expense.set({ createdByUid: 'source', nombre: 'Cena' });
    const ticket = await activeTicket();
    const expenses = db.collection('groups').doc('group').collection('gastos')
      .where('createdByUid', '==', 'source').limit(450);
    const pause = pauseQueryOnce(context, expenses);
    const first = completeAccountMerge(db, ticket, 'target');
    const rejectedFirst = assert.rejects(first, (error) =>
      error instanceof AccountMergeConflictError && error.reason === 'merge-lease-lost');
    await pause.reached;
    const mergeRef = db.doc('accountMerges/source');
    const originalOwner = (await mergeRef.get()).get('leaseOwner');
    await mergeRef.update({ leaseExpiresAt: Timestamp.fromMillis(0) });
    try {
      assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 1 });
      const completedMerge = (await mergeRef.get()).data();
      const completedTicket = (await ticketRef(ticket).get()).data();
      assert.equal((await expense.get()).get('createdByUid'), 'target');
      assert.equal(completedMerge.leaseOwner, undefined);
      assert.notEqual(originalOwner, undefined);
      pause.release();
      await rejectedFirst;
      assert.deepEqual((await mergeRef.get()).data(), completedMerge,
        'the old owner must not clear or overwrite the completed merge');
      assert.deepEqual((await ticketRef(ticket).get()).data(), completedTicket);
      assert.equal((await db.doc('groupMembers/group_source').get()).exists, false);
      assert.equal((await db.doc('groupMembers/group_target').get()).exists, true);
    } finally {
      pause.release();
      await rejectedFirst;
    }
  });

  test('a failed page read releases its lease for an immediate retry without rebinding the ticket', async (context) => {
    await seedGroup('group');
    const ticket = await activeTicket();
    const memberships = db.collection('groupMembers').where('deviceId', '==', 'source').limit(450);
    const prototype = Object.getPrototypeOf(memberships);
    const get = prototype.get;
    let fail = true;
    context.mock.method(prototype, 'get', async function (...args) {
      if (fail && this.isEqual(memberships)) {
        fail = false;
        throw new Error('transient membership read failure');
      }
      return get.apply(this, args);
    });
    await assert.rejects(completeAccountMerge(db, ticket, 'target'), /transient membership read failure/);
    const failedMerge = (await db.doc('accountMerges/source').get()).data();
    assert.equal(failedMerge.status, 'running');
    assert.equal(failedMerge.targetUid, 'target');
    assert.equal(failedMerge.leaseOwner, undefined);
    assert.equal(failedMerge.leaseExpiresAt, undefined);
    assert.equal((await ticketRef(ticket).get()).get('targetUid'), 'target');
    await assert.rejects(completeAccountMerge(db, ticket, 'other'), AccountMergeConflictError);
    await assert.rejects(cancelAccountMerge(db, 'source', ticket), AccountMergeConflictError);
    assert.deepEqual(await completeAccountMerge(db, ticket, 'target'), { mergedGroups: 1 });
  });

  test('concurrent registrations and merges share the device registry lock', async () => {
    for (const uid of ['source-a', 'source-b', 'target']) {
      for (let index = 0; index < 3; index++) await seedDevice(uid, `${uid}-${index}`, index + 1);
    }
    const installationId = 'a'.repeat(48);
    await Promise.all([
      mergeAnonymousAccountData(db, 'source-a', 'target'),
      mergeAnonymousAccountData(db, 'source-b', 'target'),
      registerMessagingDevice(db, 'target', { installationId, fcmToken: 'fresh-token' }),
    ]);
    const targetDevices = await devices('target').get();
    assert.equal(targetDevices.size, MAX_REGISTERED_DEVICES);
    assert.ok(targetDevices.docs.some((doc) => doc.id === installationId));
    assert.equal((await devices('source-a').get()).empty, true);
    assert.equal((await devices('source-b').get()).empty, true);
    assert.equal((await db.doc('deviceRegistries/target').get()).get('revision'), 3);
  });

  test('merge ignores a device deleted between discovery and its transactional reread', async (context) => {
    await seedDevice('source', 'retained', 2);
    await seedDevice('target', 'deleted', 1);
    const query = devices('target').limit(MAX_REGISTERED_DEVICES + 1);
    const prototype = Object.getPrototypeOf(query);
    const get = prototype.get;
    let deleted = false;
    context.mock.method(prototype, 'get', async function (...args) {
      const snapshot = await get.apply(this, args);
      if (!deleted && this.isEqual(query)) {
        deleted = true;
        await devices('target').doc('deleted').delete();
      }
      return snapshot;
    });

    await mergeAnonymousAccountData(db, 'source', 'target');
    assert.equal(deleted, true);
    assert.deepEqual((await devices('target').get()).docs.map((doc) => doc.id), ['retained']);
    assert.equal((await devices('source').get()).empty, true);
  });

  test('oversized registries fail clearly without partially migrating devices or groups', async () => {
    for (const oversizedSide of ['source', 'target']) {
      const source = `source-over-${oversizedSide}`;
      const target = `target-over-${oversizedSide}`;
      const groupId = `group-over-${oversizedSide}`;
      await seedGroup(groupId, source);
      for (const [side, uid] of [['source', source], ['target', target]]) {
        const count = side === oversizedSide ? MAX_REGISTERED_DEVICES + 1 : 1;
        for (let index = 0; index < count; index++) await seedDevice(uid, `${side}-${index}`, index + 1);
      }
      const sourceBefore = (await devices(source).get()).docs.map((doc) => doc.data());
      const targetBefore = (await devices(target).get()).docs.map((doc) => doc.data());
      const ticket = await activeTicket(source);
      const lockBefore = (await db.doc(`accountMerges/${source}`).get()).data();

      await assert.rejects(completeAccountMerge(db, ticket, target), (error) =>
        error instanceof AccountMergeConflictError &&
        /limite de dispositivos.*datos antiguos de desarrollo/.test(error.message));

      assert.deepEqual((await devices(source).get()).docs.map((doc) => doc.data()), sourceBefore);
      assert.deepEqual((await devices(target).get()).docs.map((doc) => doc.data()), targetBefore);
      assert.deepEqual((await db.doc(`accountMerges/${source}`).get()).data(), lockBefore);
      assert.equal((await db.doc(`groups/${groupId}`).get()).get('ownerDeviceId'), source);
      assert.equal((await db.doc(`groupMembers/${groupId}_${source}`).get()).exists, true);
      assert.equal((await db.doc(`groupMembers/${groupId}_${target}`).get()).exists, false);
      assert.equal((await db.doc(`deviceRegistries/${source}`).get()).exists, false);
      assert.equal((await db.doc(`deviceRegistries/${target}`).get()).exists, false);
    }
  });
}
