import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]


class AndroidReleaseTrustTests(unittest.TestCase):
    def test_release_build_delegates_to_authoritative_pack_gate(self):
        text = (ROOT / "app" / "build.gradle.kts").read_text(encoding="utf-8")

        self.assertIn('rootProject.file("tools/pack_gate.py")', text)
        self.assertIn('rootProject.file("policy/trusted_pack_keys.json")', text)
        self.assertIn('tasks.matching { it.name == "preReleaseBuild" }', text)
        self.assertNotIn(
            'listOf("algorithm", "key_id", "value")',
            text,
        )
        self.assertNotIn("releaseSignatureReady", text)


if __name__ == "__main__":
    unittest.main()
