import json
import unittest

from tools.quran_search_one_edit_experiment import (
    assert_one_edit,
    edit_distance_at_most_one,
    evaluate_one_edit,
)


class QuranSearchOneEditExperimentTests(unittest.TestCase):
    def test_edit_distance_primitive_is_bounded_to_one(self):
        self.assertEqual(
            0,
            edit_distance_at_most_one("العالمين", "العالمين"),
        )
        self.assertEqual(
            1,
            edit_distance_at_most_one("العلمين", "العالمين"),
        )
        self.assertEqual(
            1,
            edit_distance_at_most_one("احدد", "احد"),
        )
        self.assertIsNone(
            edit_distance_at_most_one("العلم", "العالمين"),
        )

    def test_one_edit_experiment_improves_labelled_typos_without_false_positives(self):
        report = evaluate_one_edit()
        assert_one_edit(report)

        for category in (
            "exact_source",
            "diacritic_free",
            "partial_phrase",
            "typo",
            "orthographic_variant",
            "keyboard_variant",
        ):
            self.assertEqual(
                1.0,
                report["categories"][category]["recall_at_5"],
            )
        self.assertEqual(
            0.0,
            report["metrics"]["negative_false_positive_rate"],
        )

        typo_modes = {
            row["id"]: row["match_mode"]
            for row in report["cases"]
            if row["category"] == "typo"
        }
        # The pre-existing spelling fallback already resolves the Fatiha case;
        # this experiment is valuable only if it adds the still-missing Ahad case.
        self.assertEqual(
            "approximate_spelling",
            typo_modes["typo-fatiha-alamin"],
        )
        self.assertEqual(
            "approximate_one_edit",
            typo_modes["typo-ikhlas-ahad"],
        )

        serialized = json.dumps(report, ensure_ascii=False)
        self.assertNotIn("query_text", serialized)
        self.assertNotIn("original_text", serialized)
        self.assertNotIn("search_diacritic_free", serialized)


if __name__ == "__main__":
    unittest.main()
