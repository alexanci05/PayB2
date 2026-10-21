import 'package:flutter_test/flutter_test.dart';
import 'package:payb2/domain/expense_split.dart';
import 'package:payb2/domain/calendar_date.dart';
import 'package:timezone/timezone.dart' as tz;

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

  group('calendar dates', () {
    test('preserves and validates calendar components', () {
      expect(formatCalendarDate('2026-11-01'), '01/11/2026');
      expect(calendarDateString(parseCalendarDate('2024-02-29')), '2024-02-29');
      for (final value in [
        '0000-01-01',
        '2025-02-29',
        '2026-13-01',
        '2026-1-01',
        '2026-01-01T00:00:00Z',
      ]) {
        expect(() => parseCalendarDate(value), throwsFormatException);
      }
    });

    test('today uses the group zone across midnight and DST', () {
      final instant = DateTime.utc(2026, 3, 29, 1, 30);
      expect(
        calendarDateString(todayInTimeZone('Europe/Madrid', now: instant)),
        '2026-03-29',
      );
      expect(
        calendarDateString(
          todayInTimeZone('America/Los_Angeles', now: instant),
        ),
        '2026-03-28',
      );
      expect(
        () => todayInTimeZone('invalid/zone'),
        throwsA(isA<tz.LocationNotFoundException>()),
      );
    });
  });
}
