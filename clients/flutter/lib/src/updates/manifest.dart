import 'dart:convert';

import 'package:crypto/crypto.dart' as hashes;
import 'package:cryptography/cryptography.dart';

const updateDomain = 'arveil-client-updates-v1\n';
const maxManifestBytes = 65536;
const maxPackageBytes = 512 * 1024 * 1024;

/// Deliberately carries a stable code, never an HTTP response, URL or path.
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
    throw const UpdateFailure('manifest');
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

  static UpdateConfig? fromEnvironment() {
    const url = String.fromEnvironment('ARVEIL_UPDATE_URL');
    const key = String.fromEnvironment('ARVEIL_UPDATE_PUBLIC_KEY');
    const channel = String.fromEnvironment(
      'ARVEIL_UPDATE_CHANNEL',
      defaultValue: 'beta',
    );
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
    UpdateConfig config,
  ) async {
    try {
      if (wire.length > maxManifestBytes) throw const UpdateFailure('manifest');
      final envelope = jsonDecode(utf8.decode(wire)) as Map<String, dynamic>;
      if (envelope['schema'] != 1) throw const UpdateFailure('manifest');
      final payload = base64Decode(envelope['payload'] as String);
      final signature = base64Decode(envelope['signature'] as String);
      if (signature.length != 64 ||
          !await Ed25519().verify(
            [...utf8.encode(updateDomain), ...payload],
            signature: Signature(
              signature,
              publicKey: SimplePublicKey(
                config.publicKey,
                type: KeyPairType.ed25519,
              ),
            ),
          )) {
        throw const UpdateFailure('signature');
      }
      final data = jsonDecode(utf8.decode(payload)) as Map<String, dynamic>;
      if (data['schema'] != 1 || data['channel'] != config.channel) {
        throw const UpdateFailure('manifest');
      }
      final sequence = _integer(data['sequence'], 1, 9007199254740991);
      final expires = DateTime.parse(data['expires'] as String);
      if (!expires.isUtc) throw const UpdateFailure('manifest');
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
          notes.length > 8000) {
        throw const UpdateFailure('manifest');
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
      throw const UpdateFailure('manifest');
    }
  }
}

int _integer(Object? value, int minimum, int maximum) {
  if (value is! int || value < minimum || value > maximum) {
    throw const UpdateFailure('manifest');
  }
  return value;
}
