import 'dart:convert';

import 'package:arveil/src/attachment_files.dart';
import 'package:arveil/src/attachment_viewer.dart';
import 'package:arveil/src/rust/api/profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'attachments_test.dart' as fixtures;

final png = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNQaGj4DwAEBAIgeLZ75wAAAABJRU5ErkJggg==',
);

class ViewerFiles extends fixtures.Files {
  final List<Uint8List> opened = [];
  @override
  Future<bool> openExternal(String name, Uint8List bytes) async {
    opened.add(bytes);
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'image content is recognized without trusting a filename; pixels are bounded',
    () async {
      expect(isPreviewImage(png), isTrue);
      expect(isPreviewImage(Uint8List.fromList('<svg/>'.codeUnits)), isFalse);
      expect(previewDimensions(8000, 6000), (width: 2309, height: 1732));
      expect(() => previewDimensions(40000, 40000), throwsFormatException);
      final image = await decodeAttachmentImage(png);
      expect(image.width, 1);
      expect(image.height, 1);
      image.dispose();
      await expectLater(
        decodeAttachmentImage(
          Uint8List.fromList([137, 80, 78, 71, 13, 10, 26, 10]),
        ),
        throwsA(anything),
      );
    },
  );

  testWidgets(
    'opening verified bytes does not export; external sharing needs confirmation',
    (tester) async {
      final profile = fixtures.FileProfile()
        ..messages = [fixtures.attachment(AttachmentStateView.ready)];
      final files = ViewerFiles();
      await fixtures.open(tester, profile, files);
      await tester.tap(find.byKey(const Key('open-file-a')));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentViewer), findsOneWidget);
      expect(profile.exports, 1);
      expect(files.saved, isEmpty);
      expect(files.opened, isEmpty);
      await tester.tap(find.byKey(const Key('open-file-external')));
      await tester.pumpAndSettle();
      expect(files.opened, isEmpty);
      await tester.tap(find.text('Cancelar'));
      await tester.pumpAndSettle();
      expect(files.opened, isEmpty);
      await tester.tap(find.byKey(const Key('open-file-external')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('confirm-file-share')));
      await tester.pumpAndSettle();
      expect(files.opened.single, [1, 2, 3]);
      expect(files.saved, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'failed verification cannot open a viewer or leak the internal error',
    (tester) async {
      final profile = fixtures.FileProfile()
        ..messages = [fixtures.attachment(AttachmentStateView.ready)]
        ..failExport = true;
      final files = ViewerFiles();
      await fixtures.open(tester, profile, files);
      await tester.tap(find.byKey(const Key('open-file-a')));
      await tester.pumpAndSettle();
      expect(find.byType(AttachmentViewer), findsNothing);
      expect(find.textContaining('PRIVATE_'), findsNothing);
      expect(files.opened, isEmpty);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'external channel receives sanitized name and bounded bytes only',
    () async {
      const channel = MethodChannel(
        'io.github.ulzuhan.arveil/attachment_viewer',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      MethodCall? invoked;
      messenger.setMockMethodCallHandler(channel, (call) async {
        invoked = call;
        return true;
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      expect(
        await const AttachmentFiles().openExternal(
          '../a.pdf',
          Uint8List.fromList([1]),
        ),
        isTrue,
      );
      expect(invoked!.arguments, {
        'name': 'a.pdf',
        'bytes': [1],
      });
      await expectLater(
        const AttachmentFiles().openExternal(
          'big',
          Uint8List(maximumAttachmentBytes + 1),
        ),
        throwsFormatException,
      );
    },
  );
}
