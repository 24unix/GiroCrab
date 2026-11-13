#!/usr/bin/env python3
"""Canonical form and merge driver for the String Catalogs (GitHub #271).

The catalogs are kept sorted by key: new keys then land all over the file
instead of at its end, so parallel PRs rarely touch the same lines. The
canonical form is exactly what GiroCrabApp/Tools/update-localizations.sh
writes (keep `dump` and that script in sync).

  scripts/xcstrings.py check  [catalog…]   exit 1 if a catalog is not canonical
  scripts/xcstrings.py format [catalog…]   rewrite the catalogs in canonical form
  scripts/xcstrings.py merge %O %A %B      git merge driver (see .gitattributes)

Without arguments `check`/`format` cover GiroCrabApp/Xcode/App/*.xcstrings.

The merge driver merges base/ours/theirs per JSON key instead of per line, so
only a key that both sides changed differently is a conflict. Register it once
per clone (the hooks in .githooks do it too):
  git config merge.xcstrings.driver 'scripts/xcstrings.py merge %O %A %B'
"""
import glob
import json
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MISSING = object()


def dump(catalog):
    return json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : ")) + "\n"


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def merge3(base, ours, theirs):
    """Three-way merge of JSON values. Returns (base, ours, theirs) views that
    are identical wherever the merge is clean and differ only at conflicts."""
    if ours == theirs or theirs == base:
        return ours, ours, ours
    if ours == base:
        return theirs, theirs, theirs
    if isinstance(ours, dict) and isinstance(theirs, dict) and (base is MISSING or isinstance(base, dict)):
        base = {} if base is MISSING else base
        views = ({}, {}, {})
        for key in base.keys() | ours.keys() | theirs.keys():
            merged = merge3(base.get(key, MISSING), ours.get(key, MISSING), theirs.get(key, MISSING))
            for view, value in zip(views, merged):
                if value is not MISSING:
                    view[key] = value
        return views
    return base, ours, theirs


def merge(base_path, ours_path, theirs_path):
    try:
        versions = [json.loads(read(p)) for p in (base_path, ours_path, theirs_path)]
    except ValueError:
        # Not JSON (e.g. the catalog is new on both sides): plain text merge.
        return subprocess.call(["git", "merge-file", ours_path, base_path, theirs_path])
    base, ours, theirs = merge3(*versions)
    if ours == theirs:
        write(ours_path, dump(ours))
        return 0
    # Conflict markers around the conflicting keys only: the three views agree everywhere else.
    with tempfile.TemporaryDirectory() as tmp:
        base_view, theirs_view = os.path.join(tmp, "base"), os.path.join(tmp, "theirs")
        write(base_view, dump(base))
        write(theirs_view, dump(theirs))
        write(ours_path, dump(ours))
        subprocess.call(["git", "merge-file", "-L", "ours", "-L", "base", "-L", "theirs",
                         ours_path, base_view, theirs_view])
    return 1


def main(argv):
    if len(argv) == 5 and argv[1] == "merge":
        return merge(*argv[2:])
    if len(argv) < 2 or argv[1] not in ("check", "format"):
        print(__doc__, file=sys.stderr)
        return 2
    paths = argv[2:] or sorted(glob.glob(os.path.join(ROOT, "GiroCrabApp/Xcode/App/*.xcstrings")))
    stale = []
    for path in paths:
        text = read(path)
        canonical = dump(json.loads(text))
        if text != canonical:
            stale.append(path)
            if argv[1] == "format":
                write(path, canonical)
    if argv[1] == "check" and stale:
        print("String Catalog nicht sortiert/kanonisch – scripts/xcstrings.py format ausführen:", file=sys.stderr)
        for path in stale:
            print("  " + os.path.relpath(path, ROOT), file=sys.stderr)
        return 1
    print(f"xcstrings: {len(paths)} Kataloge ok" if argv[1] == "check" else f"xcstrings: {len(stale)} Kataloge neu geschrieben")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
