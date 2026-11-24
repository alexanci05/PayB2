'use strict';

const assert = require('node:assert/strict');
const { randomBytes } = require('node:crypto');
const { test } = require('node:test');

function localRequest(url, options = {}) {
  return fetch(url, { ...options, signal: AbortSignal.timeout(20_000) });
}

test('la suite demo conecta Auth, callables y reglas sin un proyecto real', {
  skip: process.env.PAYB2_DEMO_SMOKE !== 'true',
  timeout: 60_000,
}, async () => {
  assert.equal(process.env.GCLOUD_PROJECT, 'demo-payb2');
  assert.equal(process.env.FIRESTORE_EMULATOR_HOST, '127.0.0.1:8080');
  assert.equal(process.env.FIREBASE_AUTH_EMULATOR_HOST, '127.0.0.1:9099');

  const session = await localRequest('http://127.0.0.1:9099/identitytoolkit.googleapis.com/v1/accounts:signUp?key=demo-key', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ returnSecureToken: true }),
  });
  assert.equal(session.status, 200);
  const { idToken, localId } = await session.json();
  const url = 'http://127.0.0.1:5001/demo-payb2/us-central1/crearGrupo';
  const request = {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ data: {
      nombre: 'Grupo local', miembros: ['Ana', 'Luis'], timeZone: 'Europe/Madrid',
      requestId: randomBytes(10).toString('hex'),
    } }),
  };
  assert.equal((await localRequest(url, request)).status, 401);
  const response = await localRequest(url, {
    ...request,
    headers: { ...request.headers, Authorization: `Bearer ${idToken}` },
  });
  const body = await response.json();
  assert.equal(response.status, 200, JSON.stringify(body));
  assert.equal(typeof body.result.groupId, 'string');

  const document = `http://127.0.0.1:8080/v1/projects/demo-payb2/databases/(default)/documents/groups/${body.result.groupId}`;
  const group = await localRequest(document, { headers: { Authorization: `Bearer ${idToken}` } });
  assert.equal(group.status, 200);
  assert.equal((await group.json()).fields.ownerDeviceId.stringValue, localId);
  assert.equal((await localRequest(document)).status, 403);
});
