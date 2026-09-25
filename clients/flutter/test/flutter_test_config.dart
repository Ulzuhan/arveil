import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

/// The tests read the Spanish interface, the product's normative language.
/// Tests for English set their own locale.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized()
      .platformDispatcher
      .localesTestValue = const [
    Locale('es', 'ES'),
  ];
  await testMain();
}
