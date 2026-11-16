#!/usr/bin/env python3
"""Lists Linux UI texts without English and exits non-zero if there are any.

The English UI takes its texts from the Mac app's string catalog
(GiroCrabApp/Xcode/App/Localizable.xcstrings) and from i18n/en-linux.json, the same way
build.rs does. Texts are collected from `qsTr("…")` in qml/ and qml-optional/,
`QCoreApplication::translate("…", "…")` in cpp/ and `tr("…")` in src/.

Usage: python3 -I GiroCrabLinux/scripts/i18n-report.py [--verbose]
"""
import json
import pathlib
import re
import sys

LINUX = pathlib.Path(__file__).resolve().parent.parent
CATALOG = LINUX.parent / "GiroCrabApp/Xcode/App/Localizable.xcstrings"
OWN = LINUX / "i18n/en-linux.json"

# build.rs `qt_placeholders`: %1$@ → %1, otherwise numbered in order; %% → %.
SWIFT_PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?(@|lld|llu|ld|lu|d|i|u|f)|%%")


def qt_placeholders(s):
    count = 0

    def repl(m):
        nonlocal count
        if m.group(0) == "%%":
            return "%"
        count += 1
        return "%" + (m.group(1) or str(count))
    return SWIFT_PLACEHOLDER.sub(repl, s)


def unit(v):
    if "stringUnit" in v:
        return v["stringUnit"]["value"]
    return v["variations"]["plural"]["other"]["stringUnit"]["value"]


def catalog_english():
    out = {}
    for key, entry in json.loads(CATALOG.read_text())["strings"].items():
        # no `localizations`: "shouldTranslate": false or not translated yet (as build.rs)
        en = entry.get("localizations", {}).get("en")
        if en is None:
            continue
        value = unit(en)
        for name, sub in en.get("substitutions", {}).items():
            form = unit(sub).replace("%arg", "%{}${}".format(sub["argNum"], sub.get("formatSpecifier", "@")))
            value = value.replace("%#@" + name + "@", form)
        key, value = qt_placeholders(key), qt_placeholders(value)
        if "&" in key:
            out.setdefault(key.replace("&", "&&"), value.replace("&", "&&"))
        out.setdefault(key, value)
    return out


LITERAL = r'"((?:[^"\\]|\\[\s\S])*)"'
SOURCES = [
    ("qml", "*.qml", re.compile(r"\bqsTr\(\s*" + LITERAL)),
    ("qml-optional", "*.qml", re.compile(r"\bqsTr\(\s*" + LITERAL)),
    ("cpp", "*.cpp", re.compile(r"QCoreApplication::translate\(\s*" + LITERAL + r"\s*,\s*" + LITERAL)),
    ("src", "*.rs", re.compile(r"\btr\(\s*" + LITERAL)),
]


def ui_texts():
    texts = {}
    for folder, pattern, regex in SOURCES:
        for path in sorted((LINUX / folder).glob(pattern)):
            for m in regex.finditer(path.read_text()):
                raw = m.group(m.lastindex)
                # Rust: a backslash at the end of a line continues the string without
                # the line break and the next line's indentation.
                raw = re.sub(r"\\\n\s*", "", raw)
                text = json.loads('"' + raw + '"')
                texts.setdefault(text, "{}/{}".format(folder, path.name))
    return texts


def main():
    verbose = "--verbose" in sys.argv
    catalog = catalog_english()
    own = json.loads(OWN.read_text())
    texts = ui_texts()
    missing = sorted((t, f) for t, f in texts.items() if t not in own and t not in catalog)
    from_catalog = sum(1 for t in texts if t in catalog and t not in own)
    from_own = sum(1 for t in texts if t in own)
    unused = sorted(k for k in own if k not in texts)
    print("{} UI texts: {} from Localizable.xcstrings, {} from i18n/en-linux.json, {} without English"
          .format(len(texts), from_catalog, from_own, len(missing)))
    for key in unused:
        print("warning: i18n/en-linux.json: unused entry {!r}".format(key))
    if verbose:
        for key in sorted(k for k in own if k in catalog and own[k] == catalog[k]):
            print("note: i18n/en-linux.json repeats the catalog: {!r}".format(key))
    for text, where in missing:
        print("missing English ({}): {!r}".format(where, text))
    if missing:
        print("Add the English to GiroCrabLinux/i18n/en-linux.json (German → English, %1 … as in the source).")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
