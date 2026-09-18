const functions = require('firebase-functions/v1');
const admin = require('firebase-admin');
const { randomInt } = require('node:crypto');
admin.initializeApp();

const { Timestamp } = require("firebase-admin/firestore");
const {
  centsFromAmount,
  splitCents,
  nextScheduledDate,
  scheduledOccurrenceId,
  divisionId,
} = require('./lib/scheduled-occurrences');
const { debtNotificationForTransition } = require('./lib/debt-notifications');

exports.crearGrupo = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Debes iniciar sesión");
  }

  const nombre = typeof data?.nombre === "string" ? data.nombre.trim() : "";
  const memberNames = Array.isArray(data?.miembros)
    ? data.miembros.map((name) => typeof name === "string" ? name.trim() : "")
    : [];
  const uniqueNames = new Set(memberNames.map((name) => name.toLocaleLowerCase("es")));
  if (!nombre || nombre.length > 80) {
    throw new functions.https.HttpsError("invalid-argument", "El nombre del grupo no es válido");
  }
  if (
    memberNames.length === 0 ||
    memberNames.length > 50 ||
    memberNames.some((name) => !name || name.length > 50) ||
    uniqueNames.size !== memberNames.length
  ) {
    throw new functions.https.HttpsError("invalid-argument", "La lista de miembros no es válida");
  }

  const db = admin.firestore();
  const uid = context.auth.uid;
  const groupRef = db.collection("groups").doc();

  for (let attempt = 0; attempt < 5; attempt += 1) {
    const groupCode = createGroupCode();
    const reserved = await db.runTransaction(async (transaction) => {
      const codeRef = db.collection("groupCodes").doc(groupCode);
      const codeSnapshot = await transaction.get(codeRef);
      if (codeSnapshot.exists) return false;

      transaction.create(codeRef, {
        groupId: groupRef.id,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      transaction.create(groupRef, {
        name: nombre,
        createdAt: admin.firestore.FieldValue.serverTimestamp(),
        groupCode,
        ownerDeviceId: uid,
      });
      transaction.create(db.collection("groupMembers").doc(`${groupRef.id}_${uid}`), {
        groupId: groupRef.id,
        deviceId: uid,
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
      });
      memberNames.forEach((memberName, index) => {
        const memberId = `member_${String(index + 1).padStart(3, "0")}`;
        transaction.create(groupRef.collection("members").doc(memberId), {
          name: memberName,
          reclamadoPor: null,
        });
      });
      return true;
    });

    if (reserved) return { groupId: groupRef.id, groupCode };
  }

  throw new functions.https.HttpsError("aborted", "No se pudo reservar un código de grupo");
});

function createGroupCode() {
  const chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789";
  return Array.from({ length: 8 }, () => chars[randomInt(chars.length)]).join("");
}

exports.unirseAGrupo = functions.https.onCall(async (data, context) => {
  if (!context.auth) {
    throw new functions.https.HttpsError("unauthenticated", "Debes iniciar sesión");
  }

  const codigo = typeof data?.codigo === "string" ? data.codigo.trim() : "";
  if (!/^[A-Za-z0-9]{8}$/.test(codigo)) {
    throw new functions.https.HttpsError("invalid-argument", "El código no es válido");
  }

  const db = admin.firestore();
  const uid = context.auth.uid;
  const attemptsRef = db.collection("joinAttempts").doc(uid);
  const result = await db.runTransaction(async (transaction) => {
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
        joinedAt: admin.firestore.FieldValue.serverTimestamp(),
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
    const db = admin.firestore();
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
            const result = await generarOcurrenciaProgramada({
              db,
              groupId,
              scheduleRef: gastoProgramadoDoc.ref,
              now: hoy,
            });
            if (result) {
              console.log(`Gasto programado ${gastoProgramadoDoc.id} en grupo ${groupId}: ${result}`);
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
      return "ya eliminado";
    }

    const schedule = scheduleSnap.data();
    const scheduledAt = schedule.proximaFecha;
    if (!scheduledAt || typeof scheduledAt.toDate !== "function" || typeof scheduledAt.toMillis !== "function") {
      throw new TypeError("proximaFecha debe ser un Timestamp de Firestore");
    }
    if (scheduledAt.toMillis() > now.toMillis()) {
      return "ya no vence";
    }

    const scheduledDate = scheduledAt.toDate();
    const totalCents = centsFromAmount(schedule.cantidadCentimos, schedule.cantidad);
    const shares = splitCents(totalCents, schedule.pagadoPor, schedule.participantes || []);
    const occurrenceId = scheduledOccurrenceId(scheduleRef.id, scheduledAt);
    const occurrenceRef = db.collection("groups").doc(groupId).collection("gastos").doc(occurrenceId);
    const occurrenceSnap = await transaction.get(occurrenceRef);
    const isOneOff = schedule.frecuencia === null || schedule.frecuencia === undefined;
    const nextDate = isOneOff ? null : nextScheduledDate(scheduledDate, schedule.frecuencia);

    if (!occurrenceSnap.exists) {
      transaction.create(occurrenceRef, {
        nombre: schedule.nombre,
        descripcion: schedule.descripcion || "",
        cantidad: totalCents / 100,
        cantidadCentimos: totalCents,
        fecha: scheduledAt,
        created: admin.firestore.FieldValue.serverTimestamp(),
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
          created: admin.firestore.FieldValue.serverTimestamp(),
          fecha: scheduledAt,
          nombre: schedule.nombre,
          pagadoPor: schedule.pagadoPor,
        });
      }
    }

    if (isOneOff) {
      transaction.delete(scheduleRef);
      return occurrenceSnap.exists ? "ocurrencia existente y programación eliminada" : "ocurrencia creada y programación eliminada";
    }

    transaction.update(scheduleRef, { proximaFecha: Timestamp.fromDate(nextDate) });
    return occurrenceSnap.exists ? "ocurrencia existente y próxima fecha avanzada" : "ocurrencia creada";
  });
}

exports.recordatorioDeudas = functions.pubsub
  .schedule("every day 15:00")
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

      // 1. Leer TODOS los usuarios
      const usuariosSnap = await admin.firestore()
        .collection("usuarios")
        .get();

      console.log(`Usuarios encontrados: ${usuariosSnap.size}`);

      for (const usuarioDoc of usuariosSnap.docs) {
        const deviceId = usuarioDoc.id;
        const token = usuarioDoc.get("fcmToken");

        if (!token) {
          console.log(`Usuario ${deviceId} sin token, se omite`);
          continue;
        }

        // 2. Buscar todos los groupIds donde esté
        const memberSnap = await admin.firestore()
          .collection("groupMembers")
          .where("deviceId", "==", deviceId)
          .get();

        const groupIds = memberSnap.docs.map((d) => d.get("groupId"));
        console.log(`Usuario ${deviceId} pertenece a grupos: ${groupIds.join(", ")}`);

        let tieneDeudaPendiente = false;

        // 3. Para cada grupo, buscar gastos y divisiones
        for (const gid of groupIds) {
          // a) Buscar miembros del grupo
          const membersSnap = await admin.firestore()
            .collection("groups").doc(gid)
            .collection("members")
            .get();

          const phantomSnap = membersSnap.docs.find(
            (m) => m.get("reclamadoPor") === deviceId
          );

          if (!phantomSnap) {
            continue;
          }

          const phantomId = phantomSnap.id;

          // b) Buscar todos los gastos
          const gastosSnap = await admin.firestore()
            .collection("groups").doc(gid)
            .collection("gastos")
            .get();

          for (const gastoDoc of gastosSnap.docs) {
            const gastoData = gastoDoc.data();
            const pagadoPorId = gastoData.pagadoPor || "";

            // c) Buscar divisiones mías (phantomId)
            const divisionesSnap = await gastoDoc.ref
              .collection("divisiones")
              .where("memberId", "==", phantomId)
              .where("pagado", "==", false)
              .where("cantidad", ">", 0)
              .get();

            if (divisionesSnap.size > 0 && pagadoPorId !== phantomId) {
              console.log(`Usuario ${deviceId} tiene deuda pendiente en grupo ${gid}`);
              tieneDeudaPendiente = true;
              break; // con encontrar una es suficiente
            }
          }

          if (tieneDeudaPendiente) break;
        }

        // 4. Si tiene deudas → enviar notificación
        if (tieneDeudaPendiente) {
          try {
            await admin.messaging().send({
              token: token,
              notification: {
                title: "Recordatorio de deudas",
                body: "Tienes deudas pendientes en la app.",
              },
            });
            console.log(`Notificación enviada a ${deviceId}`);
          } catch (error) {
            if (isInvalidMessagingToken(error)) {
              await usuarioDoc.ref.update({
                fcmToken: admin.firestore.FieldValue.delete(),
                tokenInvalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
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
  const memberDoc = await admin.firestore()
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

  const userRef = admin.firestore().collection('usuarios').doc(uid);
  const userDoc = await userRef.get();
  const token = userDoc.get('fcmToken');
  if (!token) {
    console.log(`Usuario ${uid} no tiene token de notificación.`);
    return;
  }

  try {
    await admin.messaging().send({ token, notification: { title, body } });
    console.log(`Notificación de deuda enviada al usuario ${uid}`);
  } catch (error) {
    if (!isInvalidMessagingToken(error)) throw error;
    await userRef.update({
      fcmToken: admin.firestore.FieldValue.delete(),
      tokenInvalidatedAt: admin.firestore.FieldValue.serverTimestamp(),
    });
    console.warn(`Token FCM inválido eliminado para ${uid}`);
  }
}

function isInvalidMessagingToken(error) {
  return error?.code === "messaging/registration-token-not-registered" ||
    error?.code === "messaging/invalid-registration-token";
}
