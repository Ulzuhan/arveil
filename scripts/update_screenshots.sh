#!/usr/bin/env bash
# Regenerates the client's screen goldens from invented test data and copies
# the ones the documentation shows. Nothing real appears in them: names,
# messages and identifiers come from test/goldens/screens_test.dart.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/clients/flutter"
flutter test test/goldens/screens_test.dart --update-goldens
mkdir -p "$ROOT/docs/assets/screens"
for name in phone_start_light phone_chats_light phone_conversation_dark \
  phone_settings_light desktop_conversation_light desktop_conversation_dark; do
  cp "test/goldens/screens/$name.png" "$ROOT/docs/assets/screens/$name.png"
done
echo "Screenshots updated in docs/assets/screens."
