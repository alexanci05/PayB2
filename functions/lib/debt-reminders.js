'use strict';

const { randomUUID } = require('node:crypto');
const { FieldPath, FieldValue } = require('firebase-admin/firestore');
const { sendNotificationToUser } = require('./device-notifications');
const { MAX_REGISTERED_DEVICES } = require('./security-policy');

// Every requested result slot and FCM attempt is charged before the external work.
// These are application ceilings; billing budgets remain alerts, not spending caps.
const REMINDER_LIMITS = Object.freeze({
  divisionsPerRun: 50,
  divisionsPerDay: 1000,
  sendsPerRun: 20,
  sendsPerDay: 300,
  attemptsPerDivision: 3,
  leaseMs: 150_000,
  workMs: 80_000,
});

function reminderClock(date) {
  const parts = new Intl.DateTimeFormat('en-GB', {
    timeZone: 'Europe/Madrid', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).formatToParts(date);
  const values = Object.fromEntries(parts.map((part) => [part.type, part.value]));
  return { period: `${values.year}-${values.month}-${values.day}`, ready: `${values.hour}:${values.minute}` >= '15:15' };
}

function budgetError() {
  return Object.assign(new Error('Reminder send budget reached'), { code: 'reminders/budget' });
}

async function runDebtReminders({ db, messaging, now = new Date(), limits = REMINDER_LIMITS }) {
  const { period, ready } = reminderClock(now);
  if (!ready) return { status: 'outside-window' };
  const stateRef = db.collection('backgroundJobs').doc('debtReminders');
  const reservation = randomUUID();
  const startedAt = Date.now();
  let state = await db.runTransaction(async (transaction) => {
    const snapshot = await transaction.get(stateRef);
    const previous = snapshot.data() || {};
    if (previous.leaseUntil > startedAt) return null;
    if (previous.period === period && previous.done) return null;
    const value = previous.period === period ? previous : {
      period, cursor: previous.cursor || null, divisionsCharged: 0, sendsCharged: 0,
      attempts: 0, attemptPath: null, done: false,
    };
    transaction.set(stateRef, {
      ...value, reservation, leaseUntil: startedAt + limits.leaseMs,
      updatedAt: FieldValue.serverTimestamp(),
    });
    return value;
  });
  if (!state) return { status: 'idle' };

  async function checkpoint(updates) {
    state = await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(stateRef);
      if (snapshot.get('reservation') !== reservation || snapshot.get('leaseUntil') <= Date.now()) {
        throw Object.assign(new Error('Reminder lease lost'), { code: 'reminders/lease-lost' });
      }
      const next = { ...snapshot.data(), ...updates };
      transaction.update(stateRef, { ...updates, updatedAt: FieldValue.serverTimestamp() });
      return next;
    });
  }

  let sendsThisRun = 0;
  try {
    const pageSize = Math.min(limits.divisionsPerRun, limits.divisionsPerDay - state.divisionsCharged);
    if (pageSize <= 0 || state.sendsCharged >= limits.sendsPerDay) {
      await checkpoint({ done: true, stoppedReason: 'daily-budget' });
      return { status: 'daily-budget' };
    }
    // Reserve requested slots even if the query is empty or this invocation crashes.
    await checkpoint({ divisionsCharged: state.divisionsCharged + pageSize });
    let query = db.collectionGroup('divisiones').where('pagado', '==', false)
      .orderBy(FieldPath.documentId()).limit(pageSize);
    if (state.cursor) query = query.startAfter(db.doc(state.cursor));
    const page = await query.get();
    if (page.empty) {
      await checkpoint({ done: true, cursor: null, attempts: 0, stoppedReason: 'scan-complete' });
      return { status: 'complete' };
    }

    for (const division of page.docs) {
      if (Date.now() - startedAt >= limits.workMs || sendsThisRun >= limits.sendsPerRun) break;
      if (state.sendsCharged >= limits.sendsPerDay) {
        await checkpoint({ done: true, stoppedReason: 'daily-budget' });
        break;
      }
      const attempts = state.attemptPath === division.ref.path ? state.attempts : 0;
      if (attempts >= limits.attemptsPerDivision) {
        console.warn('Reminder division abandoned after bounded retries', { path: division.ref.path, period });
        await checkpoint({ cursor: division.ref.path, attempts: 0, attemptPath: null });
        continue;
      }
      await checkpoint({ attempts: attempts + 1, attemptPath: division.ref.path });
      try {
        const path = division.ref.path.split('/');
        const memberId = division.get('memberId');
        const cents = division.get('cantidadCentimos');
        const valid = path.length === 6 && path[0] === 'groups' && path[2] === 'gastos' &&
          path[4] === 'divisiones' && division.get('groupId') === path[1] &&
          typeof memberId === 'string' && memberId.length > 0 && !memberId.includes('/') &&
          memberId !== division.get('pagadoPor') && Number.isSafeInteger(cents) && cents > 0;
        if (valid) {
          const member = await db.doc(`groups/${path[1]}/members/${memberId}`).get();
          const uid = member.get('reclamadoPor');
          if (typeof uid === 'string' && uid && !uid.includes('/')) {
            const membership = await db.collection('groupMembers').doc(`${path[1]}_${uid}`).get();
            if (membership.get('groupId') === path[1] && membership.get('deviceId') === uid) {
              await sendNotificationToUser({
                db, uid, period, maxDevices: MAX_REGISTERED_DEVICES,
                eventId: `debt-reminder:${period}:${uid}`,
                title: 'Recordatorio de deudas', body: 'Tienes deudas pendientes en la app.',
                messaging: { send: async (message) => {
                  if (sendsThisRun >= limits.sendsPerRun || state.sendsCharged >= limits.sendsPerDay) {
                    throw budgetError();
                  }
                  await checkpoint({ sendsCharged: state.sendsCharged + 1 });
                  sendsThisRun += 1;
                  return messaging.send(message);
                } },
              });
            }
          }
        }
        await checkpoint({ cursor: division.ref.path, attempts: 0, attemptPath: null });
      } catch (error) {
        if (error.code === 'reminders/lease-lost') throw error;
        console.error('Reminder division deferred', { path: division.ref.path, period, error });
        // Preserve the last completed cursor and bounded attempts for the next tick.
        break;
      }
    }
    return { status: 'progress', sends: sendsThisRun };
  } finally {
    await db.runTransaction(async (transaction) => {
      const snapshot = await transaction.get(stateRef);
      if (snapshot.get('reservation') !== reservation) return;
      transaction.update(stateRef, { leaseUntil: 0, reservation: null });
    });
  }
}

module.exports = { runDebtReminders, reminderClock, REMINDER_LIMITS };
