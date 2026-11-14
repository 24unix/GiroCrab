#!/usr/bin/env python3
"""Transforms behind scripts/sync-docs-and-website.sh (pure file edits, no git/network).

  sync_docs.py readme  <repo-root> --version vX.Y.Z   # README.md + docs/assets/download-macos.svg
  sync_docs.py site    <repo-root> <site-dir> --version vX.Y.Z

Only machine-derivable facts are rewritten; all prose stays untouched:
  * version strings (download button alt text / SVG, "Version vX", "Aktuelle Version", meta description)
  * the block between `<!-- sync:connectors:start -->` and `<!-- sync:connectors:end -->`
    (README DE/EN, website FAQ), derived from girocrab-core/src/connectors/catalog.rs and
    girocrab-core/data/fints_directory.tsv.
Idempotent: a second run changes nothing.
"""
import argparse
import re
import sys
from pathlib import Path

VERSION_RE = re.compile(r"^v\d+\.\d+\.\d+$")

# catalog.rs names that go through tr(): English wording for the EN README block.
EN_NAMES = {
    "Amazon Bestellungen": "Amazon orders",
    "Bank per PSD2 (Enable Banking)": "Enable Banking (PSD2)",
}
DE_NAMES = {"Bank per PSD2 (Enable Banking)": "Enable Banking (PSD2)"}

START, END = "<!-- sync:connectors:start -->", "<!-- sync:connectors:end -->"


def parse_catalog(text):
    """-> [(name, protocol)] for every `descriptor` arm in catalog.rs."""
    out = []
    for block in re.split(r"ConnectorKind::\w+ => BankDescriptor \{", text)[1:]:
        name = re.search(r'name:\s*(?:tr\()?"([^"]+)"', block)
        proto = re.search(r'protocol:\s*(?:tr\()?"([^"]+)"', block)
        if name and proto:
            out.append((name.group(1), proto.group(1)))
    return out


def direct_connectors(catalog):
    """Names of connectors that are not plain FinTS entries (those are covered by the FinTS directory)."""
    return [n for n, p in catalog if not p.startswith("FinTS")]


def fints_count(tsv_text):
    return sum(1 for l in tsv_text.splitlines() if l.strip() and not l.startswith("#"))


def join(items, last):
    return items[0] if len(items) == 1 else ", ".join(items[:-1]) + f" {last} " + items[-1]


def connector_text(lang, names, n_fints):
    if lang == "en":
        items = [EN_NAMES.get(n, n) for n in names]
        return (f"Direct connectors in the catalog: {join(items, 'and')}; "
                f"plus {n_fints:,} institutions in the FinTS directory.")
    items = [DE_NAMES.get(n, n) for n in names]
    de_n = f"{n_fints:,}".replace(",", ".")
    return (f"Direkte Konnektoren im Katalog: {join(items, 'und')}; "
            f"dazu {de_n} Institute im FinTS-Verzeichnis.")


def replace_block(text, new_inner):
    """Replace the content of every marker block; keeps the markers. Returns (text, n_blocks)."""
    pat = re.compile(re.escape(START) + r".*?" + re.escape(END), re.S)
    return pat.subn(lambda m: f"{START}{new_inner(m)}{END}", text)


def replace_version(text, version):
    """Version strings only; patterns are specific so prose is never touched."""
    subs = [
        (r"v\d+\.\d+\.\d+( · Apple Silicon)", rf"{version}\1"),
        (r"(✓ Version )v\d+\.\d+\.\d+", rf"\g<1>{version}"),
        (r"(Aktuelle Version: \*\*)v\d+\.\d+\.\d+(\*\*)", rf"\g<1>{version}\2"),
        (r"(Current version: \*\*)v\d+\.\d+\.\d+(\*\*)", rf"\g<1>{version}\2"),
        (r"(GiroCrab )v\d+\.\d+\.\d+( ist die freie)", rf"\g<1>{version}\2"),
    ]
    for pat, rep in subs:
        text = re.sub(pat, rep, text)
    return text


def read_facts(root):
    cat = parse_catalog((root / "girocrab-core/src/connectors/catalog.rs").read_text())
    names = direct_connectors(cat)
    if not names:
        sys.exit("error: no connectors parsed from catalog.rs (format changed?)")
    n = fints_count((root / "girocrab-core/data/fints_directory.tsv").read_text())
    return names, n


def edit(path, fn):
    old = path.read_text()
    new = fn(old)
    if new != old:
        path.write_text(new)
        print(f"updated {path}")
    return new != old


def run_readme(root, version):
    names, n = read_facts(root)

    def fix(text):
        text = replace_version(text, version)
        # Two blocks in README order: DE first, EN second.
        langs = iter(["de", "en"])
        text, k = replace_block(text, lambda m: f"\n{connector_text(next(langs, 'en'), names, n)}\n")
        if k != 2:
            sys.exit(f"error: README.md needs exactly 2 sync:connectors blocks (DE, EN), found {k}")
        return text

    edit(root / "README.md", fix)
    edit(root / "docs/assets/download-macos.svg", lambda t: replace_version(t, version))


def run_site(root, site, version):
    names, n = read_facts(root)

    def fix(text):
        text = replace_version(text, version)
        text, k = replace_block(text, lambda m: connector_text("de", names, n))
        if k < 1:
            sys.exit("error: index.html has no sync:connectors block")
        return text

    edit(site / "index.html", fix)
    edit(site / "img/download-macos.svg", lambda t: replace_version(t, version))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["readme", "site"])
    ap.add_argument("root", type=Path)
    ap.add_argument("site", type=Path, nargs="?")
    ap.add_argument("--version", required=True)
    a = ap.parse_args()
    if not VERSION_RE.match(a.version):
        sys.exit(f"error: version must look like v1.2.3, got {a.version!r}")
    if a.mode == "readme":
        run_readme(a.root, a.version)
    else:
        if not a.site:
            sys.exit("error: site mode needs <site-dir>")
        run_site(a.root, a.site, a.version)


if __name__ == "__main__":
    main()
