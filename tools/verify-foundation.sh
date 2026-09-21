#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

kotlinc \
  "$ROOT/core/foundation/src/main/kotlin/com/aaris/shield/core/ShieldRuntimeRegistry.kt" \
  "$ROOT/tools/foundation-smoke.kt" \
  -include-runtime \
  -d "$OUT/foundation-smoke.jar"

java -jar "$OUT/foundation-smoke.jar"

python3 - <<'PY' "$ROOT"
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
root = Path(sys.argv[1])
for path in [
    root / "app/src/main/AndroidManifest.xml",
    root / "app/src/main/res/values/strings.xml",
    root / "core/foundation/src/main/AndroidManifest.xml",
]:
    ET.parse(path)
print("Android XML parse checks: PASS")
PY
