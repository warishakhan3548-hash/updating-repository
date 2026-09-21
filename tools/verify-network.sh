#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$(mktemp -d)"
trap 'rm -rf "$OUT"' EXIT

kotlinc   "$ROOT/core/network/src/main/kotlin/com/aaris/shield/network/DomainPolicy.kt"   "$ROOT/core/network/src/main/kotlin/com/aaris/shield/network/DnsMessage.kt"   "$ROOT/core/network/src/main/kotlin/com/aaris/shield/network/Ipv4UdpPacket.kt"   "$ROOT/tools/network-smoke.kt"   -include-runtime   -d "$OUT/network-smoke.jar"

java -jar "$OUT/network-smoke.jar"

python3 - <<'PY' "$ROOT"
from pathlib import Path
import sys
import xml.etree.ElementTree as ET
root = Path(sys.argv[1])
for path in [
    root / "app/src/main/AndroidManifest.xml",
    root / "core/network/src/main/AndroidManifest.xml",
    root / "core/network/src/main/res/drawable/ic_shield_notification.xml",
]:
    ET.parse(path)

manifest = (root / "core/network/src/main/AndroidManifest.xml").read_text()
assert 'android.permission.BIND_VPN_SERVICE' in manifest
assert 'android:foregroundServiceType="systemExempted"' in manifest
assert 'android.net.VpnService.SUPPORTS_ALWAYS_ON' in manifest
assert 'android:value="false"' in manifest

rules = [
    line.strip() for line in (root / "core/network/src/main/assets/aaris_shield/adult_domains.txt").read_text().splitlines()
    if line.strip() and not line.lstrip().startswith('#')
]
assert len(rules) >= 10
print("Aaris Shield network static checks: PASS")
PY
