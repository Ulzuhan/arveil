import 'dart:async';
import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

/// The tests read the Spanish interface, the product's normative language,
/// on the 24-hour clock a system in Spain uses. Tests for English or a
/// 12-hour clock set their own.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized().platformDispatcher
    ..localesTestValue = const [Locale('es', 'ES')]
    ..alwaysUse24HourFormatTestValue = true;
  await testMain();
}
