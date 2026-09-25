import 'package:arveil/l10n/l10n.dart';
import 'package:arveil/src/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child, {double textScale = 1}) => MaterialApp(
  theme: ArveilTheme.light(),
  home: MediaQuery(
    data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
    child: Scaffold(body: SingleChildScrollView(child: child)),
  ),
);

void main() {
  test('delivery says what the relay accepted, never that anyone read', () {
    expect(deliveryStatus([]), DeliveryStatus.none);
    expect(deliveryStatus(['sealed']), DeliveryStatus.pending);
    expect(
      deliveryStatus(['accepted', 'accepted (relay keeps it until 9)']),
      DeliveryStatus.accepted,
    );
    expect(deliveryStatus(['accepted', 'sealed']), DeliveryStatus.pending);
    expect(
      deliveryStatus(['accepted', 'undeliverable (mailbox refused)']),
      DeliveryStatus.rejected,
    );
    expect(deliveryStatus(['expired/unknown']), DeliveryStatus.expired);
    for (final status in DeliveryStatus.values) {
      expect(
        DeliveryIcon.label(currentStrings, status),
        isNot(contains('leído')),
      );
    }
  });

  test('initials come from names, never from short identifiers', () {
    expect(ArveilAvatar.initials('Lucía García'), 'LG');
    expect(ArveilAvatar.initials('mamá'), 'M');
    expect(ArveilAvatar.initials('  Ana  María  López '), 'AM');
    expect(ArveilAvatar.initials('37809307'), isNull);
    expect(ArveilAvatar.initials(''), isNull);
    expect(ArveilAvatar.initials(null), isNull);
  });

  testWidgets('screen readers hear counts, states and numbers in words', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(
        const Column(
          children: [
            UnreadBadge(count: 3),
            DeliveryIcon(status: DeliveryStatus.pending),
            SafetyNumberGrid(number: '38215 90472 11806 57339'),
            ArveilAvatar(identity: 'x', label: 'Lucía'),
          ],
        ),
      ),
    );
    expect(find.bySemanticsLabel('3 mensajes sin leer'), findsOneWidget);
    expect(find.bySemanticsLabel('Pendiente de envío'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Número de seguridad: 38215, 90472, 11806, 57339'),
      findsOneWidget,
    );
    // The avatar is decoration: its initials are not announced.
    expect(find.bySemanticsLabel('L'), findsNothing);
    semantics.dispose();
  });

  testWidgets('components fit a phone at twice the text size', (tester) async {
    tester.view.physicalSize = const Size(390, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        Column(
          children: [
            const ConversationTile(
              identity: 'a',
              title: 'Familia de Lucía y Pablo',
              preview: 'Lucía: ¿Quién trae el postre el domingo por la tarde?',
              time: '18:42',
              unread: 120,
              verified: true,
              status: DeliveryStatus.pending,
            ),
            const ChatBubble(
              own: false,
              sender: 'Lucía García',
              meta: BubbleMeta(time: '18:40'),
              child: Text('¿Quién trae el postre el domingo?'),
            ),
            SettingsRow(
              icon: Icons.key_outlined,
              title: 'Kit de identidad',
              subtitle: 'No guardado · lo necesitas para recuperarte',
              attention: true,
              onTap: () {},
            ),
            Composer(
              controller: TextEditingController(),
              onSend: () {},
              onAttach: () {},
            ),
          ],
        ),
        textScale: 2,
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
