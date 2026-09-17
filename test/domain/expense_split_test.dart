import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/domain/expense_split.dart';

void main() {
  group('parseAmountCents', () {
    test('parses decimal input without floating point rounding', () {
      expect(parseAmountCents('12'), 1200);
      expect(parseAmountCents('12.3'), 1230);
      expect(parseAmountCents('12,30'), 1230);
      expect(parseAmountCents('000.01'), 1);
    });

    test('rejects amounts with more than two decimal places', () {
      expect(parseAmountCents('12.345'), isNull);
      expect(parseAmountCents('.50'), isNull);
      expect(parseAmountCents('12.'), isNull);
    });
  });

  group('splitExpenseCents', () {
    test('includes payer, sorts IDs, and assigns remainder cents first', () {
      final shares = splitExpenseCents(
        totalCents: 1000,
        payerId: 'zara',
        participantIds: ['maria', 'ana', 'maria'],
      );

      expect(shares.map((share) => share.memberId), ['ana', 'maria', 'zara']);
      expect(shares.map((share) => share.amountCents), [334, 333, 333]);
      expect(
        shares.fold<int>(0, (total, share) => total + share.amountCents),
        1000,
      );
    });

    test('requires a selected participant besides the payer', () {
      expect(
        () => splitExpenseCents(
          totalCents: 100,
          payerId: 'ana',
          participantIds: ['ana'],
        ),
        throwsArgumentError,
      );
    });

    test('requires at least one cent for every member', () {
      expect(
        () => splitExpenseCents(
          totalCents: 2,
          payerId: 'ana',
          participantIds: ['bea', 'carla'],
        ),
        throwsArgumentError,
      );
    });
  });

  group('recurrence', () {
    test('clamps month and year recurrences to the end of the month', () {
      expect(
        nextOccurrenceDate(
          DateTime(2025, 1, 31),
          'Mensual (mismo día todos los meses)',
        ),
        DateTime(2025, 2, 28),
      );
      expect(
        nextOccurrenceDate(
          DateTime(2024, 1, 31),
          'Mensual (mismo día todos los meses)',
        ),
        DateTime(2024, 2, 29),
      );
      expect(
        nextOccurrenceDate(DateTime(2024, 2, 29), 'Anual (mismo día cada año)'),
        DateTime(2025, 2, 28),
      );
    });

    test('uses a stable ID for a schedule timestamp', () {
      final date = DateTime.utc(2025, 1, 2, 3, 4, 5, 6, 7);

      expect(
        scheduledOccurrenceId('schedule-1', date),
        scheduledOccurrenceId('schedule-1', date.toLocal()),
      );
    });
  });
}
