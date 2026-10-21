import 'package:intl/intl.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

bool _timeZonesInitialized = false;

DateTime parseCalendarDate(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
    throw FormatException('Expected YYYY-MM-DD', value);
  }
  final date = DateTime.parse('${value}T00:00:00Z');
  if (date.year < 1 || calendarDateString(date) != value) {
    throw FormatException('Invalid calendar date', value);
  }
  return date;
}

String calendarDateString(DateTime date) =>
    DateFormat('yyyy-MM-dd').format(date);

String formatCalendarDate(String value) =>
    DateFormat('dd/MM/yyyy').format(parseCalendarDate(value));

DateTime todayInTimeZone(String timeZone, {DateTime? now}) {
  if (!_timeZonesInitialized) {
    tzdata.initializeTimeZones();
    _timeZonesInitialized = true;
  }
  final location = tz.getLocation(timeZone);
  final date = now == null
      ? tz.TZDateTime.now(location)
      : tz.TZDateTime.from(now, location);
  // A UTC carrier preserves calendar components without device-zone conversion.
  return DateTime.utc(date.year, date.month, date.day);
}
