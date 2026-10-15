int divisionAmountCents(Map<String, dynamic> division) {
  final cents = division['cantidadCentimos'];
  if (cents is num) return cents.round();
  return (((division['cantidad'] as num?) ?? 0) * 100).round();
}

class GroupBalances {
  final debts = <String, int>{};
  final net = <String, int>{};

  GroupBalances(Iterable<Map<String, dynamic>> divisions) {
    for (final division in divisions) {
      final debtor = division['memberId'] as String?;
      final creditor = division['pagadoPor'] as String?;
      if (division['pagado'] == true ||
          debtor == null ||
          creditor == null ||
          debtor == creditor) {
        continue;
      }
      final cents = divisionAmountCents(division);
      debts[debtor] = (debts[debtor] ?? 0) + cents;
      net[debtor] = (net[debtor] ?? 0) - cents;
      net[creditor] = (net[creditor] ?? 0) + cents;
    }
  }
}
