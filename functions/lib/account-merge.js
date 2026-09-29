'use strict';

const { createHash, randomBytes } = require('node:crypto');
const { FieldValue, Timestamp } = require('firebase-admin/firestore');

class AccountMergeConflictError extends Error {}

const MERGE_TICKET_TTL_MS = 7 * 24 * 60 * 60 * 1000;

function ticketId(ticket) {
  return createHash('sha256').update(ticket).digest('hex');
}

async function prepareAccountMerge(db, sourceUid) {
  const ticket = randomBytes(32).toString('base64url');
  const ticketRef = db.collection('accountMergeTickets').doc(ticketId(ticket));
  await ticketRef.create({
    sourceUid,
    status: 'prepared',
    expiresAt: Timestamp.fromMillis(Date.now() + MERGE_TICKET_TTL_MS),
    createdAt: FieldValue.serverTimestamp(),
  });
  return ticket;
}

async function activateAccountMerge(db, sourceUid, ticket) {
  const ticketRef = db.collection('accountMergeTickets').doc(ticketId(ticket));
  const mergeRef = db.collection('accountMerges').doc(sourceUid);
  await db.runTransaction(async (transaction) => {
    const [ticketSnapshot, mergeSnapshot] = await transaction.getAll(ticketRef, mergeRef);
    if (!ticketSnapshot.exists || ticketSnapshot.get('sourceUid') !== sourceUid ||
        ticketSnapshot.get('status') !== 'prepared' ||
        ticketSnapshot.get('expiresAt')?.toMillis() < Date.now()) {
      throw new AccountMergeConflictError('El ticket de fusión no es válido');
    }
    if (mergeSnapshot.exists) {
      throw new AccountMergeConflictError('Ya hay una fusión en curso para esta sesión');
    }
    transaction.create(mergeRef, {
      sourceUid,
      ticketId: ticketRef.id,
      status: 'prepared',
      updatedAt: FieldValue.serverTimestamp(),
    });
    transaction.update(ticketRef, {
      status: 'active',
      updatedAt: FieldValue.serverTimestamp(),
    });
  });
}

async function consumeAccountMergeTicket(db, ticket, targetUid) {
  const ticketRef = db.collection('accountMergeTickets').doc(ticketId(ticket));
  const ticketSnapshot = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(ticketRef);
    if (!snapshot.exists) {
      throw new AccountMergeConflictError('El ticket de fusión no es válido');
    }
    const data = snapshot.data();
    if (data.targetUid && data.targetUid !== targetUid) {
      throw new AccountMergeConflictError('El ticket pertenece a otra cuenta');
    }
    if (data.status === 'completed') return snapshot;
    if (!['active', 'running'].includes(data.status)) {
      throw new AccountMergeConflictError('El ticket de fusión todavía no está activo');
    }
    if (data.expiresAt?.toMillis() < Date.now() && !data.targetUid) {
      throw new AccountMergeConflictError('El ticket de fusión ha caducado');
    }
    transaction.update(ticketRef, {
      targetUid,
      status: 'running',
      updatedAt: FieldValue.serverTimestamp(),
    });
    return snapshot;
  });
  return { ticketRef, sourceUid: ticketSnapshot.get('sourceUid') };
}

async function cancelAccountMerge(db, sourceUid, ticket) {
  const ticketRef = db.collection('accountMergeTickets').doc(ticketId(ticket));
  const mergeRef = db.collection('accountMerges').doc(sourceUid);
  await db.runTransaction(async (transaction) => {
    const [ticketSnapshot, mergeSnapshot] = await transaction.getAll(ticketRef, mergeRef);
    if (!ticketSnapshot.exists || ticketSnapshot.get('sourceUid') !== sourceUid ||
        !['prepared', 'active'].includes(ticketSnapshot.get('status'))) {
      throw new AccountMergeConflictError('La fusión ya no se puede cancelar');
    }
    transaction.delete(ticketRef);
    if (mergeSnapshot.exists && mergeSnapshot.get('status') === 'prepared' &&
        mergeSnapshot.get('ticketId') === ticketRef.id) {
      transaction.delete(mergeRef);
    }
  });
}

async function reserveMerge(db, sourceUid, targetUid) {
  const mergeRef = db.collection('accountMerges').doc(sourceUid);
  await db.runTransaction(async (transaction) => {
    const merge = await transaction.get(mergeRef);
    if (merge.exists && merge.get('targetUid') && merge.get('targetUid') !== targetUid) {
      throw new AccountMergeConflictError(
        'La sesión anónima ya está vinculada a otra cuenta',
      );
    }
    transaction.set(mergeRef, {
      sourceUid,
      targetUid,
      status: 'running',
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
  });
  return mergeRef;
}

async function commitUpdates(db, snapshots, data) {
  const documents = snapshots.flatMap((snapshot) => snapshot.docs);
  for (let offset = 0; offset < documents.length; offset += 450) {
    const batch = db.batch();
    for (const document of documents.slice(offset, offset + 450)) {
      batch.update(document.ref, data);
    }
    await batch.commit();
  }
}

async function migrateGroupCreationRequests(db, sourceUid, targetUid) {
  const requests = await db.collection('groupCreationRequests')
    .where('createdByUid', '==', sourceUid)
    .get();
  for (const request of requests.docs) {
    const requestId = request.id.slice(`${sourceUid}_`.length);
    const targetRef = db.collection('groupCreationRequests').doc(`${targetUid}_${requestId}`);
    await db.runTransaction(async (transaction) => {
      const target = await transaction.get(targetRef);
      if (!target.exists) {
        transaction.create(targetRef, {
          ...request.data(),
          createdByUid: targetUid,
          mergedFromUid: sourceUid,
        });
      }
      transaction.delete(request.ref);
    });
  }
}

async function mergeGroup(db, groupId, sourceUid, targetUid) {
  const groupRef = db.collection('groups').doc(groupId);
  const sourceMembershipRef = db.collection('groupMembers').doc(`${groupId}_${sourceUid}`);
  const targetMembershipRef = db.collection('groupMembers').doc(`${groupId}_${targetUid}`);
  const membersRef = groupRef.collection('members');

  await db.runTransaction(async (transaction) => {
    const sourceClaimQuery = membersRef.where('reclamadoPor', '==', sourceUid).limit(1);
    const targetClaimQuery = membersRef.where('reclamadoPor', '==', targetUid).limit(1);
    const [group, sourceMembership, targetMembership, sourceClaims, targetClaims] =
      await Promise.all([
        transaction.get(groupRef),
        transaction.get(sourceMembershipRef),
        transaction.get(targetMembershipRef),
        transaction.get(sourceClaimQuery),
        transaction.get(targetClaimQuery),
      ]);

    if (!sourceMembership.exists) return;
    if (!group.exists) {
      throw new Error(`El grupo ${groupId} no existe`);
    }

    const sourceData = sourceMembership.data();
    const sourceClaim = sourceClaims.docs[0];
    const targetClaim = targetClaims.docs[0];
    const sourceMemberId = sourceClaim?.id ?? sourceData.memberId ?? null;
    const targetMemberId = targetClaim?.id ?? targetMembership.data()?.memberId ?? null;

    if (sourceClaim && sourceClaim.id !== targetMemberId) {
      transaction.update(sourceClaim.ref, { reclamadoPor: targetUid });
    }

    const mergedMemberId = targetMemberId ?? sourceMemberId;
    const membershipData = {
      ...(targetMembership.exists ? {} : sourceData),
      deviceId: targetUid,
      groupId,
      mergedAt: FieldValue.serverTimestamp(),
    };
    if (mergedMemberId) membershipData.memberId = mergedMemberId;
    transaction.set(targetMembershipRef, membershipData, { merge: true });

    if (group.get('ownerDeviceId') === sourceUid) {
      transaction.update(groupRef, { ownerDeviceId: targetUid });
    }
  });

  const [expenses, schedules, requests] = await Promise.all([
    groupRef.collection('gastos').where('createdByUid', '==', sourceUid).get(),
    groupRef.collection('gastosProgramados').where('createdByUid', '==', sourceUid).get(),
    groupRef.collection('expenseRequests').where('createdByUid', '==', sourceUid).get(),
  ]);
  await commitUpdates(db, [expenses, schedules, requests], {
    createdByUid: targetUid,
    mergedFromUid: sourceUid,
  });

  await sourceMembershipRef.delete();
}

async function mergeAnonymousAccountData(db, sourceUid, targetUid) {
  if (!sourceUid || !targetUid || sourceUid === targetUid) {
    throw new Error('Los usuarios de origen y destino no son válidos');
  }

  const mergeRef = await reserveMerge(db, sourceUid, targetUid);
  const memberships = await db
    .collection('groupMembers')
    .where('deviceId', '==', sourceUid)
    .get();

  for (const membership of memberships.docs) {
    await mergeGroup(db, membership.get('groupId'), sourceUid, targetUid);
  }

  await migrateGroupCreationRequests(db, sourceUid, targetUid);

  const sourceUserRef = db.collection('usuarios').doc(sourceUid);
  const targetUserRef = db.collection('usuarios').doc(targetUid);
  await db.runTransaction(async (transaction) => {
    const sourceUser = await transaction.get(sourceUserRef);
    if (!sourceUser.exists) return;
    transaction.set(targetUserRef, {
      ...sourceUser.data(),
      deviceId: targetUid,
      mergedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    transaction.delete(sourceUserRef);
  });

  await mergeRef.set({
    status: 'completed',
    completedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });

  return { mergedGroups: memberships.size };
}

async function completeAccountMerge(db, ticket, targetUid) {
  const { ticketRef, sourceUid } = await consumeAccountMergeTicket(db, ticket, targetUid);
  const result = await mergeAnonymousAccountData(db, sourceUid, targetUid);
  await ticketRef.set({
    status: 'completed',
    completedAt: FieldValue.serverTimestamp(),
    updatedAt: FieldValue.serverTimestamp(),
  }, { merge: true });
  return result;
}

module.exports = {
  AccountMergeConflictError,
  activateAccountMerge,
  cancelAccountMerge,
  completeAccountMerge,
  mergeAnonymousAccountData,
  prepareAccountMerge,
};
