#!/usr/bin/env python3
"""Evaluation-only one-edit Quran typo fallback.

Runs only after the current strict + constrained spelling search abstains.
Source/display Quran text is never modified.
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
    from tools.quran_core import normalize_search_constrained_variant
    from tools.quran_search_eval import (
        DEFAULT_GOLDEN,
        DEFAULT_PACK,
        QuranSearchEvalError,
        _ndcg_at,
        _query_for_case,
        _recall_at,
        _reciprocal_rank,
        load_golden,
        reader_search,
    )
else:
    from quran_core import normalize_search_constrained_variant
    from quran_search_eval import (
        DEFAULT_GOLDEN,
        DEFAULT_PACK,
        QuranSearchEvalError,
        _ndcg_at,
        _query_for_case,
        _recall_at,
        _reciprocal_rank,
        load_golden,
        reader_search,
    )

ENGINE_ID = "quran-one-edit-fallback-v1"


def edit_distance_at_most_one(left: str, right: str) -> int | None:
    if left == right:
        return 0
    if abs(len(left) - len(right)) > 1:
        return None
    if len(left) == len(right):
        return 1 if sum(a != b for a, b in zip(left, right)) == 1 else None

    short, long = (left, right) if len(left) < len(right) else (right, left)
    short_i = long_i = 0
    skipped = False
    while short_i < len(short) and long_i < len(long):
        if short[short_i] == long[long_i]:
            short_i += 1
            long_i += 1
        else:
            if skipped:
                return None
            skipped = True
            long_i += 1
    return 1


class OneEditFallback:
    def __init__(self, connection: sqlite3.Connection):
        rows = connection.execute(
            """
            SELECT ayah_id, surah, ayah, search_diacritic_free
            FROM quran_ayah
            ORDER BY surah, ayah
            """
        ).fetchall()
        self.rows = [
            (
                ayah_id,
                surah,
                ayah,
                normalize_search_constrained_variant(search_text),
            )
            for ayah_id, surah, ayah, search_text in rows
        ]

    def search(self, query: str, *, limit: int = 50) -> list[str]:
        if not 1 <= limit <= 100:
            raise QuranSearchEvalError("search limit must be between 1 and 100")
        query_tokens = normalize_search_constrained_variant(query).split()
        # Fuzzy single words are intentionally too weak to return sacred text.
        if len(query_tokens) < 2:
            return []

        matches: list[tuple[int, int, int, int, str]] = []
        width = len(query_tokens)
        for ayah_id, surah, ayah, candidate in self.rows:
            tokens = candidate.split()
            if len(tokens) < width:
                continue
            best_start: int | None = None
            for start in range(len(tokens) - width + 1):
                edits = 0
                for query_token, candidate_token in zip(
                    query_tokens, tokens[start : start + width]
                ):
                    distance = edit_distance_at_most_one(query_token, candidate_token)
                    if distance is None:
                        break
                    edits += distance
                    if edits > 1:
                        break
                else:
                    if edits <= 1:
                        best_start = start
                        break
            if best_start is not None:
                matches.append(
                    (best_start, len(tokens), surah, ayah, ayah_id)
                )

        matches.sort()
        return [row[-1] for row in matches[:limit]]


def typo_candidate_search(
    connection: sqlite3.Connection,
    fallback: OneEditFallback,
    query: str,
    *,
    limit: int = 50,
) -> tuple[list[str], str]:
    ranked, mode = reader_search(connection, query, limit=limit)
    if ranked:
        return ranked, mode
    typo = fallback.search(query, limit=limit)
    return (typo, "approximate_one_edit") if typo else ([], "none")


def evaluate_one_edit(
    pack_path: Path = DEFAULT_PACK,
    golden_path: Path = DEFAULT_GOLDEN,
    *,
    limit: int = 50,
) -> dict[str, Any]:
    golden = load_golden(golden_path)
    connection = sqlite3.connect(f"file:{pack_path}?mode=ro", uri=True)
    try:
        fallback = OneEditFallback(connection)
        reports: list[dict[str, Any]] = []
        latencies: list[float] = []
        for case in golden["cases"]:
            query = _query_for_case(connection, case)
            started = time.perf_counter()
            ranked, mode = typo_candidate_search(
                connection, fallback, query, limit=limit
            )
            latency = (time.perf_counter() - started) * 1000.0
            latencies.append(latency)
            expected = case["expected_ayah_ids"]
            positive = bool(expected)
            reports.append(
                {
                    "id": case["id"],
                    "category": case["category"],
                    "positive": positive,
                    "match_mode": mode,
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

        categories: dict[str, dict[str, Any]] = {}
        for category in sorted({row["category"] for row in reports}):
            rows = [row for row in reports if row["category"] == category]
            positives = [row for row in rows if row["positive"]]
            negatives = [row for row in rows if not row["positive"]]
            metrics: dict[str, Any] = {"case_count": len(rows)}
            if positives:
                metrics["recall_at_5"] = statistics.fmean(
                    row["recall_at_5"] for row in positives
                )
                metrics["mrr"] = statistics.fmean(
                    row["reciprocal_rank"] for row in positives
                )
            if negatives:
                metrics["false_positive_rate"] = (
                    sum(row["result_count"] > 0 for row in negatives) / len(negatives)
                )
            categories[category] = metrics

        positives = [row for row in reports if row["positive"]]
        negatives = [row for row in reports if not row["positive"]]
        ordered = sorted(latencies)
        p95 = ordered[max(0, (95 * len(ordered) + 99) // 100 - 1)]
        return {
            "schema_version": 1,
            "engine_id": ENGINE_ID,
            "golden_set_id": golden["golden_set_id"],
            "metrics": {
                "recall_at_5": statistics.fmean(
                    row["recall_at_5"] for row in positives
                ),
                "mrr": statistics.fmean(
                    row["reciprocal_rank"] for row in positives
                ),
                "negative_false_positive_rate": (
                    sum(row["result_count"] > 0 for row in negatives) / len(negatives)
                    if negatives
                    else 0.0
                ),
                "host_p50_latency_ms": round(statistics.median(latencies), 3),
                "host_p95_latency_ms": round(p95, 3),
            },
            "categories": categories,
            "cases": reports,
            "latency_scope": (
                "Host-side full-corpus experiment only; not an Android performance claim."
            ),
        }
    finally:
        connection.close()


def assert_one_edit(report: dict[str, Any]) -> None:
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
        raise QuranSearchEvalError("labelled no-answer false positive")

    one_edit_cases = [
        case
        for case in report["cases"]
        if case["match_mode"] == "approximate_one_edit"
    ]
    if not one_edit_cases:
        raise QuranSearchEvalError(
            "experiment must recover at least one residual miss via one-edit fallback"
        )
    if any(case["category"] != "typo" for case in one_edit_cases):
        raise QuranSearchEvalError(
            "one-edit fallback displaced a non-typo baseline category"
        )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--pack", type=Path, default=DEFAULT_PACK)
    parser.add_argument("--golden", type=Path, default=DEFAULT_GOLDEN)
    parser.add_argument("--limit", type=int, default=50)
    parser.add_argument("--assert-experiment", action="store_true")
    args = parser.parse_args()
    report = evaluate_one_edit(args.pack, args.golden, limit=args.limit)
    if args.assert_experiment:
        assert_one_edit(report)
    print(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2))


if __name__ == "__main__":
    main()
