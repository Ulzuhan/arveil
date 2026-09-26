import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';

import '../l10n/l10n.dart';
import 'profile_session.dart';
import 'rust/api/profile.dart';
import 'updates/manifest.dart';

/// Set by the packaging script; empty in a local build.
const appVersion = String.fromEnvironment('ARVEIL_VERSION');
const appRevision = String.fromEnvironment('ARVEIL_REVISION');

final _operation = RegExp(r'^[a-z0-9-]{1,40}$');

/// What kind of failure happened and during which operation: never its
/// message or reason, which may carry paths, addresses or remote text.
String failureCode(Object failure) {
  String op(String operation) =>
      _operation.hasMatch(operation) ? operation : 'unknown';
  return switch (failure) {
    CommandError_Busy(:final operation) => 'busy:${op(operation)}',
    CommandError_Panicked(:final operation) => 'panicked:${op(operation)}',
    CommandError_Transport(:final operation) => 'transport:${op(operation)}',
    CommandError_Storage(:final operation) => 'storage:${op(operation)}',
    CommandError_Protocol(:final operation) => 'protocol:${op(operation)}',
    CommandError_Quota(:final operation) => 'quota:${op(operation)}',
    CommandError_Domain(:final operation) => 'domain:${op(operation)}',
    CommandError_FileSystem(:final operation) => 'filesystem:${op(operation)}',
    CommandError_Internal(:final operation) => 'internal:${op(operation)}',
    CommandError_Interrupted() => 'interrupted',
    ProfileError_BadKey() => 'profile:bad-key',
    ProfileError_NoRandomness() => 'profile:no-randomness',
    ProfileError_AlreadyOpen() => 'profile:already-open',
    ProfileError_InUse() => 'profile:in-use',
    ProfileError_Closing() => 'profile:closing',
    ProfileError_TooNew() => 'profile:too-new',
    ProfileError_Unusable() => 'profile:unusable',
    ProfileError_Io() => 'profile:io',
    ProfileAccessException() => 'profile:access',
    FormatException() => 'format',
    _ => 'other',
  };
}

/// The codes of the latest failures, oldest first, kept only in memory.
abstract final class FailureLog {
  static const limit = 20;
  static final _codes = <String>[];

  static void record(Object failure) {
    _codes.add(failureCode(failure));
    if (_codes.length > limit) _codes.removeAt(0);
  }

  static List<String> get codes => List.unmodifiable(_codes);

  @visibleForTesting
  static void clear() => _codes.clear();
}

/// A report for whoever helps with a problem: versions, system, language,
/// the update channel, the profile's state in counts, and failure codes. No
/// keys, identifiers, routes, addresses, invitations, names or content.
Future<String> diagnosticReport(
  ProfileSession session, {
  String? language,
  String? system,
}) async {
  final setup = session.setup;
  final profile = session.profile;
  Future<String> count(Future<int> Function() read) async {
    try {
      return '${await read()}';
    } catch (_) {
      return 'unavailable';
    }
  }

  final conversations = profile == null
      ? 'none'
      : await count(() async => (await profile.conversations()).length);
  final devices = profile == null || setup?.stage != SetupStage.ready
      ? 'none'
      : await count(
          () async =>
              (await profile.devices()).devices.where((d) => !d.revoked).length,
        );
  final kit = setup == null || !setup.administrator
      ? 'not-exported-here'
      : setup.kitSavedAt == null
      ? 'missing'
      : setup.kitStale
      ? 'stale'
      : 'saved';
  final failures = FailureLog.codes;
  return [
    'Arveil diagnostic report',
    'version: ${appVersion.isEmpty ? 'local build' : appVersion}',
    'revision: ${appRevision.isEmpty ? 'none' : appRevision}',
    'system: ${system ?? '${Platform.operatingSystem} ${Platform.operatingSystemVersion}'}',
    'language: ${language ?? currentStrings.localeName}',
    // A build whose update settings were refused would otherwise look like
    // one without updates.
    'updates: ${UpdateConfig.status()}',
    'profile: ${profile == null ? 'closed' : 'open'}',
    'setup: ${setup?.stage.name ?? 'unknown'}',
    'role: ${setup == null
        ? 'unknown'
        : setup.administrator
        ? 'administrator'
        : 'linked'}',
    'conversations: $conversations',
    'active devices: $devices',
    'identity kit: $kit',
    'keys for new groups: ${session.keyPackages?.level.name ?? 'unknown'}',
    'recent failures: ${failures.isEmpty ? 'none' : failures.join(', ')}',
    '',
  ].join('\n');
}

/// Saves the report through the native dialog.
class DiagnosticFiles {
  const DiagnosticFiles();

  Future<bool> save(String report) async =>
      await FilePicker.saveFile(
        dialogTitle: currentStrings.diagnosticsSaveDialog,
        fileName: 'arveil-diagnostic.txt',
        bytes: Uint8List.fromList(utf8.encode(report)),
      ) !=
      null;
}
