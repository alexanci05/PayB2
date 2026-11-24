'use strict';

const assert = require('node:assert/strict');
const { test } = require('node:test');
const { initializeApp, deleteApp } = require('firebase-admin/app');
const { getFirestore, FieldValue } = require('firebase-admin/firestore');

test('the pinned Firestore transport supports backend operations and listeners', {
  skip: !process.env.FIRESTORE_EMULATOR_HOST,
  timeout: 30_000,
}, async () => {
  // Never permit this compatibility test to fall back to a real project.
  assert.match(process.env.FIRESTORE_EMULATOR_HOST, /^(127\.0\.0\.1|localhost|\[::1\]):\d+$/);
  const app = initializeApp({ projectId: 'demo-payb2-sdk-compat' }, 'sdk-compat');
  const db = getFirestore(app);
  const collection = db.collection(`transport_${process.pid}`);
  let unsubscribe;
  try {
    const a = collection.doc('a');
    const b = collection.doc('b');
    await a.set({ value: 1, createdAt: FieldValue.serverTimestamp() });
    assert.equal((await a.get()).get('value'), 1);
    assert.equal(typeof (await a.get()).get('createdAt').toMillis(), 'number');
    await db.batch().set(b, { value: 2 }).update(a, { value: 3 }).commit();
    assert.deepEqual((await collection.orderBy('value').get()).docs.map(doc => doc.get('value')), [2, 3]);
    assert.equal((await collection.count().get()).data().count, 2);
    await db.runTransaction(async transaction => {
      const snapshot = await transaction.get(a);
      transaction.update(a, { value: snapshot.get('value') + 1 });
    });
    const streamed = [];
    for await (const document of collection.orderBy('value').stream()) streamed.push(document.get('value'));
    assert.deepEqual(streamed, [2, 4]);

    let timer;
    await new Promise((resolve, reject) => {
      timer = setTimeout(() => reject(new Error('Firestore listener timed out')), 10_000);
      unsubscribe = a.onSnapshot(snapshot => {
        if (snapshot.get('value') === 5) resolve();
      }, reject);
      a.update({ value: 5 }).catch(reject);
    }).finally(() => clearTimeout(timer));
    unsubscribe();
    unsubscribe = undefined;
    await b.delete();
    assert.equal((await b.get()).exists, false);
  } finally {
    if (unsubscribe) unsubscribe();
    await db.recursiveDelete(collection);
    await db.terminate();
    await deleteApp(app);
  }
});
