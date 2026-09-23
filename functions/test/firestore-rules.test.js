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
  deleteDoc,
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
      setDoc(doc(db, 'groups/group-1/gastosProgramados/schedule-1'), {
        nombre: 'Cena', createdByUid: 'creditor-uid',
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

test('el propietario puede renombrar su grupo con un nombre valido', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  const group = doc(db, 'groups/group-1');

  await assertSucceeds(updateDoc(group, { name: 'Viaje nuevo' }));
  await assertSucceeds(updateDoc(group, { name: 'A'.repeat(80) }));
});

test('el propietario no puede usar nombres invalidos', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  const group = doc(db, 'groups/group-1');

  await assertFails(updateDoc(group, { name: '' }));
  await assertFails(updateDoc(group, { name: 'A'.repeat(81) }));
  await assertFails(updateDoc(group, { name: 123 }));
});

test('el propietario no puede cambiar otros campos ni al renombrar', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  const group = doc(db, 'groups/group-1');

  await assertFails(updateDoc(group, { groupCode: 'OTRO' }));
  await assertFails(updateDoc(group, {
    name: 'Viaje nuevo', groupCode: 'OTRO',
  }));
  await assertFails(updateDoc(group, { ownerDeviceId: 'debtor-uid' }));
  await assertFails(updateDoc(group, {
    name: 'Viaje nuevo', ownerDeviceId: 'debtor-uid',
  }));
  await assertFails(updateDoc(group, {
    name: 'Viaje nuevo', description: 'Campo extra',
  }));
});

test('un miembro que no es propietario no puede renombrar el grupo', async () => {
  const db = testEnv.authenticatedContext('debtor-uid').firestore();

  await assertFails(updateDoc(doc(db, 'groups/group-1'), {
    name: 'Viaje nuevo',
  }));
});

test('el propietario no puede eliminar directamente un grupo con subcolecciones', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();

  await assertFails(deleteDoc(doc(db, 'groups/group-1')));
});

test('un cliente no puede crear gastos, divisiones ni programaciones directamente', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  await assertFails(setDoc(doc(db, 'groups/group-1/gastos/otro'), {
    nombre: 'Manipulado', cantidadCentimos: 3000, pagadoPor: 'creditor',
    createdByMemberId: 'creditor', createdByUid: 'creditor-uid', fecha: new Date(),
  }));
  await assertFails(setDoc(doc(db, 'groups/group-1/gastos/expense-1/divisiones/other'), {
    memberId: 'other', groupId: 'group-1', cantidadCentimos: 50000,
    pagadoPor: 'creditor', pagado: false,
  }));
  await assertFails(setDoc(doc(db, 'groups/group-1/gastosProgramados/otro'), {
    nombre: 'Manipulado', cantidadCentimos: 3000, pagadoPor: 'creditor',
    participantes: ['debtor'], frecuencia: null, proximaFecha: new Date(),
    createdByMemberId: 'creditor', createdByUid: 'creditor-uid',
  }));
});

test('un cliente no puede crear, actualizar ni eliminar miembros directamente', async () => {
  const ownerDb = testEnv.authenticatedContext('creditor-uid').firestore();
  const memberDb = testEnv.authenticatedContext('debtor-uid').firestore();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'groups/group-1/members/unclaimed'), {
      name: 'Sin reclamar', reclamadoPor: null,
    });
  });

  await assertFails(setDoc(doc(ownerDb, 'groups/group-1/members/new'), {
    name: 'Nuevo', reclamadoPor: null,
  }));
  await assertFails(updateDoc(doc(ownerDb, 'groups/group-1/members/debtor'), {
    name: 'Cambiado',
  }));
  await assertFails(deleteDoc(doc(ownerDb, 'groups/group-1/members/debtor')));
  await assertFails(updateDoc(doc(memberDb, 'groups/group-1/members/unclaimed'), {
    reclamadoPor: 'debtor-uid',
  }));
});

test('un cliente no puede eliminar directamente gastos ni divisiones', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  await assertFails(deleteDoc(debtRef(db)));
  await assertFails(deleteDoc(doc(db, 'groups/group-1/gastos/expense-1')));
  await assertFails(deleteDoc(doc(db, 'groups/group-1/gastosProgramados/schedule-1')));
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
