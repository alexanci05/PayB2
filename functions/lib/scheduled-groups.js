'use strict';

const { FieldValue, Timestamp } = require('firebase-admin/firestore');

async function claimScheduledGroup(db, queuedGroup, now) {
  return db.runTransaction(async (transaction) => {
    const group = await transaction.get(queuedGroup.ref);
    const checkedAt = group.get('schedulesCheckedAt');
    if (!(checkedAt instanceof Timestamp) ||
        !checkedAt.isEqual(queuedGroup.get('schedulesCheckedAt'))) return null;

    const schedules = await transaction.get(
      group.ref.collection('gastosProgramados').orderBy('nextAttemptAt').limit(1),
    );
    if (schedules.empty) {
      transaction.update(group.ref, { schedulesCheckedAt: FieldValue.delete() });
      return null;
    }

    // Rotate the group even if its oldest schedule is future, blocked or invalid.
    transaction.update(group.ref, { schedulesCheckedAt: FieldValue.serverTimestamp() });
    const schedule = schedules.docs[0];
    const attemptAt = schedule.get('nextAttemptAt');
    if (!(attemptAt instanceof Timestamp)) {
      transaction.update(schedule.ref, {
        nextAttemptAt: FieldValue.delete(),
        quarantineReason: 'invalid-next-attempt-at',
        quarantinedAt: FieldValue.serverTimestamp(),
      });
      return null;
    }
    if (attemptAt.toMillis() <= now.toMillis()) {
      // Keep a failed or backlogged schedule behind those still awaiting a turn.
      transaction.update(schedule.ref, { nextAttemptAt: now });
      return schedule;
    }
    return null;
  });
}

module.exports = { claimScheduledGroup };
