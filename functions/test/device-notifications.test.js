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
  const collection = (path) => ({
    doc: (id) => { assert.ok(!id.includes('/')); return ref(`${path}/${id}`); },
    get: async () => ({ docs: [...records.keys()]
      .filter((key) => key.startsWith(`${path}/`) && !key.slice(path.length + 1).includes('/'))
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
  return { send, records };
}

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
