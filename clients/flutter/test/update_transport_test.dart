import 'dart:async';
import 'dart:io';

import 'package:arveil/src/updates/manifest.dart';
import 'package:arveil/src/updates/transport.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class Response extends Stream<List<int>> implements HttpClientResponse {
  Response(
    this.body, {
    this.statusCode = 200,
    this.contentLength = -1,
    this.values = const {},
    this.stream,
  });
  final List<List<int>> body;

  /// Replaces [body] for a response that arrives over time.
  final Stream<List<int>>? stream;
  final Map<String, String> values;
  @override
  final int statusCode;
  @override
  final int contentLength;
  @override
  HttpHeaders get headers => Headers(values);
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => (stream ?? Stream.fromIterable(body)).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Headers implements HttpHeaders {
  Headers(this.values);
  final Map<String, String> values;
  @override
  String? value(String name) => values[name];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Request implements HttpClientRequest {
  Request(this.response);
  final Response response;
  @override
  final RequestHeaders headers = RequestHeaders();
  @override
  bool followRedirects = true;
  @override
  Future<HttpClientResponse> close() async => response;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class RequestHeaders implements HttpHeaders {
  // Reproduce Dart's default, which survives autoUncompress=false.
  final values = <String, String>{'accept-encoding': 'gzip'};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) {
    values[name.toLowerCase()] = value.toString();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class Client implements HttpClient {
  final responses = <Response>[];
  final urls = <Uri>[];
  final requests = <Request>[];
  bool closed = false;
  void Function()? onClose;
  @override
  String? userAgent = 'default';
  @override
  bool autoUncompress = true;
  @override
  Duration? connectionTimeout;
  @override
  Future<HttpClientRequest> getUrl(Uri url) async {
    urls.add(url);
    final request = Request(responses.removeAt(0));
    requests.add(request);
    return request;
  }

  @override
  void close({bool force = false}) {
    closed = true;
    onClose?.call();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory directory;
  late Client client;
  late HttpsUpdateTransport transport;
  const bytes = [1, 2, 3, 4, 5];
  AndroidUpdate update({int size = 5, String? digest}) => AndroidUpdate(
    build: 18,
    version: '0.1.0',
    minimumSdk: 24,
    applicationId: 'io.github.ulzuhan.arveil',
    url: Uri.parse(
      'https://github.com/example/arveil/releases/download/clients-v1/app.apk',
    ),
    size: size,
    sha256: digest ?? sha256.convert(bytes).toString(),
    notes: 'Notes',
    notesUrl: Uri.parse('https://example.org/notes'),
  );

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('arveil-download-test-');
    client = Client();
    transport = HttpsUpdateTransport(
      () async => directory,
      client: () => client,
      idle: const Duration(milliseconds: 200),
    );
  });
  tearDown(() => directory.delete(recursive: true));

  test(
    'feed is a plain fixed URL GET with no user agent or automatic redirects',
    () async {
      client.responses.add(
        Response(
          [
            [123, 125],
          ],
          values: {'set-cookie': 'tracker=1'},
        ),
      );
      final url = Uri.parse('https://updates.example.org/clients.json');
      expect(await transport.manifest(url), [123, 125]);
      expect(client.urls, [url]);
      expect(client.userAgent, null);
      expect(client.requests.single.followRedirects, false);
      expect(client.autoUncompress, false);
      expect(client.closed, true);
      expect(client.requests.single.headers.values, {
        'accept-encoding': 'identity',
      });
    },
  );

  test('an explicit identity encoding is accepted', () async {
    client.responses.add(
      Response(
        [
          [123, 125],
        ],
        values: {'content-encoding': 'Identity'},
      ),
    );
    expect(await transport.manifest(Uri.parse('https://example.org/feed')), [
      123,
      125,
    ]);
  });

  test(
    'manifest size cap applies to streamed bytes without Content-Length',
    () async {
      client.responses.add(Response([List.filled(maxManifestBytes + 1, 0)]));
      await expectLater(
        transport.manifest(Uri.parse('https://example.org/feed')),
        throwsA(isA<UpdateFailure>()),
      );
      expect(client.closed, true);
    },
  );

  test('feed redirects and compressed bodies are rejected', () async {
    for (final response in [
      Response(
        [],
        statusCode: 302,
        values: {'location': 'https://another.example.org/'},
      ),
      Response(
        [
          [1],
        ],
        values: {'content-encoding': 'gzip'},
      ),
    ]) {
      client.responses.add(response);
      await expectLater(
        transport.manifest(Uri.parse('https://example.org/feed')),
        throwsA(isA<UpdateFailure>()),
      );
    }
    expect(client.urls, hasLength(2));
  });

  test(
    'verified package follows HTTPS asset redirects without sending cookies',
    () async {
      client.responses.addAll([
        Response(
          [],
          statusCode: 302,
          values: {
            'location': 'https://release-assets.githubusercontent.com/asset',
            'set-cookie': 'tracker=1',
          },
        ),
        Response([
          [1, 2],
          [3, 4, 5],
        ], contentLength: 5),
      ]);
      final counts = <int>[];
      final file = await transport.download(update(), counts.add);
      expect(file.path, '${directory.path}/update.apk');
      expect(await file.readAsBytes(), bytes);
      expect(counts.last, 5);
      expect(client.urls, hasLength(2));
      expect(client.requests.every((r) => !r.followRedirects), true);
      for (final request in client.requests) {
        expect(request.headers.values, {'accept-encoding': 'identity'});
      }
      expect(File('${directory.path}/update.part').existsSync(), false);
    },
  );

  test(
    'hash mismatch, truncation, surplus and misleading length delete every artifact',
    () async {
      for (final response in [
        Response([
          [1, 2, 3, 4, 6],
        ]),
        Response([
          [1, 2],
        ]),
        Response([
          [1, 2, 3, 4, 5, 6],
        ]),
        Response([bytes], contentLength: 10),
      ]) {
        client.responses.add(response);
        await File('${directory.path}/update.apk').writeAsBytes(bytes);
        await expectLater(
          transport.download(update(), (_) {}),
          throwsA(isA<UpdateFailure>()),
        );
        expect(await directory.list().toList(), isEmpty);
      }
    },
  );

  test(
    'redirect to plaintext or with credentials fails before connecting there',
    () async {
      for (final url in [
        'http://example.org/app.apk',
        'https://user:password@example.org/app.apk',
      ]) {
        client.responses.add(
          Response([], statusCode: 302, values: {'location': url}),
        );
        await expectLater(
          transport.download(update(), (_) {}),
          throwsA(isA<UpdateFailure>()),
        );
      }
      expect(client.urls.every((u) => u.host == 'github.com'), true);
      expect(await directory.list().toList(), isEmpty);
    },
  );

  test('a refused or failed response is a network failure', () async {
    for (final status in [404, 500, 503]) {
      client.responses.add(Response([], statusCode: status));
      await expectLater(
        transport.manifest(Uri.parse('https://example.org/feed')),
        throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', 'network')),
      );
      client.responses.add(Response([bytes], statusCode: status));
      await expectLater(
        transport.download(update(), (_) {}),
        throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', 'network')),
      );
      expect(await directory.list().toList(), isEmpty);
    }
  });

  test('a feed announced above the size cap is not read', () async {
    var read = false;
    client.responses.add(
      Response(
        [],
        contentLength: maxManifestBytes + 1,
        // Only listening runs this, so it records whether the body was read.
        stream: Stream.multi((body) {
          read = true;
          body
            ..add([1])
            ..close();
        }),
      ),
    );
    await expectLater(
      transport.manifest(Uri.parse('https://example.org/feed')),
      throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', 'format')),
    );
    expect(read, false);
    expect(client.closed, true);
  });

  test('cancelling a download stops it and deletes the partial file', () async {
    final body = StreamController<List<int>>();
    client.onClose = () {
      if (!body.isClosed) {
        body.addError(const HttpException('Connection closed'));
        body.close();
      }
    };
    client.responses.add(Response([], contentLength: 5, stream: body.stream));
    final started = Completer<void>();
    final result = transport.download(update(), (_) {
      if (!started.isCompleted) started.complete();
    });
    body.add([1, 2]);
    await started.future;
    expect(File('${directory.path}/update.part').existsSync(), true);
    transport.cancel();
    await expectLater(result, throwsA(isA<UpdateFailure>()));
    expect(await directory.list().toList(), isEmpty);
  });

  test('a stalled download times out and deletes the partial file', () async {
    final body = StreamController<List<int>>();
    addTearDown(body.close);
    client.responses.add(Response([], contentLength: 5, stream: body.stream));
    final result = transport.download(update(), (_) {});
    body.add([1, 2]);
    await expectLater(
      result,
      throwsA(isA<UpdateFailure>().having((e) => e.code, 'code', 'network')),
    );
    expect(await directory.list().toList(), isEmpty);
    expect(client.closed, true);
  });

  test('the whole-download limit grows with the package', () {
    expect(HttpsUpdateTransport.limit(1), const Duration(minutes: 10));
    expect(
      HttpsUpdateTransport.limit(40 * 1024 * 1024),
      const Duration(seconds: 600 + 2560),
    );
    expect(
      HttpsUpdateTransport.limit(maxPackageBytes),
      greaterThan(const Duration(hours: 9)),
    );
  });

  test('a package left from an earlier run is discarded', () async {
    await File('${directory.path}/update.apk').writeAsBytes(bytes);
    await File('${directory.path}/update.part').writeAsBytes(bytes);
    await transport.discard();
    expect(await directory.list().toList(), isEmpty);
    await transport.discard();
  });

  test('redirect loops are bounded', () async {
    client.responses.addAll(
      List.generate(
        6,
        (_) => Response(
          [],
          statusCode: 302,
          values: {'location': 'https://example.org/loop'},
        ),
      ),
    );
    await expectLater(
      transport.download(update(), (_) {}),
      throwsA(isA<UpdateFailure>()),
    );
    expect(client.urls, hasLength(6));
    expect(client.closed, true);
  });
}
