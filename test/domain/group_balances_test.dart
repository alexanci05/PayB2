import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/domain/group_balances.dart';

void main() {
  test('group debts and net use cents and exclude paid and self divisions', () {
    final balances = GroupBalances([
      {
        'memberId': 'a',
        'pagadoPor': 'b',
        'cantidadCentimos': 1001,
        'cantidad': 99,
      },
      {'memberId': 'b', 'pagadoPor': 'a', 'cantidad': 2.345},
      {'memberId': 'c', 'pagadoPor': 'a', 'cantidadCentimos': 100},
      {'memberId': 'a', 'pagadoPor': 'a', 'cantidadCentimos': 500},
      {
        'memberId': 'a',
        'pagadoPor': 'b',
        'cantidadCentimos': 900,
        'pagado': true,
      },
    ]);

    expect(balances.debts, {'a': 1001, 'b': 235, 'c': 100});
    expect(balances.net, {'a': -666, 'b': 766, 'c': -100});
    expect(balances.net.values.reduce((a, b) => a + b), 0);
    expect(GroupBalances([]).debts, isEmpty);
    expect(GroupBalances([]).net, isEmpty);
  });
}
