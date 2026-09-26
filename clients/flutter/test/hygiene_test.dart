import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Screens take colours from the design system and words from the ARB
/// files: outside `design/` and `l10n/` neither is written by hand.
Iterable<(String, int, String)> screenLines() sync* {
  for (final file in Directory('lib').listSync(recursive: true)) {
    final path = file.path;
    if (file is! File ||
        !path.endsWith('.dart') ||
        path.contains('/l10n/') ||
        path.contains('/design/') ||
        path.contains('/rust/')) {
      continue;
    }
    for (final (i, line) in file.readAsLinesSync().indexed) {
      if (line.trimLeft().startsWith('//')) continue;
      yield (path, i + 1, line);
    }
  }
}

void main() {
  test('screens use no colour literals', () {
    final colour = RegExp(r'Color\(0x|Color\.fromARGB|Colors\.(?!transparent)');
    final found = [
      for (final (path, n, line) in screenLines())
        if (colour.hasMatch(line.replaceAll('ArveilColors', ''))) '$path:$n',
    ];
    expect(found, isEmpty);
  });

  test('screens write no visible text by hand', () {
    final literal = RegExp(
      r"(Text\(|tooltip:|labelText:|hintText:|helperText:|title:|label:|"
      r"semanticsLabel:|semanticLabel:|message:)\s*(const\s+)?(Text\()?\s*"
      r"'([^']*)'",
    );
    // Formats a person pastes, not language.
    const allowed = {'arveil-bootstrap:v0:…'};
    final found = [
      for (final (path, n, line) in screenLines())
        for (final match in literal.allMatches(line))
          if (RegExp(r'[A-Za-zÁÉÍÓÚáéíóúñÑ]{2}').hasMatch(match.group(4)!) &&
              !allowed.contains(match.group(4)))
            '$path:$n ${match.group(4)}',
    ];
    expect(found, isEmpty);
  });

  test('the documentation shows the current screens', () {
    final docs = Directory('../../docs/assets/screens');
    final shots = docs.listSync().whereType<File>().toList();
    expect(shots, isNotEmpty);
    for (final shot in shots) {
      final name = shot.uri.pathSegments.last;
      final golden = File('test/goldens/screens/$name');
      expect(
        shot.readAsBytesSync(),
        golden.readAsBytesSync(),
        reason: '$name differs; run scripts/update_screenshots.sh',
      );
    }
  });
}
