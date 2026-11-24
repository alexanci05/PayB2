'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { sendNotificationToUser } = require('../lib/device-notifications');

function fixture(tokens = ['A', 'B']) {
  const records = new Map(tokens.map((token) => [`usuarios/user/devices/${token}`, { fcmToken: token }]));
  const snapshot = (path) => ({ get: (key) => records.get(path)?.[key] });
  const ref = (path) => ({
    path, get: async () => snapshot(path),
    set: async (data) => records.set(path, data),
    collection: (name) => collection(`${path}/${name}`),
  });
  const collection = (path, maximum = Infinity) => ({
    doc: (id) => { assert.ok(!id.includes('/')); return ref(`${path}/${id}`); },
    limit: (count) => collection(path, count),
    get: async () => ({ docs: [...records.keys()]
      .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
      .sort().slice(0, maximum)
      .map((key) => ({ ...snapshot(key), ref: ref(key), id: key.split('/').at(-1) })) }),
  });
  let queue = Promise.resolve();
  const db = { collection, runTransaction(callback) {
    const result = queue.then(async () => {
      const writes = [];
      const value = await callback({
        get: async (doc) => snapshot(doc.path),
        set: (doc, data) => writes.push(() => records.set(doc.path, data)),
        delete: (doc) => writes.push(() => records.delete(doc.path)),
      });
      writes.forEach((write) => write());
      return value;
    });
    queue = result.catch(() => {});
    return result;
  } };
  const send = (messaging, eventId = 'events/one', period) => sendNotificationToUser({
    db, messaging, uid: 'user', title: 'Title', body: 'Body', eventId, period,
  });
  return { send, records, db };
}

test('legacy device records cannot amplify one notification beyond three destinations', async () => {
  const { send } = fixture(['A', 'B', 'C', 'D', 'E']);
  const calls = [];
  await send({ send: async ({ token }) => calls.push(token) });
  assert.deepEqual(calls, ['A', 'B', 'C']);
});

test('partial retry sends only failed installation; distinct events deliver again', async () => {
  const { send, records } = fixture();
  const calls = [];
  let fail = true;
  const messaging = { send: async ({ token }) => {
    calls.push(token);
    if (token === 'B' && fail) throw new Error('temporary FCM failure');
  } };
  await assert.rejects(send(messaging), AggregateError);
  fail = false;
  await send(messaging);
  await send(messaging);
  assert.deepEqual(calls, ['A', 'B', 'B']);
  await send(messaging, 'events/two');
  assert.deepEqual(calls, ['A', 'B', 'B', 'A', 'B']);
  const deliveries = [...records.entries()].filter(([key]) => key.startsWith('eventNotificationDeliveries/'));
  assert.equal(deliveries.length, 4);
  assert.ok(deliveries.every(([key, value]) => /^eventNotificationDeliveries\/[a-f0-9]{64}$/.test(key) && value.status === 'sent'));
  for (const [, value] of deliveries) {
    assert.ok(value.expiresAt.toMillis() > Date.now() + 6 * 24 * 60 * 60 * 1000);
    assert.ok(value.expiresAt.toMillis() <= Date.now() + 7 * 24 * 60 * 60 * 1000);
  }
});

test('concurrent repeat fails retriably while leased, then skips accepted delivery', async () => {
  const { send } = fixture(['A']);
  let entered;
  let release;
  const started = new Promise((resolve) => { entered = resolve; });
  const blocked = new Promise((resolve) => { release = resolve; });
  let calls = 0;
  const messaging = { send: async () => { calls++; entered(); await blocked; } };
  const first = send(messaging);
  await started;
  try {
    await assert.rejects(send(messaging), (error) =>
      error instanceof AggregateError && error.errors[0].code === 'notifications/delivery-in-progress');
    assert.equal(calls, 1);
  } finally { release(); }
  await first;
  await send(messaging);
  assert.equal(calls, 1);
});

test('expired lease is reclaimed and late failure cannot delete its successor', async () => {
  const { send, records } = fixture(['A']);
  let entered, fail, calls = 0;
  const started = new Promise((resolve) => { entered = resolve; });
  const first = assert.rejects(send({ send: () => {
    entered(); return new Promise((resolve, reject) => { fail = reject; });
  } }), AggregateError);
  await started;
  const key = [...records.keys()].find((key) => key.startsWith('eventNotificationDeliveries/'));
  records.get(key).leaseUntil = 0;
  const messaging = { send: async () => { calls++; } };
  await send(messaging);
  fail(new Error('late FCM failure'));
  await first;
  await send(messaging);
  assert.equal(calls, 1);
  assert.equal(records.get(key).status, 'sent');
});

test('an unfinished reservation retains a seven-day expiry after its lease expires', async () => {
  const { send, records } = fixture(['A']);
  let entered;
  const started = new Promise((resolve) => { entered = resolve; });
  // Leave FCM unresolved to model a process dying without finalizing its reservation.
  void send({ send: () => { entered(); return new Promise(() => {}); } });
  await started;
  const pending = [...records.values()].find((value) => value.status === 'pending');
  assert.ok(pending);
  const expiry = pending.expiresAt.toMillis();
  assert.ok(expiry > Date.now() + 6 * 24 * 60 * 60 * 1000);
  assert.ok(expiry <= Date.now() + 7 * 24 * 60 * 60 * 1000);
  pending.leaseUntil = 0;
  assert.equal(pending.status, 'pending');
  assert.equal(pending.expiresAt.toMillis(), expiry);
});

test('invalid device tokens are removed and daily period deduplication remains unchanged', async () => {
  const { send, records } = fixture(['A', 'B']);
  const calls = [];
  const messaging = { send: async ({ token }) => {
    calls.push(token);
    if (token === 'B') throw Object.assign(new Error('invalid'), { code: 'messaging/registration-token-not-registered' });
  } };
  await send(messaging);
  assert.equal(records.has('usuarios/user/devices/B'), false);
  await send(messaging);
  assert.deepEqual(calls, ['A', 'B']);
  const daily = fixture(['A']);
  daily.records.set('usuarios/user', { fcmToken: 'ignored-root-token' });
  daily.records.set('reminderDeliveries/user', { period: '2026-10-16' });
  const dailyMessaging = { send: async ({ token }) => calls.push(token) };
  await daily.send(dailyMessaging, null, '2026-10-16');
  await daily.send(dailyMessaging, null, '2026-10-16');
  await daily.send(dailyMessaging, null, '2026-10-17');
  assert.deepEqual(calls, ['A', 'B', 'A', 'A']);
  assert.deepEqual(daily.records.get('usuarios/user'), { fcmToken: 'ignored-root-token' });
  assert.deepEqual(daily.records.get('reminderDeliveries/user'), { period: '2026-10-16' });
  assert.equal([...daily.records.keys()].some((key) => key.startsWith('eventNotificationDeliveries/')), false);
});

test('permanent payload/config failures checkpoint event and period without deleting healthy tokens', async (t) => {
  const warnings = [];
  t.mock.method(console, 'warn', (...args) => warnings.push(args));
  for (const code of ['messaging/invalid-argument', 'messaging/invalid-payload',
    'messaging/authentication-error', 'messaging/third-party-auth-error']) {
    const { send, records } = fixture(['private-token']);
    let calls = 0;
    const messaging = { send: async () => {
      calls++;
      throw Object.assign(new Error('private-token must never be logged'), { code });
    } };
    await send(messaging, 'events/one', '2026-10-26');
    await send(messaging, 'events/one');
    await send(messaging, null, '2026-10-26');
    assert.equal(calls, 1);
    assert.ok(records.has('usuarios/user/devices/private-token'));
    for (const prefix of ['eventNotificationDeliveries/', 'reminderDeliveries/']) {
      const checkpoint = [...records.entries()].find(([key]) => key.startsWith(prefix))[1];
      assert.equal(checkpoint.status, 'terminal');
      assert.equal(checkpoint.errorCode, code);
    }
    await send(messaging, 'events/two', '2026-10-27');
    assert.equal(calls, 2);
  }
  assert.ok(warnings.every((args) => !JSON.stringify(args).includes('private-token')));
  assert.equal(warnings[0][1].code, 'messaging/invalid-argument');
});

test('invalid, expired and wrong-project tokens remove only the exact failed token', async (t) => {
  t.mock.method(console, 'warn', () => {});
  for (const code of ['messaging/invalid-registration-token',
    'messaging/registration-token-not-registered', 'messaging/mismatched-credential']) {
    for (const renewed of [false, true]) {
      const { send, records } = fixture(['A']);
      let calls = 0;
      const messaging = { send: async () => {
        calls++;
        if (renewed) records.set('usuarios/user/devices/A', { fcmToken: 'renewed' });
        throw Object.assign(new Error('invalid token'), { code });
      } };
      await send(messaging);
      assert.equal(records.has('usuarios/user/devices/A'), renewed);
      if (renewed) assert.equal(records.get('usuarios/user/devices/A').fcmToken, 'renewed');
      await send(messaging);
      assert.equal(calls, 1);
      assert.equal([...records.values()].find((value) => value.status === 'terminal').errorCode, code);
    }
  }
});

test('transient and unknown FCM errors remain retryable and preserve partial terminal/sent results', async (t) => {
  t.mock.method(console, 'warn', () => {});
  for (const code of ['messaging/server-unavailable', 'messaging/internal-error',
    'messaging/message-rate-exceeded', 'messaging/unknown-error', undefined]) {
    const { send, records } = fixture(['A', 'B', 'C']);
    const calls = [];
    let fail = true;
    const messaging = { send: async ({ token }) => {
      calls.push(token);
      if (token === 'A') throw Object.assign(new Error('payload'), { code: 'messaging/invalid-argument' });
      if (token === 'C' && fail) throw Object.assign(new Error('retry'), { code });
    } };
    for (let attempt = 0; attempt < 4; attempt++) {
      await assert.rejects(send(messaging), (error) =>
        error instanceof AggregateError && error.errors.length === 1 && error.errors[0].code === code);
    }
    fail = false;
    await send(messaging);
    await send(messaging);
    assert.deepEqual(calls, ['A', 'B', 'C', 'C', 'C', 'C', 'C']);
    assert.equal(records.has('usuarios/user/devices/C'), true);
  }
});

test('Firestore cleanup failures propagate and release the event for retry', async (t) => {
  t.mock.method(console, 'warn', () => {});
  const { send, records, db } = fixture(['A']);
  const runTransaction = db.runTransaction.bind(db);
  let failCleanup = true;
  const failure = new Error('Firestore cleanup unavailable');
  db.runTransaction = (callback) => runTransaction((transaction) => callback({
    ...transaction,
    delete: (doc) => {
      if (failCleanup && doc.path.startsWith('usuarios/')) throw failure;
      return transaction.delete(doc);
    },
  }));
  const messaging = { send: async () => {
    throw Object.assign(new Error('invalid token'), { code: 'messaging/mismatched-credential' });
  } };
  await assert.rejects(send(messaging), (error) => error.errors[0] === failure);
  assert.equal(records.has('usuarios/user/devices/A'), true);
  assert.equal([...records.keys()].some((key) => key.startsWith('eventNotificationDeliveries/')), false);
  failCleanup = false;
  await send(messaging);
  assert.equal(records.has('usuarios/user/devices/A'), false);
});

test('post-FCM checkpoint failures propagate, preserve tokens and keep event/daily writes atomic', async (t) => {
  t.mock.method(console, 'warn', () => {});
  for (const permanent of [false, true]) {
    const { send, records, db } = fixture(['A']);
    const runTransaction = db.runTransaction.bind(db);
    const failure = Object.assign(new Error('Firestore write failure'), {
      code: 'messaging/invalid-registration-token',
    });
    let failCheckpoint = true;
    db.runTransaction = (callback) => runTransaction((transaction) => callback({
      ...transaction,
      set: (doc, data) => {
        if (failCheckpoint && doc.path.startsWith('reminderDeliveries/')) throw failure;
        return transaction.set(doc, data);
      },
    }));
    let calls = 0;
    const messaging = { send: async () => {
      calls++;
      if (permanent) throw Object.assign(new Error('payload'), { code: 'messaging/invalid-argument' });
    } };
    await assert.rejects(send(messaging, 'events/one', '2026-10-26'),
      (error) => error.errors[0] === failure);
    assert.ok(records.has('usuarios/user/devices/A'));
    const event = [...records.values()].find((value) => value.status === 'pending');
    assert.ok(event);
    assert.equal([...records.keys()].some((key) => key.startsWith('reminderDeliveries/')), false);
    await assert.rejects(send(messaging, 'events/one', '2026-10-26'), AggregateError);
    assert.equal(calls, 1);
    event.leaseUntil = 0;
    failCheckpoint = false;
    await send(messaging, 'events/one', '2026-10-26');
    await send(messaging, 'events/one', '2026-10-26');
    assert.equal(calls, 2);
    assert.equal([...records.values()].find((value) => value.period)?.status,
      permanent ? 'terminal' : undefined);
  }
});
