import json
import unittest

from tools.quran_search_experiment import (
    FUZZY_MATCH_MODE,
    _edit_distance_at_most_one,
    assert_experiment,
    evaluate_experiment,
)


class QuranSearchExperimentTests(unittest.TestCase):
    def test_one_edit_primitive_is_strict(self):
        self.assertEqual(0, _edit_distance_at_most_one("العالمين", "العالمين"))
        self.assertEqual(1, _edit_distance_at_most_one("العلمين", "العالمين"))
        self.assertEqual(1, _edit_distance_at_most_one("احدد", "احد"))
        self.assertIsNone(_edit_distance_at_most_one("العلم", "العالمين"))
        self.assertIsNone(_edit_distance_at_most_one("عبد", "بعد"))

    def test_conservative_fuzzy_experiment_clears_labelled_gate(self):
        report = evaluate_experiment()
        assert_experiment(report)

        for category in (
            "exact_source",
            "diacritic_free",
            "partial_phrase",
            "typo",
            "orthographic_variant",
            "keyboard_variant",
        ):
            self.assertEqual(1.0, report["categories"][category]["recall_at_5"])
        self.assertEqual(0.0, report["metrics"]["negative_false_positive_rate"])

        typo_cases = [
            case for case in report["cases"] if case["category"] == "typo"
        ]
        self.assertTrue(typo_cases)
        self.assertTrue(
            all(case["match_mode"] == FUZZY_MATCH_MODE for case in typo_cases)
        )

        baseline_categories = {
            "exact_source",
            "diacritic_free",
            "partial_phrase",
            "orthographic_variant",
            "keyboard_variant",
        }
        baseline_cases = [
            case
            for case in report["cases"]
            if case["category"] in baseline_categories
        ]
        self.assertTrue(baseline_cases)
        self.assertTrue(
            all(case["match_mode"] != FUZZY_MATCH_MODE for case in baseline_cases)
        )

        serialized = json.dumps(report, ensure_ascii=False)
        self.assertNotIn("query_text", serialized)
        self.assertNotIn("original_text", serialized)
        self.assertNotIn("search_diacritic_free", serialized)


if __name__ == "__main__":
    unittest.main()
