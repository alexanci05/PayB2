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
} = require('./lib/scheduled-occurrences');
const { debtNotificationForTransition } = require('./lib/debt-notifications');
const {
  AccountMergeConflictError,
  activateAccountMerge,
  cancelAccountMerge,
  completeAccountMerge,
  prepareAccountMerge,
} = require('./lib/account-merge');
const MAX_OCCURRENCES_PER_SCHEDULE_RUN = 100;

function reminderPeriod(date = new Date()) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Madrid',
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return `${values.year}-${values.month}-${values.day}`;
}

async function assertAccountCanMutate(transaction, uid) {
  const merge = await transaction.get(db.collection('accountMerges').doc(uid));
  if (merge.exists) {
    throw new functions.https.HttpsError(
      'failed-precondition',
      'La cuenta está terminando un inicio de sesión',
    );
  }
}

exports.prepararFusionCuenta = functions.https.onCall(async (_data, context) => {
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
    if (error instanceof AccountMergeConflictError) {
      throw new functions.https.HttpsError('failed-precondition', error.message);
    }
    throw new functions.https.HttpsError('internal', 'No se pudo preparar la fusión');
  }
});

exports.cancelarFusionCuenta = functions.https.onCall(async (data, context) => {
  if (!context.auth || context.auth.token.firebase?.sign_in_provider !== 'anonymous') {
    throw new functions.https.HttpsError('unauthenticated', 'La sesión anónima no está activa');
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

exports.bloquearFusionCuenta = functions.https.onCall(async (data, context) => {
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

exports.fusionarCuentaAnonima = functions.https.onCall(async (data, context) => {
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
      throw new functions.https.HttpsError('failed-precondition', error.message);
    }
    throw new functions.https.HttpsError('internal', 'No se pudieron conservar los datos de la sesión');
  }
});

exports.crearGrupo = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Debes iniciar sesión");
  }

  const nombre = typeof data?.nombre === "string" ? data.nombre.trim() : "";
  const memberNames = Array.isArray(data?.miembros)
    ? data.miembros.map((name) => typeof name === "string" ? name.trim() : "")
    : [];
  const uniqueNames = new Set(memberNames.map((name) => name.toLocaleLowerCase("es")));
  const requestId = data?.requestId;
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
  const fingerprint = createHash('sha256').update(JSON.stringify([nombre, memberNames])).digest('hex');

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const groupCode = createGroupCode();
    const result = await db.runTransaction(async (transaction) => {
      await assertAccountCanMutate(transaction, uid);
      const requestSnap = await transaction.get(requestRef);
      if (requestSnap.exists) {
        const legacyFingerprint = createHash('sha256').update(JSON.stringify([
          requestSnap.get('mergedFromUid') ?? uid, nombre, memberNames,
        ])).digest('hex');
        if (![fingerprint, legacyFingerprint].includes(requestSnap.get('fingerprint'))) {
          throw new functions.https.HttpsError('failed-precondition', 'Esta solicitud ya se usó para otro grupo');
        }
        return { groupId: requestSnap.get('groupId'), groupCode: requestSnap.get('groupCode') };
      }

      const codeRef = db.collection("groupCodes").doc(groupCode);
      const codeSnapshot = await transaction.get(codeRef);
      if (codeSnapshot.exists) return null;

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

exports.reclamarMiembro = functions.https.onCall(async (data, context) => {
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

exports.crearGasto = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }

  const {
    groupId, nombre, descripcion, cantidadCentimos, fecha, pagadoPor,
    participantes, frecuencia, requestId, timeZoneOffsetMinutes,
  } = data || {};
  const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 1500 && !id.includes('/');
  if (!validId(groupId) || !validId(pagadoPor) ||
      typeof requestId !== 'string' || !/^[A-Za-z0-9_-]{20}$/.test(requestId) ||
      typeof nombre !== 'string' ||
      !nombre.trim() || nombre.trim().length > 100 || typeof descripcion !== 'string' ||
      !Number.isSafeInteger(cantidadCentimos) || cantidadCentimos <= 0 ||
      !Array.isArray(participantes) || participantes.length < 1 || participantes.length > 49 ||
      participantes.some((id) => !validId(id) || id === pagadoPor) ||
      new Set(participantes).size !== participantes.length ||
      cantidadCentimos < participantes.length + 1 ||
      !Number.isInteger(timeZoneOffsetMinutes) ||
      timeZoneOffsetMinutes < -14 * 60 || timeZoneOffsetMinutes > 14 * 60 ||
      (frecuencia !== null && frecuencia !== undefined && typeof frecuencia !== 'string')) {
    throw new functions.https.HttpsError('invalid-argument', 'Los datos del gasto no son válidos');
  }

  if (typeof fecha !== 'string' || !/^\d{4}-\d{2}-\d{2}$/.test(fecha)) {
    throw new functions.https.HttpsError('invalid-argument', 'La fecha no es válida');
  }
  const expenseDate = new Date(`${fecha}T12:00:00.000Z`);
  if (Number.isNaN(expenseDate.getTime()) || expenseDate.toISOString().slice(0, 10) !== fecha) {
    throw new functions.https.HttpsError('invalid-argument', 'La fecha no es válida');
  }
  if (frecuencia != null) {
    try {
      nextScheduledDate(expenseDate, frecuencia);
    } catch (_) {
      throw new functions.https.HttpsError('invalid-argument', 'La frecuencia no es válida');
    }
  }

  const clientNow = new Date(Date.now() + timeZoneOffsetMinutes * 60 * 1000);
  const today = clientNow.toISOString().slice(0, 10);
  const isFuture = fecha > today;
  const groupRef = db.collection('groups').doc(groupId);
  const scheduleRef = (isFuture || frecuencia != null) ? groupRef.collection('gastosProgramados').doc() : null;
  const occurrenceRef = isFuture ? null : scheduleRef
    ? groupRef.collection('gastos').doc(scheduledOccurrenceId(scheduleRef.id, expenseDate))
    : groupRef.collection('gastos').doc();
  const shares = splitCents(cantidadCentimos, pagadoPor, participantes);
  const expenseTimestamp = Timestamp.fromDate(expenseDate);
  const uid = context.auth.uid;
  const requestRef = groupRef.collection('expenseRequests').doc(requestId);
  const fingerprintPayload = [
    nombre.trim(), descripcion.trim(), cantidadCentimos, fecha,
    pagadoPor, [...participantes].sort(), frecuencia ?? null, timeZoneOffsetMinutes,
  ];
  const fingerprint = createHash('sha256').update(JSON.stringify(fingerprintPayload)).digest('hex');

  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const requestSnap = await transaction.get(requestRef);
    if (requestSnap.exists) {
      const legacyFingerprint = createHash('sha256').update(JSON.stringify([
        requestSnap.get('mergedFromUid') ?? uid, ...fingerprintPayload,
      ])).digest('hex');
      if (![fingerprint, legacyFingerprint].includes(requestSnap.get('fingerprint')) ||
          requestSnap.get('createdByUid') !== uid) {
        throw new functions.https.HttpsError('failed-precondition', 'Esta solicitud ya se usó para otro gasto');
      }
      return { gastoId: requestSnap.get('gastoId'), scheduleId: requestSnap.get('scheduleId') };
    }

    const membershipRef = db.collection('groupMembers').doc(`${groupId}_${uid}`);
    const memberRefs = shares.map((share) => groupRef.collection('members').doc(share.memberId));
    const [groupSnap, membershipSnap, ...memberSnaps] = await transaction.getAll(
      groupRef, membershipRef, ...memberRefs,
    );
    if (!groupSnap.exists || !membershipSnap.exists ||
        membershipSnap.get('groupId') !== groupId || membershipSnap.get('deviceId') !== uid ||
        memberSnaps.some((snapshot) => !snapshot.exists) ||
        memberSnaps.find((snapshot) => snapshot.id === pagadoPor).get('reclamadoPor') !== uid) {
      throw new functions.https.HttpsError('permission-denied', 'No puedes crear este gasto para este grupo');
    }

    if (scheduleRef) {
      transaction.create(scheduleRef, {
        nombre: nombre.trim(), descripcion: descripcion.trim(),
        cantidad: cantidadCentimos / 100, cantidadCentimos, pagadoPor,
        participantes: [...participantes].sort(), frecuencia: frecuencia ?? null,
        diaAncla: frecuencia == null ? null : expenseDate.getUTCDate(),
        proximaFecha: isFuture ? expenseTimestamp : Timestamp.fromDate(nextScheduledDate(expenseDate, frecuencia)),
        created: FieldValue.serverTimestamp(), createdByMemberId: pagadoPor, createdByUid: uid,
      });
    }

    if (occurrenceRef) {
      transaction.create(occurrenceRef, {
        nombre: nombre.trim(), descripcion: descripcion.trim(),
        cantidad: cantidadCentimos / 100, cantidadCentimos, fecha: expenseTimestamp,
        created: FieldValue.serverTimestamp(), pagadoPor,
        scheduleId: scheduleRef?.id ?? null,
        occurrenceKey: scheduleRef ? occurrenceRef.id : null,
        createdByMemberId: pagadoPor, createdByUid: uid,
      });
      for (const share of shares) {
        transaction.create(occurrenceRef.collection('divisiones').doc(divisionId(share.memberId)), {
          memberId: share.memberId, groupId, cantidad: share.cantidad,
          cantidadCentimos: share.cantidadCentimos, pagado: share.memberId === pagadoPor,
          pagadoEn: share.memberId === pagadoPor ? expenseTimestamp : null,
          created: FieldValue.serverTimestamp(), fecha: expenseTimestamp,
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

exports.eliminarGasto = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError('unauthenticated', 'Debes iniciar sesión');
  }

  const { groupId, gastoId, eliminarSerie } = data || {};
  const validId = (id) => typeof id === 'string' && id.length > 0 && id.length <= 1500 && !id.includes('/');
  if (!validId(groupId) || !validId(gastoId) || typeof eliminarSerie !== 'boolean') {
    throw new functions.https.HttpsError('invalid-argument', 'Los datos del borrado no son válidos');
  }

  const uid = context.auth.uid;
  const groupRef = db.collection('groups').doc(groupId);
  const expenseRef = groupRef.collection('gastos').doc(gastoId);
  return db.runTransaction(async (transaction) => {
    await assertAccountCanMutate(transaction, uid);
    const [groupSnap, expenseSnap, divisionsSnap] = await Promise.all([
      transaction.get(groupRef),
      transaction.get(expenseRef),
      transaction.get(expenseRef.collection('divisiones')),
    ]);
    if (!expenseSnap.exists) return { deleted: false };
    if (!groupSnap.exists ||
        (groupSnap.get('ownerDeviceId') !== uid && expenseSnap.get('createdByUid') !== uid)) {
      throw new functions.https.HttpsError('permission-denied', 'No puedes eliminar este gasto');
    }

    const scheduleId = expenseSnap.get('scheduleId');
    if (eliminarSerie && scheduleId != null) {
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

exports.unirseAGrupo = functions.https.onCall(async (data, context) => {
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

    const groupQuery = db.collection("groups").where("groupCode", "==", codigo).limit(1);
    const groupSnapshot = await transaction.get(groupQuery);
    if (groupSnapshot.empty) {
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

    const groupId = groupSnapshot.docs[0].id;
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
  .runWith({ failurePolicy: true })
  .firestore
  .document('groups/{groupId}/gastos/{gastoId}/divisiones/{divisionId}')
  .onUpdate(async (change, context) => {
    try {
      const before = change.before.data();
      const after = change.after.data();
      const notification = debtNotificationForTransition(before, after);
      if (!notification) return null;

      await sendNotificationToMember({
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


exports.ejecutarGastosPeriodicos = functions.pubsub
  .schedule("every day 15:00")
  .retryConfig({
    retryCount: 3,
    minBackoffDuration: "60s",
    maxBackoffDuration: "10m",
    maxDoublings: 3,
  })
  .timeZone("Europe/Madrid")
  .onRun(async (context) => {
    const hoy = Timestamp.now();
    console.log(`--- Ejecutando Gastos Periódicos - Hoy: ${hoy.toDate().toISOString()} ---`);

    try {
      const failures = [];
      const gruposSnap = await db.collection("groups").get();

      for (const grupo of gruposSnap.docs) {
        const groupId = grupo.id;

        const gastosProgramadosSnap = await db
          .collection("groups")
          .doc(groupId)
          .collection("gastosProgramados")
          .where("proximaFecha", "<=", hoy)
          .get();

        console.log(`Gastos programados encontrados: ${gastosProgramadosSnap.size}`);

        for (const gastoProgramadoDoc of gastosProgramadosSnap.docs) {
          try {
            for (let generated = 0; generated < MAX_OCCURRENCES_PER_SCHEDULE_RUN; generated += 1) {
              const result = await generarOcurrenciaProgramada({
                db,
                groupId,
                scheduleRef: gastoProgramadoDoc.ref,
                now: hoy,
              });
              console.log(`Gasto programado ${gastoProgramadoDoc.id} en grupo ${groupId}: ${result.message}`);
              if (!result.hasAnotherDueOccurrence) break;
              if (generated === MAX_OCCURRENCES_PER_SCHEDULE_RUN - 1) {
                console.warn(`Gasto programado ${gastoProgramadoDoc.id} alcanzó el límite de recuperación`);
              }
            }
          } catch (error) {
            failures.push(error);
            console.error(
              `Error al procesar gasto programado ${gastoProgramadoDoc.ref.path}:`,
              error,
            );
          }
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
      return { message: 'ya eliminado', hasAnotherDueOccurrence: false };
    }

    const schedule = scheduleSnap.data();
    await assertAccountCanMutate(transaction, schedule.createdByUid);
    const scheduledAt = schedule.proximaFecha;
    if (!scheduledAt || typeof scheduledAt.toDate !== "function" || typeof scheduledAt.toMillis !== "function") {
      throw new TypeError("proximaFecha debe ser un Timestamp de Firestore");
    }
    if (scheduledAt.toMillis() > now.toMillis()) {
      return { message: 'ya no vence', hasAnotherDueOccurrence: false };
    }

    const scheduledDate = scheduledAt.toDate();
    const totalCents = centsFromAmount(schedule.cantidadCentimos, schedule.cantidad);
    const shares = splitCents(totalCents, schedule.pagadoPor, schedule.participantes || []);
    const occurrenceId = scheduledOccurrenceId(scheduleRef.id, scheduledAt);
    const occurrenceRef = db.collection("groups").doc(groupId).collection("gastos").doc(occurrenceId);
    const occurrenceSnap = await transaction.get(occurrenceRef);
    const isOneOff = schedule.frecuencia === null || schedule.frecuencia === undefined;
    const nextDate = isOneOff ? null : nextScheduledDate(scheduledDate, schedule.frecuencia, schedule.diaAncla ?? undefined);

    if (!occurrenceSnap.exists) {
      transaction.create(occurrenceRef, {
        nombre: schedule.nombre,
        descripcion: schedule.descripcion || "",
        cantidad: totalCents / 100,
        cantidadCentimos: totalCents,
        fecha: scheduledAt,
        created: FieldValue.serverTimestamp(),
        pagadoPor: schedule.pagadoPor,
        scheduleId: scheduleRef.id,
        occurrenceKey: occurrenceId,
        createdByMemberId: schedule.createdByMemberId,
        createdByUid: schedule.createdByUid,
      });

      for (const share of shares) {
        transaction.create(occurrenceRef.collection("divisiones").doc(divisionId(share.memberId)), {
          memberId: share.memberId,
          groupId,
          cantidad: share.cantidad,
          cantidadCentimos: share.cantidadCentimos,
          pagado: share.memberId === schedule.pagadoPor,
          ...(share.memberId === schedule.pagadoPor ? { pagadoEn: scheduledAt } : {}),
          created: FieldValue.serverTimestamp(),
          fecha: scheduledAt,
          nombre: schedule.nombre,
          pagadoPor: schedule.pagadoPor,
        });
      }
    }

    if (isOneOff) {
      transaction.delete(scheduleRef);
      return {
        message: occurrenceSnap.exists ? 'ocurrencia existente y programación eliminada' : 'ocurrencia creada y programación eliminada',
        hasAnotherDueOccurrence: false,
      };
    }

    transaction.update(scheduleRef, { proximaFecha: Timestamp.fromDate(nextDate) });
    return {
      message: occurrenceSnap.exists ? 'ocurrencia existente y próxima fecha avanzada' : 'ocurrencia creada',
      hasAnotherDueOccurrence: nextDate.getTime() <= now.toMillis(),
    };
  });
}

exports.recordatorioDeudas = functions.pubsub
  .schedule("every day 15:15")
  .retryConfig({
    retryCount: 2,
    minBackoffDuration: "60s",
    maxBackoffDuration: "5m",
    maxDoublings: 2,
  })
  .timeZone("Europe/Madrid")
  .onRun(async (context) => {
    try {
      console.log("Inicio de recordatorioDeudas");
      const deliveryFailures = [];

      const [usuariosSnap, membershipsSnap] = await Promise.all([
        db.collection("usuarios").get(),
        db.collection("groupMembers").get(),
      ]);

      console.log(`Usuarios encontrados: ${usuariosSnap.size}`);
      const period = reminderPeriod();

      const accountUidsByGroup = new Map();
      for (const membership of membershipsSnap.docs) {
        const groupId = membership.get('groupId');
        const uid = membership.get('deviceId');
        if (typeof groupId !== 'string' || typeof uid !== 'string') continue;
        const groupUids = accountUidsByGroup.get(groupId) ?? new Set();
        groupUids.add(uid);
        accountUidsByGroup.set(groupId, groupUids);
      }

      const debtorUids = new Set();
      for (const [groupId, groupUids] of accountUidsByGroup) {
        const [members, pendingDivisions] = await Promise.all([
          db.collection('groups').doc(groupId).collection('members').get(),
          db.collectionGroup('divisiones')
            .where('groupId', '==', groupId)
            .where('pagado', '==', false)
            .get(),
        ]);
        const uidByMemberId = new Map(
          members.docs.map((member) => [member.id, member.get('reclamadoPor')]),
        );

        for (const division of pendingDivisions.docs) {
          const memberId = division.get('memberId');
          const payerId = division.get('pagadoPor');
          const cents = division.get('cantidadCentimos');
          const legacyAmount = division.get('cantidad');
          const hasPositiveAmount = Number.isSafeInteger(cents)
            ? cents > 0
            : typeof legacyAmount === 'number' && legacyAmount > 0;
          const debtorUid = uidByMemberId.get(memberId);
          if (hasPositiveAmount && memberId !== payerId && groupUids.has(debtorUid)) {
            debtorUids.add(debtorUid);
          }
        }
      }

      for (const usuarioDoc of usuariosSnap.docs) {
        const deviceId = usuarioDoc.id;
        const token = usuarioDoc.get("fcmToken");

        if (!token) {
          console.log(`Usuario ${deviceId} sin token, se omite`);
          continue;
        }

        if (debtorUids.has(deviceId)) {
          const deliveryRef = db.collection('reminderDeliveries').doc(deviceId);
          const delivery = await deliveryRef.get();
          if (delivery.exists && delivery.get('period') === period) {
            console.log(`Recordatorio ${period} ya enviado a ${deviceId}`);
            continue;
          }
          try {
            await messaging.send({
              token: token,
              notification: {
                title: "Recordatorio de deudas",
                body: "Tienes deudas pendientes en la app.",
              },
            });
            await deliveryRef.set({
              period,
              userUid: deviceId,
              sentAt: FieldValue.serverTimestamp(),
            });
            console.log(`Notificación enviada a ${deviceId}`);
          } catch (error) {
            if (isInvalidMessagingToken(error)) {
              await usuarioDoc.ref.update({
                fcmToken: FieldValue.delete(),
                tokenInvalidatedAt: FieldValue.serverTimestamp(),
              });
              console.warn(`Token FCM inválido eliminado para ${deviceId}`);
            } else {
              console.error(`No se pudo notificar a ${deviceId}:`, error);
              deliveryFailures.push(error);
            }
          }
        } else {
          console.log(`Usuario ${deviceId} no tiene deudas pendientes`);
        }
      }

      console.log("Fin de recordatorioDeudas");

      if (deliveryFailures.length > 0) {
        throw new Error(
          `Fallaron ${deliveryFailures.length} envíos de recordatorios`,
          { cause: deliveryFailures[0] },
        );
      }

      return null;
    } catch (error) {
      console.error("Error en recordatorioDeudas:", error);
      throw error;
    }
  }
);

async function sendNotificationToMember({ groupId, memberId, title, body }) {
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

  const userRef = db.collection('usuarios').doc(uid);
  const userDoc = await userRef.get();
  const token = userDoc.get('fcmToken');
  if (!token) {
    console.log(`Usuario ${uid} no tiene token de notificación.`);
    return;
  }

  try {
    await messaging.send({ token, notification: { title, body } });
    console.log(`Notificación de deuda enviada al usuario ${uid}`);
  } catch (error) {
    if (!isInvalidMessagingToken(error)) throw error;
    await userRef.update({
      fcmToken: FieldValue.delete(),
      tokenInvalidatedAt: FieldValue.serverTimestamp(),
    });
    console.warn(`Token FCM inválido eliminado para ${uid}`);
  }
}

function isInvalidMessagingToken(error) {
  return error?.code === "messaging/registration-token-not-registered" ||
    error?.code === "messaging/invalid-registration-token";
}
