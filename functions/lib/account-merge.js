'use strict';

const { createHash, randomBytes, randomUUID } = require('node:crypto');
const { FieldValue, Timestamp } = require('firebase-admin/firestore');
const { MAX_REGISTERED_DEVICES } = require('./security-policy');
const { reserveProjectCapacity } = require('./usage-limits');

class AccountMergeConflictError extends Error {}

const MERGE_TICKET_TTL_MS = 7 * 24 * 60 * 60 * 1000;
// Longer than the callable's 60-second timeout. A killed invocation cannot keep
// its reservation indefinitely; every migration write also fences its owner.
const MERGE_EXECUTION_LEASE_MS = 90_000;

function ticketId(ticket) {
  return createHash('sha256').update(ticket).digest('hex');
}

async function prepareAccountMerge(db, sourceUid) {
  const ticket = randomBytes(32).toString('base64url');
  const ticketRef = db.collection('accountMergeTickets').doc(ticketId(ticket));
  const preparationRef = db.collection('accountMergePreparations').doc(sourceUid);
  const mergeRef = db.collection('accountMerges').doc(sourceUid);
  return db.runTransaction(async (transaction) => {
    const [preparation, merge] = await transaction.getAll(preparationRef, mergeRef);
    const existingId = preparation.get('ticketId');
    const existing = existingId
      ? await transaction.get(db.collection('accountMergeTickets').doc(existingId))
      : null;
    const ownsTicket = existing?.exists && existing.get('sourceUid') === sourceUid &&
      typeof preparation.get('ticket') === 'string' &&
      ticketId(preparation.get('ticket')) === existingId;
    if (ownsTicket && !existing.get('targetUid') &&
        ((existing.get('status') === 'prepared' && !merge.exists &&
          existing.get('expiresAt')?.toMillis() > Date.now()) ||
         (existing.get('status') === 'active' && merge.get('status') === 'prepared' &&
          merge.get('ticketId') === existingId && !merge.get('targetUid')))) {
      return preparation.get('ticket');
    }
    if (merge.exists || (existing?.exists &&
        ['active', 'running', 'completed'].includes(existing.get('status')))) {
      throw new AccountMergeConflictError('Ya hay una fusión en curso para esta sesión');
    }
    await reserveProjectCapacity(transaction, db, 'prepararFusionCuenta');
    if (existing?.exists && existing.get('status') === 'prepared') {
      transaction.update(existing.ref, {
        status: 'expired',
        updatedAt: FieldValue.serverTimestamp(),
      });
    }
    transaction.create(ticketRef, {
      sourceUid,
      status: 'prepared',
      expiresAt: Timestamp.fromMillis(Date.now() + MERGE_TICKET_TTL_MS),
      createdAt: FieldValue.serverTimestamp(),
    });
    // This collection is server-only under the rules' default deny.
    transaction.set(preparationRef, { ticketId: ticketRef.id, ticket });
    return ticket;
  });
}

async function activateAccountMerge(db, sourceUid, ticket) {
  const ticketRef = db.collection('accountMergeTickets').doc(ticketId(ticket));
  const mergeRef = db.collection('accountMerges').doc(sourceUid);
  const preparationRef = db.collection('accountMergePreparations').doc(sourceUid);
  await db.runTransaction(async (transaction) => {
    const [ticketSnapshot, mergeSnapshot, preparation] =
      await transaction.getAll(ticketRef, mergeRef, preparationRef);
    if (ticketSnapshot.get('sourceUid') === sourceUid &&
        ticketSnapshot.get('status') === 'active' && !ticketSnapshot.get('targetUid') &&
        mergeSnapshot.get('status') === 'prepared' && !mergeSnapshot.get('targetUid') &&
        mergeSnapshot.get('ticketId') === ticketRef.id) return;
    if (!ticketSnapshot.exists || ticketSnapshot.get('sourceUid') !== sourceUid ||
        preparation.get('ticketId') !== ticketRef.id ||
        ticketSnapshot.get('targetUid') ||
        ticketSnapshot.get('status') !== 'prepared' ||
        !(ticketSnapshot.get('expiresAt')?.toMillis() > Date.now())) {
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
    if (data.sourceUid === targetUid) {
      const error = new AccountMergeConflictError('Los usuarios de origen y destino no son válidos');
      error.reason = 'same-account';
      throw error;
    }
    if (data.targetUid && data.targetUid !== targetUid) {
      throw new AccountMergeConflictError('El ticket pertenece a otra cuenta');
    }
    if (data.status === 'completed') return snapshot;
    if (!['active', 'running'].includes(data.status)) {
      throw new AccountMergeConflictError('El ticket de fusión todavía no está activo');
    }
    const merge = await transaction.get(db.collection('accountMerges').doc(data.sourceUid));
    if (!merge.exists || merge.get('ticketId') !== ticketRef.id ||
        (merge.get('targetUid') && merge.get('targetUid') !== targetUid)) {
      throw new AccountMergeConflictError('El ticket no corresponde a la fusión activa');
    }
    transaction.update(ticketRef, {
      targetUid,
      status: 'running',
      updatedAt: FieldValue.serverTimestamp(),
    });
    return snapshot;
  });
  return {
    ticketRef,
    sourceUid: ticketSnapshot.get('sourceUid'),
    completed: ticketSnapshot.get('status') === 'completed',
    result: ticketSnapshot.get('result'),
  };
}

async function cancelAccountMerge(db, sourceUid, ticket) {
  const ticketRef = db.collection('accountMergeTickets').doc(ticketId(ticket));
  const mergeRef = db.collection('accountMerges').doc(sourceUid);
  const preparationRef = db.collection('accountMergePreparations').doc(sourceUid);
  await db.runTransaction(async (transaction) => {
    const [ticketSnapshot, mergeSnapshot, preparation] =
      await transaction.getAll(ticketRef, mergeRef, preparationRef);
    // Without ticket ownership evidence, never touch a merge lock.
    if (!ticketSnapshot.exists) {
      if (mergeSnapshot.exists) {
        throw new AccountMergeConflictError('La fusión ya no se puede cancelar');
      }
      return;
    }
    if (ticketSnapshot.get('sourceUid') !== sourceUid || ticketSnapshot.get('targetUid')) {
      throw new AccountMergeConflictError('La fusión ya no se puede cancelar');
    }
    if (ticketSnapshot.get('status') === 'canceled') return;
    if (!['prepared', 'active'].includes(ticketSnapshot.get('status')) ||
        (mergeSnapshot.exists && mergeSnapshot.get('ticketId') === ticketRef.id &&
          (mergeSnapshot.get('status') !== 'prepared' || mergeSnapshot.get('targetUid')))) {
      throw new AccountMergeConflictError('La fusión ya no se puede cancelar');
    }
    transaction.update(ticketRef, {
      status: 'canceled',
      updatedAt: FieldValue.serverTimestamp(),
    });
    if (preparation.get('ticketId') === ticketRef.id) transaction.delete(preparationRef);
    if (mergeSnapshot.exists && mergeSnapshot.get('status') === 'prepared' &&
        mergeSnapshot.get('ticketId') === ticketRef.id) {
      transaction.delete(mergeRef);
    }
  });
}

async function reserveMerge(db, sourceUid, targetUid) {
  const mergeRef = db.collection('accountMerges').doc(sourceUid);
  const leaseOwner = randomUUID();
  const state = await db.runTransaction(async (transaction) => {
    const sourceRegistryRef = db.collection('deviceRegistries').doc(sourceUid);
    const targetRegistryRef = db.collection('deviceRegistries').doc(targetUid);
    // Lock registries first, in a stable order shared with device registration.
    const registries = [sourceRegistryRef, targetRegistryRef]
      .sort((left, right) => left.path < right.path ? -1 : left.path > right.path ? 1 : 0);
    for (const registry of registries) await transaction.get(registry);
    const merge = await transaction.get(mergeRef);
    if (merge.exists && merge.get('targetUid') && merge.get('targetUid') !== targetUid) {
      throw new AccountMergeConflictError(
        'La sesión anónima ya está vinculada a otra cuenta',
      );
    }
    if (merge.get('status') === 'completed') {
      return { completed: true, result: merge.get('result') };
    }
    if (merge.get('leaseExpiresAt')?.toMillis() > Date.now()) {
      const error = new AccountMergeConflictError('La fusión ya se está ejecutando; inténtalo más tarde');
      error.reason = 'merge-in-progress';
      throw error;
    }
    const sourceDevicesRef = db.collection('usuarios').doc(sourceUid).collection('devices');
    const targetDevicesRef = db.collection('usuarios').doc(targetUid).collection('devices');
    const targetMerge = await transaction.get(db.collection('accountMerges').doc(targetUid));
    if (targetMerge.exists) {
      throw new AccountMergeConflictError('La cuenta de destino tiene una fusión en curso');
    }
    const sourceDevices = await readDevices(transaction, sourceDevicesRef);
    const targetDevices = await readDevices(transaction, targetDevicesRef);
    const devices = new Map(targetDevices.map((device) => [device.id, device]));
    for (const device of sourceDevices) {
      const target = devices.get(device.id);
      if (!target || compareDeviceRecency(device, target) < 0) devices.set(device.id, device);
    }
    const retained = [...devices.values()]
      .sort(compareDeviceRecency).slice(0, MAX_REGISTERED_DEVICES);
    const retainedIds = new Set(retained.map((device) => device.id));
    for (const device of retained) {
      if (device.ref.parent.path === sourceDevicesRef.path) {
        transaction.set(targetDevicesRef.doc(device.id), device.data());
      }
    }
    for (const device of targetDevices) {
      if (!retainedIds.has(device.id)) transaction.delete(device.ref);
    }
    for (const device of sourceDevices) transaction.delete(device.ref);
    // Registration uses these same documents to serialize otherwise disjoint IDs.
    for (const registryRef of [sourceRegistryRef, targetRegistryRef]) {
      transaction.set(registryRef, {
        revision: FieldValue.increment(1),
        updatedAt: FieldValue.serverTimestamp(),
      }, { merge: true });
    }
    transaction.set(mergeRef, {
      sourceUid,
      targetUid,
      status: 'running',
      leaseOwner,
      leaseExpiresAt: Timestamp.fromMillis(Date.now() + MERGE_EXECUTION_LEASE_MS),
      updatedAt: FieldValue.serverTimestamp(),
    }, { merge: true });
    return { completed: false, result: merge.get('result') };
  });
  return { mergeRef, leaseOwner, targetUid, ...state };
}

async function assertMergeLease(transaction, lease) {
  const merge = await transaction.get(lease.mergeRef);
  if (merge.get('status') !== 'running' || merge.get('leaseOwner') !== lease.leaseOwner ||
      merge.get('targetUid') !== lease.targetUid ||
      !(merge.get('leaseExpiresAt')?.toMillis() > Date.now())) {
    const error = new AccountMergeConflictError('La reserva de fusión ha caducado o pertenece a otra ejecución');
    error.reason = 'merge-lease-lost';
    throw error;
  }
  return merge;
}

async function releaseMergeLease(db, lease) {
  await db.runTransaction(async (transaction) => {
    const merge = await transaction.get(lease.mergeRef);
    if (merge.get('leaseOwner') !== lease.leaseOwner || merge.get('status') !== 'running') return;
    transaction.update(lease.mergeRef, {
      leaseOwner: FieldValue.delete(), leaseExpiresAt: FieldValue.delete(),
    });
  });
}

function compareDeviceRecency(left, right) {
  const leftTime = left.get('tokenUpdatedAt');
  const rightTime = right.get('tokenUpdatedAt');
  const byTime = (rightTime?.seconds ?? 0) - (leftTime?.seconds ?? 0) ||
    (rightTime?.nanoseconds ?? 0) - (leftTime?.nanoseconds ?? 0);
  return byTime || (left.id < right.id ? -1 : left.id > right.id ? 1 : 0);
}

async function readDevices(transaction, collection) {
  // Registry reads/writes protect discovery against phantom insertions. Avoid a
  // transactional query's collection lock, which can deadlock registry writers.
  const snapshot = await collection.limit(MAX_REGISTERED_DEVICES + 1).get();
  if (snapshot.size > MAX_REGISTERED_DEVICES) {
    throw new AccountMergeConflictError(
      'El registro supera el limite de dispositivos; limpia o restablece los datos antiguos de desarrollo',
    );
  }
  if (snapshot.empty) return [];
  const devices = await transaction.getAll(...snapshot.docs.map((device) => device.ref));
  return devices.filter((device) => device.exists);
}

async function* readPages(db, query, lease) {
  let next = query.limit(450);
  for (;;) {
    await db.runTransaction((transaction) => assertMergeLease(transaction, lease));
    const page = await next.get();
    if (page.empty) return;
    yield page;
    if (page.size < 450) return;
    next = query.limit(450).startAfter(page.docs.at(-1));
  }
}

async function commitUpdates(db, query, data, lease) {
  for await (const page of readPages(db, query, lease)) {
    await db.runTransaction(async (transaction) => {
      await assertMergeLease(transaction, lease);
      for (const document of page.docs) transaction.update(document.ref, data);
    });
  }
}

async function migrateGroupCreationRequests(db, sourceUid, targetUid, lease) {
  const requests = db.collection('groupCreationRequests').where('createdByUid', '==', sourceUid);
  for await (const page of readPages(db, requests, lease)) {
    for (const request of page.docs) {
      const requestId = request.id.slice(`${sourceUid}_`.length);
      const targetRef = db.collection('groupCreationRequests').doc(`${targetUid}_${requestId}`);
      await db.runTransaction(async (transaction) => {
        await assertMergeLease(transaction, lease);
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
}

async function mergeGroup(db, groupId, sourceUid, targetUid, lease) {
  const groupRef = db.collection('groups').doc(groupId);
  const sourceMembershipRef = db.collection('groupMembers').doc(`${groupId}_${sourceUid}`);
  const targetMembershipRef = db.collection('groupMembers').doc(`${groupId}_${targetUid}`);
  const membersRef = groupRef.collection('members');

  await db.runTransaction(async (transaction) => {
    await assertMergeLease(transaction, lease);
    const sourceClaimQuery = membersRef.where('reclamadoPor', '==', sourceUid);
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
    const sourceMemberId = sourceData.memberId ?? sourceClaim?.id ?? null;
    const targetMemberId = targetMembership.data()?.memberId ?? targetClaim?.id ?? null;

    for (const claim of sourceClaims.docs) {
      if (claim.id !== targetMemberId) {
        transaction.update(claim.ref, { reclamadoPor: targetUid });
      }
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

  for (const collection of ['gastos', 'gastosProgramados', 'expenseRequests']) {
    await commitUpdates(db, groupRef.collection(collection).where('createdByUid', '==', sourceUid), {
      createdByUid: targetUid,
      mergedFromUid: sourceUid,
    }, lease);
  }

  await db.runTransaction(async (transaction) => {
    await assertMergeLease(transaction, lease);
    transaction.delete(sourceMembershipRef);
  });
}

async function mergeAnonymousAccountData(db, sourceUid, targetUid) {
  if (!sourceUid || !targetUid || sourceUid === targetUid) {
    throw new Error('Los usuarios de origen y destino no son válidos');
  }

  const lease = await reserveMerge(db, sourceUid, targetUid);
  const { mergeRef, completed, result: savedResult } = lease;
  if (completed) return savedResult ?? { mergedGroups: 0 };
  try {
    const memberships = db.collection('groupMembers').where('deviceId', '==', sourceUid);
    let result = savedResult;
    if (!result) {
      const count = await memberships.count().get();
      result = await db.runTransaction(async (transaction) => {
        const merge = await assertMergeLease(transaction, lease);
        if (merge.get('result')) return merge.get('result');
        const plannedResult = { mergedGroups: count.data().count };
        transaction.update(mergeRef, { result: plannedResult });
        return plannedResult;
      });
    }

    for await (const page of readPages(db, memberships, lease)) {
      for (const membership of page.docs) {
        await mergeGroup(db, membership.get('groupId'), sourceUid, targetUid, lease);
      }
    }

    await migrateGroupCreationRequests(db, sourceUid, targetUid, lease);

    await db.runTransaction(async (transaction) => {
      await assertMergeLease(transaction, lease);
      transaction.update(mergeRef, {
        status: 'completed',
        result,
        leaseOwner: FieldValue.delete(),
        leaseExpiresAt: FieldValue.delete(),
        completedAt: FieldValue.serverTimestamp(),
        updatedAt: FieldValue.serverTimestamp(),
      });
    });

    return result;
  } finally {
    await releaseMergeLease(db, lease);
  }
}

async function completeAccountMerge(db, ticket, targetUid) {
  const { ticketRef, sourceUid, completed, result: savedResult } =
    await consumeAccountMergeTicket(db, ticket, targetUid);
  if (completed) return savedResult;
  const result = await mergeAnonymousAccountData(db, sourceUid, targetUid);
  await ticketRef.set({
    status: 'completed',
    result,
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
