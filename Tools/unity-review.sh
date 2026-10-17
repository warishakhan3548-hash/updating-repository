#!/usr/bin/env bash
set -euo pipefail

# A manually invoked authoring task, never an APK/AAB build.
# Supply a licensed Unity 6000.3.26f1 editor with a graphics device for render mode.
repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
: "${UNITY_EDITOR:?Set UNITY_EDITOR to a licensed Unity 6000.3.26f1 executable}"
mkdir -p Review

case "${1:-compile}" in
  compile)
    "$UNITY_EDITOR" -batchmode -nographics -quit -projectPath "$repo_root" \
      -executeMethod Aaris.World.Editor.UnityWorldCompiler.Compile -logFile "$repo_root/Review/unity-compile.log"
    ;;
  render)
    # Linux cloud runner: invoke this script under xvfb-run with Mesa/GPU support.
    "$UNITY_EDITOR" -batchmode -quit -projectPath "$repo_root" \
      -executeMethod Aaris.World.Editor.WorldReview.Render -logFile "$repo_root/Review/unity-render.log"
    ;;
  test)
    # Unity Test Framework exits after finishing; -quit would interrupt its test run.
    "$UNITY_EDITOR" -batchmode -nographics -projectPath "$repo_root" -runTests -testPlatform EditMode \
      -testResults "$repo_root/Review/unity-tests.xml" -logFile "$repo_root/Review/unity-tests.log"
    ;;
  *) printf '%s\n' 'Usage: bash Tools/unity-review.sh [compile|render|test]' >&2; exit 2 ;;
esac
