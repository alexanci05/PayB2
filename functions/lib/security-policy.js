'use strict';

// The legacy App Engine identity is disabled. Production uses this dedicated
// Firestore/FCM identity, without the project-wide Editor role.
const RUNTIME_SERVICE_ACCOUNT = 'payb2-functions-runtime@payb2-5e89e.iam.gserviceaccount.com';

const CALLABLE_OPTIONS = Object.freeze({
  serviceAccount: RUNTIME_SERVICE_ACCOUNT,
  enforceAppCheck: true,
  minInstances: 0,
  maxInstances: 2,
  memory: '256MB',
  timeoutSeconds: 60,
});

const BACKGROUND_OPTIONS = Object.freeze({
  serviceAccount: RUNTIME_SERVICE_ACCOUNT,
  minInstances: 0,
  maxInstances: 1,
  memory: '256MB',
  timeoutSeconds: 120,
});

const MAX_REGISTERED_DEVICES = 3;
const MAX_OCCURRENCES_PER_RUN = 10;
const MAX_OCCURRENCES_PER_DAY = 100;
const MAX_OCCURRENCES_PER_GROUP_PER_DAY = 10;
const MAX_SCHEDULED_GROUPS_PER_RUN = 10;

const CALL_LIMITS = Object.freeze({
  userPerMinute: 30,
  userPerDay: 300,
});

const PROJECT_CREATION_LIMITS = Object.freeze({
  perMinute: 60,
  perDay: 1000,
});

const OPERATION_DAILY_LIMITS = Object.freeze({
  crearGrupo: 10,
  crearGasto: 100,
  prepararFusionCuenta: 10,
  registrarDispositivo: 100,
});

module.exports = {
  CALLABLE_OPTIONS,
  BACKGROUND_OPTIONS,
  MAX_REGISTERED_DEVICES,
  MAX_OCCURRENCES_PER_RUN,
  MAX_OCCURRENCES_PER_DAY,
  MAX_OCCURRENCES_PER_GROUP_PER_DAY,
  MAX_SCHEDULED_GROUPS_PER_RUN,
  CALL_LIMITS,
  PROJECT_CREATION_LIMITS,
  OPERATION_DAILY_LIMITS,
};
