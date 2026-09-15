import 'dart:async';

import 'package:arveil/src/profile_keys.dart';
import 'package:arveil/src/rust/frb_generated.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class _Api extends ArveilRustApi {
  int generated = 0;

  @override
  Future<String> crateApiProfileGenerateProfileKey() async =>
      (++generated).toRadixString(16).padLeft(64, '0');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

// Hold the first write after a caller has read "no key" and generated one.
// A second ProfileKeys instance must wait until that write is durable.
class _Store implements FlutterSecureStorage {
  final writing = Completer<void>();
  final release = Completer<void>();
  String? value;
  int reads = 0;
  int writes = 0;
  bool failFirstWrite = false;

  Future<void> _write(String next) async {
    if (++writes == 1) {
      writing.complete();
      await release.future;
      if (failFirstWrite) throw PlatformException(code: 'unavailable');
    }
    value = next;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #read) {
      reads++;
      return Future<String?>.value(value);
    }
    if (invocation.memberName == #write) {
      return _write(invocation.namedArguments[#value] as String);
    }
    if (invocation.memberName == #delete) {
      value = null;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final api = _Api();
  setUpAll(() => ArveilRust.initMock(api: api));
  tearDownAll(ArveilRust.dispose);

  test(
    'concurrent first opens share the key across ProfileKeys instances',
    () async {
      final store = _Store();
      final before = api.generated;
      final first = ProfileKeys(
        storage: store,
      ).forProfile(profileExists: false);
      await store.writing.future;
      final second = ProfileKeys(
        storage: store,
      ).forProfile(profileExists: false);
      await Future<void>.delayed(Duration.zero);
      final readsWhileWriting = store.reads;
      store.release.complete();
      final results = await Future.wait([first, second]);
      expect(readsWhileWriting, 1);
      expect(api.generated - before, 1);
      expect(results[0].value, store.value);
      expect(results[1].value, store.value);
      expect(results[1].state, KeyState.present);
    },
  );

  test('a failed write releases queued attempts', () async {
    final store = _Store()..failFirstWrite = true;
    final first = ProfileKeys(storage: store).forProfile(profileExists: false);
    await store.writing.future;
    final second = ProfileKeys(storage: store).forProfile(profileExists: false);
    store.release.complete();
    expect((await first).state, KeyState.unavailable);
    final retried = await second;
    expect(retried.state, KeyState.fresh);
    expect(retried.value, store.value);
  });

  test('forget waits for an in-progress key creation', () async {
    final store = _Store();
    final first = ProfileKeys(storage: store).forProfile(profileExists: false);
    await store.writing.future;
    final forgotten = ProfileKeys(storage: store).forget();
    store.release.complete();
    await first;
    await forgotten;
    expect(store.value, isNull);
    final missing = await ProfileKeys(
      storage: store,
    ).forProfile(profileExists: true);
    expect(missing.state, KeyState.missing);
    expect(store.writes, 1);
  });
}
