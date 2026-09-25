import 'package:arveil/src/export_secret.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('hidden result cannot be revealed in the background', () {
    final secret = ExportSecret();
    secret.saved('fixture', AppLifecycleState.paused);
    secret.reveal(AppLifecycleState.paused);
    expect(secret.visible, isNull);
    expect(secret.pending, isTrue);
    secret.lifecycle(AppLifecycleState.resumed);
    expect(secret.visible, isNull);
    secret.reveal(AppLifecycleState.resumed);
    expect(secret.visible, 'fixture');
    expect(secret.pending, isFalse);
  });

  test('another loss of focus discards an unrevealed result', () {
    final secret = ExportSecret();
    secret.saved('fixture', AppLifecycleState.paused);
    secret.lifecycle(AppLifecycleState.resumed);
    secret.lifecycle(AppLifecycleState.inactive);
    secret.lifecycle(AppLifecycleState.resumed);
    secret.reveal(AppLifecycleState.resumed);
    expect(secret.visible, isNull);
    expect(secret.pending, isFalse);
  });

  test('leaving the page or detaching discards the pending result', () {
    final secret = ExportSecret();
    secret.saved('fixture', AppLifecycleState.paused);
    secret.clear();
    expect(secret.pending, isFalse);
    secret.saved('fixture', AppLifecycleState.paused);
    secret.lifecycle(AppLifecycleState.detached);
    expect(secret.pending, isFalse);
  });
}
