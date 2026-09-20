import json
from pathlib import Path
import subprocess
import sys
import unittest

from tools.quran_search_eval import (
    DEFAULT_GOLDEN,
    DEFAULT_PACK,
    HISTORICAL_GOLDEN_V1,
    QUERY_VARIANT_NORMALIZATION_VERSION,
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
            golden["runtime"]["query_variant_normalization_version"],
            QUERY_VARIANT_NORMALIZATION_VERSION,
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

    def test_historical_v1_remains_the_original_strict_baseline(self):
        historical = load_golden(HISTORICAL_GOLDEN_V1)
        self.assertEqual(historical["golden_set_id"], "quran-search-golden-v1")
        minimums = historical["baseline_policy"]["minimum_recall_at_5_by_category"]
        self.assertEqual(
            set(minimums),
            {"exact_source", "diacritic_free", "partial_phrase"},
        )
        self.assertNotIn("runtime", historical)
        keyboard_case = next(
            case
            for case in historical["cases"]
            if case["id"] == "keyboard-persian-yeh-baqarah-2-255"
        )
        self.assertEqual(keyboard_case["expected_ayah_ids"], ["qa:002:255"])

    def test_active_golden_rejects_query_variant_version_drift(self):
        golden = load_golden(DEFAULT_GOLDEN)
        golden["runtime"]["query_variant_normalization_version"] = "unexpected-v999"
        mismatch_path = ROOT / "evaluation" / ".mismatched-search-golden-v2.json"
        try:
            mismatch_path.write_text(
                json.dumps(golden, ensure_ascii=False),
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                QuranSearchEvalError,
                "query variant normalization version mismatch",
            ):
                evaluate(DEFAULT_PACK, mismatch_path)
        finally:
            mismatch_path.unlink(missing_ok=True)

    def test_strict_baseline_preserves_supported_recall_and_abstention(self):
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

        approximate_cases = [
            case
            for case in report["cases"]
            if case["category"] in {"orthographic_variant", "keyboard_variant"}
        ]
        self.assertTrue(approximate_cases)
        self.assertTrue(
            all(case["match_mode"] == "approximate_spelling" for case in approximate_cases)
        )
        self.assertEqual(report["metrics"]["negative_false_positive_rate"], 0.0)
        self.assertIn("Host-side SQLite timing only", report["latency_scope"])

    def test_evaluator_never_reports_normalized_quran_as_display_evidence(self):
        report, _ = evaluate(DEFAULT_PACK, DEFAULT_GOLDEN)
        serialized = json.dumps(report, ensure_ascii=False)
        self.assertNotIn("query_text", serialized)
        self.assertNotIn("original_text", serialized)
        self.assertNotIn("search_diacritic_free", serialized)
        self.assertEqual(
            report["pack"]["query_variant_normalization_version"],
            "arabic-query-variant-v1",
        )

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
