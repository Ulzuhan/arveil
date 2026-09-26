import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart';

import 'manifest.dart';

abstract interface class UpdateTransport {
  Future<List<int>> manifest(Uri url);
  Future<File> download(AndroidUpdate update, void Function(int) progress);
  void cancel();
}

/// Separate, short-lived HTTP clients: no cookies, auth, profile data, version
/// query parameters or persistent connection to the update service.
class HttpsUpdateTransport implements UpdateTransport {
  HttpsUpdateTransport(this.directory, {HttpClient Function()? client})
    : _client = client ?? HttpClient.new;
  final Future<Directory> Function() directory;
  final HttpClient Function() _client;
  HttpClient? _active;

  HttpClient _start() {
    final client = _client()
      ..userAgent = null
      ..autoUncompress = false
      ..connectionTimeout = const Duration(seconds: 20);
    _active = client;
    return client;
  }

  Future<HttpClientResponse> _get(
    HttpClient client,
    Uri url, {
    required bool redirects,
  }) async {
    for (var remaining = redirects ? 5 : 0; ; remaining--) {
      updateUri(url.toString());
      final request = await client
          .getUrl(url)
          .timeout(const Duration(seconds: 20));
      request.followRedirects = false;
      final response = await request.close().timeout(
        const Duration(seconds: 20),
      );
      if ([301, 302, 303, 307, 308].contains(response.statusCode) &&
          remaining > 0) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        if (location == null) throw const UpdateFailure('network');
        // GitHub redirects assets to its storage. Never forward any response
        // cookies or allow a redirect to HTTP, even for a signed package URL.
        final next = updateUri(url.resolve(location).toString());
        // Cancel this response instead of draining an unbounded redirect body.
        await response.listen((_) {}).cancel();
        url = next;
        continue;
      }
      if (response.statusCode != HttpStatus.ok ||
          response.headers.value(HttpHeaders.contentEncodingHeader) != null) {
        throw const UpdateFailure('network');
      }
      return response;
    }
  }

  @override
  Future<List<int>> manifest(Uri url) async {
    final client = _start();
    try {
      return await (() async {
        final response = await _get(client, url, redirects: false);
        if (response.contentLength > maxManifestBytes) {
          throw const UpdateFailure('manifest');
        }
        final bytes = <int>[];
        await for (final chunk in response.timeout(
          const Duration(seconds: 20),
        )) {
          if (bytes.length + chunk.length > maxManifestBytes) {
            throw const UpdateFailure('manifest');
          }
          bytes.addAll(chunk);
        }
        return bytes;
      })().timeout(const Duration(seconds: 45));
    } on UpdateFailure {
      rethrow;
    } catch (_) {
      throw const UpdateFailure('network');
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
    }
  }

  @override
  Future<File> download(
    AndroidUpdate update,
    void Function(int) progress,
  ) async {
    final client = _start();
    File? partial;
    File? complete;
    IOSink? output;
    var accepted = false;
    try {
      final destination = await directory();
      await destination.create(recursive: true);
      partial = File('${destination.path}/update.part');
      complete = File('${destination.path}/update.apk');
      if (await complete.exists()) await complete.delete();
      await (() async {
        final response = await _get(client, update.url, redirects: true);
        if (response.contentLength >= 0 &&
            response.contentLength != update.size) {
          throw const UpdateFailure('package');
        }
        output = partial!.openWrite();
        // Attach a handler immediately; disk-full errors may arrive before
        // the network stream finishes and flush/close are awaited below.
        unawaited(output!.done.catchError((Object _) {}));
        var received = 0;
        await for (final chunk in response.timeout(
          const Duration(seconds: 30),
        )) {
          received += chunk.length;
          if (received > update.size || received > maxPackageBytes) {
            throw const UpdateFailure('package');
          }
          output!.add(chunk);
          await output!.flush();
          progress(received);
        }
        await output!.close();
        output = null;
        if (received != update.size ||
            (await sha256.bind(partial.openRead()).first).toString() !=
                update.sha256) {
          throw const UpdateFailure('package');
        }
      })().timeout(
        const Duration(minutes: 10),
        onTimeout: () {
          client.close(force: true);
          throw const UpdateFailure('network');
        },
      );
      final file = await partial.rename(complete.path);
      accepted = true;
      return file;
    } on UpdateFailure {
      rethrow;
    } catch (_) {
      throw const UpdateFailure('network');
    } finally {
      client.close(force: true);
      if (identical(_active, client)) _active = null;
      try {
        await output?.close();
      } catch (_) {
        /* Still remove the partial. */
      }
      if (!accepted) {
        for (final file in [partial, complete]) {
          if (file != null && await file.exists()) await file.delete();
        }
      }
    }
  }

  @override
  void cancel() => _active?.close(force: true);
}
