// The technical screen before anything is opened. Pressing its buttons
// needs the Rust library, so that flow lives in the integration test that
// runs on a device; this one only checks what the screen says at rest.
import 'package:arveil/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('the screen starts with no profile open', (tester) async {
    await tester.pumpWidget(const ArveilApp());

    expect(find.byKey(const Key('status')), findsOneWidget);
    expect(find.text('no profile open'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Open'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Conversations'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, 'Close'), findsOneWidget);
  });
}
