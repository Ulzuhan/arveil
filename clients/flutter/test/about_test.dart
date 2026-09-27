import 'package:arveil/l10n/l10n.dart';
import 'package:arveil/main.dart';
import 'package:arveil/src/about_page.dart';
import 'package:arveil/src/profile_session.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'navigation_test.dart' show desktop, openHome, phone;
import 'widget_test.dart' show FakeProfile, openSettings;

const updates = MethodChannel('io.github.ulzuhan.arveil/updates');

Future<List<Uri>> about(
  WidgetTester tester, {
  Locale locale = const Locale('es'),
  String version = '0.1.0-beta.4+22',
}) async {
  final opened = <Uri>[];
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: AboutArveilPage(
        version: version,
        open: (url) async => opened.add(url),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return opened;
}

Future<void> tapRow(WidgetTester tester, String key) async {
  final row = find.byKey(Key(key));
  await tester.scrollUntilVisible(row, 100);
  await tester.tap(row);
  await tester.pumpAndSettle();
}

void main() {
  test('the version reads as its name and build', () {
    expect(displayVersion('0.1.0-beta.3+21'), '0.1.0-beta.3 (21)');
    expect(displayVersion('0.1.0'), '0.1.0');
    expect(displayVersion(''), isNull);
  });

  testWidgets('about names the maker and opens its pages in Spanish', (
    tester,
  ) async {
    final opened = await about(tester);
    expect(find.text('Versión 0.1.0-beta.4 (22)'), findsOneWidget);
    expect(find.text('Hecho por KaiCorp Labs'), findsOneWidget);
    for (final key in [
      'about-kaicorp',
      'about-website',
      'about-privacy',
      'about-source',
    ]) {
      await tapRow(tester, key);
    }
    expect(opened.map((url) => '$url'), [
      'https://kaicorplabs.com/',
      'https://arveil.kaicorplabs.com/es/',
      'https://arveil.kaicorplabs.com/es/privacidad/',
      'https://github.com/Ulzuhan/arveil',
    ]);
  });

  testWidgets('an English reader gets the English privacy policy', (
    tester,
  ) async {
    final opened = await about(tester, locale: const Locale('en'));
    expect(find.text('Privacy policy'), findsOneWidget);
    await tapRow(tester, 'about-privacy');
    expect(opened.single, Uri.parse('https://arveil.kaicorplabs.com/privacy/'));
  });

  testWidgets('about meets the tap target and label guidelines', (
    tester,
  ) async {
    final handle = tester.ensureSemantics();
    await about(tester);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    await expectLater(tester, meetsGuideline(textContrastGuideline));
    handle.dispose();
  });

  testWidgets('a local build says so instead of a version', (tester) async {
    await about(tester, version: '');
    expect(find.text('Compilación local'), findsOneWidget);
  });

  testWidgets('the licences list the notices the app ships', (tester) async {
    await about(tester);
    await tapRow(tester, 'about-licenses');
    expect(find.byType(LicensePage), findsOneWidget);
    expect(find.text('© 2026 KaiCorp Labs · Licencia Apache 2.0'), findsOne);
  });

  testWidgets('links open through the native handler the app registers', (
    tester,
  ) async {
    final calls = <MethodCall>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(updates, (
      call,
    ) async {
      calls.add(call);
      return null;
    });
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        updates,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const AboutArveilPage(),
      ),
    );
    await tapRow(tester, 'about-privacy');
    expect(calls.single.method, 'open');
    expect(calls.single.arguments, {
      'url': 'https://arveil.kaicorplabs.com/es/privacidad/',
    });
  });

  testWidgets('without a browser the link is copied instead', (tester) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: AboutArveilPage(
          open: (url) async => throw PlatformException(code: 'browser'),
        ),
      ),
    );
    await tapRow(tester, 'about-privacy');
    expect(copied, ['https://arveil.kaicorplabs.com/es/privacidad/']);
    expect(
      find.text('No se pudo abrir el navegador: se ha copiado el enlace'),
      findsOneWidget,
    );
  });

  testWidgets('settings open about, with the privacy policy in it', (
    tester,
  ) async {
    await openHome(tester, desktop);
    await openSettings(tester);
    await tester.ensureVisible(find.byKey(const Key('open-about')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('open-about')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Acerca de Arveil'), findsOneWidget);
    expect(find.byKey(const Key('about-privacy')), findsOneWidget);
  });

  testWidgets('about is there before any identity exists', (tester) async {
    tester.view.physicalSize = phone;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final session = ProfileSession(opener: () async => FakeProfile());
    addTearDown(session.dispose);
    await tester.pumpWidget(ArveilApp(session: session));
    await tester.tap(find.byKey(const Key('welcome-about')));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(AppBar, 'Acerca de Arveil'), findsOneWidget);
    expect(find.text('Política de privacidad'), findsOneWidget);
  });
}
