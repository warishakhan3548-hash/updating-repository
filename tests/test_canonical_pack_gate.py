import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from tools.build_quran_core import build_pack
from tools.pack_gate import PackGateError, validate_manifest
from tools.quran_canonical import QuranCanonicalError, build_canonical, load_canonical
from tools.quran_core import load_production_source

ROOT = Path(__file__).resolve().parents[1]


class CanonicalPackGateTests(unittest.TestCase):
    def _copy_fixture_root(self, destination: Path) -> None:
        (destination / "schemas").mkdir(parents=True)
        shutil.copy2(
            ROOT / "schemas" / "content_v1.sql",
            destination / "schemas" / "content_v1.sql",
        )
        source, artifact, _ = load_production_source(ROOT)
        for field in ("vault_artifact", "licence_snapshot", "provenance"):
            rel = Path(source[field])
            target = destination / rel
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / rel if field != "vault_artifact" else artifact, target)
        registry = destination / "source-vault" / "registry.json"
        registry.parent.mkdir(parents=True, exist_ok=True)
        registry.write_text(
            json.dumps({"schema_version": 1, "sources": [source]}, indent=2) + "\n",
            encoding="utf-8",
        )

    def _build(self, root: Path):
        self._copy_fixture_root(root)
        canonical_artifact, canonical_manifest = build_canonical(root)
        _, pack_manifest = build_pack(
            root, Path("content-packs/quran-core/1.1.0")
        )
        registry = root / "source-vault" / "registry.json"
        return registry, pack_manifest, canonical_artifact, canonical_manifest

    def test_schema_v3_pack_with_canonical_binding_passes(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, _, _ = self._build(Path(tmp))
            validate_manifest(manifest, registry)

    def test_tampered_canonical_artifact_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            registry, manifest, canonical, _ = self._build(Path(tmp))
            canonical.write_text('{"tampered":true}\n', encoding="utf-8")
            with self.assertRaisesRegex(PackGateError, "canonical artifact"):
                validate_manifest(manifest, registry)

    def test_canonical_source_identity_cannot_drift(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, _, canonical_manifest = self._build(root)
            data = json.loads(canonical_manifest.read_text(encoding="utf-8"))
            data["source_version"] = "other"
            canonical_manifest.write_text(
                json.dumps(data, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            pack = json.loads(manifest.read_text(encoding="utf-8"))
            pack["canonical"]["manifest_sha256"] = hashlib.sha256(
                canonical_manifest.read_bytes()
            ).hexdigest()
            manifest.write_text(
                json.dumps(pack, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackGateError, "source_version"):
                validate_manifest(manifest, registry)

    def test_canonical_artifact_cannot_escape_its_manifest_directory(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            registry, manifest, canonical, _ = self._build(root)
            other = root / "canonical" / "other" / "1.0" / "ayahs.jsonl"
            other.parent.mkdir(parents=True)
            other.write_bytes(canonical.read_bytes())
            canonical.unlink()
            canonical.symlink_to(other)

            pack = json.loads(manifest.read_text(encoding="utf-8"))
            pack["canonical"]["artifact_sha256"] = hashlib.sha256(
                other.read_bytes()
            ).hexdigest()
            pack["canonical"]["artifact_byte_size"] = other.stat().st_size
            manifest.write_text(
                json.dumps(pack, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(PackGateError, "canonical artifact must resolve"):
                validate_manifest(manifest, registry)

    def test_rehashed_canonical_text_tamper_still_fails_source_fidelity(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            _, _, canonical, canonical_manifest = self._build(root)

            lines = canonical.read_text(encoding="utf-8").splitlines()
            first = json.loads(lines[0])
            first["original_text"] = first["original_text"] + " تَحْرِيف"
            lines[0] = json.dumps(
                first, ensure_ascii=False, sort_keys=True, separators=(",", ":")
            )
            canonical.write_text("\n".join(lines) + "\n", encoding="utf-8")

            data = json.loads(canonical_manifest.read_text(encoding="utf-8"))
            data["artifact_sha256"] = hashlib.sha256(canonical.read_bytes()).hexdigest()
            data["artifact_byte_size"] = canonical.stat().st_size
            canonical_manifest.write_text(
                json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
                encoding="utf-8",
            )

            with self.assertRaisesRegex(
                QuranCanonicalError,
                "canonical Quran text does not match preserved Source Vault artifact",
            ):
                load_canonical(root, canonical_manifest)


if __name__ == "__main__":
    unittest.main()
