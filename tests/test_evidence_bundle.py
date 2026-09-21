import copy
from pathlib import Path
import tempfile
import unittest

from tools.evidence_bundle import (
    EvidenceBundleError,
    build_quran_evidence_bundle,
    canonical_evidence_bytes,
    evidence_bundle_sha256,
    render_evidence_text,
    verify_back,
    write_evidence_bundle,
)


ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / "content-packs" / "quran-core" / "1.1.0" / "manifest.json"
REGISTRY = ROOT / "source-vault" / "registry.json"


class EvidenceBundleTests(unittest.TestCase):
    def _bundle(self, citations=None, question=None):
        return build_quran_evidence_bundle(
            MANIFEST,
            REGISTRY,
            citations or ["qa:001:001", "qa:002:255"],
            research_question=question,
            allow_candidate_for_development=True,
        )

    def test_production_export_rejects_current_unsigned_candidate(self):
        with self.assertRaisesRegex(
            EvidenceBundleError,
            "requires an approved content pack",
        ):
            build_quran_evidence_bundle(
                MANIFEST,
                REGISTRY,
                ["qa:001:001"],
            )

    def test_export_contains_only_source_faithful_quran_records(self):
        bundle = self._bundle()

        self.assertEqual("aaris-evidence-bundle-v1", bundle["format"])
        self.assertEqual(2, bundle["scope"]["record_count"])
        self.assertEqual(
            ["qa:001:001", "qa:002:255"],
            [record["citation_id"] for record in bundle["records"]],
        )
        self.assertIn("Tanzil Project", bundle["pack"]["source_attribution"])
        self.assertIn("tanzil.net", bundle["pack"]["source_url"])
        self.assertIn(
            "PLEASE DO NOT REMOVE OR CHANGE THIS COPYRIGHT BLOCK",
            bundle["source_notice"]["text"],
        )
        self.assertEqual(64, len(bundle["source_notice"]["sha256"]))
        for record in bundle["records"]:
            self.assertEqual("quran_ayah", record["kind"])
            self.assertTrue(record["original_arabic"])
            self.assertEqual(64, len(record["source_text_sha256"]))
            self.assertNotIn("search_unicode", record)
            self.assertNotIn("search_diacritic_free", record)
            self.assertNotIn("translation", record)

    def test_bundle_bytes_and_hash_are_deterministic(self):
        first = self._bundle(question="What does the supplied evidence say?")
        second = self._bundle(question="What does the supplied evidence say?")

        self.assertEqual(canonical_evidence_bytes(first), canonical_evidence_bytes(second))
        self.assertEqual(evidence_bundle_sha256(first), evidence_bundle_sha256(second))

    def test_human_text_carries_scope_and_conclusion_boundary(self):
        bundle = self._bundle(question="Research this from the supplied ayahs.")
        rendered = render_evidence_text(bundle)

        self.assertIn("Answer only from the evidence records", rendered)
        self.assertIn("[qa:001:001] Quran 1:1", rendered)
        self.assertIn("Research this from the supplied ayahs.", rendered)
        self.assertIn("Source attribution: Tanzil Project", rendered)
        self.assertIn("tanzil.net", rendered)
        self.assertIn("PLEASE DO NOT REMOVE OR CHANGE THIS COPYRIGHT BLOCK", rendered)
        self.assertIn("does not verify the reasoning or conclusion", rendered)

    def test_write_emits_json_text_and_checksum_set_without_overwrite(self):
        bundle = self._bundle()

        with tempfile.TemporaryDirectory() as tmp:
            paths = write_evidence_bundle(bundle, Path(tmp) / "bundle")

            self.assertTrue(paths["json"].is_file())
            self.assertTrue(paths["text"].is_file())
            self.assertTrue(paths["checksums"].is_file())
            checksum_text = paths["checksums"].read_text(encoding="utf-8")
            self.assertIn("  evidence.json", checksum_text)
            self.assertIn("  evidence.txt", checksum_text)

            with self.assertRaisesRegex(EvidenceBundleError, "refusing to overwrite"):
                write_evidence_bundle(bundle, Path(tmp) / "bundle")

    def test_verify_back_accepts_only_supplied_reference_scope(self):
        bundle = self._bundle()
        digest = evidence_bundle_sha256(bundle)

        result = verify_back(
            bundle,
            "The supplied passage supports this observation [qa:002:255].",
            MANIFEST,
            REGISTRY,
            expected_bundle_sha256=digest,
            allow_candidate_for_development=True,
        )

        self.assertEqual("references-verified", result["status"])
        self.assertEqual("References verified", result["message"])
        self.assertEqual(["qa:002:255"], result["citation_ids"])
        self.assertFalse(result["conclusion_verified"])

    def test_verify_back_rejects_valid_local_reference_outside_export(self):
        bundle = self._bundle(citations=["qa:001:001"])

        with self.assertRaisesRegex(EvidenceBundleError, "outside the exported evidence scope"):
            verify_back(
                bundle,
                "This answer escaped the supplied evidence [qa:002:255].",
                MANIFEST,
                REGISTRY,
                expected_bundle_sha256=evidence_bundle_sha256(bundle),
                allow_candidate_for_development=True,
            )

    def test_verify_back_rejects_missing_or_malformed_reference(self):
        bundle = self._bundle(citations=["qa:001:001"])

        with self.assertRaisesRegex(EvidenceBundleError, "no verifiable Quran citation"):
            verify_back(
                bundle,
                "No citation supplied.",
                MANIFEST,
                REGISTRY,
                expected_bundle_sha256=evidence_bundle_sha256(bundle),
                allow_candidate_for_development=True,
            )

        with self.assertRaisesRegex(EvidenceBundleError, "malformed Quran citation"):
            verify_back(
                bundle,
                "Malformed reference [qa:1:1].",
                MANIFEST,
                REGISTRY,
                expected_bundle_sha256=evidence_bundle_sha256(bundle),
                allow_candidate_for_development=True,
            )

    def test_verify_back_rejects_mutated_source_notice(self):
        bundle = self._bundle(citations=["qa:001:001"])
        tampered = copy.deepcopy(bundle)
        tampered["source_notice"]["text"] = "Tanzil Project"

        with self.assertRaisesRegex(EvidenceBundleError, "source notice does not match"):
            verify_back(
                tampered,
                "Citation [qa:001:001].",
                MANIFEST,
                REGISTRY,
                expected_bundle_sha256=evidence_bundle_sha256(bundle),
                allow_candidate_for_development=True,
            )

    def test_verify_back_rejects_mutated_exported_arabic(self):
        bundle = self._bundle(citations=["qa:001:001"])
        tampered = copy.deepcopy(bundle)
        tampered["records"][0]["original_arabic"] += "x"

        with self.assertRaisesRegex(EvidenceBundleError, "do not exactly match"):
            verify_back(
                tampered,
                "Citation [qa:001:001].",
                MANIFEST,
                REGISTRY,
                expected_bundle_sha256=evidence_bundle_sha256(bundle),
                allow_candidate_for_development=True,
            )

    def test_verify_back_requires_the_exact_export_hash(self):
        bundle = self._bundle(citations=["qa:001:001"])

        with self.assertRaises(TypeError):
            verify_back(
                bundle,
                "Citation [qa:001:001].",
                MANIFEST,
                REGISTRY,
                allow_candidate_for_development=True,
            )

    def test_verify_back_can_pin_the_exact_export_hash(self):
        bundle = self._bundle(citations=["qa:001:001"])

        with self.assertRaisesRegex(EvidenceBundleError, "does not match the expected export"):
            verify_back(
                bundle,
                "Citation [qa:001:001].",
                MANIFEST,
                REGISTRY,
                expected_bundle_sha256="0" * 64,
                allow_candidate_for_development=True,
            )

    def test_duplicate_or_nonexistent_citations_fail_closed(self):
        with self.assertRaisesRegex(EvidenceBundleError, "duplicate citation ID"):
            self._bundle(citations=["qa:001:001", "qa:001:001"])

        with self.assertRaisesRegex(EvidenceBundleError, "does not exist"):
            self._bundle(citations=["qa:114:999"])


if __name__ == "__main__":
    unittest.main()
