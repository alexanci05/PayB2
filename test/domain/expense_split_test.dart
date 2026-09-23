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

    test('restores the anchor day after monthly February clamps', () {
      for (final year in [2024, 2025]) {
        final january = DateTime.utc(year, 1, 31, 12, 34, 56, 789, 123);
        final february = nextOccurrenceDate(
          january,
          'Mensual (mismo día todos los meses)',
          anchorDay: 31,
        );
        expect(
          february,
          DateTime.utc(year, 2, year == 2024 ? 29 : 28, 12, 34, 56, 789, 123),
        );
        expect(
          nextOccurrenceDate(
            february!,
            'Mensual (mismo día todos los meses)',
            anchorDay: 31,
          ),
          DateTime.utc(year, 3, 31, 12, 34, 56, 789, 123),
        );
      }
    });

    test('restores the anchor day after a quarterly clamp', () {
      final april = nextOccurrenceDate(
        DateTime(2025, 1, 31),
        'Trimestral (mismo día cada 3 meses)',
        anchorDay: 31,
      );
      expect(april, DateTime(2025, 4, 30));
      expect(
        nextOccurrenceDate(
          april!,
          'Trimestral (mismo día cada 3 meses)',
          anchorDay: 31,
        ),
        DateTime(2025, 7, 31),
      );
    });

    test('restores leap day for an anchored annual recurrence', () {
      var occurrence = DateTime.utc(2024, 2, 29);
      for (final year in [2025, 2026, 2027, 2028]) {
        occurrence = nextOccurrenceDate(
          occurrence,
          'Anual (mismo día cada año)',
          anchorDay: 29,
        )!;
        expect(occurrence, DateTime.utc(year, 2, year == 2028 ? 29 : 28));
      }
    });

    test('keeps fixed-day frequencies independent of the anchor day', () {
      final date = DateTime.utc(2025, 2, 28, 12);
      for (final days in [7, 15, 30, 365]) {
        expect(
          nextOccurrenceDate(date, 'Cada $days días', anchorDay: 31),
          date.add(Duration(days: days)),
        );
      }
    });

    test('rejects an invalid calendar anchor day', () {
      expect(
        () => nextOccurrenceDate(
          DateTime.utc(2025, 2, 28),
          'Mensual (mismo día todos los meses)',
          anchorDay: 0,
        ),
        throwsArgumentError,
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
