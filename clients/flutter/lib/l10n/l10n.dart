import 'package:flutter/widgets.dart';

import 'app_localizations.dart';

export 'app_localizations.dart';

/// `context.l10n.someText`: the strings of the language in use. Outside
/// the app's localizations (a component pumped on its own) it falls back
/// to [currentStrings].
extension L10nContext on BuildContext {
  AppLocalizations get l10n =>
      Localizations.of<AppLocalizations>(this, AppLocalizations) ??
      currentStrings;
}

/// Spanish unless the system prefers English: Spanish is the product's
/// language, and a phone set to another language spoken in Spain (Catalan,
/// Galician, Basque) is better served by it than by English.
Locale resolveLocale(List<Locale>? preferred, Iterable<Locale> supported) {
  for (final locale in preferred ?? const <Locale>[]) {
    if (locale.languageCode == 'en') return const Locale('en');
    if (locale.languageCode == 'es') return const Locale('es');
  }
  return const Locale('es');
}

AppLocalizations _current = lookupAppLocalizations(const Locale('es'));

/// Strings for code outside the widget tree: sessions, controllers and
/// native file dialogs. The app keeps it in step with the language in use;
/// it starts in Spanish.
AppLocalizations get currentStrings => _current;

void useStrings(AppLocalizations strings) => _current = strings;

String _two(int n) => n.toString().padLeft(2, '0');

/// Whether the system shows a 24-hour clock. Every platform reports it;
/// a Spanish system usually does, an English one in the United States
/// usually does not.
bool get uses24HourClock =>
    WidgetsBinding.instance.platformDispatcher.alwaysUse24HourFormat;

/// Hour and minute on the clock the system uses: "18:30", or "6:30 PM"
/// ("6:30 p. m." in Spanish) on a 12-hour clock.
String clockTime(DateTime at, {bool? use24}) {
  if (use24 ?? uses24HourClock) return '${_two(at.hour)}:${_two(at.minute)}';
  final hour = at.hour % 12 == 0 ? 12 : at.hour % 12;
  final s = currentStrings;
  return s.clockTime12(
    '$hour:${_two(at.minute)}',
    at.hour < 12 ? s.clockAm : s.clockPm,
  );
}

/// Time left as minutes and seconds ("9:59"), with hours in front past
/// an hour ("1:00:00"). Never negative.
String countdown(int seconds) {
  final s = seconds < 0 ? 0 : seconds;
  final hours = s ~/ 3600;
  final minutes = s % 3600 ~/ 60;
  final rest = _two(s % 60);
  return hours > 0 ? '$hours:${_two(minutes)}:$rest' : '$minutes:$rest';
}

/// A short date in the order the language writes it: "20/9/2026" in
/// Spanish, "Sep 20, 2026" in English, where digits alone would be read
/// in two orders.
String shortDate(AppLocalizations l10n, DateTime at) => l10n.shortDate(
  '${at.day}',
  l10n.shortDateMonths.split(' ')[at.month - 1],
  '${at.year}',
);
