import json
import unittest

from tools.quran_search_one_edit_experiment import (
    AMBIGUOUS_CANDIDATE_POLICY,
    ENGINE_ID,
    MIN_QUERY_TOKENS,
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
        self.assertEqual(
            1,
            edit_distance_at_most_one("اخد", "احد"),
        )
        self.assertEqual(
            1,
            edit_distance_at_most_one("حد", "احد"),
        )
        self.assertIsNone(
            edit_distance_at_most_one("العلم", "العالمين"),
        )
        self.assertIsNone(
            edit_distance_at_most_one("عبد", "بعد"),
        )
        self.assertIsNone(
            edit_distance_at_most_one("ادح", "احد"),
        )

    def test_one_edit_candidate_is_bound_to_conservative_policy(self):
        report = evaluate_one_edit()
        self.assertEqual(ENGINE_ID, report["engine_id"])
        self.assertEqual(
            {
                "minimum_query_tokens": MIN_QUERY_TOKENS,
                "ambiguous_candidate_policy": AMBIGUOUS_CANDIDATE_POLICY,
            },
            report["candidate_runtime"],
        )
        self.assertEqual(3, MIN_QUERY_TOKENS)
        self.assertEqual("abstain", AMBIGUOUS_CANDIDATE_POLICY)

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

        modes = {row["id"]: row["match_mode"] for row in report["cases"]}
        self.assertEqual("approximate_spelling", modes["typo-fatiha-alamin"])
        for case_id in (
            "typo-ikhlas-ahad",
            "typo-ikhlas-ahad-substitution",
            "typo-ikhlas-ahad-deletion",
        ):
            self.assertEqual("approximate_one_edit", modes[case_id])

        for case_id in (
            "unsupported-transposition-ikhlas-ahad",
            "negative-short-fuzzy-ahad",
            "negative-short-fuzzy-qayyum",
            "negative-two-edit-ikhlas",
            "negative-ambiguous-repeated-divine-phrase",
        ):
            self.assertEqual("none", modes[case_id])

        serialized = json.dumps(report, ensure_ascii=False)
        self.assertNotIn("query_text", serialized)
        self.assertNotIn("original_text", serialized)
        self.assertNotIn("search_diacritic_free", serialized)


if __name__ == "__main__":
    unittest.main()
