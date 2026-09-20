#!/usr/bin/env python3
"""Compile the SQLite schemas in memory and run structural integrity probes."""
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[1]


def validate_schema(path: Path) -> None:
    connection = sqlite3.connect(":memory:")
    try:
        connection.executescript(path.read_text(encoding="utf-8"))
        violations = connection.execute("PRAGMA foreign_key_check").fetchall()
        if violations:
            raise RuntimeError(f"{path.name}: foreign-key violations: {violations}")
    finally:
        connection.close()


if __name__ == "__main__":
    validate_schema(ROOT / "schemas" / "content_v1.sql")
    validate_schema(ROOT / "schemas" / "user_v1.sql")
    print("SQLite schemas: PASS")
