'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const { debtNotificationForTransition } = require('../lib/debt-notifications');

test('a paid debt notifies the creditor', () => {
  const notification = debtNotificationForTransition(
    { pagado: false },
    {
      pagado: true,
      memberId: 'debtor',
      pagadoPor: 'creditor',
      pagoRegistradoPor: 'debtor',
    },
  );

  assert.equal(notification.targetMemberId, 'creditor');
});

test('a debt closed by the creditor does not notify the creditor', () => {
  const notification = debtNotificationForTransition(
    { pagado: false },
    {
      pagado: true,
      memberId: 'debtor',
      pagadoPor: 'creditor',
      pagoRegistradoPor: 'creditor',
    },
  );

  assert.equal(notification, null);
});

test('a reopened debt notifies the debtor', () => {
  const notification = debtNotificationForTransition(
    { pagado: true },
    { pagado: false, memberId: 'debtor', pagadoPor: 'creditor' },
  );

  assert.equal(notification.targetMemberId, 'debtor');
});

test('unrelated updates do not send debt notifications', () => {
  assert.equal(
    debtNotificationForTransition(
      { pagado: false },
      { pagado: false, memberId: 'debtor', pagadoPor: 'creditor' },
    ),
    null,
  );
});
