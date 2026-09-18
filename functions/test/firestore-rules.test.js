'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { after, before, beforeEach, test } = require('node:test');
const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  deleteField,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} = require('firebase/firestore');

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId: 'demo-payb2-rules',
    firestore: {
      rules: fs.readFileSync(
        path.resolve(__dirname, '../../firestore.rules'),
        'utf8',
      ),
    },
  });
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await Promise.all([
      setDoc(doc(db, 'groups/group-1'), {
        name: 'Viaje',
        ownerDeviceId: 'creditor-uid',
      }),
      setDoc(doc(db, 'groupMembers/group-1_creditor-uid'), {
        groupId: 'group-1',
        deviceId: 'creditor-uid',
      }),
      setDoc(doc(db, 'groupMembers/group-1_debtor-uid'), {
        groupId: 'group-1',
        deviceId: 'debtor-uid',
      }),
      setDoc(doc(db, 'groupMembers/group-1_other-uid'), {
        groupId: 'group-1',
        deviceId: 'other-uid',
      }),
      setDoc(doc(db, 'groups/group-1/members/creditor'), {
        name: 'Acreedor',
        reclamadoPor: 'creditor-uid',
      }),
      setDoc(doc(db, 'groups/group-1/members/debtor'), {
        name: 'Deudor',
        reclamadoPor: 'debtor-uid',
      }),
      setDoc(doc(db, 'groups/group-1/members/other'), {
        name: 'Otro',
        reclamadoPor: 'other-uid',
      }),
      setDoc(doc(db, 'groups/group-1/gastos/expense-1'), {
        nombre: 'Cena',
        cantidadCentimos: 3000,
        pagadoPor: 'creditor',
        createdByMemberId: 'creditor',
        createdByUid: 'creditor-uid',
        fecha: new Date(),
      }),
      setDoc(
        doc(db, 'groups/group-1/gastos/expense-1/divisiones/debtor'),
        {
          memberId: 'debtor',
          groupId: 'group-1',
          cantidadCentimos: 1500,
          pagadoPor: 'creditor',
          pagado: false,
        },
      ),
    ]);
  });
});

after(async () => {
  await testEnv.cleanup();
});

test('un miembro puede leer su grupo y un usuario ajeno no', async () => {
  const memberDb = testEnv.authenticatedContext('debtor-uid').firestore();
  const outsiderDb = testEnv.authenticatedContext('outsider-uid').firestore();

  await assertSucceeds(getDoc(doc(memberDb, 'groups/group-1')));
  await assertFails(getDoc(doc(outsiderDb, 'groups/group-1')));
});

test('el deudor puede marcar su propia deuda como pagada', async () => {
  const db = testEnv.authenticatedContext('debtor-uid').firestore();

  await assertSucceeds(
    updateDoc(debtRef(db), {
      pagado: true,
      pagadoEn: serverTimestamp(),
      pagoRegistradoPor: 'debtor',
    }),
  );
});

test('el acreedor puede registrar como cobrada una deuda que se le debe', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();

  await assertSucceeds(
    updateDoc(debtRef(db), {
      pagado: true,
      pagadoEn: serverTimestamp(),
      pagoRegistradoPor: 'creditor',
    }),
  );
});

test('otro miembro no puede cerrar una deuda ajena', async () => {
  const db = testEnv.authenticatedContext('other-uid').firestore();

  await assertFails(
    updateDoc(debtRef(db), {
      pagado: true,
      pagadoEn: serverTimestamp(),
      pagoRegistradoPor: 'other',
    }),
  );
});

test('el acreedor puede devolver un pago a pendiente', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(debtRef(context.firestore()), {
      pagado: true,
      pagadoEn: new Date(),
      pagoRegistradoPor: 'debtor',
    });
  });
  const db = testEnv.authenticatedContext('creditor-uid').firestore();

  await assertSucceeds(
    updateDoc(debtRef(db), {
      pagado: false,
      pagadoEn: deleteField(),
      pagoRegistradoPor: deleteField(),
    }),
  );
});

function debtRef(db) {
  return doc(db, 'groups/group-1/gastos/expense-1/divisiones/debtor');
}
