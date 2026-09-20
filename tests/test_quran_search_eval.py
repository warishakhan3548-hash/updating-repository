import json
from pathlib import Path
import subprocess
import sys
import unittest

from tools.quran_search_eval import (
    DEFAULT_GOLDEN,
    DEFAULT_PACK,
    QUERY_COMPATIBILITY_VERSION,
    QuranSearchEvalError,
    assert_baseline,
    evaluate,
    load_golden,
)

ROOT = Path(__file__).resolve().parents[1]


class QuranSearchEvaluationTests(unittest.TestCase):
    def test_golden_set_is_versioned_and_category_complete(self):
        golden = load_golden(DEFAULT_GOLDEN)
        self.assertEqual(golden["golden_set_id"], "quran-search-golden-v2")
        self.assertEqual(
            golden["runtime"]["query_compatibility_version"],
            QUERY_COMPATIBILITY_VERSION,
        )
        self.assertEqual(golden["pack"]["pack_id"], "quran-core")
        self.assertEqual(golden["pack"]["content_version"], "1.1.0")
        self.assertEqual(
            golden["pack"]["search_normalization_version"],
            "arabic-search-v1",
        )
        categories = {case["category"] for case in golden["cases"]}
        self.assertTrue(
            {
                "exact_source",
                "diacritic_free",
                "partial_phrase",
                "typo",
                "orthographic_variant",
                "keyboard_variant",
                "no_answer",
            }.issubset(categories)
        )

    def test_evaluated_search_preserves_supported_recall_and_abstention(self):
        report, golden = evaluate(DEFAULT_PACK, DEFAULT_GOLDEN)
        assert_baseline(report, golden)

        for category in (
            "exact_source",
            "diacritic_free",
            "partial_phrase",
            "orthographic_variant",
            "keyboard_variant",
        ):
            self.assertEqual(report["categories"][category]["recall_at_5"], 1.0)

        compatibility_cases = [
            case
            for case in report["cases"]
            if case["category"] in {"orthographic_variant", "keyboard_variant"}
        ]
        self.assertTrue(compatibility_cases)
        self.assertTrue(
            all(case["match_lane"] == "compatibility" for case in compatibility_cases)
        )
        self.assertEqual(
            report["runtime"]["query_compatibility_version"],
            QUERY_COMPATIBILITY_VERSION,
        )
        self.assertEqual(report["metrics"]["negative_false_positive_rate"], 0.0)
        self.assertIn("Host-side SQLite timing only", report["latency_scope"])

    def test_evaluator_never_reports_normalized_quran_as_display_evidence(self):
        report, _ = evaluate(DEFAULT_PACK, DEFAULT_GOLDEN)
        serialized = json.dumps(report, ensure_ascii=False)
        self.assertNotIn("query_text", serialized)
        self.assertNotIn("original_text", serialized)
        self.assertNotIn("search_diacritic_free", serialized)

    def test_cli_asserts_the_regression_floor(self):
        completed = subprocess.run(
            [
                sys.executable,
                str(ROOT / "tools" / "quran_search_eval.py"),
                "--assert-baseline",
            ],
            cwd=ROOT,
            check=True,
            capture_output=True,
            text=True,
        )
        report = json.loads(completed.stdout)
        self.assertEqual(report["pack"]["pack_id"], "quran-core")
        self.assertGreater(report["case_count"], 10)

    def test_golden_loader_rejects_duplicate_case_ids(self):
        golden = load_golden(DEFAULT_GOLDEN)
        golden["cases"].append(dict(golden["cases"][0]))
        duplicate_path = ROOT / "evaluation" / ".duplicate-search-golden.json"
        try:
            duplicate_path.write_text(
                json.dumps(golden, ensure_ascii=False),
                encoding="utf-8",
            )
            with self.assertRaises(QuranSearchEvalError):
                load_golden(duplicate_path)
        finally:
            duplicate_path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main()
