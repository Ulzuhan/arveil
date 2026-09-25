import 'package:arveil/src/design/design.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const _lucia = 'a41f09c27be1d530';
const _pablo = '3f9ac21b71c20e84';
const _group = '2ca6cb0173c1c756';

class _ConversationSheet extends StatelessWidget {
  const _ConversationSheet();

  @override
  Widget build(BuildContext context) {
    final c = ArveilColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const ConversationTile(
          identity: _group,
          title: 'Familia',
          preview: 'Lucía: ¿Quién trae el postre el domingo?',
          time: '18:42',
          unread: 3,
        ),
        const ConversationTile(
          identity: _lucia,
          title: 'Lucía',
          preview: 'Tú: Llego a las nueve',
          time: '17:55',
          verified: true,
          status: DeliveryStatus.pending,
          selected: true,
        ),
        const ConversationTile(
          identity: _pablo,
          title: 'Pablo',
          preview: 'Vale, mañana lo miramos',
          time: 'Ayer',
          unverified: true,
        ),
        const DateSeparator('Hoy'),
        ChatBubble(
          own: false,
          sender: 'Lucía',
          senderColor: c.senderFor(_lucia),
          position: BubblePosition.first,
          meta: const BubbleMeta(time: '18:40'),
          child: const Text('¿Quién trae el postre el domingo?'),
        ),
        const ChatBubble(
          own: true,
          meta: BubbleMeta(
            time: '18:42',
            own: true,
            status: DeliveryStatus.accepted,
          ),
          child: Text('Yo llevo tarta de queso.'),
        ),
        const ChatBubble(
          own: true,
          meta: BubbleMeta(
            time: '18:45',
            own: true,
            status: DeliveryStatus.pending,
          ),
          child: Text('¿A qué hora quedamos?'),
        ),
        const NoticeChip(
          text: 'Lucía ha añadido un dispositivo.',
          detail: 'El cambio está firmado por su identidad verificada.',
        ),
        const SizedBox(height: 8),
        const StatusBanner(
          icon: Icons.wifi_off,
          title: 'Sin conexión con tu servidor',
          body:
              'Puedes leer y escribir. Enviaremos lo pendiente al reconectar.',
        ),
        const SizedBox(height: 8),
        const SyncLine(
          text: 'Conectado · sincronizado hace 2 min',
          reached: true,
        ),
        const SizedBox(height: 8),
        Composer(
          controller: TextEditingController(),
          onSend: () {},
          onAttach: () {},
        ),
      ],
    );
  }
}

class _IdentitySheet extends StatelessWidget {
  const _IdentitySheet();

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Row(
        children: [
          BrandMark(size: 48),
          SizedBox(width: 12),
          ArveilAvatar(identity: _lucia, label: 'Lucía García'),
          SizedBox(width: 8),
          ArveilAvatar(identity: _pablo, label: 'Pablo'),
          SizedBox(width: 8),
          ArveilAvatar(identity: _group, label: '37809307'),
          SizedBox(width: 12),
          VerifiedMark(),
          SizedBox(width: 8),
          UnverifiedChip(),
        ],
      ),
      const SizedBox(height: 16),
      const SafetyNumberGrid(
        number: '38215 90472 11806 57339 64021 28895 70314 45568',
        caption: 'Número de seguridad · 8 grupos de 5 cifras',
      ),
      SettingsGroup(
        title: 'Seguridad y recuperación',
        children: [
          SettingsRow(
            icon: Icons.key_outlined,
            title: 'Kit de identidad',
            subtitle: 'No guardado · lo necesitas para recuperarte',
            attention: true,
            onTap: () {},
          ),
          SettingsRow(
            icon: Icons.devices_outlined,
            title: 'Dispositivos',
            subtitle: '3 vinculados',
            onTap: () {},
          ),
          SettingsRow(
            icon: Icons.contrast,
            title: 'Apariencia',
            value: 'Automática',
            onTap: () {},
          ),
        ],
      ),
      const SizedBox(height: 16),
      Row(
        children: [
          FilledButton(onPressed: () {}, child: const Text('Coinciden')),
          const SizedBox(width: 8),
          OutlinedButton(onPressed: () {}, child: const Text('Escanear')),
          const SizedBox(width: 8),
          TextButton(onPressed: () {}, child: const Text('Más tarde')),
        ],
      ),
      const SizedBox(height: 12),
      const TextField(decoration: InputDecoration(labelText: 'Invitación')),
      const SizedBox(
        height: 220,
        child: EmptyState(
          icon: Icons.forum_outlined,
          title: 'Todavía no hay conversaciones',
          body: 'Crea una con un contacto guardado.',
        ),
      ),
    ],
  );
}

void main() {
  setUpAll(() async {
    goldenFileComparator = TolerantComparator(
      Uri.parse('test/goldens/components_test.dart'),
    );
    await loadFonts();
  });

  for (final (mode, theme) in [
    ('light', ArveilTheme.light()),
    ('dark', ArveilTheme.dark()),
  ]) {
    for (final (name, sheet, height) in [
      ('conversation', const _ConversationSheet() as Widget, 760.0),
      ('identity', const _IdentitySheet() as Widget, 930.0),
    ]) {
      testWidgets('$name components, $mode', (tester) async {
        tester.view.physicalSize = Size(390, height);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: theme,
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: sheet,
              ),
            ),
          ),
        );
        await expectLater(
          find.byType(Scaffold),
          matchesGoldenFile('${name}_$mode.png'),
        );
      });
    }
  }
}
