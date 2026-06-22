#!/usr/bin/env python3
"""Audit bundled Keyboard Switcher dictionary resources.

This script is intentionally read-only. It verifies that automatic, manual,
short-word, and technical dictionary layers remain separated.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import sys


REPO_ROOT = Path(__file__).resolve().parents[1]
RESOURCES = REPO_ROOT / "KeyboardSwitcher" / "Resources"


@dataclass(frozen=True)
class WordSet:
    name: str
    path: Path
    words: set[str]
    rows: int
    bytes: int


def normalize(word: str) -> str:
    return word.strip().lower().replace("ё", "е")


def read_frequency_tsv(resource_name: str) -> WordSet:
    path = RESOURCES / resource_name
    lines = path.read_text(encoding="utf-8").splitlines()
    words: set[str] = set()
    duplicate_rows = 0
    for line in lines[1:]:
        if not line.strip():
            continue
        word = normalize(line.split("\t", 1)[0])
        if not word:
            continue
        if word in words:
            duplicate_rows += 1
        words.add(word)
    if duplicate_rows:
        raise AssertionError(f"{resource_name} contains {duplicate_rows} duplicate rows")
    return WordSet(resource_name, path, words, max(0, len(lines) - 1), path.stat().st_size)


def read_short_whitelist(language_code: str) -> WordSet:
    path = RESOURCES / "short_words_auto_whitelist.tsv"
    lines = path.read_text(encoding="utf-8").splitlines()
    words: set[str] = set()
    duplicate_rows = 0
    for line in lines[1:]:
        if not line.strip():
            continue
        columns = line.split("\t")
        if len(columns) < 2 or columns[0] != language_code:
            continue
        word = normalize(columns[1])
        if word in words:
            duplicate_rows += 1
        words.add(word)
    if duplicate_rows:
        raise AssertionError(f"short_words_auto_whitelist.tsv:{language_code} contains {duplicate_rows} duplicate rows")
    return WordSet(f"short_words_auto_whitelist.tsv:{language_code}", path, words, len(words), path.stat().st_size)


def read_technical_exact_words() -> WordSet:
    path = RESOURCES / "technical_never_correct.tsv"
    lines = path.read_text(encoding="utf-8").splitlines()
    words: set[str] = set()
    duplicate_rows = 0
    for line in lines[1:]:
        if not line.strip():
            continue
        columns = line.split("\t")
        if len(columns) < 4 or columns[3] != "exact_or_case_preserving":
            continue
        word = normalize(columns[1])
        if word in words:
            duplicate_rows += 1
        words.add(word)
    if duplicate_rows:
        raise AssertionError("technical_never_correct.tsv contains duplicate exact rows")
    return WordSet("technical_never_correct.tsv:exact", path, words, len(words), path.stat().st_size)


def technical_regex_rule_count() -> int:
    path = RESOURCES / "technical_never_correct.tsv"
    lines = path.read_text(encoding="utf-8").splitlines()
    return sum(
        1
        for line in lines[1:]
        if line.strip() and len(line.split("\t")) >= 4 and line.split("\t")[3] == "regex"
    )


def assert_disjoint(left: WordSet, right: WordSet, *, required: bool = True) -> None:
    overlap = left.words & right.words
    if overlap and required:
        sample = ", ".join(sorted(overlap)[:12])
        raise AssertionError(f"{left.name} overlaps {right.name}: {len(overlap)} words; sample: {sample}")
    print(f"{left.name} ∩ {right.name}: {len(overlap)}")


def print_summary(items: list[WordSet]) -> None:
    print("Dictionary resource summary")
    print("===========================")
    for item in items:
        print(f"{item.name}: rows={item.rows:,} unique={len(item.words):,} size={item.bytes / 1024 / 1024:.2f} MB")
    total_bytes = sum({item.path: item.bytes for item in items}.values())
    print(f"Total audited resource size: {total_bytes / 1024 / 1024:.2f} MB")
    print()


def main() -> int:
    ru_auto = read_frequency_tsv("ru_auto_core_100k.tsv")
    ru_manual = read_frequency_tsv("ru_manual_extended_300k.tsv")
    en_auto = read_frequency_tsv("en_auto_core_50k.tsv")
    en_manual = read_frequency_tsv("en_manual_extended_200k.tsv")
    ru_short = read_short_whitelist("ru")
    en_short = read_short_whitelist("en")
    technical = read_technical_exact_words()
    regex_rule_count = technical_regex_rule_count()

    print_summary([ru_auto, ru_manual, en_auto, en_manual, ru_short, en_short, technical])
    print(f"technical_never_correct.tsv:regex rules={regex_rule_count:,}")
    print()

    assert_disjoint(ru_manual, ru_auto)
    assert_disjoint(ru_manual, ru_short)
    assert_disjoint(en_manual, en_auto)
    assert_disjoint(en_manual, en_short)
    assert_disjoint(technical, ru_auto, required=False)
    assert_disjoint(technical, ru_manual, required=False)
    assert_disjoint(technical, en_auto, required=False)
    assert_disjoint(technical, en_manual, required=False)

    print("\nDictionary audit passed.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except AssertionError as error:
        print(f"Dictionary audit failed: {error}", file=sys.stderr)
        raise SystemExit(1)
