const functions = require('firebase-functions');
const admin = require('firebase-admin');
admin.initializeApp();

const { Timestamp } = require("firebase-admin/firestore");


exports.onDeudaPagada = functions.firestore
  .document('groups/{groupId}/gastos/{gastoId}/divisiones/{divisionId}')
  .onUpdate(async (change, context) => {
    try {
      const before = change.before.data();
      const after = change.after.data();
      const { groupId, gastoId } = context.params;

      if (before.pagado === false && after.pagado === true) {
        const pagadoPorId = after.pagadoPor;
        const miembroPagador = after.memberId;

        if (!pagadoPorId || !miembroPagador) {
          console.log('Faltan campos en after:', after);
          return null;
        }

        const miembroDoc = await admin.firestore()
          .collection('groups')
          .doc(groupId)
          .collection('members')
          .doc(pagadoPorId)
          .get();

        if (!miembroDoc.exists) {
          console.log(`Miembro ${pagadoPorId} no encontrado en grupo ${groupId}`);
          return null;
        }

        const reclamadoPor = miembroDoc.get('reclamadoPor');
        if (!reclamadoPor) {
          console.log(`Miembro ${pagadoPorId} aún no ha sido reclamado.`);
          return null;
        }

        const usuarioSnap = await admin.firestore()
          .collection('usuarios')
          .doc(reclamadoPor)
          .get();

        if (!usuarioSnap.exists) {
          console.log(`Usuario con deviceId ${reclamadoPor} no encontrado.`);
          return null;
        }

        const token = usuarioSnap.get('fcmToken');
        if (!token) {
          console.log(`Usuario ${reclamadoPor} no tiene token de notificación.`);
          return null;
        }

        const payload = {
          notification: {
            title: '¡Tu deuda fue pagada!',
            body: `El usuario con ID ${miembroPagador} ha marcado como pagada su deuda.`,
          },
        };

        await admin.messaging().send({
          token: token,
          notification: {
            title: '¡Una deuda fue pagada!',
            body: `El usuario con ID ${miembroPagador} ha marcado como pagada su deuda.`,
          },
        });

        console.log('Notificación enviada a', token);
      }

      return null;
    } catch (error) {
      console.error('Error en onDeudaPagada:', error);
      return null;
    }
  }
);


exports.ejecutarGastosPeriodicos = functions.pubsub
  .schedule("every day 15:00") // Hora de ejecución diaria a las 15:00 (UTC)
  .timeZone("Europe/Madrid")
  .onRun(async (context) => {

    const hoy = Timestamp.now();  // Ahora puedes acceder correctamente a Timestamp
    console.log(`--- Ejecutando Gastos Periódicos - Hoy: ${hoy.toDate().toISOString()} ---`);

    try {

      const gruposSnap = await admin.firestore().collection("groups").get();

      for (const grupo of gruposSnap.docs) {
        const groupId = grupo.id;

        const gastosSnap = await admin.firestore()
          .collection("groups")
          .doc(groupId)
          .collection("gastos")
          .where("proximaFecha", "<=", hoy)
          .get();

        console.log(`Gastos encontrados: ${gastosSnap.size}`);


        for (const gastoDoc of gastosSnap.docs) {
          const gastoRef = gastoDoc.ref;
          const gastoData = gastoDoc.data();

          console.log(`Procesando gasto: ${gastoRef.id} | proximaFecha: ${gastoData.proximaFecha?.toDate()} | frecuencia: ${gastoData.frecuencia}`);


          // 2. Obtener subcolección divisiones
          const divisionesSnap = await gastoRef.collection("divisiones").get();

          // 3. Crear nuevas divisiones con fecha actual
          const batch = admin.firestore().batch();
          for (const div of divisionesSnap.docs) {
            const data = div.data();
            const nuevaRef = gastoRef.collection("divisiones").doc();

            batch.set(nuevaRef, {
              ...data,
              fecha: Timestamp.now(),
            });
          }

          // 4. Calcular nueva proximaFecha
          const nuevaFecha = calcularProximaFecha(
            gastoData.proximaFecha.toDate(),
            gastoData.frecuencia
          );

          console.log(`Nueva proximaFecha para ${gastoRef.id}: ${nuevaFecha}`);

          // 5. Actualizar campo proximaFecha
          batch.update(gastoRef, {
            proximaFecha: Timestamp.fromDate(nuevaFecha),
          });

          await batch.commit();
          console.log(
            `Gasto ${gastoRef.id} en grupo ${groupId} procesado, siguiente repetición: ${nuevaFecha}`
          );
        }
      }
    } catch (e) {
      console.error("Error al ejecutar gastos periódicos:", e);
    }
  });

function calcularProximaFecha(actual, frecuencia) {
  const nueva = new Date(actual);
  switch (frecuencia) {
    case "Cada 7 días":
      nueva.setDate(nueva.getDate() + 7);
      break;
    case "Cada 15 días":
      nueva.setDate(nueva.getDate() + 15);
      break;
    case "Cada 30 días":
      nueva.setDate(nueva.getDate() + 30);
      break;
    case "Cada 365 días":
      nueva.setDate(nueva.getDate() + 365);
      break;
    case "Mensual (mismo día todos los meses)":
      nueva.setMonth(nueva.getMonth() + 1);
      break;
    case "Trimestral (mismo día cada 3 meses)":
      nueva.setMonth(nueva.getMonth() + 3);
      break;
    case "Anual (mismo día cada año)":
      nueva.setFullYear(nueva.getFullYear() + 1);
      break;
    default:
      nueva.setMonth(nueva.getMonth() + 1); // fallback
  }
  return nueva;
}

exports.recordatorioDeudas = functions.pubsub
  .schedule("every day 15:00")
  .timeZone("Europe/Madrid")
  .onRun(async (context) => {
    try {
      console.log("Inicio de recordatorioDeudas");

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
          await admin.messaging().send({
            token: token,
            notification: {
              title: "Recordatorio de deudas",
              body: "Tienes deudas pendientes en la app.",
            },
          });

          console.log(`Notificación enviada a ${deviceId}`);
        } else {
          console.log(`Usuario ${deviceId} no tiene deudas pendientes`);
        }
      }

      console.log("Fin de recordatorioDeudas");

      return null;
    } catch (error) {
      console.error("Error en recordatorioDeudas:", error);
      return null;
    }
  }
);
