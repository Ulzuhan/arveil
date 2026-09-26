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

/// Hour and minute on a 24-hour clock.
String clockTime(DateTime at) => '${_two(at.hour)}:${_two(at.minute)}';

/// A date in digits, in the order the language writes it.
String numericDate(AppLocalizations l10n, DateTime at) =>
    l10n.numericDate('${at.day}', '${at.month}', '${at.year}');
