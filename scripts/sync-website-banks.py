#!/usr/bin/env python3
"""Regenerate the bank table of the website from the codebase.

  python3 scripts/sync-website-banks.py [path/to/girocrab.de/index.html]

Source of truth: `BANK_MATRIX` in girocrab-core/src/connectors/catalog.rs (interface,
capabilities, test status, linked GitHub issues such as #313/#156/#45/#289) and the
institute count of girocrab-core/data/fints_directory.tsv. Only the content between
`<!-- BEGIN GENERATED BANKS TABLE -->` and `<!-- END GENERATED BANKS TABLE -->` is rewritten.
The filter input and js/bank-filter.js live outside that block. Idempotent.
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(Path(__file__).resolve().parent))
import sync_docs as sd  # noqa: E402


def main():
    index = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT.parent / "girocrab.de" / "index.html"
    if not index.is_file():
        sys.exit(f"error: {index} not found")
    matrix, n = sd.read_facts(ROOT)
    text = index.read_text()
    new, k = sd.replace_block(text, lambda m: f"\n{sd.matrix_text('de', matrix, n, 'html')}\n",
                              sd.SITE_START, sd.SITE_END)
    if k != 1:
        sys.exit(f"error: expected exactly 1 generated-banks block in {index}, found {k}")
    if new != text:
        index.write_text(new)
        print(f"updated {index} ({len(matrix)} entries)")
    else:
        print("already up to date")


if __name__ == "__main__":
    main()
