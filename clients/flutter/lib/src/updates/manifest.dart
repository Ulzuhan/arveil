import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;

/// Signed ahead of the payload; the Rust core holds the same constant, and
/// test/fixtures/update-manifest-vectors.json ties the two together.
const updateDomain = 'arveil-client-updates-v1\n';

/// Checks an Ed25519 signature by [publicKey] over [updateDomain] followed by
/// the exact payload bytes. The app passes the Rust core's check, so the
/// update path has one Ed25519 implementation; tests may pass their own.
typedef UpdateSignatureVerifier =
    FutureOr<bool> Function(
      List<int> payload,
      List<int> signature,
      List<int> publicKey,
    );
const maxManifestBytes = 65536;

/// Counted in Unicode code points, as the release signer counts them.
const maxNotes = 8000;
const maxPackageBytes = 512 * 1024 * 1024;

/// Deliberately carries a stable code, never an HTTP response, URL or path:
/// 'signature' for a bad signature, 'channel' for a feed of another channel,
/// 'format' for anything unreadable or out of range, and so on.
class UpdateFailure implements Exception {
  const UpdateFailure(this.code);
  final String code;
}

Uri updateUri(Object? value) {
  final uri = value is String ? Uri.tryParse(value) : null;
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasFragment) {
    throw const UpdateFailure('format');
  }
  return uri;
}

/// Distribution configuration, never a realm address or an enrollment token.
class UpdateConfig {
  UpdateConfig({
    required this.feed,
    required this.publicKey,
    required this.channel,
  }) {
    updateUri(feed.toString());
    if (feed.hasQuery ||
        publicKey.length != 32 ||
        !['stable', 'beta'].contains(channel)) {
      throw const UpdateFailure('configuration');
    }
  }
  final Uri feed;
  final List<int> publicKey;
  final String channel;

  static UpdateConfig? fromEnvironment() => parse(
    url: const String.fromEnvironment('ARVEIL_UPDATE_URL'),
    key: const String.fromEnvironment('ARVEIL_UPDATE_PUBLIC_KEY'),
    channel: const String.fromEnvironment(
      'ARVEIL_UPDATE_CHANNEL',
      defaultValue: 'beta',
    ),
  );

  static UpdateConfig? parse({
    required String url,
    required String key,
    required String channel,
  }) {
    if (url.isEmpty || key.isEmpty) return null;
    try {
      return UpdateConfig(
        feed: updateUri(url),
        publicKey: base64Decode(key),
        channel: channel,
      );
    } catch (_) {
      return null; // An unconfigured build never contacts a guessed server.
    }
  }

  /// For the diagnostic report: 'none' when the build carries no update
  /// configuration, the channel when it carries a usable one, and 'invalid'
  /// when it carries one the app refused, which otherwise looks like 'none'.
  static String status({
    String url = const String.fromEnvironment('ARVEIL_UPDATE_URL'),
    String key = const String.fromEnvironment('ARVEIL_UPDATE_PUBLIC_KEY'),
    String channel = const String.fromEnvironment(
      'ARVEIL_UPDATE_CHANNEL',
      defaultValue: 'beta',
    ),
  }) {
    if (url.isEmpty && key.isEmpty) return 'none';
    return parse(url: url, key: key, channel: channel)?.channel ?? 'invalid';
  }
}

class UpdateDevice {
  const UpdateDevice({
    required this.build,
    required this.sdk,
    required this.applicationId,
    required this.arm64,
  });
  final int build;
  final int sdk;
  final String applicationId;
  final bool arm64;
}

class AndroidUpdate {
  const AndroidUpdate({
    required this.build,
    required this.version,
    required this.minimumSdk,
    required this.applicationId,
    required this.url,
    required this.size,
    required this.sha256,
    required this.notes,
    required this.notesUrl,
  });
  final int build;
  final String version;
  final int minimumSdk;
  final String applicationId;
  final Uri url;
  final int size;
  final String sha256;
  final String notes;
  final Uri notesUrl;

  bool newerThan(UpdateDevice device) => build > device.build;
  bool compatibleWith(UpdateDevice device) =>
      device.arm64 &&
      device.sdk >= minimumSdk &&
      device.applicationId == applicationId;
}

class UpdateManifest {
  const UpdateManifest({
    required this.sequence,
    required this.expires,
    required this.digest,
    required this.android,
  });
  final int sequence;
  final DateTime expires;
  final String digest;
  final AndroidUpdate android;

  void checkFreshness(
    DateTime now, {
    required int lastSequence,
    required String? lastDigest,
  }) {
    if (!expires.isAfter(now.toUtc())) throw const UpdateFailure('expired');
    if (sequence < lastSequence ||
        (sequence == lastSequence && digest != lastDigest)) {
      throw const UpdateFailure('rollback');
    }
  }

  /// Sign exact payload bytes, with a protocol domain separator. No JSON
  /// canonicalization dependency between the publisher and the client.
  static Future<UpdateManifest> verify(
    List<int> wire,
    UpdateConfig config, {
    required UpdateSignatureVerifier verifier,
  }) async {
    try {
      if (wire.length > maxManifestBytes) throw const UpdateFailure('format');
      final envelope = jsonDecode(utf8.decode(wire)) as Map<String, dynamic>;
      if (envelope['schema'] != 1) throw const UpdateFailure('format');
      final payload = base64Decode(envelope['payload'] as String);
      final signature = base64Decode(envelope['signature'] as String);
      if (signature.length != 64 ||
          !await verifier(payload, signature, config.publicKey)) {
        throw const UpdateFailure('signature');
      }
      final data = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      if (data['schema'] != 1) throw const UpdateFailure('format');
      if (data['channel'] != config.channel) {
        throw const UpdateFailure('channel');
      }
      final sequence = _integer(data['sequence'], 1, 9007199254740991);
      final expires = DateTime.parse(data['expires'] as String);
      if (!expires.isUtc) throw const UpdateFailure('format');
      final android = (data['platforms'] as Map)['android-arm64'] as Map;
      final version = android['version'] as String;
      final digest = android['sha256'] as String;
      final applicationId = android['application_id'] as String;
      final notes = android['notes'] as String;
      if (!RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(digest) ||
          !RegExp(
            r'^[a-zA-Z][a-zA-Z0-9_]*(\.[a-zA-Z][a-zA-Z0-9_]*)+$',
          ).hasMatch(applicationId) ||
          notes.runes.length > maxNotes) {
        throw const UpdateFailure('format');
      }
      return UpdateManifest(
        sequence: sequence,
        expires: expires,
        digest: hashes.sha256.convert(payload).toString(),
        android: AndroidUpdate(
          build: _integer(android['build'], 1, 2100000000),
          version: version,
          minimumSdk: _integer(android['minimum_sdk'], 21, 1000),
          applicationId: applicationId,
          url: updateUri(android['url']),
          size: _integer(android['size'], 1, maxPackageBytes),
          sha256: digest,
          notes: notes,
          notesUrl: updateUri(android['notes_url']),
        ),
      );
    } on UpdateFailure {
      rethrow;
    } catch (_) {
      throw const UpdateFailure('format');
    }
  }
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const UpdateFailure('format');
  }
  return value;
}
