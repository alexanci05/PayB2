'use strict';

const { HttpsError } = require('firebase-functions/v1/https');
const { createHash } = require('node:crypto');
const { CALL_LIMITS, PROJECT_CREATION_LIMITS, OPERATION_DAILY_LIMITS } = require('./security-policy');

function nextUsage(current, operation, nowMillis, minuteLimit, dailyLimit, operationLimit) {
  const currentMinute = Math.floor(nowMillis / 60_000);
  const currentDay = new Date(nowMillis).toISOString().slice(0, 10);
  // A transaction retried across a boundary must not reopen an older window.
  const minute = Math.max(currentMinute, current.minute ?? currentMinute);
  const day = current.day > currentDay ? current.day : currentDay;
  const sameDay = current.day === day;
  const minuteCount = current.minute === minute ? current.minuteCount : 0;
  const dayCount = sameDay ? current.dayCount : 0;
  const operations = sameDay ? current.operations ?? {} : {};
  const operationCount = operations[operation] ?? 0;
  if (minuteCount >= minuteLimit || dayCount >= dailyLimit ||
      (operationLimit != null && operationCount >= operationLimit)) {
    throw new HttpsError('resource-exhausted', 'Se ha alcanzado el límite temporal de operaciones. Inténtalo más tarde.');
  }
  return {
    minute,
    minuteCount: minuteCount + 1,
    day,
    dayCount: dayCount + 1,
    operations: { ...operations, [operation]: operationCount + 1 },
  };
}

async function consumeCallableQuota(db, uid, operation, nowMillis = Date.now()) {
  const userId = createHash('sha256').update(uid).digest('hex');
  const userRef = db.collection('usageLimits').doc(`user_${userId}`);
  await db.runTransaction(async (transaction) => {
    const user = await transaction.get(userRef);
    const userUsage = nextUsage(
      user.data() ?? {}, operation, nowMillis,
      CALL_LIMITS.userPerMinute, CALL_LIMITS.userPerDay, OPERATION_DAILY_LIMITS[operation],
    );
    transaction.set(userRef, userUsage);
  });
}

async function reserveProjectCapacity(transaction, db, operation, nowMillis = Date.now()) {
  const projectRef = db.collection('usageLimits').doc('project');
  const project = await transaction.get(projectRef);
  const usage = nextUsage(
    project.data() ?? {}, operation, nowMillis,
    PROJECT_CREATION_LIMITS.perMinute, PROJECT_CREATION_LIMITS.perDay,
  );
  // Admission commits with the resource, not with malformed requests or replays.
  transaction.set(projectRef, usage);
}

module.exports = { consumeCallableQuota, reserveProjectCapacity, nextUsage };
