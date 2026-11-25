const functions = require('firebase-functions/v1');
const { initializeApp } = require('firebase-admin/app');
const { getFirestore, FieldValue, Timestamp } = require('firebase-admin/firestore');
const { getMessaging } = require('firebase-admin/messaging');
const { createHash, randomInt } = require('node:crypto');
initializeApp();

const db = getFirestore();
const messaging = getMessaging();
const {
  centsFromAmount,
  splitCents,
  nextScheduledDate,
  scheduledOccurrenceId,
  divisionId,
  parseCalendarDate,
  validateTimeZone,
  todayInZone,
  scheduleInstant,
} = require('./lib/scheduled-occurrences');
const { debtNotificationForTransition } = require('./lib/debt-notifications');
const { sendNotificationToUser } = require('./lib/device-notifications');
const { registerMessagingDevice } = require('./lib/device-registration');
const { registerDebtPayment } = require('./lib/debt-payments');
const { runDebtReminders } = require('./lib/debt-reminders');
const { notificationEventRejection } = require('./lib/notification-event-policy');
const { claimScheduledGroup } = require('./lib/scheduled-groups');
const { secureCallable } = require('./lib/secure-callable');
const { reserveProjectCapacity } = require('./lib/usage-limits');
const {
  BACKGROUND_OPTIONS,
  MAX_OCCURRENCES_PER_RUN,
  MAX_OCCURRENCES_PER_DAY,
  MAX_OCCURRENCES_PER_GROUP_PER_DAY,
  MAX_SCHEDULED_GROUPS_PER_RUN,
} = require('./lib/security-policy');
const { isGroupAdmin } = require('./lib/group-permissions');
const {
  AccountMergeConflictError,
  activateAccountMerge,
  cancelAccountMerge,
  completeAccountMerge,
  prepareAccountMerge,
} = require('./lib/account-merge');

async function assertAccountCanMutate(transaction, uid) {
  const merge = await transaction.get(db.collection('accountMerges').doc(uid));
  if (merge.exists) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'La cuenta está terminando un inicio de sesión',
    );
  }
}

exports.prepararFusionCuenta = secureCallable(db, 'prepararFusionCuenta', async (_data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }
  if (context.auth.token.firebase?.sign_in_provider !== 'anonymous') {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'La cuenta de origen no es anónima',
    );
  }

  try {
    return { mergeTicket: await prepareAccountMerge(db, context.auth.uid) };
  } catch (error) {
    if (error instanceof functions.https.HttpsError) throw error;
    if (error instanceof AccountMergeConflictError) {
      throw new functions.https.HttpsError('failed-precondition', error.message);
    }
    throw new functions.https.HttpsError('internal', 'No se pudo preparar la fusión');
  }
});

exports.cancelarFusionCuenta = secureCallable(db, 'cancelarFusionCuenta', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }
  const mergeTicket = data?.mergeTicket;
  if (typeof mergeTicket !== 'string' || mergeTicket.length < 40) {
    throw new functions.https.HttpsError('invalid-argument', 'El ticket de fusión no es válido');
  }
  try {
    await cancelAccountMerge(db, context.auth.uid, mergeTicket);
    return { canceled: true };
  } catch (error) {
    if (error instanceof AccountMergeConflictError) {
      throw new functions.https.HttpsError('failed-precondition', error.message);
    }
    throw new functions.https.HttpsError('internal', 'No se pudo cancelar la fusión');
  }
});

exports.bloquearFusionCuenta = secureCallable(db, 'bloquearFusionCuenta', async (data, context) => {
  if (!context.auth || context.auth.token.firebase?.sign_in_provider !== 'anonymous') {
    throw new functions.https.HttpsError('unauthenticated', 'La sesión anónima no está activa');
  }
  const mergeTicket = data?.mergeTicket;
  if (typeof mergeTicket !== 'string' || mergeTicket.length < 40) {
    throw new functions.https.HttpsError('invalid-argument', 'El ticket de fusión no es válido');
  }
  try {
    await activateAccountMerge(db, context.auth.uid, mergeTicket);
    return { active: true };
  } catch (error) {
    if (error instanceof AccountMergeConflictError) {
      throw new functions.https.HttpsError('failed-precondition', error.message);
    }
    throw new functions.https.HttpsError('internal', 'No se pudo bloquear la sesión anónima');
  }
});

exports.fusionarCuentaAnonima = secureCallable(db, 'fusionarCuentaAnonima', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }
  if (context.auth.token.firebase?.sign_in_provider === 'anonymous') {
    throw new functions.https.HttpsError('failed-precondition', 'La cuenta de destino no es válida');
  }
  const mergeTicket = data?.mergeTicket;
  if (typeof mergeTicket !== 'string' || mergeTicket.length < 40) {
    throw new functions.https.HttpsError('invalid-argument', 'El ticket de fusión no es válido');
  }

  try {
    return await completeAccountMerge(db, mergeTicket, context.auth.uid);
  } catch (error) {
    console.error('No se pudo fusionar la cuenta anónima', { targetUid: context.auth.uid, error });
    if (error instanceof AccountMergeConflictError) {
      throw new functions.https.HttpsError('failed-precondition', error.message,
        error.reason ? { reason: error.reason } : undefined);
    }
    throw new functions.https.HttpsError('internal', 'No se pudieron conservar los datos de la sesión');
  }
});

exports.registrarDispositivo = secureCallable(db, 'registrarDispositivo', (data, context) =>
  registerMessagingDevice(db, context.auth.uid, data || {}));

exports.registrarPagoDeuda = secureCallable(db, 'registrarPagoDeuda', (data, context) =>
  registerDebtPayment(db, context.auth.uid, data || {}));

exports.crearGrupo = secureCallable(db, 'crearGrupo', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Debes iniciar sesión");
  }

  const nombre = typeof data?.nombre === "string" ? data.nombre.trim() : "";
  const memberNames = Array.isArray(data?.miembros)
    ? data.miembros.map((name) => typeof name === "string" ? name.trim() : "")
    : [];
  const uniqueNames = new Set(memberNames.map((name) => name.toLocaleLowerCase("es")));
  const requestId = data?.requestId;
  let timeZone;
  try {
    timeZone = validateTimeZone(data?.timeZone);
  } catch (_) {
    throw new functions.https.HttpsError('invalid-argument', 'La zona horaria no es válida');
  }
  if (!nombre || nombre.length > 80) {
    throw new functions.https.HttpsError("invalid-argument", "El nombre del grupo no es válido");
  }
  if (
    memberNames.length === 0 ||
    memberNames.length > 50 ||
    memberNames.some((name) => !name || name.length > 50) ||
    uniqueNames.size !== memberNames.length ||
    typeof requestId !== 'string' || !/^[A-Za-z0-9_-]{20}$/.test(requestId)
  ) {
    throw new functions.https.HttpsError("invalid-argument", "La lista de miembros no es válida");
  }

  const uid = context.auth.uid;
  const groupRef = db.collection("groups").doc();
  const requestRef = db.collection('groupCreationRequests').doc(`${uid}_${requestId}`);
  const fingerprint = createHash('sha256').update(JSON.stringify([nombre, memberNames, timeZone])).digest('hex');

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const groupCode = createGroupCode();
    const result = await db.runTransaction(async (transaction) => {
      await assertAccountCanMutate(transaction, uid);
      const requestSnap = await transaction.get(requestRef);
      if (requestSnap.exists) {
        if (fingerprint !== requestSnap.get('fingerprint')) {
          throw new functions.https.HttpsError('failed-precondition', 'Esta solicitud ya se usó para otro grupo');
        }
        return { groupId: requestSnap.get('groupId'), groupCode: requestSnap.get('groupCode') };
      }

      const codeRef = db.collection("groupCodes").doc(groupCode);
      const codeSnapshot = await transaction.get(codeRef);
      if (codeSnapshot.exists) return null;
      await reserveProjectCapacity(transaction, db, 'crearGrupo');

      transaction.create(requestRef, {
        groupId: groupRef.id, groupCode, fingerprint,
        createdByUid: uid, createdAt: FieldValue.serverTimestamp(),
      });

      transaction.create(codeRef, {
        groupId: groupRef.id,
        createdAt: FieldValue.serverTimestamp(),
      });
      transaction.create(groupRef, {
        name: nombre,
        createdAt: FieldValue.serverTimestamp(),
        groupCode,
        ownerDeviceId: uid,
        timeZone,
        allMembersAreAdmins: false,
        memberCount: memberNames.length,
      });
      transaction.create(db.collection("groupMembers").doc(`${groupRef.id}_${uid}`), {
        groupId: groupRef.id,
        deviceId: uid,
        joinedAt: FieldValue.serverTimestamp(),
      });
      memberNames.forEach((memberName, index) => {
        const memberId = `member_${String(index + 1).padStart(3, "0")}`;
        transaction.create(groupRef.collection("members").doc(memberId), {
          name: memberName,
          reclamadoPor: null,
        });
      });
      return { groupId: groupRef.id, groupCode };
    });

    if (result) return result;
  }

  throw new functions.https.HttpsError("aborted", "No se pudo reservar un código de grupo");
});

function createGroupCode() {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  return Array.from({ length: 8 }, () => chars[randomInt(chars.length)]).join("");
}

exports.configurarAdministracionGrupo = secureCallable(db, 'configurarAdministracionGrupo', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesion');
  }
  const { groupId, allMembersAreAdmins } = data || {};
  if (typeof groupId !== 'string' || !groupId || groupId.length > 1500 || groupId.includes('/') ||
      typeof allMembersAreAdmins !== 'boolean') {
    throw new functions.https.HttpsError('invalid-argument', 'La configuracion no es valida');
  }

  const uid = context.auth.uid;
  const groupRef = db.collection('groups').doc(groupId);
  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const groupSnap = await transaction.get(groupRef);
    if (!groupSnap.exists || groupSnap.get('ownerDeviceId') !== uid) {
      throw new functions.https.HttpsError('permission-denied', 'Solo el propietario puede configurar el grupo');
    }
    transaction.update(groupRef, { allMembersAreAdmins });
    return { allMembersAreAdmins };
  });
});

exports.renombrarGrupo = secureCallable(db, 'renombrarGrupo', async (data, context) => {
  const { groupId } = data || {};
  const nombre = typeof data?.nombre === 'string' ? data.nombre.trim() : '';
  if (typeof groupId !== 'string' || !groupId || groupId.length > 1500 || groupId.includes('/') ||
      !nombre || nombre.length > 80) {
    throw new functions.https.HttpsError('invalid-argument', 'El nombre o grupo no es válido');
  }
  const uid = context.auth.uid;
  const groupRef = db.collection('groups').doc(groupId);
  const membershipRef = db.collection('groupMembers').doc(`${groupId}_${uid}`);
  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const [group, membership] = await transaction.getAll(groupRef, membershipRef);
    const isMember = membership.exists && membership.get('groupId') === groupId &&
      membership.get('deviceId') === uid;
    if (!isGroupAdmin(group.data(), uid, isMember)) {
      throw new functions.https.HttpsError('permission-denied', 'No puedes renombrar este grupo');
    }
    transaction.update(groupRef, { name: nombre });
    return { renamed: true };
  });
});

exports.agregarMiembroGrupo = secureCallable(db, 'agregarMiembroGrupo', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesion');
  }
  const { groupId, requestId } = data || {};
  const nombre = typeof data?.nombre === 'string' ? data.nombre.trim() : '';
  if (typeof groupId !== 'string' || !groupId || groupId.length > 1500 || groupId.includes('/') ||
      !nombre || nombre.length > 50 ||
      typeof requestId !== 'string' || !/^[A-Za-z0-9_-]{20}$/.test(requestId)) {
    throw new functions.https.HttpsError('invalid-argument', 'Los datos del miembro no son validos');
  }

  const uid = context.auth.uid;
  const groupRef = db.collection('groups').doc(groupId);
  const membershipRef = db.collection('groupMembers').doc(`${groupId}_${uid}`);
  const memberRef = groupRef.collection('members').doc(`added_${requestId}`);
  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const [groupSnap, membershipSnap, memberSnap] = await transaction.getAll(
      groupRef, membershipRef, memberRef,
    );
    const isMember = membershipSnap.exists && membershipSnap.get('groupId') === groupId &&
      membershipSnap.get('deviceId') === uid;
    if (!isGroupAdmin(groupSnap.data(), uid, isMember)) {
      throw new functions.https.HttpsError('permission-denied', 'No puedes agregar miembros a este grupo');
    }
    if (memberSnap.exists) {
      if (memberSnap.get('name') !== nombre) {
        throw new functions.https.HttpsError('failed-precondition', 'Esta solicitud ya se uso para otro miembro');
      }
      return { memberId: memberRef.id };
    }

    const members = await transaction.get(groupRef.collection('members'));
    if (members.docs.some((member) => member.get('name').toLocaleLowerCase('es') === nombre.toLocaleLowerCase('es'))) {
      throw new functions.https.HttpsError('already-exists', 'Ya existe un miembro con ese nombre');
    }
    if (members.size >= 50) {
      throw new functions.https.HttpsError('resource-exhausted', 'El grupo ya tiene 50 miembros');
    }
    transaction.create(memberRef, { name: nombre, reclamadoPor: null });
    // All additions write the group so concurrent requests recheck names and capacity.
    transaction.update(groupRef, { memberCount: members.size + 1 });
    return { memberId: memberRef.id };
  });
});

exports.reclamarMiembro = secureCallable(db, 'reclamarMiembro', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }

  const { groupId, memberId } = data || {};
  const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 1500 && !id.includes('/');
  if (!validId(groupId) || !validId(memberId)) {
    throw new functions.https.HttpsError('invalid-argument', 'El grupo o la identidad no son válidos');
  }

  const uid = context.auth.uid;
  const groupRef = db.collection('groups').doc(groupId);
  const membershipRef = db.collection('groupMembers').doc(`${groupId}_${uid}`);
  const memberRef = groupRef.collection('members').doc(memberId);
  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const [groupSnap, membershipSnap, memberSnap] = await transaction.getAll(
      groupRef, membershipRef, memberRef,
    );
    if (!groupSnap.exists || !membershipSnap.exists ||
        membershipSnap.get('groupId') !== groupId || membershipSnap.get('deviceId') !== uid) {
      throw new functions.https.HttpsError('permission-denied', 'No perteneces a este grupo');
    }

    const claimedQuery = groupRef.collection('members').where('reclamadoPor', '==', uid).limit(1);
    const alreadyClaimed = await transaction.get(claimedQuery);
    if (!alreadyClaimed.empty) {
      const existingId = alreadyClaimed.docs[0].id;
      if (membershipSnap.get('memberId') !== existingId) {
        transaction.update(membershipRef, { memberId: existingId });
      }
      return { memberId: existingId };
    }
    if (!memberSnap.exists || memberSnap.get('reclamadoPor') != null) {
      throw new functions.https.HttpsError('failed-precondition', 'Esa identidad ya no está disponible');
    }

    transaction.update(memberRef, { reclamadoPor: uid });
    transaction.update(membershipRef, { memberId });
    return { memberId };
  });
});

exports.crearGasto = secureCallable(db, 'crearGasto', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }

  const {
    groupId, nombre, descripcion, cantidadCentimos, fecha, pagadoPor,
    participantes, frecuencia, requestId,
  } = data || {};
  const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 1500 && !id.includes('/');
  if (!validId(groupId) || !validId(pagadoPor) ||
      typeof requestId !== 'string' || !/^[A-Za-z0-9_-]{20}$/.test(requestId) ||
      typeof nombre !== 'string' ||
      !nombre.trim() || nombre.trim().length > 100 ||
      typeof descripcion !== 'string' || descripcion.length > 2000 ||
      !Number.isSafeInteger(cantidadCentimos) || cantidadCentimos <= 0 ||
      !Array.isArray(participantes) || participantes.length < 1 || participantes.length > 49 ||
      participantes.some((id) => !validId(id) || id === pagadoPor) ||
      new Set(participantes).size !== participantes.length ||
      cantidadCentimos < participantes.length + 1 ||
      (frecuencia !== null && frecuencia !== undefined && typeof frecuencia !== 'string')) {
    throw new functions.https.HttpsError('invalid-argument', 'Los datos del gasto no son válidos');
  }

  let expenseDate;
  try {
    expenseDate = parseCalendarDate(fecha);
  } catch (_) {
    throw new functions.https.HttpsError('invalid-argument', 'La fecha no es válida');
  }
  if (frecuencia != null) {
    try {
      nextScheduledDate(fecha, frecuencia);
    } catch (_) {
      throw new functions.https.HttpsError('invalid-argument', 'La frecuencia no es válida');
    }
  }

  const groupRef = db.collection('groups').doc(groupId);
  const possibleScheduleRef = groupRef.collection('gastosProgramados').doc();
  const possibleExpenseRef = groupRef.collection('gastos').doc();
  const shares = splitCents(cantidadCentimos, pagadoPor, participantes);
  const requestTime = Timestamp.now();
  const uid = context.auth.uid;
  const requestRef = groupRef.collection('expenseRequests').doc(requestId);
  const fingerprintPayload = [
    nombre.trim(), descripcion.trim(), cantidadCentimos, fecha,
    pagadoPor, [...participantes].sort(), frecuencia ?? null,
  ];
  const fingerprint = createHash('sha256').update(JSON.stringify(fingerprintPayload)).digest('hex');

  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const membershipRef = db.collection('groupMembers').doc(`${groupId}_${uid}`);
    const memberRefs = shares.map((share) => groupRef.collection('members').doc(share.memberId));
    const [requestSnap, groupSnap, membershipSnap, ...memberSnaps] = await transaction.getAll(
      requestRef, groupRef, membershipRef, ...memberRefs,
    );
    if (!groupSnap.exists || !membershipSnap.exists ||
        membershipSnap.get('groupId') !== groupId || membershipSnap.get('deviceId') !== uid ||
        memberSnaps.some((snapshot) => !snapshot.exists)) {
      throw new functions.https.HttpsError('permission-denied', 'No puedes crear este gasto para este grupo');
    }
    if (requestSnap.exists) {
      if (fingerprint !== requestSnap.get('fingerprint') ||
          requestSnap.get('createdByUid') !== uid) {
        throw new functions.https.HttpsError('failed-precondition', 'Esta solicitud ya se usó para otro gasto');
      }
      return { gastoId: requestSnap.get('gastoId'), scheduleId: requestSnap.get('scheduleId') };
    }

    let timeZone;
    try {
      timeZone = validateTimeZone(groupSnap.get('timeZone'));
    } catch (_) {
      throw new functions.https.HttpsError('failed-precondition', 'El grupo no tiene una zona horaria válida');
    }
    const isFuture = fecha > todayInZone(timeZone, requestTime.toMillis());
    const scheduleRef = isFuture || frecuencia != null ? possibleScheduleRef : null;
    const occurrenceRef = isFuture ? null : scheduleRef
      ? groupRef.collection('gastos').doc(scheduledOccurrenceId(scheduleRef.id, fecha))
      : possibleExpenseRef;

    const authorIdentities = await transaction.get(
      groupRef.collection('members').where('reclamadoPor', '==', uid),
    );
    const authorIdentity = authorIdentities.docs.find((member) => member.id === membershipSnap.get('memberId')) ??
      authorIdentities.docs[0];
    const author = {
      createdByUid: uid,
      ...(authorIdentity ? { createdByMemberId: authorIdentity.id } : {}),
    };
    await reserveProjectCapacity(transaction, db, 'crearGasto', requestTime.toMillis());

    if (scheduleRef) {
      const nextDate = isFuture ? fecha : nextScheduledDate(fecha, frecuencia);
      const nextInstant = Timestamp.fromDate(scheduleInstant(nextDate, timeZone));
      if (groupSnap.get('schedulesCheckedAt') == null) {
        transaction.update(groupRef, { schedulesCheckedAt: Timestamp.fromMillis(0) });
      }
      transaction.create(scheduleRef, {
        nombre: nombre.trim(), descripcion: descripcion.trim(),
        cantidadCentimos, pagadoPor, timeZone,
        participantes: [...participantes].sort(), frecuencia: frecuencia ?? null,
        diaAncla: frecuencia == null ? null : expenseDate.day,
        proximaFecha: nextDate,
        proximaEjecucion: nextInstant,
        nextAttemptAt: nextInstant,
        created: FieldValue.serverTimestamp(), ...author,
      });
    }

    if (occurrenceRef) {
      transaction.create(occurrenceRef, {
        nombre: nombre.trim(), descripcion: descripcion.trim(),
        cantidadCentimos, fecha,
        created: FieldValue.serverTimestamp(), pagadoPor,
        scheduleId: scheduleRef?.id ?? null,
        occurrenceKey: scheduleRef ? occurrenceRef.id : null,
        ...author,
      });
      for (const share of shares) {
        transaction.create(occurrenceRef.collection('divisiones').doc(divisionId(share.memberId)), {
          memberId: share.memberId, groupId,
          cantidadCentimos: share.cantidadCentimos, pagado: share.memberId === pagadoPor,
          ...(share.memberId === pagadoPor ? { pagadoEn: FieldValue.serverTimestamp() } : {}),
          created: FieldValue.serverTimestamp(), fecha,
          nombre: nombre.trim(), pagadoPor,
        });
      }
    }
    const result = { gastoId: occurrenceRef?.id ?? null, scheduleId: scheduleRef?.id ?? null };
    transaction.create(requestRef, {
      ...result, fingerprint, createdByUid: uid, created: FieldValue.serverTimestamp(),
    });
    return result;
  });
});

exports.eliminarGasto = secureCallable(db, 'eliminarGasto', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }

  const { groupId, gastoId } = data || {};
  const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 1500 && !id.includes('/');
  if (!validId(groupId) || !validId(gastoId)) {
    throw new functions.https.HttpsError('invalid-argument', 'Los datos del borrado no son válidos');
  }

  const uid = context.auth.uid;
  const groupRef = db.collection('groups').doc(groupId);
  const expenseRef = groupRef.collection('gastos').doc(gastoId);
  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const [groupSnap, expenseSnap, divisionsSnap, membershipSnap] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(expenseRef),
      transaction.get(expenseRef.collection('divisiones')),
      transaction.get(db.collection('groupMembers').doc(`${groupId}_${uid}`)),
    ]);
    if (!expenseSnap.exists) return { deleted: false };
    const isMember = membershipSnap.exists && membershipSnap.get('groupId') === groupId &&
      membershipSnap.get('deviceId') === uid;
    if (!groupSnap.exists ||
        (!isGroupAdmin(groupSnap.data(), uid, isMember) && expenseSnap.get('createdByUid') !== uid)) {
      throw new functions.https.HttpsError('permission-denied', 'No puedes eliminar este gasto');
    }

    const scheduleId = expenseSnap.get('scheduleId');
    if (scheduleId != null) {
      if (!validId(scheduleId)) {
        throw new functions.https.HttpsError('failed-precondition', 'La programación asociada no es válida');
      }
      transaction.delete(groupRef.collection('gastosProgramados').doc(scheduleId));
    }
    for (const division of divisionsSnap.docs) transaction.delete(division.ref);
    transaction.delete(expenseRef);
    return { deleted: true };
  });
});

exports.eliminarGastoProgramado = secureCallable(db, 'eliminarGastoProgramado', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }

  const { groupId, scheduleId, scheduledFor } = data || {};
  const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 1500 && !id.includes('/');
  if (!validId(groupId) || !validId(scheduleId)) {
    throw new functions.https.HttpsError('invalid-argument', 'La programación no es válida');
  }
  try {
    parseCalendarDate(scheduledFor);
  } catch (_) {
    throw new functions.https.HttpsError('invalid-argument', 'La fecha programada no es válida');
  }

  const uid = context.auth.uid;
  const groupRef = db.collection('groups').doc(groupId);
  const scheduleRef = groupRef.collection('gastosProgramados').doc(scheduleId);
  const occurrenceRef = groupRef.collection('gastos').doc(
    scheduledOccurrenceId(scheduleId, scheduledFor),
  );
  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const [groupSnap, scheduleSnap, occurrenceSnap, membershipSnap] = await transaction.getAll(
      groupRef, scheduleRef, occurrenceRef, db.collection('groupMembers').doc(`${groupId}_${uid}`),
    );
    const isMember = membershipSnap.exists && membershipSnap.get('groupId') === groupId &&
      membershipSnap.get('deviceId') === uid;
    if (!scheduleSnap.exists && !occurrenceSnap.exists) {
      if (!groupSnap.exists ||
          (groupSnap.get('ownerDeviceId') !== uid && !isMember)) {
        throw new functions.https.HttpsError('permission-denied', 'No perteneces a este grupo');
      }
      return { deleted: false, occurrenceGenerated: false };
    }
    const creatorUid = scheduleSnap.exists
      ? scheduleSnap.get('createdByUid') : occurrenceSnap.get('createdByUid');
    if (!groupSnap.exists ||
        (!isGroupAdmin(groupSnap.data(), uid, isMember) && creatorUid !== uid)) {
      throw new functions.https.HttpsError(
        'permission-denied',
        'No puedes eliminar este gasto programado',
      );
    }

    if (scheduleSnap.exists) transaction.delete(scheduleRef);
    return { deleted: scheduleSnap.exists, occurrenceGenerated: occurrenceSnap.exists };
  });
});

exports.unirseAGrupo = secureCallable(db, 'unirseAGrupo', async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Debes iniciar sesión");
  }

  const codigo = typeof data?.codigo === "string" ? data.codigo.trim() : "";
  if (!/^[A-Za-z0-9]{8}$/.test(codigo)) {
    throw new functions.https.HttpsError("invalid-argument", "El código no es válido");
  }

  const uid = context.auth.uid;
  const attemptsRef = db.collection("joinAttempts").doc(uid);
  const result = await db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const now = Timestamp.now();
    const attemptsSnap = await transaction.get(attemptsRef);
    const attempts = attemptsSnap.data() || {};
    const lockedUntil = attempts.lockedUntil;

    if (lockedUntil?.toMillis() > now.toMillis()) {
      return {
        status: "locked",
        retryAfterSeconds: Math.ceil((lockedUntil.toMillis() - now.toMillis()) / 1000),
      };
    }

    const invitation = await transaction.get(db.collection("groupCodes").doc(codigo));
    const groupId = invitation.get("groupId");
    const group = typeof groupId === "string" && groupId && !groupId.includes("/")
      ? await transaction.get(db.collection("groups").doc(groupId))
      : null;
    if (!group?.exists || group.get("groupCode") !== codigo || !group.get("timeZone")) {
      const windowStartedAt = attempts.windowStartedAt;
      const windowExpired = !windowStartedAt || now.toMillis() - windowStartedAt.toMillis() > 5 * 60 * 1000;
      const failedAttempts = windowExpired ? 1 : (attempts.failedAttempts || 0) + 1;
      const shouldLock = failedAttempts >= 3;

      transaction.set(attemptsRef, {
        failedAttempts: shouldLock ? 0 : failedAttempts,
        windowStartedAt: windowExpired ? now : windowStartedAt,
        lockedUntil: shouldLock ? Timestamp.fromMillis(now.toMillis() + 30 * 1000) : null,
      });
      return {
        status: shouldLock ? "locked" : "not-found",
        retryAfterSeconds: shouldLock ? 30 : 0,
      };
    }

    const membershipRef = db.collection("groupMembers").doc(`${groupId}_${uid}`);
    const membershipSnap = await transaction.get(membershipRef);
    if (!membershipSnap.exists) {
      transaction.create(membershipRef, {
        groupId,
        deviceId: uid,
        joinedAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.delete(attemptsRef);
    return { status: membershipSnap.exists ? "already-member" : "joined", groupId };
  });

  if (result.status === "not-found") {
    throw new functions.https.HttpsError("not-found", "No existe ningún grupo con ese código");
  }
  if (result.status === "locked") {
    throw new functions.https.HttpsError(
      "resource-exhausted",
      "Demasiados intentos fallidos",
      { retryAfterSeconds: result.retryAfterSeconds },
    );
  }
  return result;
});


exports.onDeudaPagada = functions
  .runWith({ ...BACKGROUND_OPTIONS, failurePolicy: true })
  .firestore
  .document('groups/{groupId}/gastos/{gastoId}/divisiones/{divisionId}')
  .onUpdate(async (change, context) => {
    const rejection = notificationEventRejection(context.timestamp);
    if (rejection) {
      console.warn('Discarding debt notification event', {
        eventId: context.eventId, timestamp: context.timestamp, reason: rejection,
      });
      return null;
    }
    try {
      const before = change.before.data();
      const after = change.after.data();
      const notification = debtNotificationForTransition(before, after);
      if (!notification) return null;

      await sendNotificationToMember({
        eventId: context.eventId,
        groupId: context.params.groupId,
        memberId: notification.targetMemberId,
        title: notification.title,
        body: notification.body,
      });

      return null;
    } catch (error) {
      console.error('Error en onDeudaPagada:', error);
      throw error;
    }
  }
);


exports.ejecutarGastosPeriodicos = functions.runWith(BACKGROUND_OPTIONS).pubsub
  .schedule("every 5 minutes")
  .retryConfig({
    retryCount: 3,
    minBackoffDuration: "60s",
    maxBackoffDuration: "600s",
    maxDoublings: 3,
  })
  .timeZone("UTC")
  .onRun(async (context) => {
    const hoy = Timestamp.now();
    console.log(`--- Ejecutando Gastos Periódicos - Hoy: ${hoy.toDate().toISOString()} ---`);

    try {
      const failures = [];
      const budget = await db.collection('usageLimits').doc('scheduledOccurrences').get();
      if (budget.get('day') === hoy.toDate().toISOString().slice(0, 10) &&
          budget.get('count') >= MAX_OCCURRENCES_PER_DAY) return null;
      const groups = await db.collection('groups').orderBy('schedulesCheckedAt')
        .limit(MAX_SCHEDULED_GROUPS_PER_RUN).get();
      let processed = 0;
      for (const group of groups.docs) {
        if (processed >= MAX_OCCURRENCES_PER_RUN) break;
        try {
          const gastoProgramadoDoc = await claimScheduledGroup(db, group, hoy);
          if (!gastoProgramadoDoc) continue;
          const result = await generarOcurrenciaProgramada({
            db,
            groupId: group.id,
            scheduleRef: gastoProgramadoDoc.ref,
            now: hoy,
          });
          processed += 1;
          console.log(`Gasto programado ${gastoProgramadoDoc.id} en grupo ${group.id}: ${result.message}`);
          if (result.budgetExhausted) break;
        } catch (error) {
          failures.push(error);
          console.error(
            `Error al procesar programaciones del grupo ${group.id}:`,
            error,
          );
        }
      }
      if (failures.length > 0) {
        throw new AggregateError(failures, "No se pudieron procesar todos los gastos programados");
      }
    } catch (e) {
      console.error("Error al ejecutar gastos periódicos:", e);
      throw e;
    }
  });

async function generarOcurrenciaProgramada({ db, groupId, scheduleRef, now }) {
  return db.runTransaction(async (transaction) => {
    const scheduleSnap = await transaction.get(scheduleRef);
    if (!scheduleSnap.exists) {
      return { message: 'ya eliminado' };
    }

    const schedule = scheduleSnap.data();
    await assertAccountCanMutate(transaction, schedule.createdByUid);
    const scheduledDate = schedule.proximaFecha;
    parseCalendarDate(scheduledDate);
    const timeZone = validateTimeZone(schedule.timeZone);
    const scheduledAt = schedule.proximaEjecucion;
    if (!(scheduledAt instanceof Timestamp)) {
      throw new TypeError('proximaEjecucion debe ser un Timestamp de Firestore');
    }
    if (scheduledAt.toMillis() > now.toMillis()) {
      return { message: 'ya no vence' };
    }

    const totalCents = centsFromAmount(schedule.cantidadCentimos);
    const shares = splitCents(totalCents, schedule.pagadoPor, schedule.participantes);
    const occurrenceId = scheduledOccurrenceId(scheduleRef.id, scheduledDate);
    const occurrenceRef = db.collection("groups").doc(groupId).collection("gastos").doc(occurrenceId);
    const occurrenceSnap = await transaction.get(occurrenceRef);
    const isOneOff = schedule.frecuencia === null || schedule.frecuencia === undefined;
    const nextDate = isOneOff ? null : nextScheduledDate(scheduledDate, schedule.frecuencia, schedule.diaAncla ?? undefined);

    if (!occurrenceSnap.exists) {
      const budgetRef = db.collection('usageLimits').doc('scheduledOccurrences');
      const groupBudgetRef = db.collection('usageLimits').doc(`scheduledGroup_${groupId}`);
      const [budget, groupBudget] = await transaction.getAll(budgetRef, groupBudgetRef);
      const requestedDay = now.toDate().toISOString().slice(0, 10);
      const globalDay = budget.get('day') > requestedDay ? budget.get('day') : requestedDay;
      const day = groupBudget.get('day') > globalDay ? groupBudget.get('day') : globalDay;
      const count = budget.get('day') === day ? budget.get('count') : 0;
      const groupCount = groupBudget.get('day') === day ? groupBudget.get('count') : 0;
      if (count >= MAX_OCCURRENCES_PER_DAY) {
        return { message: 'límite diario de recuperación alcanzado', budgetExhausted: true };
      }
      if (groupCount >= MAX_OCCURRENCES_PER_GROUP_PER_DAY) {
        return { message: 'límite diario de recuperación del grupo alcanzado' };
      }
      // The occurrence and its daily allowance commit together, including retries.
      transaction.set(budgetRef, { day, count: count + 1 });
      transaction.set(groupBudgetRef, { day, count: groupCount + 1 });
      transaction.create(occurrenceRef, {
        nombre: schedule.nombre,
        descripcion: schedule.descripcion || "",
        cantidadCentimos: totalCents,
        fecha: scheduledDate,
        created: FieldValue.serverTimestamp(),
        pagadoPor: schedule.pagadoPor,
        scheduleId: scheduleRef.id,
        occurrenceKey: occurrenceId,
        ...(schedule.createdByMemberId != null ? { createdByMemberId: schedule.createdByMemberId } : {}),
        createdByUid: schedule.createdByUid,
      });

      for (const share of shares) {
        transaction.create(occurrenceRef.collection("divisiones").doc(divisionId(share.memberId)), {
          memberId: share.memberId,
          groupId,
          cantidadCentimos: share.cantidadCentimos,
          pagado: share.memberId === schedule.pagadoPor,
          ...(share.memberId === schedule.pagadoPor ? { pagadoEn: FieldValue.serverTimestamp() } : {}),
          created: FieldValue.serverTimestamp(),
          fecha: scheduledDate,
          nombre: schedule.nombre,
          pagadoPor: schedule.pagadoPor,
        });
      }
    }

    if (isOneOff) {
      transaction.delete(scheduleRef);
      return {
        message: occurrenceSnap.exists ? 'ocurrencia existente y programación eliminada' : 'ocurrencia creada y programación eliminada',
      };
    }

    const nextInstant = Timestamp.fromDate(scheduleInstant(nextDate, timeZone));
    transaction.update(scheduleRef, {
      proximaFecha: nextDate,
      proximaEjecucion: nextInstant,
      nextAttemptAt: nextInstant.toMillis() > now.toMillis() ? nextInstant : now,
    });
    return {
      message: occurrenceSnap.exists ? 'ocurrencia existente y próxima fecha avanzada' : 'ocurrencia creada',
    };
  });
}

exports.recordatorioDeudas = functions.runWith(BACKGROUND_OPTIONS).pubsub
  .schedule('every 5 minutes')
  .timeZone('Europe/Madrid')
  .onRun(() => runDebtReminders({ db, messaging }));

async function sendNotificationToMember({ groupId, memberId, title, body, eventId }) {
  const memberDoc = await db
    .collection('groups')
    .doc(groupId)
    .collection('members')
    .doc(memberId)
    .get();

  if (!memberDoc.exists) {
    console.log(`Miembro ${memberId} no encontrado en grupo ${groupId}`);
    return;
  }

  const uid = memberDoc.get('reclamadoPor');
  if (!uid) {
    console.log(`Miembro ${memberId} aún no ha sido reclamado.`);
    return;
  }

  await sendNotificationToUser({ db, messaging, uid, title, body, eventId });
}
