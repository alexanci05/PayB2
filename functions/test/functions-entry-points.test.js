'use strict';

const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const { after, beforeEach, test } = require('node:test');

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  test('Functions entry points require the Firestore emulator', { skip: 'Run through firebase emulators:exec --only firestore.' }, () => {});
} else {
  process.env.GCLOUD_PROJECT ||= 'demo-payb2-functions';

  const { deleteApp, getApp } = require('firebase-admin/app');
  const { getFirestore, Timestamp } = require('firebase-admin/firestore');
  const { getMessaging } = require('firebase-admin/messaging');
  const exportedFunctions = require('../index');
  // Direct .run calls represent requests whose App Check token was verified by the SDK.
  const entryPoints = Object.fromEntries(Object.entries(exportedFunctions).map(([name, fn]) => [
    name,
    fn.__endpoint?.callableTrigger ? {
      run: (data, context) => fn.run(data, { app: { appId: 'test-app' }, ...context }),
    } : fn,
  ]));
  const { scheduledOccurrenceId, scheduleInstant, nextScheduledDate, todayInZone } = require('../lib/scheduled-occurrences');
  const {
    MAX_OCCURRENCES_PER_DAY, MAX_OCCURRENCES_PER_GROUP_PER_DAY,
    MAX_SCHEDULED_GROUPS_PER_RUN,
  } = require('../lib/security-policy');
  const {
    AccountMergeConflictError,
    activateAccountMerge,
    cancelAccountMerge,
    completeAccountMerge,
    mergeAnonymousAccountData,
    prepareAccountMerge,
  } = require('../lib/account-merge');
  const db = getFirestore();
  const { runDebtReminders, REMINDER_LIMITS } = require('../lib/debt-reminders');
  const projectId = process.env.GCLOUD_PROJECT;

  beforeEach(async () => {
    const response = await fetch(
      `http://${process.env.FIRESTORE_EMULATOR_HOST}/emulator/v1/projects/${projectId}/databases/(default)/documents`,
      { method: 'DELETE' },
    );
    assert.equal(response.ok, true, `Unable to clear Firestore emulator: ${response.status}`);
  });

  after(async () => {
    await deleteApp(getApp());
  });

  async function seedExpenseGroup() {
    const groupRef = db.collection('groups').doc('expense-group');
    await Promise.all([
      groupRef.set({ name: 'Viaje', ownerDeviceId: 'payer-uid', timeZone: 'Europe/Madrid' }),
      db.collection('groupMembers').doc('expense-group_payer-uid').set({
        groupId: 'expense-group',
        deviceId: 'payer-uid',
      }),
      groupRef.collection('members').doc('payer').set({ name: 'Ana', reclamadoPor: 'payer-uid' }),
      groupRef.collection('members').doc('alice').set({ name: 'Alice', reclamadoPor: null }),
      groupRef.collection('members').doc('bob').set({ name: 'Bob', reclamadoPor: null }),
      groupRef.collection('members').doc('other-payer').set({ name: 'Luis', reclamadoPor: 'other-uid' }),
    ]);
    return groupRef;
  }

  async function seedClaimGroup() {
    const groupRef = db.collection('groups').doc('claim-group');
    const membershipRef = db.collection('groupMembers').doc('claim-group_claimant-uid');
    await Promise.all([
      groupRef.set({ name: 'Viaje', ownerDeviceId: 'owner-uid' }),
      membershipRef.set({ groupId: 'claim-group', deviceId: 'claimant-uid' }),
      groupRef.collection('members').doc('alice').set({ name: 'Alice', reclamadoPor: null }),
      groupRef.collection('members').doc('bob').set({ name: 'Bob', reclamadoPor: null }),
      groupRef.collection('members').doc('taken').set({ name: 'Taken', reclamadoPor: 'other-uid' }),
    ]);
    return { groupRef, membershipRef };
  }

  function claim(memberId, uid = 'claimant-uid') {
    return entryPoints.reclamarMiembro.run(
      { groupId: 'claim-group', memberId },
      { auth: { uid } },
    );
  }

  function expenseInput(overrides = {}) {
    return {
      requestId: db.collection('groups').doc().id,
      groupId: 'expense-group',
      nombre: 'Cena',
      descripcion: 'Cena del viaje',
      cantidadCentimos: 1001,
      fecha: '2024-01-31',
      pagadoPor: 'payer',
      participantes: ['alice', 'bob'],
      frecuencia: null,
      ...overrides,
    };
  }

  async function assertNoExpenseWrites(groupRef) {
    const [expenses, schedules, requests] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
      groupRef.collection('expenseRequests').get(),
    ]);
    assert.equal(expenses.size, 0);
    assert.equal(schedules.size, 0);
    assert.equal(requests.size, 0);
  }

  function groupInput(overrides = {}) {
    return {
      requestId: db.collection('groups').doc().id, nombre: 'Viaje',
      miembros: ['Ana', 'Luis'], timeZone: 'Europe/Madrid', ...overrides,
    };
  }

  async function assertNoGroupCreationWrites() {
    const [groups, codes, memberships, requests] = await Promise.all([
      db.collection('groups').get(),
      db.collection('groupCodes').get(),
      db.collection('groupMembers').get(),
      db.collection('groupCreationRequests').get(),
    ]);
    assert.equal(groups.size, 0);
    assert.equal(codes.size, 0);
    assert.equal(memberships.size, 0);
    assert.equal(requests.size, 0);
  }

  async function assertSingleCreatedGroup(result) {
    const [groups, codes, memberships, members] = await Promise.all([
      db.collection('groups').get(),
      db.collection('groupCodes').get(),
      db.collection('groupMembers').get(),
      db.collection('groups').doc(result.groupId).collection('members').get(),
    ]);
    assert.deepEqual(groups.docs.map((doc) => doc.id), [result.groupId]);
    assert.deepEqual(codes.docs.map((doc) => doc.id), [result.groupCode]);
    assert.deepEqual(memberships.docs.map((doc) => doc.id), [`${result.groupId}_owner-uid`]);
    assert.equal(groups.docs[0].get('groupCode'), result.groupCode);
    assert.equal(codes.docs[0].get('groupId'), result.groupId);
    assert.deepEqual(members.docs.map((doc) => doc.get('name')), ['Ana', 'Luis']);
  }

  test('crearGrupo reserves a code and creates the group membership', async () => {
    const result = await entryPoints.crearGrupo.run(
      groupInput(),
      { auth: { uid: 'owner-uid' } },
    );

    assert.match(result.groupId, /^[A-Za-z0-9_-]{20}$/);
    assert.match(result.groupCode, /^[A-Za-z0-9]{8}$/);

    const [group, code, membership, members] = await Promise.all([
      db.collection('groups').doc(result.groupId).get(),
      db.collection('groupCodes').doc(result.groupCode).get(),
      db.collection('groupMembers').doc(`${result.groupId}_owner-uid`).get(),
      db.collection('groups').doc(result.groupId).collection('members').get(),
    ]);

    assert.deepEqual(group.data().name, 'Viaje');
    assert.equal(group.data().ownerDeviceId, 'owner-uid');
    assert.equal(group.data().allMembersAreAdmins, false);
    assert.equal(group.get('timeZone'), 'Europe/Madrid');
    assert.equal(code.data().groupId, result.groupId);
    assert.deepEqual(membership.data().groupId, result.groupId);
    assert.deepEqual(members.docs.map((member) => member.data().name), ['Ana', 'Luis']);
  });

  test('crearGrupo rejects more than 50 members without creating documents', async () => {
    const miembros = Array.from({ length: 51 }, (_, index) => `Miembro ${index + 1}`);

    await assert.rejects(
      entryPoints.crearGrupo.run(
        groupInput({ miembros }),
        { auth: { uid: 'owner-uid' } },
      ),
      { code: 'invalid-argument' },
    );

    await assertNoGroupCreationWrites();
  });

  test('una cuenta no puede superar la cuota diaria de creación de grupos', async () => {
    const context = { auth: { uid: 'owner-uid' } };
    for (let index = 0; index < 10; index += 1) {
      await entryPoints.crearGrupo.run(groupInput(), context);
    }
    await assert.rejects(entryPoints.crearGrupo.run(groupInput(), context), { code: 'resource-exhausted' });
    assert.equal((await db.collection('groups').get()).size, 10);
  });

  test('crearGrupo replays the same request with one group, code and membership', async () => {
    const input = groupInput();
    const auth = { auth: { uid: 'owner-uid' } };

    const first = await entryPoints.crearGrupo.run(input, auth);
    const repeated = await entryPoints.crearGrupo.run({ ...input }, auth);

    assert.deepEqual(repeated, first);
    await assertSingleCreatedGroup(first);
  });

  test('solo las creaciones nuevas y validas consumen el cupo global, no errores ni reintentos', async () => {
    const context = { auth: { uid: 'owner-uid' } };
    const budget = db.doc('usageLimits/project');
    await assert.rejects(entryPoints.crearGrupo.run(groupInput({ nombre: '' }), context), { code: 'invalid-argument' });
    assert.equal((await budget.get()).exists, false);
    const input = groupInput();
    const group = await entryPoints.crearGrupo.run(input, context);
    const expense = expenseInput({ groupId: group.groupId, pagadoPor: 'member_001', participantes: ['member_002'] });
    const created = await entryPoints.crearGasto.run(expense, context);
    await assert.rejects(entryPoints.crearGasto.run({ ...expense, requestId: db.collection('groups').doc().id },
      { auth: { uid: 'outsider' } }), { code: 'permission-denied' });
    assert.equal((await budget.get()).get('dayCount'), 2);
    await budget.set({ day: new Date().toISOString().slice(0, 10), dayCount: 1000 });
    assert.deepEqual(await entryPoints.crearGrupo.run(input, context), group);
    assert.deepEqual(await entryPoints.crearGasto.run(expense, context), created);
    await assert.rejects(entryPoints.crearGrupo.run(groupInput(), context), { code: 'resource-exhausted' });
    await assert.rejects(entryPoints.crearGasto.run(expenseInput({
      ...expense, requestId: db.collection('groups').doc().id,
    }), context), { code: 'resource-exhausted' });
    assert.equal((await db.collection('groups').get()).size, 1);
    assert.equal((await db.collection('groups').doc(group.groupId).collection('gastos').get()).size, 1);
    assert.equal((await budget.get()).get('dayCount'), 1000);
  });

  test('agotar las creaciones no bloquea registro de dispositivos ni recuperacion o cancelacion de fusiones', async () => {
    const anonymous = (uid) => ({ auth: { uid, token: { firebase: { sign_in_provider: 'anonymous' } } } });
    const source = anonymous('source');
    const cancelSource = anonymous('cancel-source');
    const ticket = (await entryPoints.prepararFusionCuenta.run({}, source)).mergeTicket;
    const cancelTicket = (await entryPoints.prepararFusionCuenta.run({}, cancelSource)).mergeTicket;
    await entryPoints.bloquearFusionCuenta.run({ mergeTicket: cancelTicket }, cancelSource);
    const budget = db.doc('usageLimits/project');
    await budget.set({ day: new Date().toISOString().slice(0, 10), dayCount: 1000 });
    assert.equal((await entryPoints.prepararFusionCuenta.run({}, source)).mergeTicket, ticket);
    const installationId = 'a'.repeat(48);
    await entryPoints.registrarDispositivo.run({ installationId, fcmToken: 'test-token' }, source);
    assert.equal((await db.doc(`usuarios/source/devices/${installationId}`).get()).exists, true);
    await entryPoints.bloquearFusionCuenta.run({ mergeTicket: ticket }, source);
    const target = { auth: { uid: 'target', token: { firebase: { sign_in_provider: 'google.com' } } } };
    const result = await entryPoints.fusionarCuentaAnonima.run({ mergeTicket: ticket }, target);
    assert.deepEqual(await entryPoints.fusionarCuentaAnonima.run({ mergeTicket: ticket }, target), result);
    assert.equal((await db.doc(`usuarios/target/devices/${installationId}`).get()).exists, true);
    await entryPoints.cancelarFusionCuenta.run({ mergeTicket: cancelTicket }, cancelSource);
    assert.equal((await db.doc('accountMerges/cancel-source').get()).exists, false);
    await assert.rejects(entryPoints.prepararFusionCuenta.run({}, anonymous('new-source')), { code: 'resource-exhausted' });
    assert.equal((await budget.get()).get('dayCount'), 1000);
  });

  test('crearGrupo handles concurrent retries with one group, code and membership', async () => {
    const input = groupInput();
    const auth = { auth: { uid: 'owner-uid' } };

    const outcomes = await Promise.allSettled([
      entryPoints.crearGrupo.run(input, auth),
      entryPoints.crearGrupo.run({ ...input }, auth),
    ]);

    assert.ok(outcomes.every((outcome) => outcome.status === 'fulfilled'), JSON.stringify(outcomes));
    assert.deepEqual(outcomes[1].value, outcomes[0].value);
    await assertSingleCreatedGroup(outcomes[0].value);
  });

  test('crearGrupo rejects a changed payload for an existing requestId', async () => {
    const input = groupInput();
    const auth = { auth: { uid: 'owner-uid' } };
    const first = await entryPoints.crearGrupo.run(input, auth);

    await assert.rejects(
      entryPoints.crearGrupo.run({ ...input, miembros: ['Ana', 'Lucia'] }, auth),
      { code: 'failed-precondition' },
    );
    await assertSingleCreatedGroup(first);
  });

  test('crearGrupo recovers identical IDs after the first response is lost', async () => {
    const input = groupInput();
    const auth = { auth: { uid: 'owner-uid' } };
    await entryPoints.crearGrupo.run(input, auth);
    const original = (await db.collection('groups').get()).docs[0];
    assert.ok(original);

    const recovered = await entryPoints.crearGrupo.run({ ...input }, auth);

    assert.deepEqual(recovered, { groupId: original.id, groupCode: original.get('groupCode') });
    await assertSingleCreatedGroup(recovered);
  });

  test('configurarAdministracionGrupo is owner-only, validates the flag and blocks merging accounts', async () => {
    const groupRef = await seedExpenseGroup();
    const input = { groupId: groupRef.id, allMembersAreAdmins: true };
    await assert.rejects(entryPoints.configurarAdministracionGrupo.run(input, {}), { code: 'unauthenticated' });
    await db.collection('groupMembers').doc('expense-group_other-uid').set({
      groupId: groupRef.id, deviceId: 'other-uid',
    });
    for (const value of ['true', null, 1]) {
      await assert.rejects(entryPoints.configurarAdministracionGrupo.run(
        { ...input, allMembersAreAdmins: value }, { auth: { uid: 'payer-uid' } },
      ), { code: 'invalid-argument' });
    }
    for (const enabled of [true, false]) {
      assert.deepEqual(await entryPoints.configurarAdministracionGrupo.run(
        { ...input, allMembersAreAdmins: enabled }, { auth: { uid: 'payer-uid' } },
      ), { allMembersAreAdmins: enabled });
      assert.equal((await groupRef.get()).get('allMembersAreAdmins'), enabled);
      for (const uid of ['other-uid', 'outsider-uid']) {
        await assert.rejects(entryPoints.configurarAdministracionGrupo.run(input, { auth: { uid } }),
          { code: 'permission-denied' });
      }
    }
    await db.collection('accountMerges').doc('payer-uid').set({ status: 'prepared' });
    await assert.rejects(entryPoints.configurarAdministracionGrupo.run(input, { auth: { uid: 'payer-uid' } }),
      { code: 'failed-precondition' });
    assert.equal((await groupRef.get()).get('allMembersAreAdmins'), false);
  });

  function addMember(groupId, nombre, requestId = db.collection('groups').doc().id, uid = 'payer-uid') {
    return entryPoints.agregarMiembroGrupo.run({ groupId, nombre, requestId }, { auth: { uid } });
  }

  test('agregarMiembroGrupo permits owners or shared admins, never outsiders, and blocks account merges', async () => {
    const groupRef = await seedExpenseGroup();
    const input = { groupId: groupRef.id, nombre: 'Nuevo', requestId: 'A'.repeat(20) };
    await assert.rejects(entryPoints.agregarMiembroGrupo.run(input, {}), { code: 'unauthenticated' });
    await db.collection('groupMembers').doc('expense-group_other-uid').set({
      groupId: groupRef.id, deviceId: 'other-uid',
    });
    await assert.rejects(addMember(groupRef.id, 'Nuevo', undefined, 'other-uid'), { code: 'permission-denied' });
    await groupRef.update({ allMembersAreAdmins: true });
    await assert.rejects(addMember(groupRef.id, 'Nuevo', undefined, 'outsider-uid'), { code: 'permission-denied' });
    await addMember(groupRef.id, 'Nuevo', undefined, 'other-uid');
    await groupRef.update({ allMembersAreAdmins: false });
    await assert.rejects(addMember(groupRef.id, 'Otro', undefined, 'other-uid'), { code: 'permission-denied' });
    await db.collection('groupMembers').doc('expense-group_payer-uid').delete();
    await addMember(groupRef.id, 'Del propietario');
    await db.collection('accountMerges').doc('payer-uid').set({ status: 'prepared' });
    await assert.rejects(addMember(groupRef.id, 'Bloqueado'), { code: 'failed-precondition' });
    assert.equal((await groupRef.collection('members').get()).size, 6);
  });

  test('agregarMiembroGrupo validates names and request IDs without partial writes', async () => {
    const groupRef = await seedExpenseGroup();
    for (const nombre of ['', '   ', 'A'.repeat(51), null]) {
      await assert.rejects(addMember(groupRef.id, nombre), { code: 'invalid-argument' });
    }
    for (const requestId of ['short', 'A'.repeat(21), '/'.repeat(20)]) {
      await assert.rejects(addMember(groupRef.id, 'Nuevo', requestId), { code: 'invalid-argument' });
    }
    await assert.rejects(addMember(groupRef.id, ' aNA '), { code: 'already-exists' });
    await addMember(groupRef.id, 'A'.repeat(50));
    assert.equal((await groupRef.collection('members').get()).size, 5);
  });

  test('agregarMiembroGrupo trims names and replays concurrent retries with one deterministic ID', async () => {
    const groupRef = await seedExpenseGroup();
    const requestId = 'A'.repeat(20);
    const results = await Promise.all([
      addMember(groupRef.id, '  Lucia  ', requestId),
      addMember(groupRef.id, 'Lucia', requestId),
    ]);
    assert.deepEqual(results[0], results[1]);
    assert.deepEqual(await addMember(groupRef.id, 'Lucia', requestId), results[0]);
    await assert.rejects(addMember(groupRef.id, 'Otra', requestId), { code: 'failed-precondition' });
    const member = await groupRef.collection('members').doc(results[0].memberId).get();
    assert.deepEqual(member.data(), { name: 'Lucia', reclamadoPor: null });
    assert.equal((await groupRef.collection('members').get()).size, 5);
  });

  test('agregarMiembroGrupo serializes concurrent case-insensitive duplicates', async () => {
    const groupRef = await seedExpenseGroup();
    const results = await Promise.allSettled([
      addMember(groupRef.id, ' Lucia '), addMember(groupRef.id, 'LUCIA'),
    ]);
    assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
    assert.equal(results.find((result) => result.status === 'rejected').reason.code, 'already-exists');
    assert.equal((await groupRef.collection('members').get()).size, 5);
  });

  test('agregarMiembroGrupo enforces the 50-person limit across concurrent additions and replays at capacity', async () => {
    const groupRef = await seedExpenseGroup();
    const batch = db.batch();
    for (let index = 0; index < 45; index += 1) {
      batch.create(groupRef.collection('members').doc(`extra-${index}`), { name: `Extra ${index}`, reclamadoPor: null });
    }
    await batch.commit();
    const requests = ['A'.repeat(20), 'B'.repeat(20)];
    const results = await Promise.allSettled(requests.map((requestId, index) =>
      addMember(groupRef.id, `Ultimo ${index}`, requestId)));
    const winner = results.findIndex((result) => result.status === 'fulfilled');
    assert.equal(results.filter((result) => result.status === 'fulfilled').length, 1);
    assert.equal(results.find((result) => result.status === 'rejected').reason.code, 'resource-exhausted');
    assert.deepEqual(await addMember(groupRef.id, `Ultimo ${winner}`, requests[winner]), results[winner].value);
    assert.equal((await groupRef.collection('members').get()).size, 50);
    assert.equal((await groupRef.get()).get('memberCount'), 50);
  });

  test('unirseAGrupo creates a membership and remains idempotent', async () => {
    await db.collection('groups').doc('group-1').set({ groupCode: 'Ab12Cd34' });

    const joined = await entryPoints.unirseAGrupo.run(
      { codigo: 'Ab12Cd34' },
      { auth: { uid: 'member-uid' } },
    );
    const repeated = await entryPoints.unirseAGrupo.run(
      { codigo: 'Ab12Cd34' },
      { auth: { uid: 'member-uid' } },
    );

    assert.deepEqual(joined, { status: 'joined', groupId: 'group-1' });
    assert.deepEqual(repeated, { status: 'already-member', groupId: 'group-1' });
    assert.equal((await db.collection('groupMembers').doc('group-1_member-uid').get()).exists, true);
  });

  test('account merge preserves the union of groups and ownership', async () => {
    const oldGroup = db.collection('groups').doc('old-group');
    const newGroup = db.collection('groups').doc('new-group');
    await Promise.all([
      oldGroup.set({ name: 'Antiguo', ownerDeviceId: 'target-uid' }),
      db.collection('groupMembers').doc('old-group_target-uid').set({
        groupId: 'old-group', deviceId: 'target-uid', memberId: 'old-member',
      }),
      oldGroup.collection('members').doc('old-member').set({
        name: 'Ana', reclamadoPor: 'target-uid',
      }),
      newGroup.set({ name: 'Nuevo', ownerDeviceId: 'source-uid' }),
      db.collection('groupMembers').doc('new-group_source-uid').set({
        groupId: 'new-group', deviceId: 'source-uid', memberId: 'new-member',
      }),
      newGroup.collection('members').doc('new-member').set({
        name: 'Ana', reclamadoPor: 'source-uid',
      }),
      newGroup.collection('gastos').doc('expense').set({ createdByUid: 'source-uid' }),
      newGroup.collection('gastosProgramados').doc('schedule').set({ createdByUid: 'source-uid' }),
      newGroup.collection('expenseRequests').doc('request').set({ createdByUid: 'source-uid' }),
      db.collection('usuarios').doc('source-uid').set({ deviceId: 'source-uid', fcmToken: 'token' }),
      db.doc('usuarios/source-uid/devices/phone').set({ fcmToken: 'phone-token' }),
      db.doc('usuarios/target-uid/devices/tablet').set({ fcmToken: 'tablet-token' }),
    ]);

    assert.deepEqual(
      await mergeAnonymousAccountData(db, 'source-uid', 'target-uid'),
      { mergedGroups: 1 },
    );

    const [oldMembership, newMembership, sourceMembership, group, member, expense, schedule, request, user] =
      await Promise.all([
        db.collection('groupMembers').doc('old-group_target-uid').get(),
        db.collection('groupMembers').doc('new-group_target-uid').get(),
        db.collection('groupMembers').doc('new-group_source-uid').get(),
        newGroup.get(),
        newGroup.collection('members').doc('new-member').get(),
        newGroup.collection('gastos').doc('expense').get(),
        newGroup.collection('gastosProgramados').doc('schedule').get(),
        newGroup.collection('expenseRequests').doc('request').get(),
        db.collection('usuarios').doc('target-uid').get(),
      ]);
    assert.equal(oldMembership.exists, true);
    assert.equal(newMembership.get('deviceId'), 'target-uid');
    assert.equal(newMembership.get('memberId'), 'new-member');
    assert.equal(sourceMembership.exists, false);
    assert.equal(group.get('ownerDeviceId'), 'target-uid');
    assert.equal(member.get('reclamadoPor'), 'target-uid');
    assert.equal(expense.get('createdByUid'), 'target-uid');
    assert.equal(schedule.get('createdByUid'), 'target-uid');
    assert.equal(request.get('createdByUid'), 'target-uid');
    assert.equal(user.exists, false);
    assert.equal((await db.doc('usuarios/target-uid/devices/phone').get()).get('fcmToken'), 'phone-token');
    assert.equal((await db.doc('usuarios/target-uid/devices/tablet').get()).get('fcmToken'), 'tablet-token');
    assert.equal((await db.doc('usuarios/source-uid/devices/phone').get()).exists, false);
  });

  test('merge ticket locks the source and can only be completed by one target', async () => {
    const group = db.collection('groups').doc('ticket-group');
    await Promise.all([
      group.set({ name: 'Nuevo', ownerDeviceId: 'source-uid' }),
      db.collection('groupMembers').doc('ticket-group_source-uid').set({
        groupId: 'ticket-group', deviceId: 'source-uid', memberId: 'source-member',
      }),
      group.collection('members').doc('source-member').set({
        name: 'Ana', reclamadoPor: 'source-uid',
      }),
    ]);

    const ticket = await prepareAccountMerge(db, 'source-uid');
    await activateAccountMerge(db, 'source-uid', ticket);
    await assert.rejects(
      entryPoints.crearGrupo.run(
        groupInput({ nombre: 'Bloqueado', miembros: ['Ana'] }),
        { auth: { uid: 'source-uid' } },
      ),
      (error) => error.code === 'failed-precondition',
    );

    await completeAccountMerge(db, ticket, 'target-uid');
    await assert.rejects(
      completeAccountMerge(db, ticket, 'other-target-uid'),
      AccountMergeConflictError,
    );
    assert.equal(
      (await db.collection('groupMembers').doc('ticket-group_target-uid').get()).exists,
      true,
    );
  });

  test('an activated merge remains recoverable after its preparation deadline', async () => {
    const ticket = await prepareAccountMerge(db, 'source-uid');
    await activateAccountMerge(db, 'source-uid', ticket);

    const ticketId = createHash('sha256').update(ticket).digest('hex');
    await db.collection('accountMergeTickets').doc(ticketId).update({
      expiresAt: Timestamp.fromMillis(Date.now() - 1),
    });

    await completeAccountMerge(db, ticket, 'target-uid');

    assert.equal(
      (await db.collection('accountMerges').doc('source-uid').get()).get('status'),
      'completed',
    );
  });

  test('a prepared merge can be canceled before changing accounts', async () => {
    const ticket = await prepareAccountMerge(db, 'source-uid');
    await cancelAccountMerge(db, 'source-uid', ticket);

    assert.equal((await db.collection('accountMerges').doc('source-uid').get()).exists, false);
    const created = await entryPoints.crearGrupo.run(
      groupInput({ nombre: 'Disponible', miembros: ['Ana'] }),
      { auth: { uid: 'source-uid' } },
    );
    assert.ok(created.groupId);
  });

  test('merge cancellation is retryable and its tombstone remains source-owned', async () => {
    const ticket = await prepareAccountMerge(db, 'source-uid');
    await activateAccountMerge(db, 'source-uid', ticket);
    const input = { mergeTicket: ticket };
    const auth = { auth: { uid: 'source-uid', token: { firebase: { sign_in_provider: 'anonymous' } } } };

    assert.deepEqual(await entryPoints.cancelarFusionCuenta.run(input, auth), { canceled: true });
    assert.deepEqual(await entryPoints.cancelarFusionCuenta.run(input, auth), { canceled: true });

    const ticketId = createHash('sha256').update(ticket).digest('hex');
    const canceled = await db.collection('accountMergeTickets').doc(ticketId).get();
    assert.equal(canceled.get('sourceUid'), 'source-uid');
    assert.equal(canceled.get('status'), 'canceled');
    assert.equal((await db.collection('accountMerges').doc('source-uid').get()).exists, false);
    await assert.rejects(cancelAccountMerge(db, 'foreign-uid', ticket), AccountMergeConflictError);
    await assert.rejects(activateAccountMerge(db, 'source-uid', ticket), AccountMergeConflictError);
    await assert.rejects(completeAccountMerge(db, ticket, 'target-uid'), AccountMergeConflictError);
  });

  test('un origen ya vinculado puede cancelar su ticket tras rechazar una fusion hacia si mismo', async () => {
    const ticket = await prepareAccountMerge(db, 'source-uid');
    await activateAccountMerge(db, 'source-uid', ticket);
    const protectedSource = { auth: { uid: 'source-uid', token: { firebase: { sign_in_provider: 'google.com' } } } };
    await assert.rejects(entryPoints.fusionarCuentaAnonima.run({ mergeTicket: ticket }, protectedSource), (error) =>
      error.code === 'failed-precondition' && error.details?.reason === 'same-account');
    await assert.rejects(entryPoints.cancelarFusionCuenta.run({ mergeTicket: ticket }, {
      auth: { uid: 'foreign-uid', token: { firebase: { sign_in_provider: 'google.com' } } },
    }), { code: 'failed-precondition' });
    assert.equal((await db.doc('accountMerges/source-uid').get()).exists, true);
    await entryPoints.cancelarFusionCuenta.run({ mergeTicket: ticket }, protectedSource);
    assert.equal((await db.doc('accountMerges/source-uid').get()).exists, false);
  });

  test('reusing an active preparation or canceling a missing ticket preserves the merge lock', async () => {
    const original = await prepareAccountMerge(db, 'source-uid');
    await activateAccountMerge(db, 'source-uid', original);
    const mergeRef = db.collection('accountMerges').doc('source-uid');
    const originalLock = (await mergeRef.get()).data();
    assert.equal(await prepareAccountMerge(db, 'source-uid'), original);
    await activateAccountMerge(db, 'source-uid', original);
    const other = 'missing-ticket-from-another-preparation';
    await assert.rejects(activateAccountMerge(db, 'source-uid', other), AccountMergeConflictError);
    await assert.rejects(cancelAccountMerge(db, 'foreign-uid', original), AccountMergeConflictError);
    await assert.rejects(cancelAccountMerge(db, 'source-uid', other), AccountMergeConflictError);

    assert.deepEqual((await mergeRef.get()).data(), originalLock);
    await assert.rejects(
      entryPoints.crearGrupo.run(
        groupInput({ nombre: 'Bloqueado', miembros: ['Ana'] }),
        { auth: { uid: 'source-uid' } },
      ),
      { code: 'failed-precondition' },
    );
    await completeAccountMerge(db, original, 'target-uid');
    await assert.rejects(cancelAccountMerge(db, 'source-uid', original), AccountMergeConflictError);
    await assert.rejects(completeAccountMerge(db, original, 'other-target-uid'), AccountMergeConflictError);
  });

  test('a missing merge ticket is cancelable only without an existing merge lock', async () => {
    const ticket = await prepareAccountMerge(db, 'source-uid');
    const ticketId = createHash('sha256').update(ticket).digest('hex');
    await db.collection('accountMergeTickets').doc(ticketId).delete();

    await cancelAccountMerge(db, 'source-uid', ticket);
    await cancelAccountMerge(db, 'source-uid', ticket);
    const original = await prepareAccountMerge(db, 'source-uid');
    await activateAccountMerge(db, 'source-uid', original);
    const mergeRef = db.collection('accountMerges').doc('source-uid');
    const originalLock = (await mergeRef.get()).data();

    await assert.rejects(cancelAccountMerge(db, 'source-uid', ticket), AccountMergeConflictError);
    assert.deepEqual((await mergeRef.get()).data(), originalLock);
  });

  test('merge cancellation rejects tickets already claimed by a target', async () => {
    const ticket = await prepareAccountMerge(db, 'source-uid');
    await activateAccountMerge(db, 'source-uid', ticket);
    const ticketId = createHash('sha256').update(ticket).digest('hex');
    const ticketRef = db.collection('accountMergeTickets').doc(ticketId);
    await ticketRef.update({ targetUid: 'target-uid', status: 'running' });

    await assert.rejects(cancelAccountMerge(db, 'source-uid', ticket), AccountMergeConflictError);
    assert.equal((await ticketRef.get()).get('status'), 'running');
    assert.equal((await db.collection('accountMerges').doc('source-uid').get()).exists, true);
  });

  test('account merge keeps both identities when accounts share a group', async () => {
    const group = db.collection('groups').doc('shared-group');
    await Promise.all([
      group.set({ name: 'Compartido', ownerDeviceId: 'owner-uid' }),
      db.collection('groupMembers').doc('shared-group_source-uid').set({
        groupId: 'shared-group', deviceId: 'source-uid', memberId: 'source-member',
      }),
      db.collection('groupMembers').doc('shared-group_target-uid').set({
        groupId: 'shared-group', deviceId: 'target-uid', memberId: 'target-member',
      }),
      group.collection('members').doc('source-member').set({
        name: 'Móvil', reclamadoPor: 'source-uid',
      }),
      group.collection('members').doc('target-member').set({
        name: 'Cuenta', reclamadoPor: 'target-uid',
      }),
    ]);

    await mergeAnonymousAccountData(db, 'source-uid', 'target-uid');
    await mergeAnonymousAccountData(db, 'source-uid', 'target-uid');

    const [membership, sourceMember, targetMember] = await Promise.all([
      db.collection('groupMembers').doc('shared-group_target-uid').get(),
      group.collection('members').doc('source-member').get(),
      group.collection('members').doc('target-member').get(),
    ]);
    assert.equal(membership.get('memberId'), 'target-member');
    assert.equal(sourceMember.get('reclamadoPor'), 'target-uid');
    assert.equal(targetMember.get('reclamadoPor'), 'target-uid');
  });

  test('account merge transfers every identity already owned by the source', async () => {
    const group = db.collection('groups').doc('multi-identity-group');
    await Promise.all([
      group.set({ name: 'Compartido', ownerDeviceId: 'owner-uid' }),
      db.collection('groupMembers').doc('multi-identity-group_source-uid').set({
        groupId: 'multi-identity-group', deviceId: 'source-uid', memberId: 'source-primary',
      }),
      db.collection('groupMembers').doc('multi-identity-group_target-uid').set({
        groupId: 'multi-identity-group', deviceId: 'target-uid', memberId: 'target-primary',
      }),
      group.collection('members').doc('source-primary').set({
        name: 'Móvil', reclamadoPor: 'source-uid',
      }),
      group.collection('members').doc('source-secondary').set({
        name: 'Tablet', reclamadoPor: 'source-uid',
      }),
      group.collection('members').doc('target-primary').set({
        name: 'Cuenta', reclamadoPor: 'target-uid',
      }),
    ]);

    await mergeAnonymousAccountData(db, 'source-uid', 'target-uid');

    const [sourcePrimary, sourceSecondary, targetPrimary] = await Promise.all([
      group.collection('members').doc('source-primary').get(),
      group.collection('members').doc('source-secondary').get(),
      group.collection('members').doc('target-primary').get(),
    ]);
    assert.equal(sourcePrimary.get('reclamadoPor'), 'target-uid');
    assert.equal(sourceSecondary.get('reclamadoPor'), 'target-uid');
    assert.equal(targetPrimary.get('reclamadoPor'), 'target-uid');
  });

  test('account merge cannot redirect the same anonymous session to another account', async () => {
    await mergeAnonymousAccountData(db, 'source-uid', 'target-uid');

    await assert.rejects(
      mergeAnonymousAccountData(db, 'source-uid', 'different-target-uid'),
      AccountMergeConflictError,
    );
  });

  test('reclamarMiembro claims an identity and records it on the membership', async () => {
    const { groupRef, membershipRef } = await seedClaimGroup();

    assert.deepEqual(await claim('alice'), { memberId: 'alice' });
    const [member, membership] = await Promise.all([
      groupRef.collection('members').doc('alice').get(),
      membershipRef.get(),
    ]);
    assert.equal(member.get('reclamadoPor'), 'claimant-uid');
    assert.equal(membership.get('memberId'), 'alice');
  });

  test('reclamarMiembro requires auth and group membership without writing a claim', async () => {
    const { groupRef, membershipRef } = await seedClaimGroup();
    await assert.rejects(
      entryPoints.reclamarMiembro.run({ groupId: 'claim-group', memberId: 'alice' }, {}),
      { code: 'unauthenticated' },
    );
    await assert.rejects(claim('alice', 'outsider-uid'), { code: 'permission-denied' });

    assert.equal((await groupRef.collection('members').doc('alice').get()).get('reclamadoPor'), null);
    assert.equal((await membershipRef.get()).get('memberId'), undefined);
    assert.equal((await db.collection('groupMembers').doc('claim-group_outsider-uid').get()).exists, false);
  });

  test('reclamarMiembro rejects an identity claimed by someone else', async () => {
    const { groupRef, membershipRef } = await seedClaimGroup();
    await assert.rejects(claim('taken'), { code: 'failed-precondition' });
    assert.equal((await groupRef.collection('members').doc('taken').get()).get('reclamadoPor'), 'other-uid');
    assert.equal((await membershipRef.get()).get('memberId'), undefined);
  });

  test('reclamarMiembro returns the existing identity instead of claiming a second one', async () => {
    const { groupRef, membershipRef } = await seedClaimGroup();
    assert.deepEqual(await claim('alice'), { memberId: 'alice' });
    assert.deepEqual(await claim('bob'), { memberId: 'alice' });
    assert.equal((await membershipRef.get()).get('memberId'), 'alice');
    assert.equal((await groupRef.collection('members').doc('bob').get()).get('reclamadoPor'), null);
  });

  test('reclamarMiembro restores the primary identity pointer idempotently', async () => {
    const { groupRef, membershipRef } = await seedClaimGroup();
    await groupRef.collection('members').doc('alice').update({ reclamadoPor: 'claimant-uid' });

    assert.deepEqual(await claim('bob'), { memberId: 'alice' });
    assert.equal((await membershipRef.get()).get('memberId'), 'alice');
    assert.equal((await groupRef.collection('members').doc('bob').get()).get('reclamadoPor'), null);
  });

  test('concurrent claims by one uid leave only one identity claimed', async () => {
    const { groupRef, membershipRef } = await seedClaimGroup();
    const outcomes = await Promise.allSettled([claim('alice'), claim('bob')]);
    const successfulIds = outcomes.filter((result) => result.status === 'fulfilled')
      .map((result) => result.value.memberId);
    assert.ok(successfulIds.length >= 1, JSON.stringify(outcomes));
    assert.equal(new Set(successfulIds).size, 1, JSON.stringify(outcomes));
    const claimed = await groupRef.collection('members').where('reclamadoPor', '==', 'claimant-uid').get();
    assert.equal(claimed.size, 1);
    assert.equal((await membershipRef.get()).get('memberId'), claimed.docs[0].id);
    assert.equal(successfulIds[0], claimed.docs[0].id);
  });

  test('crearGasto creates a complete immediate expense and exact cent divisions', async () => {
    const groupRef = await seedExpenseGroup();
    const result = await entryPoints.crearGasto.run(expenseInput(), { auth: { uid: 'payer-uid' } });

    const [expenses, schedules] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
    ]);
    assert.equal(expenses.size, 1);
    assert.equal(schedules.size, 0);
    assert.deepEqual(result, { gastoId: expenses.docs[0].id, scheduleId: null });

    const expense = expenses.docs[0].data();
    assert.equal(expense.nombre, 'Cena');
    assert.equal(expense.descripcion, 'Cena del viaje');
    assert.equal(expense.cantidadCentimos, 1001);
    assert.equal(expense.cantidad, undefined);
    assert.equal(expense.fecha, '2024-01-31');
    assert.equal(expense.pagadoPor, 'payer');
    assert.equal(expense.createdByMemberId, 'payer');
    assert.equal(expense.createdByUid, 'payer-uid');
    assert.ok(expense.created);

    const divisions = await expenses.docs[0].ref.collection('divisiones').get();
    assert.deepEqual(
      divisions.docs.map((doc) => [doc.id, doc.data().cantidadCentimos, doc.data().pagado]).sort(),
      [['alice', 334, false], ['bob', 334, false], ['payer', 333, true]],
    );
    for (const divisionDoc of divisions.docs) {
      const division = divisionDoc.data();
      assert.equal(division.memberId, divisionDoc.id);
      assert.equal(division.groupId, groupRef.id);
      assert.equal(division.cantidad, undefined);
      assert.equal(division.pagadoPor, 'payer');
      assert.equal(division.fecha, '2024-01-31');
      assert.equal(division.nombre, 'Cena');
      assert.ok(division.created);
      assert.equal(Boolean(division.pagadoEn), divisionDoc.id === 'payer');
    }
  });

  test('crearGasto schedules a future recurring expense without creating an occurrence', async () => {
    const groupRef = await seedExpenseGroup();
    const frecuencia = 'Mensual (mismo d\u00eda todos los meses)';
    const result = await entryPoints.crearGasto.run(
      expenseInput({ fecha: '2099-01-31', frecuencia }),
      { auth: { uid: 'payer-uid' } },
    );

    const [expenses, schedules] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
    ]);
    assert.equal(expenses.size, 0);
    assert.equal(schedules.size, 1);
    assert.deepEqual(result, { gastoId: null, scheduleId: schedules.docs[0].id });

    const schedule = schedules.docs[0].data();
    assert.equal(schedule.nombre, 'Cena');
    assert.equal(schedule.descripcion, 'Cena del viaje');
    assert.equal(schedule.cantidadCentimos, 1001);
    assert.equal(schedule.cantidad, undefined);
    assert.equal(schedule.pagadoPor, 'payer');
    assert.deepEqual(schedule.participantes, ['alice', 'bob']);
    assert.equal(schedule.frecuencia, frecuencia);
    assert.equal(schedule.diaAncla, 31);
    assert.equal(schedule.proximaFecha, '2099-01-31');
    assert.equal(schedule.timeZone, 'Europe/Madrid');
    assert.equal(schedule.proximaEjecucion.toDate().toISOString(), '2099-01-30T23:00:00.000Z');
    assert.equal(schedule.createdByMemberId, 'payer');
    assert.equal(schedule.createdByUid, 'payer-uid');
    assert.ok(schedule.created);
  });

  test('crearGasto interprets today using the fixed group zone, not the device', async () => {
    const groupRef = await seedExpenseGroup();
    const zone = 'Pacific/Auckland';
    await groupRef.update({ timeZone: zone });
    const groupDate = todayInZone(zone);
    const result = await entryPoints.crearGasto.run(
      expenseInput({ fecha: groupDate }),
      { auth: { uid: 'payer-uid' } },
    );

    assert.ok(result.gastoId);
    assert.equal(result.scheduleId, null);
    assert.equal((await groupRef.collection('gastos').get()).size, 1);
    assert.equal((await groupRef.collection('gastosProgramados').get()).size, 0);
    assert.equal((await groupRef.collection('gastos').doc(result.gastoId).get()).get('fecha'), groupDate);
  });

  test('crearGasto creates the initial occurrence and next schedule for a past recurring expense', async () => {
    const groupRef = await seedExpenseGroup();
    const frecuencia = 'Mensual (mismo d\u00eda todos los meses)';
    const result = await entryPoints.crearGasto.run(
      expenseInput({ frecuencia }),
      { auth: { uid: 'payer-uid' } },
    );

    const [expenses, schedules] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
    ]);
    assert.equal(expenses.size, 1);
    assert.equal(schedules.size, 1);
    assert.deepEqual(result, { gastoId: expenses.docs[0].id, scheduleId: schedules.docs[0].id });

    const expense = expenses.docs[0].data();
    const schedule = schedules.docs[0].data();
    assert.equal(expense.scheduleId, result.scheduleId);
    assert.equal(expense.occurrenceKey, result.gastoId);
    assert.equal(expense.fecha, '2024-01-31');
    assert.equal(expense.cantidadCentimos, 1001);
    assert.equal(expense.pagadoPor, 'payer');
    assert.equal(schedule.frecuencia, frecuencia);
    assert.equal(schedule.diaAncla, 31);
    assert.equal(schedule.proximaFecha, '2024-02-29');
    assert.deepEqual(schedule.participantes, ['alice', 'bob']);

    const divisions = await expenses.docs[0].ref.collection('divisiones').get();
    assert.deepEqual(
      divisions.docs.map((doc) => [doc.id, doc.data().cantidadCentimos, doc.data().pagado]).sort(),
      [['alice', 334, false], ['bob', 334, false], ['payer', 333, true]],
    );
  });

  test('crearGasto recovers monthly occurrences incrementally while preserving its anchor', async () => {
    const groupRef = await seedExpenseGroup();
    const result = await entryPoints.crearGasto.run(
      expenseInput({ fecha: '2024-01-31', frecuencia: 'Mensual (mismo d\u00eda todos los meses)' }),
      { auth: { uid: 'payer-uid' } },
    );
    const scheduleRef = groupRef.collection('gastosProgramados').doc(result.scheduleId);
    assert.equal((await scheduleRef.get()).get('diaAncla'), 31);

    await entryPoints.ejecutarGastosPeriodicos.run({});
    await entryPoints.ejecutarGastosPeriodicos.run({});

    const [schedule, expenses] = await Promise.all([
      scheduleRef.get(),
      groupRef.collection('gastos').where('scheduleId', '==', result.scheduleId).get(),
    ]);
    const occurrenceDates = new Set(
      expenses.docs.map((doc) => doc.get('fecha')),
    );
    assert.equal(schedule.get('diaAncla'), 31);
    assert.equal(schedule.get('proximaFecha'), '2024-04-30');
    assert.ok(occurrenceDates.has('2024-01-31'));
    assert.ok(occurrenceDates.has('2024-02-29'));
    assert.ok(occurrenceDates.has('2024-03-31'));
  });

  test('crearGasto replays an immediate expense without creating more expenses or divisions', async () => {
    const groupRef = await seedExpenseGroup();
    const input = expenseInput();
    const auth = { auth: { uid: 'payer-uid' } };

    const first = await entryPoints.crearGasto.run(input, auth);
    const repeated = await entryPoints.crearGasto.run({
      ...input,
      nombre: ' Cena ',
      descripcion: ' Cena del viaje ',
      participantes: ['bob', 'alice'],
    }, auth);

    assert.deepEqual(repeated, first);
    assert.ok(first.gastoId);
    assert.equal(first.scheduleId, null);
    const [expenses, schedules, divisions] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
      groupRef.collection('gastos').doc(first.gastoId).collection('divisiones').get(),
    ]);
    assert.equal(expenses.size, 1);
    assert.equal(schedules.size, 0);
    assert.equal(divisions.size, 3);
  });

  test('crearGasto replays a scheduled expense without creating another schedule', async () => {
    const groupRef = await seedExpenseGroup();
    const input = expenseInput({ fecha: '2099-01-31', frecuencia: 'Mensual (mismo d\u00eda todos los meses)' });
    const auth = { auth: { uid: 'payer-uid' } };

    const first = await entryPoints.crearGasto.run(input, auth);
    const repeated = await entryPoints.crearGasto.run({ ...input }, auth);

    assert.deepEqual(repeated, first);
    assert.equal(first.gastoId, null);
    assert.ok(first.scheduleId);
    const [expenses, schedules] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
    ]);
    assert.equal(expenses.size, 0);
    assert.equal(schedules.size, 1);
  });

  test('crearGasto replays a recurring expense without duplicating its schedule or initial divisions', async () => {
    const groupRef = await seedExpenseGroup();
    const input = expenseInput({ frecuencia: 'Mensual (mismo d\u00eda todos los meses)' });
    const auth = { auth: { uid: 'payer-uid' } };

    const first = await entryPoints.crearGasto.run(input, auth);
    const repeated = await entryPoints.crearGasto.run({ ...input }, auth);

    assert.deepEqual(repeated, first);
    assert.ok(first.gastoId);
    assert.ok(first.scheduleId);
    const [expenses, schedules, divisions] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
      groupRef.collection('gastos').doc(first.gastoId).collection('divisiones').get(),
    ]);
    assert.equal(expenses.size, 1);
    assert.equal(schedules.size, 1);
    assert.equal(divisions.size, 3);
  });

  test('crearGasto handles concurrent retries with one expense and one set of divisions', async () => {
    const groupRef = await seedExpenseGroup();
    const input = expenseInput();
    const auth = { auth: { uid: 'payer-uid' } };

    const outcomes = await Promise.allSettled([
      entryPoints.crearGasto.run(input, auth),
      entryPoints.crearGasto.run({ ...input }, auth),
    ]);
    assert.ok(outcomes.every((outcome) => outcome.status === 'fulfilled'), JSON.stringify(outcomes));
    assert.deepEqual(outcomes[1].value, outcomes[0].value);
    const gastoId = outcomes[0].value.gastoId;
    const [expenses, schedules, divisions] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
      groupRef.collection('gastos').doc(gastoId).collection('divisiones').get(),
    ]);
    assert.equal(expenses.size, 1);
    assert.equal(schedules.size, 0);
    assert.equal(divisions.size, 3);
  });

  test('crearGasto rejects reuse of a requestId with changed payload or caller', async () => {
    const groupRef = await seedExpenseGroup();
    await db.collection('groupMembers').doc('expense-group_other-uid').set({
      groupId: 'expense-group', deviceId: 'other-uid',
    });
    const input = expenseInput();
    const first = await entryPoints.crearGasto.run(input, { auth: { uid: 'payer-uid' } });

    await assert.rejects(
      entryPoints.crearGasto.run({ ...input, nombre: 'Otra cena' }, { auth: { uid: 'payer-uid' } }),
      { code: 'failed-precondition' },
    );
    await assert.rejects(
      entryPoints.crearGasto.run(input, { auth: { uid: 'other-uid' } }),
      { code: 'failed-precondition' },
    );
    const [expenses, schedules, divisions] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
      groupRef.collection('gastos').doc(first.gastoId).collection('divisiones').get(),
    ]);
    assert.equal(expenses.size, 1);
    assert.equal(schedules.size, 0);
    assert.equal(divisions.size, 3);
  });

  test('crearGasto rejects callers without group membership', async () => {
    const groupRef = await seedExpenseGroup();
    const input = expenseInput({ fecha: '2099-01-31' });
    await assert.rejects(
      entryPoints.crearGasto.run(input, {}),
      { code: 'unauthenticated' },
    );
    await assert.rejects(
      entryPoints.crearGasto.run(input, { auth: { uid: 'outsider-uid' } }),
      { code: 'permission-denied' },
    );
    await assertNoExpenseWrites(groupRef);
  });

  test('crearGasto accepts existing claimed or unclaimed payers and records the actual primary author', async () => {
    const groupRef = await seedExpenseGroup();
    await groupRef.collection('members').doc('primary-author').set({ name: 'Autor', reclamadoPor: 'payer-uid' });
    await db.collection('groupMembers').doc('expense-group_payer-uid').update({ memberId: 'primary-author' });
    for (const pagadoPor of ['other-payer', 'alice']) {
      const result = await entryPoints.crearGasto.run(
        expenseInput({ pagadoPor, participantes: ['bob'], frecuencia: 'Cada 7 d\u00edas' }),
        { auth: { uid: 'payer-uid' } },
      );
      for (const ref of [groupRef.collection('gastos').doc(result.gastoId),
        groupRef.collection('gastosProgramados').doc(result.scheduleId)]) {
        const doc = await ref.get();
        assert.equal(doc.get('pagadoPor'), pagadoPor);
        assert.equal(doc.get('createdByUid'), 'payer-uid');
        assert.equal(doc.get('createdByMemberId'), 'primary-author');
      }
    }
  });

  test('on-behalf schedules without an author identity survive account merge and preserve their payer', async () => {
    const groupRef = await seedExpenseGroup();
    await db.collection('groupMembers').doc('expense-group_author-uid').set({
      groupId: groupRef.id, deviceId: 'author-uid', memberId: 'other-payer',
    });
    const input = expenseInput({ fecha: '2099-01-31', pagadoPor: 'other-payer' });
    const result = await entryPoints.crearGasto.run(input, { auth: { uid: 'author-uid' } });
    const scheduleRef = groupRef.collection('gastosProgramados').doc(result.scheduleId);
    assert.equal((await scheduleRef.get()).get('createdByMemberId'), undefined);
    await mergeAnonymousAccountData(db, 'author-uid', 'target-uid');
    assert.deepEqual(await entryPoints.crearGasto.run(input, { auth: { uid: 'target-uid' } }), result);
    const yesterday = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    await scheduleRef.update({
      proximaFecha: yesterday,
      proximaEjecucion: Timestamp.fromDate(scheduleInstant(yesterday, 'Europe/Madrid')),
      nextAttemptAt: Timestamp.fromDate(scheduleInstant(yesterday, 'Europe/Madrid')),
    });
    await entryPoints.ejecutarGastosPeriodicos.run({});
    const expenses = await groupRef.collection('gastos').get();
    assert.equal(expenses.size, 1);
    assert.equal(expenses.docs[0].get('pagadoPor'), 'other-payer');
    assert.equal(expenses.docs[0].get('createdByUid'), 'target-uid');
    assert.equal(expenses.docs[0].get('createdByMemberId'), undefined);
    assert.equal((await groupRef.collection('members').doc('other-payer').get()).get('reclamadoPor'), 'other-uid');
    const shares = await expenses.docs[0].ref.collection('divisiones').get();
    assert.ok(shares.docs.every((share) => share.get('pagadoPor') === 'other-payer'));
    assert.equal(shares.docs.find((share) => share.id === 'other-payer').get('pagado'), true);
  });

  test('crearGasto rejects unknown participants and invalid amounts atomically', async () => {
    const groupRef = await seedExpenseGroup();
    const input = expenseInput({ fecha: '2099-01-31' });
    await assert.rejects(
      entryPoints.crearGasto.run({ ...input, participantes: ['alice', 'missing'] }, { auth: { uid: 'payer-uid' } }),
      { code: 'permission-denied' },
    );
    await assertNoExpenseWrites(groupRef);
    await assert.rejects(
      entryPoints.crearGasto.run({ ...input, pagadoPor: 'missing' }, { auth: { uid: 'payer-uid' } }),
      { code: 'permission-denied' },
    );
    await assertNoExpenseWrites(groupRef);
    for (const overrides of [
      { cantidadCentimos: 0 },
      { cantidadCentimos: 1.5 },
      { cantidadCentimos: 2 },
    ]) {
      await assert.rejects(
        entryPoints.crearGasto.run({ ...input, ...overrides }, { auth: { uid: 'payer-uid' } }),
        { code: 'invalid-argument' },
      );
      await assertNoExpenseWrites(groupRef);
    }
  });

  test('crearGasto rejects more than 49 participants without creating documents', async () => {
    const groupRef = await seedExpenseGroup();
    const participantes = Array.from({ length: 50 }, (_, index) => `member-${index + 1}`);

    await assert.rejects(
      entryPoints.crearGasto.run(
        expenseInput({ participantes }),
        { auth: { uid: 'payer-uid' } },
      ),
      { code: 'invalid-argument' },
    );

    await assertNoExpenseWrites(groupRef);
  });

  test('eliminarGasto stops recurrence and preserves other generated debts', async () => {
    const groupRef = await seedExpenseGroup();
    const created = await entryPoints.crearGasto.run(
      expenseInput({ frecuencia: 'Mensual (mismo d\u00eda todos los meses)' }),
      { auth: { uid: 'payer-uid' } },
    );

    const otherExpense = groupRef.collection('gastos').doc('other-month');
    await otherExpense.set({ scheduleId: created.scheduleId, createdByUid: 'payer-uid' });
    const otherDebt = otherExpense.collection('divisiones').doc('alice');
    const pending = { pagado: false, cantidadCentimos: 334, memberId: 'alice', pagadoPor: 'payer' };
    await otherDebt.set(pending);

    assert.deepEqual(
      await entryPoints.eliminarGasto.run(
        { groupId: groupRef.id, gastoId: created.gastoId },
        { auth: { uid: 'payer-uid' } },
      ),
      { deleted: true },
    );
    const [expense, divisions, schedule] = await Promise.all([
      groupRef.collection('gastos').doc(created.gastoId).get(),
      groupRef.collection('gastos').doc(created.gastoId).collection('divisiones').get(),
      groupRef.collection('gastosProgramados').doc(created.scheduleId).get(),
    ]);
    assert.equal(expense.exists, false);
    assert.equal(divisions.empty, true);
    assert.equal(schedule.exists, false);
    assert.equal((await otherExpense.get()).exists, true);
    assert.deepEqual((await otherDebt.get()).data(), pending);
  });

  test('eliminarGasto removes the linked series and is safe to retry', async () => {
    const groupRef = await seedExpenseGroup();
    const created = await entryPoints.crearGasto.run(
      expenseInput({ frecuencia: 'Mensual (mismo d\u00eda todos los meses)' }),
      { auth: { uid: 'payer-uid' } },
    );
    const input = { groupId: groupRef.id, gastoId: created.gastoId };

    assert.deepEqual(await entryPoints.eliminarGasto.run(input, { auth: { uid: 'payer-uid' } }), { deleted: true });
    assert.deepEqual(await entryPoints.eliminarGasto.run(input, { auth: { uid: 'payer-uid' } }), { deleted: false });
    assert.equal((await groupRef.collection('gastosProgramados').doc(created.scheduleId).get()).exists, false);
  });

  test('eliminarGasto rejects an unauthenticated or unrelated caller', async () => {
    const groupRef = await seedExpenseGroup();
    const created = await entryPoints.crearGasto.run(expenseInput(), { auth: { uid: 'payer-uid' } });
    const input = { groupId: groupRef.id, gastoId: created.gastoId };

    await assert.rejects(entryPoints.eliminarGasto.run(input, {}), { code: 'unauthenticated' });
    await assert.rejects(
      entryPoints.eliminarGasto.run(input, { auth: { uid: 'outsider-uid' } }),
      { code: 'permission-denied' },
    );
    assert.equal((await groupRef.collection('gastos').doc(created.gastoId).get()).exists, true);
  });

  test('shared admins can delete others expenses and schedules, but ordinary members and outsiders cannot', async () => {
    const groupRef = await seedExpenseGroup();
    await db.collection('groupMembers').doc('expense-group_other-uid').set({
      groupId: groupRef.id, deviceId: 'other-uid',
    });
    const expenseRef = groupRef.collection('gastos').doc('someone-elses');
    const scheduleRef = groupRef.collection('gastosProgramados').doc('someone-elses');
    await expenseRef.set({ createdByUid: 'payer-uid' });
    await scheduleRef.set({ createdByUid: 'payer-uid' });
    const expenseInput = { groupId: groupRef.id, gastoId: expenseRef.id };
    const scheduleInput = { groupId: groupRef.id, scheduleId: scheduleRef.id, scheduledFor: '2026-01-01' };
    for (const flag of [undefined, true, false]) {
      if (flag !== undefined) await groupRef.update({ allMembersAreAdmins: flag });
      const denied = flag === true ? ['outsider-uid'] : ['other-uid', 'outsider-uid'];
      for (const uid of denied) {
        await assert.rejects(entryPoints.eliminarGasto.run(expenseInput, { auth: { uid } }), { code: 'permission-denied' });
        await assert.rejects(entryPoints.eliminarGastoProgramado.run(scheduleInput, { auth: { uid } }), { code: 'permission-denied' });
      }
    }
    await groupRef.update({ allMembersAreAdmins: true });
    assert.deepEqual(await entryPoints.eliminarGasto.run(expenseInput, { auth: { uid: 'other-uid' } }), { deleted: true });
    assert.deepEqual(await entryPoints.eliminarGastoProgramado.run(scheduleInput, { auth: { uid: 'other-uid' } }),
      { deleted: true, occurrenceGenerated: false });
  });

  test('eliminarGastoProgramado only allows its creator or the group owner without shared administration', async () => {
    const groupRef = await seedExpenseGroup();
    const created = await entryPoints.crearGasto.run(
      expenseInput({ fecha: '2099-01-31' }),
      { auth: { uid: 'payer-uid' } },
    );
    const input = {
      groupId: groupRef.id, scheduleId: created.scheduleId,
      scheduledFor: '2099-01-31',
    };

    await assert.rejects(
      entryPoints.eliminarGastoProgramado.run(input, { auth: { uid: 'outsider-uid' } }),
      { code: 'permission-denied' },
    );
    assert.deepEqual(
      await entryPoints.eliminarGastoProgramado.run(input, { auth: { uid: 'payer-uid' } }),
      { deleted: true, occurrenceGenerated: false },
    );
    assert.equal(
      (await groupRef.collection('gastosProgramados').doc(created.scheduleId).get()).exists,
      false,
    );
  });

  test('canceling a schedule after generation preserves that occurrence and its debt', async () => {
    const groupRef = await seedExpenseGroup();
    for (const frecuencia of [null, 'Cada 7 días']) {
      const created = await entryPoints.crearGasto.run(
        expenseInput({ fecha: '2099-01-31', frecuencia }),
        { auth: { uid: 'payer-uid' } },
      );
      const scheduleRef = groupRef.collection('gastosProgramados').doc(created.scheduleId);
      const scheduledAt = (await scheduleRef.get()).get('proximaFecha');
      const occurrenceId = scheduledOccurrenceId(created.scheduleId, scheduledAt);
      const occurrenceRef = groupRef.collection('gastos').doc(occurrenceId);
      await occurrenceRef.set({ createdByUid: 'payer-uid', scheduleId: created.scheduleId });
      const debtRef = occurrenceRef.collection('divisiones').doc('alice');
      const pending = { pagado: false, cantidadCentimos: 334 };
      await debtRef.set(pending);
      if (frecuencia) {
        const nextDate = nextScheduledDate(scheduledAt, frecuencia);
        await scheduleRef.update({
          proximaFecha: nextDate,
          proximaEjecucion: Timestamp.fromDate(scheduleInstant(nextDate, 'Europe/Madrid')),
          nextAttemptAt: Timestamp.fromDate(scheduleInstant(nextDate, 'Europe/Madrid')),
        });
      } else {
        await scheduleRef.delete();
      }

      const result = await entryPoints.eliminarGastoProgramado.run({
        groupId: groupRef.id, scheduleId: created.scheduleId,
        scheduledFor: scheduledAt,
      }, { auth: { uid: 'payer-uid' } });

      assert.deepEqual(result, { deleted: Boolean(frecuencia), occurrenceGenerated: true });
      assert.equal((await scheduleRef.get()).exists, false);
      assert.equal((await occurrenceRef.get()).exists, true);
      assert.deepEqual((await debtRef.get()).data(), pending);
    }
  });

  async function seedPayment() {
    const group = await seedExpenseGroup();
    await group.collection('members').doc('alice').update({ reclamadoPor: 'debtor-uid' });
    await db.doc('groupMembers/expense-group_debtor-uid').set({
      groupId: group.id, deviceId: 'debtor-uid',
    });
    const debt = group.collection('gastos').doc('payment-expense').collection('divisiones').doc('alice');
    await debt.set({ groupId: group.id, memberId: 'alice', pagadoPor: 'payer', pagado: false, cantidadCentimos: 500 });
    const pay = (pagado, uid, extra = {}) => entryPoints.registrarPagoDeuda.run({
      groupId: group.id, gastoId: 'payment-expense', divisionId: 'alice', pagado, ...extra,
    }, { auth: { uid } });
    const observed = async () => {
      const snapshot = await debt.get();
      const time = snapshot.get('pagadoEn');
      return {
        pagadoEn: { seconds: time.seconds, nanoseconds: time.nanoseconds },
        pagoRegistradoPor: snapshot.get('pagoRegistradoPor'),
      };
    };
    return { group, debt, pay, observed };
  }

  test('pagos: deudor y acreedor pueden confirmar sin duplicar ni aceptar fechas o importes del cliente', async () => {
    const { debt, pay, observed } = await seedPayment();
    await pay(true, 'debtor-uid', { pagoRegistradoPor: 'alice', pagadoEn: 0, cantidadCentimos: 1 });
    const first = await debt.get();
    assert.equal(first.get('cantidadCentimos'), 500);
    assert.ok(first.get('pagadoEn') instanceof Timestamp);
    assert.deepEqual(await pay(true, 'debtor-uid', { pagoRegistradoPor: 'alice' }), { changed: false });
    assert.ok((await debt.get()).get('pagadoEn').isEqual(first.get('pagadoEn')));
    await pay(false, 'payer-uid', { pagoEsperado: await observed() });
    await pay(true, 'payer-uid', { pagoRegistradoPor: 'payer' });
    assert.equal((await debt.get()).get('pagoRegistradoPor'), 'payer');
  });

  test('pagos: no se permite suplantar identidades ni reabrir una confirmacion posterior', async () => {
    const { group, debt, pay, observed } = await seedPayment();
    for (const [uid, actor] of [['outsider', 'payer'], ['debtor-uid', 'payer'], ['payer-uid', 'bob']]) {
      await assert.rejects(pay(true, uid, { pagoRegistradoPor: actor }), { code: 'permission-denied' });
    }
    await group.update({ allMembersAreAdmins: true });
    await db.doc('groupMembers/expense-group_other-uid').set({ groupId: group.id, deviceId: 'other-uid' });
    await assert.rejects(pay(true, 'other-uid', { pagoRegistradoPor: 'alice' }), { code: 'permission-denied' });
    await pay(true, 'debtor-uid', { pagoRegistradoPor: 'alice' });
    const oldPayment = await observed();
    await assert.rejects(pay(false, 'debtor-uid', { pagoEsperado: oldPayment }), { code: 'permission-denied' });
    await pay(false, 'payer-uid', { pagoEsperado: oldPayment });
    assert.equal((await debt.get()).get('pagadoEn'), undefined);
    await pay(true, 'payer-uid', { pagoRegistradoPor: 'payer' });
    await assert.rejects(pay(false, 'payer-uid', { pagoEsperado: oldPayment }), { code: 'failed-precondition' });
    assert.equal((await debt.get()).get('pagado'), true);
  });

  test('pagos: la cuota de creaciones ajenas no bloquea pagos, pero la propia y la fusion si', async () => {
    const { debt, pay } = await seedPayment();
    await db.doc('accountMerges/debtor-uid').set({ status: 'prepared' });
    await assert.rejects(pay(true, 'debtor-uid', { pagoRegistradoPor: 'alice' }), { code: 'failed-precondition' });
    await db.doc('accountMerges/debtor-uid').delete();
    await db.doc('usageLimits/project').set({ day: new Date().toISOString().slice(0, 10), dayCount: 1000 });
    await pay(true, 'debtor-uid', { pagoRegistradoPor: 'alice' });
    assert.equal((await debt.get()).get('pagado'), true);
    const userId = createHash('sha256').update('debtor-uid').digest('hex');
    await db.doc(`usageLimits/user_${userId}`).set({ day: new Date().toISOString().slice(0, 10), dayCount: 300 });
    await assert.rejects(pay(true, 'debtor-uid', { pagoRegistradoPor: 'alice' }), { code: 'resource-exhausted' });
    assert.equal((await debt.get()).get('pagado'), true);
  });

  test('el programador rota grupos y reserva el cupo diario sin perder fechas pendientes', async () => {
    for (let index = 0; index < MAX_SCHEDULED_GROUPS_PER_RUN + 2; index += 1) {
      const group = db.collection('groups').doc(`group-${String(index).padStart(2, '0')}`);
      await group.set({ schedulesCheckedAt: Timestamp.fromMillis(0) });
      await group.collection('gastosProgramados').doc('schedule').set({
        nombre: 'Auditoria', descripcion: '', cantidadCentimos: 1001,
        pagadoPor: 'payer', participantes: ['alice', 'bob'],
        proximaFecha: '2020-01-01',
        proximaEjecucion: Timestamp.fromDate(scheduleInstant('2020-01-01', 'Europe/Madrid')),
        nextAttemptAt: Timestamp.fromDate(scheduleInstant('2020-01-01', 'Europe/Madrid')),
        timeZone: 'Europe/Madrid', frecuencia: null, createdByUid: 'payer-uid',
      });
    }
    await entryPoints.ejecutarGastosPeriodicos.run({});
    assert.equal((await db.collectionGroup('gastos').get()).size, MAX_SCHEDULED_GROUPS_PER_RUN);
    assert.equal((await db.collectionGroup('gastosProgramados').get()).size, 2);

    const budgetRef = db.collection('usageLimits').doc('scheduledOccurrences');
    await budgetRef.set({ day: new Date().toISOString().slice(0, 10), count: MAX_OCCURRENCES_PER_DAY - 1 });
    await entryPoints.ejecutarGastosPeriodicos.run({});
    await entryPoints.ejecutarGastosPeriodicos.run({});
    assert.equal((await budgetRef.get()).get('count'), MAX_OCCURRENCES_PER_DAY);
    assert.equal((await db.collectionGroup('gastosProgramados').get()).size, 1);
    assert.equal((await db.collectionGroup('gastos').get()).size, MAX_SCHEDULED_GROUPS_PER_RUN + 1);
  });

  test('un grupo atrasado no desplaza a otros ni consume todo el cupo del proyecto', async () => {
    const busy = await seedExpenseGroup();
    for (let index = 0; index < 10; index += 1) {
      await entryPoints.crearGasto.run(expenseInput({ fecha: '2000-01-01', frecuencia: 'Cada 7 días' }),
        { auth: { uid: 'payer-uid' } });
    }
    const normal = await entryPoints.crearGrupo.run(groupInput({ timeZone: 'UTC' }), { auth: { uid: 'normal-uid' } });
    const lastWeek = new Date(Date.now() - 7 * 86400000).toISOString().slice(0, 10);
    const created = await entryPoints.crearGasto.run(expenseInput({
      groupId: normal.groupId, pagadoPor: 'member_001', participantes: ['member_002'],
      fecha: lastWeek, frecuencia: 'Cada 7 días',
    }), { auth: { uid: 'normal-uid' } });
    await entryPoints.ejecutarGastosPeriodicos.run({});
    const normalSchedule = await db.doc(`groups/${normal.groupId}/gastosProgramados/${created.scheduleId}`).get();
    assert.ok(normalSchedule.get('proximaFecha') > new Date().toISOString().slice(0, 10));
    const checkedAt = (await busy.get()).get('schedulesCheckedAt');
    await entryPoints.crearGasto.run(expenseInput({ fecha: '2000-01-01', frecuencia: 'Cada 7 días' }),
      { auth: { uid: 'payer-uid' } });
    assert.ok((await busy.get()).get('schedulesCheckedAt').isEqual(checkedAt));
    const groupBudget = db.doc(`usageLimits/scheduledGroup_${busy.id}`);
    await groupBudget.set({ day: new Date().toISOString().slice(0, 10), count: MAX_OCCURRENCES_PER_GROUP_PER_DAY });
    const before = (await busy.collection('gastos').get()).size;
    await entryPoints.ejecutarGastosPeriodicos.run({});
    assert.equal((await busy.collection('gastos').get()).size, before);
    assert.equal((await db.doc('usageLimits/scheduledOccurrences').get()).get('count'), 2);
    assert.equal((await busy.collection('gastosProgramados').get()).size, 11);
  });

  test('los turnos avanzan ante grupos vacios y programaciones futuras', async () => {
    const { claimScheduledGroup } = require('../lib/scheduled-groups');
    const empty = db.doc('groups/empty');
    await empty.set({ schedulesCheckedAt: Timestamp.fromMillis(0) });
    assert.equal(await claimScheduledGroup(db, await empty.get(), Timestamp.now()), null);
    assert.equal((await empty.get()).get('schedulesCheckedAt'), undefined);

    const future = await seedExpenseGroup();
    const tomorrow = new Date(Date.now() + 86400000).toISOString().slice(0, 10);
    await entryPoints.crearGasto.run(expenseInput({ fecha: tomorrow }), { auth: { uid: 'payer-uid' } });
    const queued = await future.get();
    const claims = await Promise.all([
      claimScheduledGroup(db, queued, Timestamp.now()), claimScheduledGroup(db, queued, Timestamp.now()),
    ]);
    assert.deepEqual(claims, [null, null]);
    assert.ok((await future.get()).get('schedulesCheckedAt').toMillis() > 0);
    assert.equal((await future.collection('gastosProgramados').get()).size, 1);
  });

  test('invalid schedule timestamps are quarantined while group turns and healthy schedules advance', async () => {
    const { claimScheduledGroup } = require('../lib/scheduled-groups');
    const invalidRefs = [];
    // Occupy the entire first page with malformed legacy schedules.
    for (let index = 0; index < MAX_SCHEDULED_GROUPS_PER_RUN; index += 1) {
      const group = db.doc(`groups/quarantine-${index}`);
      const invalid = group.collection('gastosProgramados').doc('invalid');
      await group.set({ schedulesCheckedAt: Timestamp.fromMillis(0) });
      await invalid.set({ nextAttemptAt: index % 2 === 0 ? null : 'invalid-timestamp' });
      invalidRefs.push(invalid);
    }
    const healthy = db.doc('groups/healthy-after-quarantine');
    await healthy.set({ schedulesCheckedAt: Timestamp.fromMillis(1) });
    const scheduledDate = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    await healthy.collection('gastosProgramados').doc('healthy').set({
      nombre: 'Healthy', cantidadCentimos: 1000, pagadoPor: 'payer', participantes: ['debtor'],
      proximaFecha: scheduledDate, proximaEjecucion: Timestamp.fromMillis(1),
      nextAttemptAt: Timestamp.fromMillis(1), timeZone: 'UTC', frecuencia: null,
      createdByUid: 'healthy-owner',
    });

    await entryPoints.ejecutarGastosPeriodicos.run({});
    for (const invalid of invalidRefs) {
      const quarantined = await invalid.get();
      assert.equal(quarantined.get('nextAttemptAt'), undefined);
      assert.equal(quarantined.get('quarantineReason'), 'invalid-next-attempt-at');
      assert.ok(quarantined.get('quarantinedAt') instanceof Timestamp);
      assert.ok((await invalid.parent.parent.get()).get('schedulesCheckedAt').toMillis() > 1);
    }
    await entryPoints.ejecutarGastosPeriodicos.run({});
    assert.equal((await healthy.collection('gastos').get()).size, 1);

    // A healthy schedule within a quarantined group is discoverable on its next turn.
    for (const invalid of [invalidRefs[0], invalidRefs[1]]) {
      const group = invalid.parent.parent;
      await group.update({ schedulesCheckedAt: Timestamp.fromMillis(0) });
      const next = group.collection('gastosProgramados').doc('healthy');
      await next.set({ nextAttemptAt: Timestamp.fromMillis(1) });
      const claimed = await claimScheduledGroup(db, await group.get(), Timestamp.now());
      assert.equal(claimed.ref.path, next.path);
      assert.equal((await invalid.get()).get('nextAttemptAt'), undefined);
    }
  });

  test('ejecutarGastosPeriodicos creates shares and advances recurring schedules', async () => {
    const scheduledDate = new Date(Date.now() - 86400000).toISOString().slice(0, 10);
    const expectedNextDate = nextScheduledDate(scheduledDate, 'Cada 7 días');
    const scheduleRef = db.collection('groups').doc('group-1').collection('gastosProgramados').doc('schedule-1');
    await Promise.all([
      db.collection('groups').doc('group-1').set({ name: 'Viaje', schedulesCheckedAt: Timestamp.fromMillis(0) }),
      scheduleRef.set({
        nombre: 'Alquiler',
        cantidadCentimos: 1001,
        pagadoPor: 'member-b',
        participantes: ['member-a', 'member-b', 'member-c'],
        proximaFecha: scheduledDate,
        proximaEjecucion: Timestamp.fromDate(scheduleInstant(scheduledDate, 'Pacific/Auckland')),
        nextAttemptAt: Timestamp.fromDate(scheduleInstant(scheduledDate, 'Pacific/Auckland')),
        timeZone: 'Pacific/Auckland',
        frecuencia: 'Cada 7 días',
        createdByMemberId: 'member-b',
        createdByUid: 'owner-uid',
      }),
    ]);

    await entryPoints.ejecutarGastosPeriodicos.run({});

    const expenses = await db.collection('groups').doc('group-1').collection('gastos').where('scheduleId', '==', 'schedule-1').get();
    assert.equal(expenses.size, 1);
    assert.equal(expenses.docs[0].data().cantidadCentimos, 1001);

    const shares = await expenses.docs[0].ref.collection('divisiones').get();
    assert.deepEqual(
      shares.docs.map((share) => [share.id, share.data().cantidadCentimos, share.data().pagado]).sort(),
      [['member-a', 334, false], ['member-b', 334, true], ['member-c', 333, false]],
    );
    assert.equal(
      (await scheduleRef.get()).data().proximaFecha,
      expectedNextDate,
    );
  });

  test('ejecutarGastosPeriodicos does not write with an account being merged', async () => {
    const groupRef = db.collection('groups').doc('locked-group');
    const scheduleRef = groupRef.collection('gastosProgramados').doc('schedule-1');
    await Promise.all([
      groupRef.set({ name: 'Viaje', schedulesCheckedAt: Timestamp.fromMillis(0) }),
      scheduleRef.set({
        nombre: 'Alquiler',
        cantidadCentimos: 1000,
        pagadoPor: 'payer',
        participantes: ['debtor'],
        proximaFecha: '2024-01-31',
        proximaEjecucion: Timestamp.fromDate(scheduleInstant('2024-01-31', 'Europe/Madrid')),
        nextAttemptAt: Timestamp.fromDate(scheduleInstant('2024-01-31', 'Europe/Madrid')),
        timeZone: 'Europe/Madrid',
        frecuencia: 'Cada 7 días',
        createdByMemberId: 'payer',
        createdByUid: 'source-uid',
      }),
      db.collection('accountMerges').doc('source-uid').set({
        sourceUid: 'source-uid', status: 'running',
      }),
    ]);

    await assert.rejects(entryPoints.ejecutarGastosPeriodicos.run({}), AggregateError);
    assert.equal((await groupRef.collection('gastos').get()).empty, true);
    assert.ok((await groupRef.get()).get('schedulesCheckedAt').toMillis() > 0);
    await groupRef.collection('gastosProgramados').doc('other-schedule').set({
      nombre: 'Otra deuda', cantidadCentimos: 1000, pagadoPor: 'payer', participantes: ['debtor'],
      proximaFecha: '2024-02-01',
      proximaEjecucion: Timestamp.fromDate(scheduleInstant('2024-02-01', 'Europe/Madrid')),
      nextAttemptAt: Timestamp.fromDate(scheduleInstant('2024-02-01', 'Europe/Madrid')),
      timeZone: 'Europe/Madrid', frecuencia: null, createdByUid: 'other-uid',
    });
    await entryPoints.ejecutarGastosPeriodicos.run({});
    assert.equal((await groupRef.collection('gastos').get()).size, 1);
    assert.equal((await scheduleRef.get()).get('proximaFecha'), '2024-01-31');
  });

  test('onDeudaPagada notifies the creditor once when the same event is retried', async () => {
    await Promise.all([
      db.collection('groups').doc('group-1').collection('members').doc('creditor').set({ reclamadoPor: 'creditor-uid' }),
      db.doc('usuarios/creditor-uid/devices/phone').set({ fcmToken: 'emulator-token' }),
    ]);
    const sent = [];
    const messaging = getMessaging();
    const originalSend = messaging.send;
    messaging.send = async (message) => sent.push(message);

    try {
      for (let attempt = 0; attempt < 2; attempt++) {
        await entryPoints.onDeudaPagada.run(
          {
            before: { data: () => ({ pagado: false }) },
            after: {
              data: () => ({
                pagado: true,
                memberId: 'debtor',
                pagadoPor: 'creditor',
                pagoRegistradoPor: 'debtor',
              }),
            },
          },
          {
            eventId: 'payment-event-1',
            timestamp: new Date().toISOString(),
            params: { groupId: 'group-1', gastoId: 'expense-1', divisionId: 'debtor' },
          },
        );
      }
    } finally {
      messaging.send = originalSend;
    }

    assert.deepEqual(sent, [{
      token: 'emulator-token',
      notification: {
        title: '\u00a1Una deuda fue pagada!',
        body: 'El miembro debtor ha marcado su parte como pagada.',
      },
    }]);
  });

  test('recordatorioDeudas notifies a user with an outstanding debt', async () => {
    await Promise.all([
      db.doc('usuarios/debtor-uid/devices/phone').set({ fcmToken: 'reminder-token' }),
      db.collection('groupMembers').doc('group-1_debtor-uid').set({
        groupId: 'group-1',
        deviceId: 'debtor-uid',
      }),
      db.collection('groups').doc('group-1').collection('members').doc('debtor').set({
        reclamadoPor: 'debtor-uid',
      }),
      db.collection('groups').doc('group-1').collection('members').doc('aaa-identity').set({
        reclamadoPor: 'debtor-uid',
      }),
      db.collection('groups').doc('group-1').collection('gastos').doc('expense-1').set({
        pagadoPor: 'creditor',
      }),
      db.collection('groups').doc('group-1').collection('gastos').doc('expense-1').collection('divisiones').doc('debtor').set({
        groupId: 'group-1',
        memberId: 'debtor',
        pagadoPor: 'creditor',
        pagado: false,
        cantidadCentimos: 1250,
      }),
    ]);
    const sent = [];
    const messaging = getMessaging();
    const originalSend = messaging.send;
    messaging.send = async (message) => sent.push(message);

    try {
      await runDebtReminders({ db, messaging, now: new Date('2026-11-04T15:15:00Z') });
      await runDebtReminders({ db, messaging, now: new Date('2026-11-04T15:15:00Z') });
    } finally {
      messaging.send = originalSend;
    }

    assert.deepEqual(sent, [{
      token: 'reminder-token',
      notification: {
        title: 'Recordatorio de deudas',
        body: 'Tienes deudas pendientes en la app.',
      },
    }]);
    assert.equal((await db.collection('reminderDeliveries').get()).size, 1);
  });

  test('renombrarGrupo permits only admins and freezes merging accounts', async () => {
    const group = db.doc('groups/rename-group');
    await Promise.all([
      group.set({ name: 'Antes', ownerDeviceId: 'owner', allMembersAreAdmins: false }),
      db.doc('groupMembers/rename-group_member').set({ groupId: 'rename-group', deviceId: 'member' }),
    ]);
    const rename = (uid, nombre = '  Después  ', groupId = 'rename-group') =>
      entryPoints.renombrarGrupo.run({ groupId, nombre }, { auth: { uid } });
    await assert.rejects(rename('member'), { code: 'permission-denied' });
    await assert.rejects(rename('stranger'), { code: 'permission-denied' });
    assert.deepEqual(await rename('owner'), { renamed: true });
    assert.equal((await group.get()).get('name'), 'Después');
    await group.update({ allMembersAreAdmins: true });
    assert.deepEqual(await rename('member', 'Miembros'), { renamed: true });
    await assert.rejects(rename('stranger'), { code: 'permission-denied' });
    await db.doc('groupMembers/rename-group_stranger').set({ groupId: 'another-group', deviceId: 'stranger' });
    await assert.rejects(rename('stranger'), { code: 'permission-denied' });
    await db.doc('accountMerges/owner').set({ status: 'running' });
    await assert.rejects(rename('owner'), { code: 'failed-precondition' });
    assert.equal((await group.get()).get('name'), 'Miembros');
  });

  test('renombrarGrupo rejects invalid input and requires auth and App Check', async () => {
    for (const data of [
      {}, { groupId: 'bad/path', nombre: 'Valid' }, { groupId: 'group', nombre: '   ' },
      { groupId: 'group', nombre: 'a'.repeat(81) }, { groupId: 'group', nombre: 12 },
    ]) {
      await assert.rejects(entryPoints.renombrarGrupo.run(data, { auth: { uid: 'owner' } }), { code: 'invalid-argument' });
    }
    await assert.rejects(entryPoints.renombrarGrupo.run({}, {}), { code: 'unauthenticated' });
    await assert.rejects(exportedFunctions.renombrarGrupo.run(
      { groupId: 'group', nombre: 'Name' }, { auth: { uid: 'owner' } },
    ), { code: 'failed-precondition' });
  });

  async function seedReminderDivisions(count) {
    for (let i = 0; i < count; i++) {
      const uid = `user-${i}`;
      await Promise.all([
        db.doc(`usuarios/${uid}/devices/phone`).set({ fcmToken: uid }),
        db.doc(`groupMembers/reminder-group_${uid}`).set({ groupId: 'reminder-group', deviceId: uid }),
        db.doc(`groups/reminder-group/members/debtor-${i}`).set({ reclamadoPor: uid }),
        db.doc(`groups/reminder-group/gastos/expense/divisiones/debt-${i}`).set({
          groupId: 'reminder-group', memberId: `debtor-${i}`, pagadoPor: 'payer',
          pagado: false, cantidadCentimos: 100,
        }),
      ]);
    }
  }

  test('reminders enforce daily and run budgets and resume the durable cursor on the next day', async () => {
    await seedReminderDivisions(4);
    const sent = [];
    const input = {
      db, messaging: { send: async ({ token }) => sent.push(token) },
      now: new Date('2026-11-04T15:15:00Z'),
      limits: { ...REMINDER_LIMITS, divisionsPerRun: 2, divisionsPerDay: 6, sendsPerRun: 2, sendsPerDay: 3 },
    };
    assert.equal((await runDebtReminders(input)).sends, 2);
    assert.equal((await db.doc('backgroundJobs/debtReminders').get()).get('cursor'),
      'groups/reminder-group/gastos/expense/divisiones/debt-1');
    assert.equal((await runDebtReminders(input)).sends, 1);
    assert.deepEqual(sent, ['user-0', 'user-1', 'user-2']);
    assert.equal((await runDebtReminders(input)).status, 'idle');
    assert.equal((await db.doc('backgroundJobs/debtReminders').get()).get('sendsCharged'), 3);
    await runDebtReminders({ ...input, now: new Date('2026-11-05T15:15:00Z') });
    assert.deepEqual(sent, ['user-0', 'user-1', 'user-2', 'user-3']);
    assert.equal((await runDebtReminders({ ...input, now: new Date('2026-11-05T15:15:00Z') })).status, 'complete');
    assert.equal((await db.doc('backgroundJobs/debtReminders').get()).get('cursor'), null);
  });

  test('reminder retries charge failures, retry the pending division and eventually advance', async () => {
    await seedReminderDivisions(2);
    const attempted = [];
    const input = {
      db, now: new Date('2026-11-04T15:15:00Z'),
      limits: { ...REMINDER_LIMITS, divisionsPerRun: 2, attemptsPerDivision: 2 },
      messaging: { send: async ({ token }) => {
        attempted.push(token);
        if (token === 'user-0') throw new Error('FCM temporarily unavailable');
      } },
    };
    await runDebtReminders(input);
    let state = await db.doc('backgroundJobs/debtReminders').get();
    assert.equal(state.get('cursor'), null);
    assert.equal(state.get('sendsCharged'), 1);
    assert.equal(state.get('leaseUntil'), 0);
    await runDebtReminders(input);
    await runDebtReminders(input);
    state = await db.doc('backgroundJobs/debtReminders').get();
    assert.deepEqual(attempted, ['user-0', 'user-0', 'user-1']);
    assert.equal(state.get('sendsCharged'), 3);
    assert.equal(state.get('cursor'), 'groups/reminder-group/gastos/expense/divisiones/debt-1');
  });

  test('reminder lease blocks overlap and can be recovered after an invocation dies', async () => {
    await seedReminderDivisions(1);
    const stateRef = db.doc('backgroundJobs/debtReminders');
    const now = new Date('2026-11-04T15:15:00Z');
    await stateRef.set({ period: '2026-11-04', leaseUntil: Date.now() + 150_000, reservation: 'other-worker' });
    const sent = [];
    const input = { db, now, messaging: { send: async ({ token }) => sent.push(token) } };
    assert.equal((await runDebtReminders(input)).status, 'idle');
    assert.equal((await stateRef.get()).get('reservation'), 'other-worker');
    // A complete checkpoint from a crashed invocation can be resumed after its lease expires.
    await stateRef.set({
      period: '2026-11-04', cursor: null, divisionsCharged: 50, sendsCharged: 0,
      attempts: 1, attemptPath: 'groups/reminder-group/gastos/expense/divisiones/debt-0',
      leaseUntil: Date.now() - 1, reservation: 'dead-worker', done: false,
    });
    await runDebtReminders(input);
    assert.deepEqual(sent, ['user-0']);
    assert.equal((await stateRef.get()).get('divisionsCharged'), 100);
    assert.equal((await stateRef.get()).get('leaseUntil'), 0);
  });

  test('reminders checkpoint partial device delivery when the run send budget is exhausted', async () => {
    await seedReminderDivisions(1);
    await Promise.all([
      db.doc('usuarios/user-0/devices/tablet').set({ fcmToken: 'tablet' }),
      db.doc('usuarios/user-0/devices/watch').set({ fcmToken: 'watch' }),
    ]);
    const sent = [];
    const input = {
      db, now: new Date('2026-11-04T15:15:00Z'),
      limits: { ...REMINDER_LIMITS, sendsPerRun: 1 },
      messaging: { send: async ({ token }) => sent.push(token) },
    };
    await runDebtReminders(input);
    assert.equal(sent.length, 1);
    assert.equal((await db.doc('backgroundJobs/debtReminders').get()).get('cursor'), null);
    await runDebtReminders(input);
    assert.equal(sent.length, 2);
    await runDebtReminders(input);
    assert.deepEqual(sent, ['user-0', 'tablet', 'watch']);
    const state = await db.doc('backgroundJobs/debtReminders').get();
    assert.equal(state.get('sendsCharged'), 3);
    assert.equal(state.get('cursor'), 'groups/reminder-group/gastos/expense/divisiones/debt-0');
  });

  test('reminder read slots are reserved before querying and cannot exceed the daily ceiling', async () => {
    await seedReminderDivisions(3);
    const input = {
      db, now: new Date('2026-11-04T15:15:00Z'),
      limits: { ...REMINDER_LIMITS, divisionsPerRun: 2, divisionsPerDay: 2 },
      messaging: { send: async () => {} },
    };
    await runDebtReminders(input);
    assert.equal((await runDebtReminders(input)).status, 'daily-budget');
    const state = await db.doc('backgroundJobs/debtReminders').get();
    assert.equal(state.get('divisionsCharged'), 2);
    assert.equal(state.get('cursor'), 'groups/reminder-group/gastos/expense/divisiones/debt-1');
    assert.equal(state.get('done'), true);
  });

  test('reminders do no database work before the Madrid daily window', async () => {
    assert.equal((await runDebtReminders({
      db: {}, messaging: {}, now: new Date('2026-11-04T14:14:59Z'),
    })).status, 'outside-window');
  });

  test('expired, future and malformed payment events finish without sending notifications', async () => {
    for (const timestamp of [new Date(Date.now() - 25 * 60 * 60 * 1000).toISOString(),
      new Date(Date.now() + 60_000).toISOString(), 'malformed', undefined]) {
      let read = false;
      await entryPoints.onDeudaPagada.run({ before: { data: () => { read = true; } } }, {
        eventId: 'discarded-event', timestamp,
        params: { groupId: 'group', gastoId: 'expense', divisionId: 'division' },
      });
      assert.equal(read, false);
    }
    assert.equal((await db.collection('eventNotificationDeliveries').get()).empty, true);
  });

  test('device reminders retry only failed devices and remove invalid tokens', async () => {
    const { sendNotificationToUser } = require('../lib/device-notifications');
    const devices = db.collection('usuarios').doc('multi-uid').collection('devices');
    await Promise.all([
      devices.doc('phone').set({ fcmToken: 'phone' }),
      devices.doc('tablet').set({ fcmToken: 'tablet' }),
      devices.doc('old').set({ fcmToken: 'invalid' }),
    ]);
    const sent = [];
    let failTablet = true;
    const messaging = {
      send: async ({ token }) => {
        if (token === 'invalid') {
          throw Object.assign(new Error('Invalid'), { code: 'messaging/registration-token-not-registered' });
        }
        if (token === 'tablet' && failTablet) throw new Error('Unavailable');
        sent.push(token);
      },
    };
    const input = { db, messaging, uid: 'multi-uid', title: 'Aviso', body: 'Deuda', period: '2026-10-15' };
    await assert.rejects(sendNotificationToUser(input), AggregateError);
    assert.equal((await devices.doc('old').get()).exists, false);
    failTablet = false;
    await sendNotificationToUser(input);
    assert.deepEqual(sent.sort(), ['phone', 'tablet']);
  });
}
