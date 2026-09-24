import 'package:integration_test/integration_test_driver.dart';

// Keep results in the helper's private log, without a separate response artifact.
Future<void> main() => integrationDriver(responseDataCallback: null);
