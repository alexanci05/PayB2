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
  collectionGroup,
  getDocs,
  getDoc,
  query,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
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

test('un miembro puede consultar las divisiones de su grupo', async () => {
  const memberDb = testEnv.authenticatedContext('debtor-uid').firestore();
  const outsiderDb = testEnv.authenticatedContext('outsider-uid').firestore();
  const memberQuery = query(
    collectionGroup(memberDb, 'divisiones'),
    where('groupId', '==', 'group-1'),
  );
  const outsiderQuery = query(
    collectionGroup(outsiderDb, 'divisiones'),
    where('groupId', '==', 'group-1'),
  );

  await assertSucceeds(getDocs(memberQuery));
  await assertFails(getDocs(outsiderQuery));
});

test('el propietario debe renombrar por callable incluso con un nombre valido', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  const group = doc(db, 'groups/group-1');

  await assertFails(updateDoc(group, { name: 'Viaje nuevo' }));
  await assertFails(updateDoc(group, { name: 'A'.repeat(80) }));
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

test('la administracion compartida tampoco permite saltarse las cuotas de renombrado', async () => {
  const member = doc(testEnv.authenticatedContext('debtor-uid').firestore(), 'groups/group-1');
  const outsider = doc(testEnv.authenticatedContext('outsider-uid').firestore(), 'groups/group-1');
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'groups/group-1'), { allMembersAreAdmins: true });
  });
  await assertFails(updateDoc(member, { name: 'Compartido' }));
  await assertFails(updateDoc(outsider, { name: 'Ajeno' }));
  await assertFails(updateDoc(member, { name: '' }));
  await assertFails(updateDoc(member, { name: 'A'.repeat(81) }));
  await assertFails(updateDoc(member, { name: 'Cambio', ownerDeviceId: 'debtor-uid' }));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'accountMerges/debtor-uid'), { status: 'prepared' });
  });
  await assertFails(updateDoc(member, { name: 'Bloqueado' }));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await deleteDoc(doc(context.firestore(), 'accountMerges/debtor-uid'));
    await updateDoc(doc(context.firestore(), 'groups/group-1'), { allMembersAreAdmins: false });
  });
  await assertFails(updateDoc(member, { name: 'Revocado' }));
});

test('el flag solo se configura por callable y los miembros siguen siendo de creacion exclusiva del servidor', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'groups/group-1'), { allMembersAreAdmins: true });
  });
  for (const uid of ['creditor-uid', 'debtor-uid', 'outsider-uid']) {
    const db = testEnv.authenticatedContext(uid).firestore();
    await assertFails(updateDoc(doc(db, 'groups/group-1'), { allMembersAreAdmins: false }));
    await assertFails(updateDoc(doc(db, 'groups/group-1'), { name: 'Cambio', allMembersAreAdmins: false }));
    await assertFails(setDoc(doc(db, 'groups/group-1/members/new'), { name: 'Nuevo', reclamadoPor: null }));
  }
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

test('el deudor no puede saltarse la callable de pagos con una escritura directa', async () => {
  const db = testEnv.authenticatedContext('debtor-uid').firestore();

  await assertFails(
    updateDoc(debtRef(db), {
      pagado: true,
      pagadoEn: serverTimestamp(),
      pagoRegistradoPor: 'debtor',
    }),
  );
});

test('el acreedor tampoco puede registrar un cobro directamente', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();

  await assertFails(
    updateDoc(debtRef(db), {
      pagado: true,
      pagadoEn: serverTimestamp(),
      pagoRegistradoPor: 'creditor',
    }),
  );
});

test('ni el deudor ni el acreedor pueden falsificar la fecha de pago', async () => {
  for (const member of ['debtor', 'creditor']) {
    const db = testEnv.authenticatedContext(`${member}-uid`).firestore();
    for (const pagadoEn of [new Date(0), new Date('2100-01-01T00:00:00Z'), null, 'now']) {
      await assertFails(updateDoc(debtRef(db), {
        pagado: true, pagadoEn, pagoRegistradoPor: member,
      }));
    }
    await assertFails(updateDoc(debtRef(db), {
      pagado: true, pagoRegistradoPor: member,
    }));
  }
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

test('la administracion compartida no permite pagar ni reabrir deudas ajenas', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'groups/group-1'), { allMembersAreAdmins: true });
  });
  const db = testEnv.authenticatedContext('other-uid').firestore();
  for (const pagoRegistradoPor of ['other', 'creditor', 'debtor']) {
    await assertFails(updateDoc(debtRef(db), {
      pagado: true, pagadoEn: serverTimestamp(), pagoRegistradoPor,
    }));
  }
  await assertFails(deleteDoc(doc(db, 'groups/group-1/gastos/expense-1')));
  await assertFails(deleteDoc(doc(db, 'groups/group-1/gastosProgramados/schedule-1')));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(debtRef(context.firestore()), {
      pagado: true, pagadoEn: new Date(), pagoRegistradoPor: 'debtor',
    });
  });
  await assertFails(updateDoc(debtRef(db), {
    pagado: false, pagadoEn: deleteField(), pagoRegistradoPor: deleteField(),
  }));
});

test('las reaperturas tambien deben pasar por la callable aunque sean del acreedor', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  for (const registeredBy of ['debtor', 'creditor']) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(debtRef(context.firestore()), {
        pagado: true,
        pagadoEn: new Date(),
        pagoRegistradoPor: registeredBy,
      });
    });
    await assertFails(
      updateDoc(debtRef(db), {
        pagado: false,
        pagadoEn: deleteField(),
        pagoRegistradoPor: deleteField(),
      }),
    );
  }
});

test('una cuenta en proceso de fusion no puede escribir', async () => {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'accountMerges/creditor-uid'), {
      sourceUid: 'creditor-uid',
      status: 'prepared',
    });
  });
  const db = testEnv.authenticatedContext('creditor-uid').firestore();

  await assertFails(updateDoc(doc(db, 'groups/group-1'), { name: 'Bloqueado' }));
  await assertFails(setDoc(doc(db, 'usuarios/creditor-uid'), { fcmToken: 'token' }));
  await assertFails(
    updateDoc(debtRef(db), {
      pagado: true,
      pagadoEn: serverTimestamp(),
      pagoRegistradoPor: 'creditor',
    }),
  );
});

function debtRef(db) {
  return doc(db, 'groups/group-1/gastos/expense-1/divisiones/debtor');
}

test('los dispositivos solo se registran por servidor y cada cuenta puede leer y borrar los suyos', async () => {
  const owner = testEnv.authenticatedContext('creditor-uid').firestore();
  const other = testEnv.authenticatedContext('other-uid').firestore();
  const anonymous = testEnv.unauthenticatedContext().firestore();
  const path = 'usuarios/creditor-uid/devices/phone';
  const device = { fcmToken: 'phone-token', tokenUpdatedAt: serverTimestamp() };
  for (const db of [owner, other, anonymous]) {
    await assertFails(setDoc(doc(db, path), device));
  }
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), path), device);
  });
  for (const db of [owner, other, anonymous]) {
    await assertFails(updateDoc(doc(db, path), { fcmToken: 'replacement-token' }));
    await assertFails(setDoc(doc(db, path), device));
  }
  await assertSucceeds(getDoc(doc(owner, path)));
  await assertFails(getDoc(doc(other, path)));
  await assertFails(getDoc(doc(anonymous, path)));
  await assertFails(deleteDoc(doc(anonymous, path)));
  await assertFails(deleteDoc(doc(other, path)));
  await assertSucceeds(deleteDoc(doc(owner, path)));
});

test('el registro compartido de dispositivos no es accesible por clientes', async () => {
  const db = testEnv.authenticatedContext('creditor-uid').firestore();
  const registry = doc(db, 'deviceRegistries/creditor-uid');
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), registry.path), { revision: 1 });
  });
  await assertFails(getDoc(registry));
  await assertFails(setDoc(registry, { revision: 0 }));
  await assertFails(updateDoc(registry, { revision: 2 }));
  await assertFails(deleteDoc(registry));
});
