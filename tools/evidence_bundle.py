#!/usr/bin/env python3
"""Deterministic local evidence export and verify-back for trusted Quran packs."""
from __future__ import annotations

import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys
from typing import Any

# Support both "python -m tools.evidence_bundle" and direct CLI execution.
if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tools.pack_gate import PackGateError, validate_manifest
from tools.pack_signatures import (
    PackSignatureError,
    canonical_json_bytes,
    load_strict_json_file,
    loads_strict_json,
)


EVIDENCE_BUNDLE_FORMAT = "aaris-evidence-bundle-v1"
_QURAN_CITATION_RE = re.compile(r"^qa:(\d{3}):(\d{3})$")
_BRACKET_TOKEN_RE = re.compile(r"\[([A-Za-z0-9_.:-]+)\]")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")

AI_EVIDENCE_INSTRUCTIONS = [
    "Answer only from the evidence records supplied in this bundle.",
    "Cite supplied citation IDs exactly, for example [qa:002:255].",
    "If the supplied evidence is insufficient, say so explicitly.",
    "Do not silently use web search or model memory as Quran or Hadith evidence.",
    "Do not invent grades, editions, numbering, translations, or source claims.",
    "Local verification checks reference identity and source text, not the conclusion.",
]


class EvidenceBundleError(RuntimeError):
    pass


def _repository_root(registry_path: Path) -> Path:
    resolved = registry_path.resolve()
    expected = ("source-vault", "registry.json")
    if resolved.parts[-2:] != expected:
        raise EvidenceBundleError(
            "registry path must resolve to source-vault/registry.json"
        )
    return resolved.parents[1]


def _validated_manifest(
    manifest_path: Path,
    registry_path: Path,
    *,
    allow_candidate_for_development: bool,
) -> tuple[Path, dict[str, Any]]:
    root = _repository_root(registry_path)
    try:
        validate_manifest(manifest_path, registry_path)
    except (PackGateError, OSError, ValueError, json.JSONDecodeError) as exc:
        raise EvidenceBundleError(f"pack validation failed: {exc}") from exc

    try:
        manifest = load_strict_json_file(
            manifest_path,
            label="evidence source manifest",
        )
    except PackSignatureError as exc:
        raise EvidenceBundleError(str(exc)) from exc

    if not isinstance(manifest, dict):
        raise EvidenceBundleError("evidence source manifest must be an object")
    if manifest.get("pack_id") != "quran-core":
        raise EvidenceBundleError("evidence export v1 supports only quran-core")
    if manifest.get("schema_version") not in {2, 3}:
        raise EvidenceBundleError("evidence export requires a provenance-bound pack")

    review_status = manifest.get("review_status")
    if review_status not in {"candidate", "reviewed", "approved"}:
        raise EvidenceBundleError("invalid source pack review status")
    if review_status != "approved" and not allow_candidate_for_development:
        raise EvidenceBundleError(
            "production evidence export requires an approved content pack"
        )
    return root, manifest


def _pack_descriptor(manifest: dict[str, Any]) -> dict[str, Any]:
    descriptor: dict[str, Any] = {
        "pack_id": manifest["pack_id"],
        "schema_version": manifest["schema_version"],
        "content_version": manifest["content_version"],
        "built_sha256": manifest["built_sha256"],
        "review_status": manifest["review_status"],
        "source_id": manifest["source_id"],
        "source_name": manifest["source_name"],
        "source_version": manifest["source_version"],
        "source_sha256": manifest["source_sha256"],
        "source_licence_sha256": manifest["source_licence_sha256"],
        "source_provenance_sha256": manifest["source_provenance_sha256"],
        "edition": manifest.get("edition"),
    }
    canonical = manifest.get("canonical")
    if isinstance(canonical, dict):
        descriptor["canonical"] = {
            "canonical_id": canonical["canonical_id"],
            "canonical_version": canonical["canonical_version"],
            "artifact_sha256": canonical["artifact_sha256"],
        }
    return descriptor


def _validated_citation_ids(citation_ids: list[str]) -> list[str]:
    if not citation_ids:
        raise EvidenceBundleError("at least one citation ID is required")

    seen: set[str] = set()
    validated: list[str] = []
    for raw in citation_ids:
        if raw in seen:
            raise EvidenceBundleError(f"duplicate citation ID: {raw}")
        match = _QURAN_CITATION_RE.fullmatch(raw)
        if match is None:
            raise EvidenceBundleError(f"invalid Quran citation ID: {raw}")
        surah = int(match.group(1))
        ayah = int(match.group(2))
        if surah not in range(1, 115) or ayah < 1:
            raise EvidenceBundleError(f"invalid Quran citation coordinate: {raw}")
        seen.add(raw)
        validated.append(raw)
    return validated


def _artifact_path(root: Path, manifest: dict[str, Any]) -> Path:
    raw = manifest.get("artifact_path")
    if not isinstance(raw, str) or not raw.startswith("content-packs/"):
        raise EvidenceBundleError("manifest artifact_path is invalid")
    artifact = (root / raw).resolve()
    try:
        artifact.relative_to((root / "content-packs").resolve())
    except ValueError as exc:
        raise EvidenceBundleError("content artifact escapes content-packs") from exc
    if not artifact.is_file():
        raise EvidenceBundleError("content artifact is missing")
    return artifact


def _load_quran_records(
    root: Path,
    manifest: dict[str, Any],
    citation_ids: list[str],
) -> list[dict[str, Any]]:
    validated_ids = _validated_citation_ids(citation_ids)
    artifact = _artifact_path(root, manifest)

    placeholders = ",".join("?" for _ in validated_ids)
    uri = f"file:{artifact.as_posix()}?mode=ro"
    try:
        with closing(sqlite3.connect(uri, uri=True)) as connection:
            rows = connection.execute(
                f"""
                SELECT ayah_id, surah, ayah, original_text, source_assertion_id
                FROM quran_ayah
                WHERE ayah_id IN ({placeholders})
                """,
                validated_ids,
            ).fetchall()
    except sqlite3.Error as exc:
        raise EvidenceBundleError("cannot read validated Quran pack") from exc

    by_id = {row[0]: row for row in rows}
    missing = [citation_id for citation_id in validated_ids if citation_id not in by_id]
    if missing:
        raise EvidenceBundleError(
            "citation does not exist in the validated local pack: "
            + ", ".join(missing)
        )

    records: list[dict[str, Any]] = []
    for citation_id in validated_ids:
        ayah_id, surah, ayah, original_text, source_assertion_id = by_id[citation_id]
        expected_id = f"qa:{surah:03d}:{ayah:03d}"
        if ayah_id != expected_id:
            raise EvidenceBundleError(
                f"canonical Quran identity mismatch for {citation_id}"
            )
        text_bytes = original_text.encode("utf-8")
        records.append(
            {
                "citation_id": citation_id,
                "kind": "quran_ayah",
                "display_citation": f"Quran {surah}:{ayah}",
                "surah": surah,
                "ayah": ayah,
                "original_arabic": original_text,
                "source_text_sha256": hashlib.sha256(text_bytes).hexdigest(),
                "source_assertion_id": source_assertion_id,
            }
        )
    return records


def build_quran_evidence_bundle(
    manifest_path: Path,
    registry_path: Path,
    citation_ids: list[str],
    *,
    research_question: str | None = None,
    allow_candidate_for_development: bool = False,
) -> dict[str, Any]:
    root, manifest = _validated_manifest(
        manifest_path,
        registry_path,
        allow_candidate_for_development=allow_candidate_for_development,
    )
    records = _load_quran_records(root, manifest, citation_ids)
    question = research_question.strip() if research_question else None
    if question == "":
        question = None

    return {
        "format": EVIDENCE_BUNDLE_FORMAT,
        "research_question": question,
        "instructions": list(AI_EVIDENCE_INSTRUCTIONS),
        "pack": _pack_descriptor(manifest),
        "scope": {
            "record_kind": "quran_ayah",
            "record_count": len(records),
            "selection_order": "explicit",
        },
        "records": records,
    }


def canonical_evidence_bytes(bundle: dict[str, Any]) -> bytes:
    if bundle.get("format") != EVIDENCE_BUNDLE_FORMAT:
        raise EvidenceBundleError("unsupported evidence bundle format")
    try:
        return canonical_json_bytes(bundle) + b"\n"
    except (PackSignatureError, TypeError, ValueError) as exc:
        raise EvidenceBundleError(f"cannot canonicalize evidence bundle: {exc}") from exc


def evidence_bundle_sha256(bundle: dict[str, Any]) -> str:
    return hashlib.sha256(canonical_evidence_bytes(bundle)).hexdigest()


def render_evidence_text(bundle: dict[str, Any]) -> str:
    digest = evidence_bundle_sha256(bundle)
    pack = bundle["pack"]
    lines = [
        "AARIS EVIDENCE EXPORT v1",
        f"Bundle SHA-256: {digest}",
        f"Pack: {pack['pack_id']} {pack['content_version']}",
        f"Pack SHA-256: {pack['built_sha256']}",
        f"Source: {pack['source_name']} {pack['source_version']}",
        f"Source SHA-256: {pack['source_sha256']}",
        "",
        "Instructions for external AI:",
    ]
    for instruction in bundle["instructions"]:
        lines.append(f"- {instruction}")

    question = bundle.get("research_question")
    if question:
        lines.extend(["", "Research question:", question])

    lines.extend(["", "Evidence:"])
    for record in bundle["records"]:
        lines.extend(
            [
                "",
                f"[{record['citation_id']}] {record['display_citation']}",
                f"Source text SHA-256: {record['source_text_sha256']}",
                record["original_arabic"],
            ]
        )

    lines.extend(
        [
            "",
            "Verification boundary:",
            "Software may verify references and exact local source identity; "
            "it does not verify the reasoning or conclusion.",
            "",
        ]
    )
    return "\n".join(lines)


def write_evidence_bundle(
    bundle: dict[str, Any],
    output_dir: Path,
    *,
    overwrite: bool = False,
) -> dict[str, Path]:
    output_dir = output_dir.resolve()
    paths = {
        "json": output_dir / "evidence.json",
        "text": output_dir / "evidence.txt",
        "checksums": output_dir / "checksums.sha256",
    }
    if output_dir.exists() and not output_dir.is_dir():
        raise EvidenceBundleError("evidence output path is not a directory")
    output_dir.mkdir(parents=True, exist_ok=True)

    existing = [path for path in paths.values() if path.exists()]
    if existing and not overwrite:
        raise EvidenceBundleError(
            "refusing to overwrite existing evidence output: "
            + ", ".join(path.name for path in existing)
        )

    json_bytes = canonical_evidence_bytes(bundle)
    text_bytes = render_evidence_text(bundle).encode("utf-8")
    paths["json"].write_bytes(json_bytes)
    paths["text"].write_bytes(text_bytes)

    checksum_lines = [
        f"{hashlib.sha256(json_bytes).hexdigest()}  evidence.json",
        f"{hashlib.sha256(text_bytes).hexdigest()}  evidence.txt",
    ]
    paths["checksums"].write_text(
        "\n".join(checksum_lines) + "\n",
        encoding="utf-8",
    )
    return paths


def load_evidence_bundle(path: Path) -> dict[str, Any]:
    try:
        value = load_strict_json_file(path, label="evidence bundle")
    except PackSignatureError as exc:
        raise EvidenceBundleError(str(exc)) from exc
    if not isinstance(value, dict):
        raise EvidenceBundleError("evidence bundle root must be an object")
    if value.get("format") != EVIDENCE_BUNDLE_FORMAT:
        raise EvidenceBundleError("unsupported evidence bundle format")
    return value


def _verify_bundle_against_local_pack(
    bundle: dict[str, Any],
    manifest_path: Path,
    registry_path: Path,
    *,
    allow_candidate_for_development: bool,
) -> set[str]:
    root, manifest = _validated_manifest(
        manifest_path,
        registry_path,
        allow_candidate_for_development=allow_candidate_for_development,
    )

    pack = bundle.get("pack")
    if not isinstance(pack, dict) or pack != _pack_descriptor(manifest):
        raise EvidenceBundleError(
            "evidence bundle pack identity does not match the validated local pack"
        )

    records = bundle.get("records")
    if not isinstance(records, list) or not records:
        raise EvidenceBundleError("evidence bundle contains no records")
    scope = bundle.get("scope")
    if not isinstance(scope, dict):
        raise EvidenceBundleError("evidence bundle scope is missing")
    if scope.get("record_kind") != "quran_ayah":
        raise EvidenceBundleError("unsupported evidence record kind")
    if scope.get("record_count") != len(records):
        raise EvidenceBundleError("evidence bundle record count mismatch")

    citation_ids: list[str] = []
    for record in records:
        if not isinstance(record, dict):
            raise EvidenceBundleError("evidence record must be an object")
        citation_id = record.get("citation_id")
        if not isinstance(citation_id, str):
            raise EvidenceBundleError("evidence record citation_id is invalid")
        citation_ids.append(citation_id)

    expected = _load_quran_records(root, manifest, citation_ids)
    if records != expected:
        raise EvidenceBundleError(
            "evidence records do not exactly match the validated local pack"
        )
    return set(citation_ids)


def verify_back(
    bundle: dict[str, Any],
    answer_text: str,
    manifest_path: Path,
    registry_path: Path,
    *,
    expected_bundle_sha256: str | None = None,
    allow_candidate_for_development: bool = False,
) -> dict[str, Any]:
    digest = evidence_bundle_sha256(bundle)
    if expected_bundle_sha256 is not None:
        if not _SHA256_RE.fullmatch(expected_bundle_sha256):
            raise EvidenceBundleError("expected bundle SHA-256 is malformed")
        if digest != expected_bundle_sha256:
            raise EvidenceBundleError("evidence bundle SHA-256 does not match the expected export")

    exported_ids = _verify_bundle_against_local_pack(
        bundle,
        manifest_path,
        registry_path,
        allow_candidate_for_development=allow_candidate_for_development,
    )

    tokens = _BRACKET_TOKEN_RE.findall(answer_text)
    malformed_quran_tokens = [
        token for token in tokens if token.startswith("qa") and _QURAN_CITATION_RE.fullmatch(token) is None
    ]
    if malformed_quran_tokens:
        raise EvidenceBundleError(
            "answer contains malformed Quran citation IDs: "
            + ", ".join(sorted(set(malformed_quran_tokens)))
        )

    cited_ids = [
        token for token in tokens if _QURAN_CITATION_RE.fullmatch(token) is not None
    ]
    if not cited_ids:
        raise EvidenceBundleError("answer contains no verifiable Quran citation IDs")

    outside_scope = sorted(set(cited_ids) - exported_ids)
    if outside_scope:
        raise EvidenceBundleError(
            "answer cites valid local references outside the exported evidence scope: "
            + ", ".join(outside_scope)
        )

    return {
        "status": "references-verified",
        "message": "References verified",
        "bundle_sha256": digest,
        "citation_ids": list(dict.fromkeys(cited_ids)),
        "issues": [],
        "conclusion_verified": False,
    }


def _default_paths() -> tuple[Path, Path]:
    root = Path(__file__).resolve().parents[1]
    return (
        root / "content-packs" / "quran-core" / "1.1.0" / "manifest.json",
        root / "source-vault" / "registry.json",
    )


def _build_parser() -> argparse.ArgumentParser:
    default_manifest, default_registry = _default_paths()
    parser = argparse.ArgumentParser(
        description="Export and locally verify source-faithful Quran evidence."
    )
    parser.add_argument(
        "--manifest",
        type=Path,
        default=default_manifest,
        help="provenance-bound quran-core manifest",
    )
    parser.add_argument(
        "--registry",
        type=Path,
        default=default_registry,
        help="Source Vault registry",
    )
    subparsers = parser.add_subparsers(dest="command", required=True)

    export = subparsers.add_parser("export")
    export.add_argument("--out", type=Path, required=True)
    export.add_argument(
        "--citation",
        action="append",
        required=True,
        dest="citations",
        help="canonical Quran citation ID; repeat for multiple records",
    )
    export.add_argument("--question")
    export.add_argument("--overwrite", action="store_true")
    export.add_argument("--allow-candidate-for-development", action="store_true")

    verify = subparsers.add_parser("verify")
    verify.add_argument("--bundle", type=Path, required=True)
    verify.add_argument(
        "--answer",
        type=Path,
        required=True,
        help="UTF-8 external-AI answer containing bracketed citation IDs",
    )
    verify.add_argument("--expected-bundle-sha256")
    verify.add_argument("--allow-candidate-for-development", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "export":
            bundle = build_quran_evidence_bundle(
                args.manifest,
                args.registry,
                args.citations,
                research_question=args.question,
                allow_candidate_for_development=args.allow_candidate_for_development,
            )
            paths = write_evidence_bundle(
                bundle,
                args.out,
                overwrite=args.overwrite,
            )
            report = {
                "status": "exported",
                "bundle_sha256": evidence_bundle_sha256(bundle),
                "record_count": len(bundle["records"]),
                "files": {key: str(path) for key, path in paths.items()},
            }
        else:
            bundle = load_evidence_bundle(args.bundle)
            try:
                answer_text = args.answer.read_text(encoding="utf-8")
            except (OSError, UnicodeDecodeError) as exc:
                raise EvidenceBundleError("cannot read external-AI answer") from exc
            report = verify_back(
                bundle,
                answer_text,
                args.manifest,
                args.registry,
                expected_bundle_sha256=args.expected_bundle_sha256,
                allow_candidate_for_development=args.allow_candidate_for_development,
            )
    except (EvidenceBundleError, OSError) as exc:
        print(f"Evidence bundle FAILED: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(report, ensure_ascii=False, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
