const functions = require('firebase-functions');
const admin = require('firebase-admin');
admin.initializeApp();

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
  });
