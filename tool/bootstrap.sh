#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
if ! command -v flutter >/dev/null 2>&1; then
  echo 'Install Flutter 3.47.2 stable and the Android SDK, then run this script again.' >&2
  exit 1
fi
if [ ! -f android/gradle/wrapper/gradle-wrapper.jar ]; then
  flutter create --platforms=android --org com.aaris --project-name aaris_pharmacy .
fi
flutter pub get
dart analyze lib test tool third_party/lib_llama_cpp/lib
flutter test --reporter expanded
echo 'Local checks passed. CI additionally compiles Android; the release workflow builds APK artifacts.'
