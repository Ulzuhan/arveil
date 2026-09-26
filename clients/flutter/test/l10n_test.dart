import 'dart:convert';
import 'dart:io';

import 'package:arveil/l10n/l10n.dart';
import 'package:arveil/main.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'widget_test.dart' show FakeProfile;

// English runs in its own file: [currentStrings] is process-wide, and the
// other tests read the Spanish interface.

Map<String, Object?> _arb(String language) =>
    jsonDecode(File('lib/l10n/app_$language.arb').readAsStringSync())
        as Map<String, Object?>;

Map<String, Set<String>> _messages(Map<String, Object?> arb) => {
  for (final MapEntry(:key, :value) in arb.entries)
    if (!key.startsWith('@'))
      key: {
        for (final m in RegExp(r'\{(\w+)[,}]').allMatches(value! as String))
          m.group(1)!,
      },
};

void main() {
  test('both languages carry every message with the same placeholders', () {
    final es = _messages(_arb('es'));
    final en = _messages(_arb('en'));
    expect(en.keys.toSet(), es.keys.toSet());
    for (final key in es.keys) {
      expect(en[key], es[key], reason: key);
    }
  });

  test('English only when the system prefers it; Spanish otherwise', () {
    const supported = AppLocalizations.supportedLocales;
    Locale pick(List<Locale>? preferred) => resolveLocale(preferred, supported);
    expect(pick(const [Locale('en', 'US')]), const Locale('en'));
    expect(pick(const [Locale('fr'), Locale('en', 'GB')]), const Locale('en'));
    expect(pick(const [Locale('es', 'MX')]), const Locale('es'));
    expect(pick(const [Locale('ca', 'ES')]), const Locale('es'));
    expect(pick(const [Locale('de')]), const Locale('es'));
    expect(pick(null), const Locale('es'));
  });

  testWidgets('an English system gets the whole interface in English', (
    tester,
  ) async {
    tester.platformDispatcher.localesTestValue = const [Locale('en', 'US')];
    addTearDown(tester.platformDispatcher.clearLocalesTestValue);
    tester.view.physicalSize = const Size(1200, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = ProfileSession(opener: () async => FakeProfile());
    addTearDown(session.dispose);
    await tester.pumpWidget(ArveilApp(session: session));
    expect(find.text('Open profile'), findsOneWidget);
    await tester.tap(find.text('Open profile'));
    await tester.pumpAndSettle();
    expect(find.text('Create identity and join'), findsOneWidget);
    await tester.tap(find.text('Create identity and join'));
    await tester.pumpAndSettle();
    expect(find.text('Paste the complete server details.'), findsOneWidget);

    // Code outside the widget tree follows the same language.
    expect(currentStrings.localeName, 'en');
    expect(
      syncStatusText(SyncState.never, null, DateTime(2026, 9, 25)),
      'Not synced yet',
    );
    expect(
      noticeText(null, const NoticeView(added: 2, removed: 1)),
      'A contact added 2 devices and removed a device.',
    );
    final at = DateTime(2026, 9, 25, 18, 4);
    expect(
      recordedTime(
        at.millisecondsSinceEpoch ~/ 1000,
        now: DateTime(2026, 9, 26, 9),
      ),
      '9/25/2026 18:04',
    );
  });
}
