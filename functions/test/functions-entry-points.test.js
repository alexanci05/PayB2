'use strict';

const assert = require('node:assert/strict');
const { after, beforeEach, test } = require('node:test');

if (!process.env.FIRESTORE_EMULATOR_HOST) {
  test('Functions entry points require the Firestore emulator', { skip: 'Run through firebase emulators:exec --only firestore.' }, () => {});
} else {
  process.env.GCLOUD_PROJECT ||= 'demo-payb2-functions';

  const { deleteApp, getApp } = require('firebase-admin/app');
  const { getFirestore, Timestamp } = require('firebase-admin/firestore');
  const { getMessaging } = require('firebase-admin/messaging');
  const entryPoints = require('../index');
  const {
    AccountMergeConflictError,
    activateAccountMerge,
    cancelAccountMerge,
    completeAccountMerge,
    mergeAnonymousAccountData,
    prepareAccountMerge,
  } = require('../lib/account-merge');
  const db = getFirestore();
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
      groupRef.set({ name: 'Viaje', ownerDeviceId: 'payer-uid' }),
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
      timeZoneOffsetMinutes: 0,
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
      { requestId: db.collection('groups').doc().id, nombre: 'Viaje', miembros: ['Ana', 'Luis'] },
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
    assert.equal(code.data().groupId, result.groupId);
    assert.deepEqual(membership.data().groupId, result.groupId);
    assert.deepEqual(members.docs.map((member) => member.data().name), ['Ana', 'Luis']);
  });

  test('crearGrupo rejects more than 50 members without creating documents', async () => {
    const miembros = Array.from({ length: 51 }, (_, index) => `Miembro ${index + 1}`);

    await assert.rejects(
      entryPoints.crearGrupo.run(
        { requestId: db.collection('groups').doc().id, nombre: 'Viaje', miembros },
        { auth: { uid: 'owner-uid' } },
      ),
      { code: 'invalid-argument' },
    );

    await assertNoGroupCreationWrites();
  });

  test('crearGrupo replays the same request with one group, code and membership', async () => {
    const input = { requestId: db.collection('groups').doc().id, nombre: 'Viaje', miembros: ['Ana', 'Luis'] };
    const auth = { auth: { uid: 'owner-uid' } };

    const first = await entryPoints.crearGrupo.run(input, auth);
    const repeated = await entryPoints.crearGrupo.run({ ...input }, auth);

    assert.deepEqual(repeated, first);
    await assertSingleCreatedGroup(first);
  });

  test('crearGrupo handles concurrent retries with one group, code and membership', async () => {
    const input = { requestId: db.collection('groups').doc().id, nombre: 'Viaje', miembros: ['Ana', 'Luis'] };
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
    const input = { requestId: db.collection('groups').doc().id, nombre: 'Viaje', miembros: ['Ana', 'Luis'] };
    const auth = { auth: { uid: 'owner-uid' } };
    const first = await entryPoints.crearGrupo.run(input, auth);

    await assert.rejects(
      entryPoints.crearGrupo.run({ ...input, miembros: ['Ana', 'Lucia'] }, auth),
      { code: 'failed-precondition' },
    );
    await assertSingleCreatedGroup(first);
  });

  test('crearGrupo recovers identical IDs after the first response is lost', async () => {
    const input = { requestId: db.collection('groups').doc().id, nombre: 'Viaje', miembros: ['Ana', 'Luis'] };
    const auth = { auth: { uid: 'owner-uid' } };
    await entryPoints.crearGrupo.run(input, auth);
    const original = (await db.collection('groups').get()).docs[0];
    assert.ok(original);

    const recovered = await entryPoints.crearGrupo.run({ ...input }, auth);

    assert.deepEqual(recovered, { groupId: original.id, groupCode: original.get('groupCode') });
    await assertSingleCreatedGroup(recovered);
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
    assert.equal(user.get('deviceId'), 'target-uid');
    assert.equal(user.get('fcmToken'), 'token');
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
        { requestId: db.collection('groups').doc().id, nombre: 'Bloqueado', miembros: ['Ana'] },
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

  test('a prepared merge can be canceled before changing accounts', async () => {
    const ticket = await prepareAccountMerge(db, 'source-uid');
    await cancelAccountMerge(db, 'source-uid', ticket);

    assert.equal((await db.collection('accountMerges').doc('source-uid').get()).exists, false);
    const created = await entryPoints.crearGrupo.run(
      { requestId: db.collection('groups').doc().id, nombre: 'Disponible', miembros: ['Ana'] },
      { auth: { uid: 'source-uid' } },
    );
    assert.ok(created.groupId);
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

  test('reclamarMiembro restores a legacy claim missing membership.memberId', async () => {
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
    assert.equal(expense.cantidad, 10.01);
    assert.equal(expense.fecha.toDate().toISOString().slice(0, 10), '2024-01-31');
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
      assert.equal(division.cantidad, division.cantidadCentimos / 100);
      assert.equal(division.pagadoPor, 'payer');
      assert.equal(division.fecha.toDate().toISOString().slice(0, 10), '2024-01-31');
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
    assert.equal(schedule.cantidad, 10.01);
    assert.equal(schedule.pagadoPor, 'payer');
    assert.deepEqual(schedule.participantes, ['alice', 'bob']);
    assert.equal(schedule.frecuencia, frecuencia);
    assert.equal(schedule.diaAncla, 31);
    assert.equal(schedule.proximaFecha.toDate().toISOString().slice(0, 10), '2099-01-31');
    assert.equal(schedule.createdByMemberId, 'payer');
    assert.equal(schedule.createdByUid, 'payer-uid');
    assert.ok(schedule.created);
  });

  test('crearGasto interprets today using the device time-zone offset', async () => {
    const groupRef = await seedExpenseGroup();
    const utcDate = new Date().toISOString().slice(0, 10);
    const offsetMinutes = [14 * 60, -14 * 60].find((offset) =>
      new Date(Date.now() + offset * 60 * 1000).toISOString().slice(0, 10) !== utcDate,
    );
    assert.notEqual(offsetMinutes, undefined);
    const clientDate = new Date(Date.now() + offsetMinutes * 60 * 1000)
      .toISOString()
      .slice(0, 10);

    const result = await entryPoints.crearGasto.run(
      expenseInput({ fecha: clientDate, timeZoneOffsetMinutes: offsetMinutes }),
      { auth: { uid: 'payer-uid' } },
    );

    assert.ok(result.gastoId);
    assert.equal(result.scheduleId, null);
    assert.equal((await groupRef.collection('gastos').get()).size, 1);
    assert.equal((await groupRef.collection('gastosProgramados').get()).size, 0);
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
    assert.equal(expense.fecha.toDate().toISOString(), '2024-01-31T12:00:00.000Z');
    assert.equal(expense.cantidadCentimos, 1001);
    assert.equal(expense.pagadoPor, 'payer');
    assert.equal(schedule.frecuencia, frecuencia);
    assert.equal(schedule.diaAncla, 31);
    assert.equal(schedule.proximaFecha.toDate().toISOString(), '2024-02-29T12:00:00.000Z');
    assert.deepEqual(schedule.participantes, ['alice', 'bob']);

    const divisions = await expenses.docs[0].ref.collection('divisiones').get();
    assert.deepEqual(
      divisions.docs.map((doc) => [doc.id, doc.data().cantidadCentimos, doc.data().pagado]).sort(),
      [['alice', 334, false], ['bob', 334, false], ['payer', 333, true]],
    );
  });

  test('crearGasto catches up monthly occurrences while preserving its anchor', async () => {
    const groupRef = await seedExpenseGroup();
    const result = await entryPoints.crearGasto.run(
      expenseInput({ fecha: '2024-01-31', frecuencia: 'Mensual (mismo d\u00eda todos los meses)' }),
      { auth: { uid: 'payer-uid' } },
    );
    const scheduleRef = groupRef.collection('gastosProgramados').doc(result.scheduleId);
    assert.equal((await scheduleRef.get()).get('diaAncla'), 31);

    await entryPoints.ejecutarGastosPeriodicos.run({});

    const [schedule, expenses] = await Promise.all([
      scheduleRef.get(),
      groupRef.collection('gastos').where('scheduleId', '==', result.scheduleId).get(),
    ]);
    const occurrenceDates = new Set(
      expenses.docs.map((doc) => doc.get('fecha').toDate().toISOString()),
    );
    assert.equal(schedule.get('diaAncla'), 31);
    assert.ok(schedule.get('proximaFecha').toMillis() > Date.now());
    assert.ok(occurrenceDates.has('2024-01-31T12:00:00.000Z'));
    assert.ok(occurrenceDates.has('2024-02-29T12:00:00.000Z'));
    assert.ok(occurrenceDates.has('2024-03-31T12:00:00.000Z'));
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

  test('crearGasto rejects callers without group membership or payer ownership', async () => {
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
    await assert.rejects(
      entryPoints.crearGasto.run({ ...input, pagadoPor: 'other-payer' }, { auth: { uid: 'payer-uid' } }),
      { code: 'permission-denied' },
    );
    await assertNoExpenseWrites(groupRef);
  });

  test('crearGasto rejects unknown participants and invalid amounts atomically', async () => {
    const groupRef = await seedExpenseGroup();
    const input = expenseInput({ fecha: '2099-01-31' });
    await assert.rejects(
      entryPoints.crearGasto.run({ ...input, participantes: ['alice', 'missing'] }, { auth: { uid: 'payer-uid' } }),
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

  test('eliminarGasto removes an expense and every division but can preserve its series', async () => {
    const groupRef = await seedExpenseGroup();
    const created = await entryPoints.crearGasto.run(
      expenseInput({ frecuencia: 'Mensual (mismo d\u00eda todos los meses)' }),
      { auth: { uid: 'payer-uid' } },
    );

    assert.deepEqual(
      await entryPoints.eliminarGasto.run(
        { groupId: groupRef.id, gastoId: created.gastoId, eliminarSerie: false },
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
    assert.equal(schedule.exists, true);
  });

  test('eliminarGasto removes the linked series and is safe to retry', async () => {
    const groupRef = await seedExpenseGroup();
    const created = await entryPoints.crearGasto.run(
      expenseInput({ frecuencia: 'Mensual (mismo d\u00eda todos los meses)' }),
      { auth: { uid: 'payer-uid' } },
    );
    const input = { groupId: groupRef.id, gastoId: created.gastoId, eliminarSerie: true };

    assert.deepEqual(await entryPoints.eliminarGasto.run(input, { auth: { uid: 'payer-uid' } }), { deleted: true });
    assert.deepEqual(await entryPoints.eliminarGasto.run(input, { auth: { uid: 'payer-uid' } }), { deleted: false });
    assert.equal((await groupRef.collection('gastosProgramados').doc(created.scheduleId).get()).exists, false);
  });

  test('eliminarGasto rejects an unauthenticated or unrelated caller', async () => {
    const groupRef = await seedExpenseGroup();
    const created = await entryPoints.crearGasto.run(expenseInput(), { auth: { uid: 'payer-uid' } });
    const input = { groupId: groupRef.id, gastoId: created.gastoId, eliminarSerie: false };

    await assert.rejects(entryPoints.eliminarGasto.run(input, {}), { code: 'unauthenticated' });
    await assert.rejects(
      entryPoints.eliminarGasto.run(input, { auth: { uid: 'outsider-uid' } }),
      { code: 'permission-denied' },
    );
    assert.equal((await groupRef.collection('gastos').doc(created.gastoId).get()).exists, true);
  });

  test('ejecutarGastosPeriodicos creates shares and advances recurring schedules', async () => {
    const scheduledDate = new Date(Date.now() - 24 * 60 * 60 * 1000);
    scheduledDate.setUTCMilliseconds(0);
    const scheduledAt = Timestamp.fromDate(scheduledDate);
    const expectedNextDate = new Date(scheduledDate.getTime() + 7 * 24 * 60 * 60 * 1000);
    const scheduleRef = db.collection('groups').doc('group-1').collection('gastosProgramados').doc('schedule-1');
    await Promise.all([
      db.collection('groups').doc('group-1').set({ name: 'Viaje' }),
      scheduleRef.set({
        nombre: 'Alquiler',
        cantidadCentimos: 1001,
        pagadoPor: 'member-b',
        participantes: ['member-a', 'member-b', 'member-c'],
        proximaFecha: scheduledAt,
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
      (await scheduleRef.get()).data().proximaFecha.toDate().toISOString(),
      expectedNextDate.toISOString(),
    );
  });

  test('ejecutarGastosPeriodicos does not write with an account being merged', async () => {
    const groupRef = db.collection('groups').doc('locked-group');
    const scheduleRef = groupRef.collection('gastosProgramados').doc('schedule-1');
    await Promise.all([
      groupRef.set({ name: 'Viaje' }),
      scheduleRef.set({
        nombre: 'Alquiler',
        cantidadCentimos: 1000,
        pagadoPor: 'payer',
        participantes: ['debtor'],
        proximaFecha: Timestamp.fromMillis(Date.now() - 1000),
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
  });

  test('onDeudaPagada sends the creditor a notification when a debtor pays', async () => {
    await Promise.all([
      db.collection('groups').doc('group-1').collection('members').doc('creditor').set({ reclamadoPor: 'creditor-uid' }),
      db.collection('usuarios').doc('creditor-uid').set({ fcmToken: 'emulator-token' }),
    ]);
    const sent = [];
    const messaging = getMessaging();
    const originalSend = messaging.send;
    messaging.send = async (message) => sent.push(message);

    try {
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
        { params: { groupId: 'group-1', gastoId: 'expense-1', divisionId: 'debtor' } },
      );
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
      db.collection('usuarios').doc('debtor-uid').set({ fcmToken: 'reminder-token' }),
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
        cantidad: 12.50,
      }),
    ]);
    const sent = [];
    const messaging = getMessaging();
    const originalSend = messaging.send;
    messaging.send = async (message) => sent.push(message);

    try {
      await entryPoints.recordatorioDeudas.run({});
      await entryPoints.recordatorioDeudas.run({});
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
}
