#!/usr/bin/env python3
"""Measured, deterministic evaluation for the current Quran search contract.

This is an evaluation harness, not a second runtime search engine. It mirrors the
strict Android SQL contract against the preserved quran-core SQLite pack so
retrieval changes can be measured before they are promoted.
"""
from __future__ import annotations

import argparse
import json
import math
from pathlib import Path
import sqlite3
import statistics
import time
from typing import Any

if __package__:
    from tools.quran_core import (
        SEARCH_NORMALIZATION_VERSION,
        normalize_search_diacritic_free,
        normalize_search_unicode,
    )
else:
    from quran_core import (
        SEARCH_NORMALIZATION_VERSION,
        normalize_search_diacritic_free,
        normalize_search_unicode,
    )

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_PACK = ROOT / "content-packs" / "quran-core" / "1.1.0" / "content.sqlite"
DEFAULT_GOLDEN = ROOT / "evaluation" / "quran_search_golden_v2.json"

QUERY_COMPATIBILITY_VERSION = "arabic-query-compat-v1"
COMPATIBILITY_TRANSLATION = str.maketrans(
    {
        "ٱ": "ا",
        "أ": "ا",
        "إ": "ا",
        "آ": "ا",
        "ی": "ي",
        "ہ": "ه",
    }
)
COMPATIBILITY_SQL_EXPRESSION = (
    "replace(replace(replace(replace(replace(replace("
    "search_diacritic_free, 'ٱ', 'ا'), 'أ', 'ا'), 'إ', 'ا'), "
    "'آ', 'ا'), 'ی', 'ي'), 'ہ', 'ه')"
)


class QuranSearchEvalError(RuntimeError):
    pass


def _pack_metadata(connection: sqlite3.Connection) -> dict[str, str]:
    return dict(connection.execute("SELECT key, value FROM pack_metadata"))


def strict_search(
    connection: sqlite3.Connection,
    query: str,
    *,
    limit: int = 50,
) -> list[str]:
    """Mirror the current Android strict-search SQL and return ranked Ayah IDs."""
    if not 1 <= limit <= 100:
        raise QuranSearchEvalError("search limit must be between 1 and 100")

    unicode_query = normalize_search_unicode(query).strip()
    diacritic_free_query = normalize_search_diacritic_free(query)
    if not diacritic_free_query:
        return []

    rows = connection.execute(
        """
        SELECT ayah_id
        FROM quran_ayah
        WHERE instr(search_unicode, ?) > 0
           OR instr(search_diacritic_free, ?) > 0
        ORDER BY
            CASE
                WHEN search_unicode = ? THEN 0
                WHEN instr(search_unicode, ?) = 1 THEN 1
                WHEN search_diacritic_free = ? THEN 2
                WHEN instr(search_diacritic_free, ?) = 1 THEN 3
                ELSE 4
            END,
            length(search_diacritic_free),
            surah,
            ayah
        LIMIT ?
        """,
        (
            unicode_query,
            diacritic_free_query,
            unicode_query,
            unicode_query,
            diacritic_free_query,
            diacritic_free_query,
            limit,
        ),
    )
    return [row[0] for row in rows]


def normalize_query_compatibility(text: str) -> str:
    """Apply the same conservative compatibility fold used by Android."""
    return normalize_search_diacritic_free(text).translate(COMPATIBILITY_TRANSLATION)


def compatibility_search(
    connection: sqlite3.Connection,
    query: str,
    *,
    limit: int = 50,
) -> list[str]:
    """Fallback search over a tiny versioned spelling-compatibility fold."""
    if not 1 <= limit <= 100:
        raise QuranSearchEvalError("search limit must be between 1 and 100")

    compatibility_query = normalize_query_compatibility(query)
    if not compatibility_query:
        return []

    rows = connection.execute(
        f"""
        WITH compatibility_candidates AS (
            SELECT
                ayah_id,
                surah,
                ayah,
                {COMPATIBILITY_SQL_EXPRESSION} AS compatibility_text
            FROM quran_ayah
        )
        SELECT ayah_id
        FROM compatibility_candidates
        WHERE instr(compatibility_text, ?) > 0
        ORDER BY
            CASE
                WHEN compatibility_text = ? THEN 0
                WHEN instr(compatibility_text, ?) = 1 THEN 1
                ELSE 2
            END,
            length(compatibility_text),
            surah,
            ayah
        LIMIT ?
        """,
        (
            compatibility_query,
            compatibility_query,
            compatibility_query,
            limit,
        ),
    )
    return [row[0] for row in rows]


def search_with_lane(
    connection: sqlite3.Connection,
    query: str,
    *,
    limit: int = 50,
) -> tuple[list[str], str]:
    strict = strict_search(connection, query, limit=limit)
    if strict:
        return strict, "strict"

    compatible = compatibility_search(connection, query, limit=limit)
    if compatible:
        return compatible, "compatibility"
    return [], "none"


def _query_for_case(connection: sqlite3.Connection, case: dict[str, Any]) -> str:
    explicit = case.get("query")
    if isinstance(explicit, str):
        if not explicit.strip():
            raise QuranSearchEvalError(f"{case['id']}: explicit query is blank")
        return explicit

    ayah_id = case.get("query_from_ayah_id")
    derivation = case.get("query_derivation")
    if not isinstance(ayah_id, str) or not isinstance(derivation, str):
        raise QuranSearchEvalError(
            f"{case['id']}: case needs either query or query_from_ayah_id/query_derivation"
        )

    row = connection.execute(
        """
        SELECT original_text, search_diacritic_free
        FROM quran_ayah
        WHERE ayah_id = ?
        """,
        (ayah_id,),
    ).fetchone()
    if row is None:
        raise QuranSearchEvalError(f"{case['id']}: unknown source ayah {ayah_id}")

    original_text, diacritic_free = row
    if derivation == "source_exact":
        return original_text
    if derivation == "diacritic_free":
        return diacritic_free
    if derivation == "word_slice_diacritic_free":
        word_slice = case.get("word_slice")
        if (
            not isinstance(word_slice, list)
            or len(word_slice) != 2
            or not all(isinstance(value, int) for value in word_slice)
        ):
            raise QuranSearchEvalError(f"{case['id']}: invalid word_slice")
        start, end = word_slice
        words = diacritic_free.split()
        if start < 0 or end <= start or end > len(words):
            raise QuranSearchEvalError(
                f"{case['id']}: word_slice {word_slice} outside {len(words)} words"
            )
        return " ".join(words[start:end])

    raise QuranSearchEvalError(
        f"{case['id']}: unsupported query_derivation {derivation!r}"
    )


def _recall_at(ranked: list[str], relevant: list[str], k: int) -> float:
    if not relevant:
        return 0.0
    return len(set(ranked[:k]).intersection(relevant)) / len(set(relevant))


def _reciprocal_rank(ranked: list[str], relevant: list[str]) -> float:
    relevant_set = set(relevant)
    for index, ayah_id in enumerate(ranked, start=1):
        if ayah_id in relevant_set:
            return 1.0 / index
    return 0.0


def _ndcg_at(ranked: list[str], relevant: list[str], k: int) -> float:
    if not relevant:
        return 0.0
    relevant_set = set(relevant)
    dcg = 0.0
    for index, ayah_id in enumerate(ranked[:k], start=1):
        if ayah_id in relevant_set:
            dcg += 1.0 / math.log2(index + 1)
    ideal_hits = min(len(relevant_set), k)
    ideal = sum(1.0 / math.log2(index + 1) for index in range(1, ideal_hits + 1))
    return dcg / ideal if ideal else 0.0


def _percentile(values: list[float], percentile: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    rank = max(1, math.ceil(percentile * len(ordered)))
    return ordered[rank - 1]


def load_golden(path: Path) -> dict[str, Any]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if data.get("schema_version") != 1:
        raise QuranSearchEvalError("unsupported golden-set schema")
    cases = data.get("cases")
    if not isinstance(cases, list) or not cases:
        raise QuranSearchEvalError("golden set must contain cases")

    seen: set[str] = set()
    for case in cases:
        case_id = case.get("id")
        category = case.get("category")
        expected = case.get("expected_ayah_ids")
        if not isinstance(case_id, str) or not case_id:
            raise QuranSearchEvalError("golden case is missing id")
        if case_id in seen:
            raise QuranSearchEvalError(f"duplicate golden case id: {case_id}")
        seen.add(case_id)
        if not isinstance(category, str) or not category:
            raise QuranSearchEvalError(f"{case_id}: category is missing")
        if not isinstance(expected, list) or not all(
            isinstance(value, str) and value.startswith("qa:") for value in expected
        ):
            raise QuranSearchEvalError(f"{case_id}: expected_ayah_ids must be Quran IDs")
    return data


def evaluate(
    pack_path: Path,
    golden_path: Path,
    *,
    limit: int = 50,
) -> tuple[dict[str, Any], dict[str, Any]]:
    golden = load_golden(golden_path)
    connection = sqlite3.connect(f"file:{pack_path}?mode=ro", uri=True)
    try:
        metadata = _pack_metadata(connection)
        expected_pack = golden.get("pack")
        if not isinstance(expected_pack, dict):
            raise QuranSearchEvalError("golden set is missing pack binding")
        required_bindings = {
            "pack_id": expected_pack.get("pack_id"),
            "content_version": expected_pack.get("content_version"),
            "search_normalization_version": expected_pack.get(
                "search_normalization_version"
            ),
        }
        for key, expected in required_bindings.items():
            if metadata.get(key) != expected:
                raise QuranSearchEvalError(
                    f"golden-set {key}={expected!r} does not match pack {metadata.get(key)!r}"
                )
        if metadata.get("search_normalization_version") != SEARCH_NORMALIZATION_VERSION:
            raise QuranSearchEvalError("runtime normalizer does not match pack contract")

        expected_runtime = golden.get("runtime")
        if not isinstance(expected_runtime, dict):
            raise QuranSearchEvalError("golden set is missing runtime binding")
        if expected_runtime.get("query_compatibility_version") != QUERY_COMPATIBILITY_VERSION:
            raise QuranSearchEvalError("golden-set query compatibility version mismatch")

        case_reports: list[dict[str, Any]] = []
        latencies_ms: list[float] = []

        for case in golden["cases"]:
            query = _query_for_case(connection, case)
            started = time.perf_counter()
            ranked, match_lane = search_with_lane(connection, query, limit=limit)
            elapsed_ms = (time.perf_counter() - started) * 1000.0
            latencies_ms.append(elapsed_ms)

            expected = case["expected_ayah_ids"]
            positive = bool(expected)
            case_reports.append(
                {
                    "id": case["id"],
                    "category": case["category"],
                    "positive": positive,
                    "result_count": len(ranked),
                    "match_lane": match_lane,
                    "top_10": ranked[:10],
                    "recall_at_5": _recall_at(ranked, expected, 5) if positive else None,
                    "recall_at_10": _recall_at(ranked, expected, 10) if positive else None,
                    "reciprocal_rank": _reciprocal_rank(ranked, expected)
                    if positive
                    else None,
                    "ndcg_at_10": _ndcg_at(ranked, expected, 10) if positive else None,
                    "latency_ms": round(elapsed_ms, 3),
                }
            )

        positives = [case for case in case_reports if case["positive"]]
        negatives = [case for case in case_reports if not case["positive"]]

        def average(field: str, rows: list[dict[str, Any]]) -> float:
            if not rows:
                return 0.0
            return statistics.fmean(float(row[field]) for row in rows)

        categories: dict[str, dict[str, Any]] = {}
        for category in sorted({case["category"] for case in case_reports}):
            rows = [case for case in case_reports if case["category"] == category]
            positive_rows = [case for case in rows if case["positive"]]
            negative_rows = [case for case in rows if not case["positive"]]
            category_report: dict[str, Any] = {
                "case_count": len(rows),
                "positive_count": len(positive_rows),
                "negative_count": len(negative_rows),
            }
            if positive_rows:
                category_report.update(
                    {
                        "recall_at_5": average("recall_at_5", positive_rows),
                        "recall_at_10": average("recall_at_10", positive_rows),
                        "mrr": average("reciprocal_rank", positive_rows),
                        "ndcg_at_10": average("ndcg_at_10", positive_rows),
                    }
                )
            if negative_rows:
                category_report["false_positive_rate"] = sum(
                    1 for row in negative_rows if row["result_count"] > 0
                ) / len(negative_rows)
            categories[category] = category_report

        negative_false_positive_rate = (
            sum(1 for case in negatives if case["result_count"] > 0) / len(negatives)
            if negatives
            else 0.0
        )
        report = {
            "schema_version": 1,
            "pack": {
                "pack_id": metadata.get("pack_id"),
                "content_version": metadata.get("content_version"),
                "search_normalization_version": metadata.get(
                    "search_normalization_version"
                ),
            },
            "runtime": {
                "query_compatibility_version": QUERY_COMPATIBILITY_VERSION,
            },
            "case_count": len(case_reports),
            "positive_case_count": len(positives),
            "negative_case_count": len(negatives),
            "metrics": {
                "recall_at_5": average("recall_at_5", positives),
                "recall_at_10": average("recall_at_10", positives),
                "mrr": average("reciprocal_rank", positives),
                "ndcg_at_10": average("ndcg_at_10", positives),
                "negative_false_positive_rate": negative_false_positive_rate,
                "zero_result_rate": sum(
                    1 for case in case_reports if case["result_count"] == 0
                )
                / len(case_reports),
                "host_p50_latency_ms": round(statistics.median(latencies_ms), 3),
                "host_p95_latency_ms": round(_percentile(latencies_ms, 0.95), 3),
            },
            "categories": categories,
            "cases": case_reports,
            "latency_scope": (
                "Host-side SQLite timing only. This is not a low-end Android performance claim."
            ),
        }
        return report, golden
    finally:
        connection.close()


def assert_baseline(report: dict[str, Any], golden: dict[str, Any]) -> None:
    policy = golden.get("baseline_policy")
    if not isinstance(policy, dict):
        raise QuranSearchEvalError("golden set is missing baseline_policy")

    required_categories = policy.get("required_categories", [])
    for category in required_categories:
        if category not in report["categories"]:
            raise QuranSearchEvalError(f"required category missing: {category}")

    minimums = policy.get("minimum_recall_at_5_by_category", {})
    for category, minimum in minimums.items():
        actual = report["categories"].get(category, {}).get("recall_at_5")
        if actual is None or actual < float(minimum):
            raise QuranSearchEvalError(
                f"{category} Recall@5 regressed: {actual!r} < {minimum}"
            )

    maximum_fpr = float(policy.get("maximum_negative_false_positive_rate", 1.0))
    actual_fpr = float(report["metrics"]["negative_false_positive_rate"])
    if actual_fpr > maximum_fpr:
        raise QuranSearchEvalError(
            f"negative false-positive rate regressed: {actual_fpr} > {maximum_fpr}"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", type=Path, default=DEFAULT_PACK)
    parser.add_argument("--golden", type=Path, default=DEFAULT_GOLDEN)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument(
        "--assert-baseline",
        action="store_true",
        help="fail if the strict-search regression floor is not met",
    )
    args = parser.parse_args()

    report, golden = evaluate(args.pack, args.golden, limit=args.limit)
    if args.assert_baseline:
        assert_baseline(report, golden)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
