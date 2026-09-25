import 'dart:async';
import 'package:arveil/src/attachment_card.dart';
import 'package:arveil/src/attachment_files.dart';
import 'package:arveil/src/conversation_controller.dart';
import 'package:arveil/src/conversations_page.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'conversations_test.dart' show ChatProfile;
import 'widget_test.dart' show relay;

HistoryEventView attachment(
  AttachmentStateView state, {
  bool outgoing = false,
  String id = 'file-a',
}) => HistoryEventView(
  cursor: 1,
  eventId: id,
  kind: outgoing ? 'file-outgoing' : 'file-pending',
  body: Uint8List.fromList('PRIVATE_INTERNAL_BODY'.codeUnits),
  delivery: const [],
  createdAt: 1790000000,
  own: outgoing,
  attachment: AttachmentView(
    name: 'same.txt',
    size: BigInt.from(3),
    outgoing: outgoing,
    state: state,
    transferred: BigInt.zero,
    total: BigInt.from(19),
  ),
);

class Files extends AttachmentFiles {
  PickedAttachment? picked = PickedAttachment(
    'same.txt',
    Uint8List.fromList([1, 2, 3]),
  );
  Completer<PickedAttachment?>? waiting;
  final List<Uint8List> saved = [];
  bool cancelSave = false;
  @override
  Future<PickedAttachment?> open() async =>
      waiting == null ? picked : await waiting!.future;
  @override
  Future<bool> save(String name, Uint8List bytes) async {
    if (cancelSave) return false;
    saved.add(bytes);
    return true;
  }
}

class FileProfile extends ChatProfile {
  int queues = 0, resumes = 0, exports = 0, cancels = 0;
  String? lastGroup, lastEvent;
  bool failTransfer = false, failExport = false;
  @override
  Future<String> queueAttachment({
    required String groupId,
    required String name,
    required List<int> bytes,
  }) async {
    queues++;
    messages = [attachment(AttachmentStateView.pending, outgoing: true)];
    return 'file-a';
  }

  @override
  Future<void> resumeAttachment({
    required String bootstrap,
    required String groupId,
    required String eventId,
  }) async {
    resumes++;
    lastGroup = groupId;
    lastEvent = eventId;
    if (failTransfer) throw Exception('PRIVATE_TRANSPORT_DETAIL');
  }

  @override
  Future<void> cancelAttachment({
    required String groupId,
    required String eventId,
  }) async {
    cancels++;
    lastGroup = groupId;
    lastEvent = eventId;
    messages = [attachment(AttachmentStateView.cancelled)];
  }

  @override
  Future<Uint8List> exportAttachment({
    required String groupId,
    required String eventId,
  }) async {
    exports++;
    if (failExport) throw Exception('PRIVATE_FILE_PATH');
    return Uint8List.fromList([1, 2, 3]);
  }
}

Future<ConversationController> open(
  WidgetTester tester,
  FileProfile profile,
  Files files,
) async {
  final chat = ConversationController(profile, relay);
  await tester.pumpWidget(
    MaterialApp(
      home: ConversationsPage(controller: chat, attachmentFiles: files),
    ),
  );
  await tester.pumpAndSettle();
  await chat.select('group-a');
  await tester.pumpAndSettle();
  return chat;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Android selection uses the bounded native channel and preserves cancellation',
    () async {
      const channel = MethodChannel('io.github.ulzuhan.arveil/attachments');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        messenger.setMockMethodCallHandler(channel, null);
      });
      Object? result;
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pick');
        expect(call.arguments, isNull);
        return result;
      });
      const files = AttachmentFiles();
      expect(await files.open(), isNull);
      result = {
        'name': '../same.txt',
        'bytes': Uint8List.fromList([1, 2, 3]),
      };
      final picked = (await files.open())!;
      expect(picked.name, 'same.txt');
      expect(picked.bytes, [1, 2, 3]);
      result = {
        'name': 'large.bin',
        'bytes': Uint8List(maximumAttachmentBytes + 1),
      };
      await expectLater(files.open(), throwsFormatException);
    },
  );

  test(
    'stream limit stops before reading more bytes and names lose paths',
    () async {
      var readMore = false;
      Stream<List<int>> source() async* {
        yield Uint8List(maximumAttachmentBytes);
        yield [1];
        readMore = true;
        yield [2];
      }

      await expectLater(readBoundedAttachment(source()), throwsFormatException);
      expect(readMore, isFalse);
      expect(safeAttachmentName(r'..\private\..same.txt'), 'same.txt');
    },
  );

  testWidgets('sending requires confirmation; retry resumes the saved event', (
    tester,
  ) async {
    final profile = FileProfile()..failTransfer = true;
    final files = Files();
    await open(tester, profile, files);
    await tester.tap(find.byKey(const Key('attach-file')));
    await tester.pumpAndSettle();
    expect(profile.queues, 0);
    await tester.tap(find.text('Cancelar'));
    await tester.pumpAndSettle();
    expect(profile.queues, 0);
    await tester.tap(find.byKey(const Key('attach-file')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('confirm-attachment')));
    await tester.pumpAndSettle();
    expect(profile.queues, 1);
    expect(profile.resumes, 1);
    expect(find.textContaining('PRIVATE_'), findsNothing);
    await tester.tap(find.byKey(const Key('resume-file-a')));
    await tester.pumpAndSettle();
    expect(profile.queues, 1);
    expect(profile.resumes, 2);
    expect(profile.lastEvent, 'file-a');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'export needs confirmation and native cancellation preserves the private copy',
    (tester) async {
      final profile = FileProfile()
        ..messages = [attachment(AttachmentStateView.ready)];
      final files = Files()..cancelSave = true;
      await open(tester, profile, files);
      await tester.tap(find.byKey(const Key('export-file-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(profile.exports, 0);
      await tester.tap(find.byKey(const Key('export-file-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-export')));
      await tester.pumpAndSettle();
      expect(profile.exports, 1);
      expect(files.saved, isEmpty);
      expect(
        profile.messages.single.attachment!.state,
        AttachmentStateView.ready,
      );
      files.cancelSave = false;
      await tester.tap(find.byKey(const Key('export-file-a')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-export')));
      await tester.pumpAndSettle();
      expect(files.saved.single, [1, 2, 3]);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('cancel targets the message and does not export bytes', (
    tester,
  ) async {
    final profile = FileProfile()
      ..messages = [attachment(AttachmentStateView.transferring)];
    await open(tester, profile, Files());
    await tester.tap(find.byKey(const Key('cancel-file-a')));
    await tester.pumpAndSettle();
    expect(profile.cancels, 1);
    expect(profile.lastGroup, 'group-a');
    expect(profile.lastEvent, 'file-a');
    expect(profile.exports, 0);
    expect(find.textContaining('Transferencia cancelada'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'a picker result cannot send into a different selected conversation',
    (tester) async {
      final profile = FileProfile();
      final files = Files()..waiting = Completer<PickedAttachment?>();
      final chat = await open(tester, profile, files);
      await tester.tap(find.byKey(const Key('attach-file')));
      await tester.pump();
      await chat.select('group-b');
      files.waiting!.complete(files.picked);
      await tester.pumpAndSettle();
      expect(profile.queues, 0);
      expect(find.byKey(const Key('confirm-attachment')), findsNothing);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'unavailable, expired and invalid files have honest actions on a phone',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      for (final state in [
        AttachmentStateView.expired,
        AttachmentStateView.invalid,
        AttachmentStateView.unavailable,
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: AttachmentCard(
                event: attachment(state),
                active: false,
                resume: () {},
                cancel: () {},
                export: () {},
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.textContaining('PRIVATE_'), findsNothing);
        expect(find.text('Guardar copia…'), findsNothing);
        expect(
          find.byKey(const Key('resume-file-a')),
          state == AttachmentStateView.unavailable
              ? findsOneWidget
              : findsNothing,
        );
        expect(tester.takeException(), isNull);
      }
    },
  );
}
