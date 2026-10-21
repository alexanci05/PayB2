class ExpenseShare {
  const ExpenseShare({required this.memberId, required this.amountCents});

  final String memberId;
  final int amountCents;
}

int? parseAmountCents(String value) {
  final match = RegExp(r'^(\d+)(?:[\.,](\d{1,2}))?$').firstMatch(value.trim());
  if (match == null) {
    return null;
  }

  final whole = int.tryParse(match.group(1)!);
  if (whole == null) {
    return null;
  }

  final decimal = (match.group(2) ?? '').padRight(2, '0');
  final cents = decimal.isEmpty ? 0 : int.parse(decimal);
  return whole * 100 + cents;
}

List<ExpenseShare> splitExpenseCents({
  required int totalCents,
  required String payerId,
  required Iterable<String> participantIds,
}) {
  if (totalCents <= 0) {
    throw ArgumentError.value(totalCents, 'totalCents', 'Must be positive.');
  }
  if (payerId.isEmpty) {
    throw ArgumentError.value(payerId, 'payerId', 'Must not be empty.');
  }

  final participants = participantIds.where((id) => id != payerId).toSet();
  if (participants.isEmpty) {
    throw ArgumentError.value(
      participantIds,
      'participantIds',
      'At least one participant besides the payer is required.',
    );
  }

  final memberIds = <String>{payerId, ...participants}.toList()..sort();
  if (totalCents < memberIds.length) {
    throw ArgumentError.value(
      totalCents,
      'totalCents',
      'The amount must assign at least one cent to every member.',
    );
  }
  final baseShare = totalCents ~/ memberIds.length;
  final remainder = totalCents % memberIds.length;

  return List<ExpenseShare>.generate(
    memberIds.length,
    (index) => ExpenseShare(
      memberId: memberIds[index],
      amountCents: baseShare + (index < remainder ? 1 : 0),
    ),
    growable: false,
  );
}
