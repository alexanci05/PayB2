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

  function expenseInput(overrides = {}) {
    return {
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
    const [expenses, schedules] = await Promise.all([
      groupRef.collection('gastos').get(),
      groupRef.collection('gastosProgramados').get(),
    ]);
    assert.equal(expenses.size, 0);
    assert.equal(schedules.size, 0);
  }

  test('crearGrupo reserves a code and creates the group membership', async () => {
    const result = await entryPoints.crearGrupo.run(
      { nombre: 'Viaje', miembros: ['Ana', 'Luis'] },
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
    assert.equal(schedule.proximaFecha.toDate().toISOString().slice(0, 10), '2099-01-31');
    assert.equal(schedule.createdByMemberId, 'payer');
    assert.equal(schedule.createdByUid, 'payer-uid');
    assert.ok(schedule.created);
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
    assert.equal(schedule.proximaFecha.toDate().toISOString(), '2024-02-29T12:00:00.000Z');
    assert.deepEqual(schedule.participantes, ['alice', 'bob']);

    const divisions = await expenses.docs[0].ref.collection('divisiones').get();
    assert.deepEqual(
      divisions.docs.map((doc) => [doc.id, doc.data().cantidadCentimos, doc.data().pagado]).sort(),
      [['alice', 334, false], ['bob', 334, false], ['payer', 333, true]],
    );
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

  test('ejecutarGastosPeriodicos creates shares and advances recurring schedules', async () => {
    const scheduledAt = Timestamp.fromDate(new Date('2024-01-31T09:30:00.000Z'));
    const scheduleRef = db.collection('groups').doc('group-1').collection('gastosProgramados').doc('schedule-1');
    await Promise.all([
      db.collection('groups').doc('group-1').set({ name: 'Viaje' }),
      scheduleRef.set({
        nombre: 'Alquiler',
        cantidadCentimos: 1001,
        pagadoPor: 'member-b',
        participantes: ['member-a', 'member-b', 'member-c'],
        proximaFecha: scheduledAt,
        frecuencia: 'Mensual (mismo d\u00eda todos los meses)',
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
      '2024-02-29T09:30:00.000Z',
    );
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
      db.collection('groups').doc('group-1').collection('gastos').doc('expense-1').set({
        pagadoPor: 'creditor',
      }),
      db.collection('groups').doc('group-1').collection('gastos').doc('expense-1').collection('divisiones').doc('debtor').set({
        memberId: 'debtor',
        pagado: false,
        cantidad: 12.50,
      }),
    ]);
    const sent = [];
    const messaging = getMessaging();
    const originalSend = messaging.send;
    messaging.send = async (message) => sent.push(message);

    try {
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
  });
}
