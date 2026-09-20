#!/usr/bin/env python3
"""Conservative deterministic Quran-search experiment.

This module is evaluation-only. It does not change display text, pack evidence or
the Android runtime. It tests whether a narrow orthographic/keyboard variant lane
plus one-edit contiguous token matching can improve the labelled golden set while
preserving abstention.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import sqlite3
import statistics
import time
from typing import Any

if __package__:
    from tools.quran_core import normalize_search_diacritic_free
    from tools.quran_search_eval import (
        DEFAULT_GOLDEN,
        DEFAULT_PACK,
        QuranSearchEvalError,
        _ndcg_at,
        _query_for_case,
        _recall_at,
        _reciprocal_rank,
        load_golden,
    )
else:
    from quran_core import normalize_search_diacritic_free
    from quran_search_eval import (
        DEFAULT_GOLDEN,
        DEFAULT_PACK,
        QuranSearchEvalError,
        _ndcg_at,
        _query_for_case,
        _recall_at,
        _reciprocal_rank,
        load_golden,
    )


ENGINE_ID = "quran-conservative-fuzzy-v1"

_VARIANT_TRANSLATION = str.maketrans(
    {
        "\u0671": "\u0627",  # ALEF WASLA -> ALEF for search only
        "\u0623": "\u0627",  # ALEF WITH HAMZA ABOVE
        "\u0625": "\u0627",  # ALEF WITH HAMZA BELOW
        "\u0622": "\u0627",  # ALEF WITH MADDA
        "\u06cc": "\u064a",  # FARSI YEH -> ARABIC YEH
        "\u06d2": "\u064a",  # YEH BARREE -> ARABIC YEH
        "\u06a9": "\u0643",  # KEHEH -> KAF
        "\u06c1": "\u0647",  # HEH GOAL -> HEH
        "\u06be": "\u0647",  # HEH DOACHASHMEE -> HEH
    }
)


def normalize_variant_lane(text: str) -> str:
    return normalize_search_diacritic_free(text).translate(_VARIANT_TRANSLATION).strip()


def _edit_distance_at_most_one(left: str, right: str) -> int | None:
    """Return 0/1 when strings are at edit distance <=1, otherwise None."""
    if left == right:
        return 0
    if abs(len(left) - len(right)) > 1:
        return None

    if len(left) == len(right):
        mismatches = sum(a != b for a, b in zip(left, right))
        return 1 if mismatches == 1 else None

    short, long = (left, right) if len(left) < len(right) else (right, left)
    short_index = 0
    long_index = 0
    skipped = False
    while short_index < len(short) and long_index < len(long):
        if short[short_index] == long[long_index]:
            short_index += 1
            long_index += 1
            continue
        if skipped:
            return None
        skipped = True
        long_index += 1
    return 1


class ConservativeFuzzySearch:
    """Prepared corpus view for deterministic evaluation without new evidence."""

    def __init__(self, connection: sqlite3.Connection):
        rows = connection.execute(
            """
            SELECT ayah_id, surah, ayah, search_diacritic_free
            FROM quran_ayah
            ORDER BY surah, ayah
            """
        ).fetchall()
        self._rows = [
            (
                ayah_id,
                surah,
                ayah,
                normalize_variant_lane(search_text),
            )
            for ayah_id, surah, ayah, search_text in rows
        ]

    def search(self, query: str, *, limit: int = 50) -> list[str]:
        if not 1 <= limit <= 100:
            raise QuranSearchEvalError("search limit must be between 1 and 100")

        normalized_query = normalize_variant_lane(query)
        if not normalized_query:
            return []

        direct: list[tuple[int, int, int, int, str]] = []
        for ayah_id, surah, ayah, candidate in self._rows:
            position = candidate.find(normalized_query)
            if position >= 0:
                direct.append(
                    (
                        0 if candidate == normalized_query else 1 if position == 0 else 2,
                        len(candidate),
                        surah,
                        ayah,
                        ayah_id,
                    )
                )
        if direct:
            direct.sort()
            return [entry[-1] for entry in direct[:limit]]

        query_tokens = normalized_query.split()
        # One-character fuzzy matching is intentionally unavailable for single-word
        # queries: a weak one-token edit has too little evidence to return Quran text.
        if len(query_tokens) < 2:
            return []

        fuzzy: list[tuple[int, int, int, int, int, str]] = []
        for ayah_id, surah, ayah, candidate in self._rows:
            candidate_tokens = candidate.split()
            if len(candidate_tokens) < len(query_tokens):
                continue

            best: tuple[int, int] | None = None
            width = len(query_tokens)
            for start in range(0, len(candidate_tokens) - width + 1):
                total_edits = 0
                valid = True
                for query_token, candidate_token in zip(
                    query_tokens,
                    candidate_tokens[start : start + width],
                ):
                    distance = _edit_distance_at_most_one(
                        query_token,
                        candidate_token,
                    )
                    if distance is None:
                        valid = False
                        break
                    total_edits += distance
                    if total_edits > 1:
                        valid = False
                        break
                if valid:
                    window = (total_edits, start)
                    if best is None or window < best:
                        best = window

            if best is not None:
                total_edits, start = best
                fuzzy.append(
                    (
                        total_edits,
                        start,
                        len(candidate_tokens),
                        surah,
                        ayah,
                        ayah_id,
                    )
                )

        fuzzy.sort()
        return [entry[-1] for entry in fuzzy[:limit]]


def _average(field: str, rows: list[dict[str, Any]]) -> float:
    if not rows:
        return 0.0
    return statistics.fmean(float(row[field]) for row in rows)


def evaluate_experiment(
    pack_path: Path = DEFAULT_PACK,
    golden_path: Path = DEFAULT_GOLDEN,
    *,
    limit: int = 50,
) -> dict[str, Any]:
    golden = load_golden(golden_path)
    connection = sqlite3.connect(f"file:{pack_path}?mode=ro", uri=True)
    try:
        search = ConservativeFuzzySearch(connection)
        reports: list[dict[str, Any]] = []
        latencies: list[float] = []
        for case in golden["cases"]:
            query = _query_for_case(connection, case)
            started = time.perf_counter()
            ranked = search.search(query, limit=limit)
            latency = (time.perf_counter() - started) * 1000.0
            latencies.append(latency)
            expected = case["expected_ayah_ids"]
            positive = bool(expected)
            reports.append(
                {
                    "id": case["id"],
                    "category": case["category"],
                    "positive": positive,
                    "result_count": len(ranked),
                    "top_10": ranked[:10],
                    "recall_at_5": _recall_at(ranked, expected, 5) if positive else None,
                    "recall_at_10": _recall_at(ranked, expected, 10) if positive else None,
                    "reciprocal_rank": (
                        _reciprocal_rank(ranked, expected) if positive else None
                    ),
                    "ndcg_at_10": _ndcg_at(ranked, expected, 10) if positive else None,
                    "latency_ms": round(latency, 3),
                }
            )

        positives = [row for row in reports if row["positive"]]
        negatives = [row for row in reports if not row["positive"]]
        categories: dict[str, dict[str, Any]] = {}
        for category in sorted({row["category"] for row in reports}):
            rows = [row for row in reports if row["category"] == category]
            positive_rows = [row for row in rows if row["positive"]]
            negative_rows = [row for row in rows if not row["positive"]]
            metrics: dict[str, Any] = {
                "case_count": len(rows),
                "positive_count": len(positive_rows),
                "negative_count": len(negative_rows),
            }
            if positive_rows:
                metrics.update(
                    {
                        "recall_at_5": _average("recall_at_5", positive_rows),
                        "recall_at_10": _average("recall_at_10", positive_rows),
                        "mrr": _average("reciprocal_rank", positive_rows),
                        "ndcg_at_10": _average("ndcg_at_10", positive_rows),
                    }
                )
            if negative_rows:
                metrics["false_positive_rate"] = (
                    sum(row["result_count"] > 0 for row in negative_rows)
                    / len(negative_rows)
                )
            categories[category] = metrics

        ordered = sorted(latencies)
        p95_index = max(0, min(len(ordered) - 1, (95 * len(ordered) + 99) // 100 - 1))
        return {
            "schema_version": 1,
            "engine_id": ENGINE_ID,
            "golden_set_id": golden["golden_set_id"],
            "case_count": len(reports),
            "metrics": {
                "recall_at_5": _average("recall_at_5", positives),
                "recall_at_10": _average("recall_at_10", positives),
                "mrr": _average("reciprocal_rank", positives),
                "ndcg_at_10": _average("ndcg_at_10", positives),
                "negative_false_positive_rate": (
                    sum(row["result_count"] > 0 for row in negatives) / len(negatives)
                    if negatives
                    else 0.0
                ),
                "zero_result_rate": (
                    sum(row["result_count"] == 0 for row in reports) / len(reports)
                ),
                "host_p50_latency_ms": round(statistics.median(latencies), 3),
                "host_p95_latency_ms": round(ordered[p95_index], 3),
            },
            "categories": categories,
            "cases": reports,
            "latency_scope": (
                "Host-side full-corpus experiment only; not an Android performance claim."
            ),
        }
    finally:
        connection.close()


def assert_experiment(report: dict[str, Any]) -> None:
    for category in (
        "exact_source",
        "diacritic_free",
        "partial_phrase",
        "typo",
        "orthographic_variant",
        "keyboard_variant",
    ):
        actual = report["categories"].get(category, {}).get("recall_at_5")
        if actual != 1.0:
            raise QuranSearchEvalError(
                f"{category} Recall@5 is {actual!r}; experiment is not promotable"
            )
    if report["metrics"]["negative_false_positive_rate"] != 0.0:
        raise QuranSearchEvalError(
            "experiment returned a labelled no-answer false positive"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", type=Path, default=DEFAULT_PACK)
    parser.add_argument("--golden", type=Path, default=DEFAULT_GOLDEN)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--assert-experiment", action="store_true")
    args = parser.parse_args()

    report = evaluate_experiment(args.pack, args.golden, limit=args.limit)
    if args.assert_experiment:
        assert_experiment(report)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
