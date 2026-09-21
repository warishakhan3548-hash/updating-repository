#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

kotlinc \
  "$ROOT/core/visual/src/main/kotlin/com/aaris/shield/visual/VisualSafetyContracts.kt" \
  "$ROOT/core/visual/src/main/kotlin/com/aaris/shield/visual/VisualSafetyPolicy.kt" \
  "$ROOT/core/visual/src/main/kotlin/com/aaris/shield/visual/AdaptiveInferenceLimiter.kt" \
  "$ROOT/tools/visual-smoke.kt" \
  -include-runtime \
  -d "$OUT/visual-smoke.jar"

java -jar "$OUT/visual-smoke.jar"

python3 - <<'PY' "$ROOT"
from pathlib import Path
import sys
import xml.etree.ElementTree as ET

root = Path(sys.argv[1])
ET.parse(root / "core/visual/src/main/AndroidManifest.xml")
build = (root / "core/visual/build.gradle.kts").read_text()
classifier = (root / "core/visual/src/main/kotlin/com/aaris/shield/visual/OpenNsfwLiteRtClassifier.kt").read_text()
assert "a1b49e0cf4d28c2f67bf60a87005a7c220cde487" in build
assert "9583ed20d47ded82738891744c7983b3fe1f2bd3" in build
assert 'litert:1.4.2' in build
assert "EXPECTED_GIT_BLOB_SHA1" in classifier
assert "DataType.INT8" in classifier and "DataType.UINT8" in classifier
assert "android.permission" not in (root / "core/visual/src/main/AndroidManifest.xml").read_text()
print("Aaris Shield visual static checks: PASS")
PY
