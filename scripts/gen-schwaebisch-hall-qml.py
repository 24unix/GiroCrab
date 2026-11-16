#!/usr/bin/env python3
"""Copies the browser scripts of SchwaebischHallUI.swift (SchwaebischHallScripts) into
GiroCrabLinux/qml/SchwaebischHallWebLoginFlow.qml, between the "BEGIN generated" and
"END generated" markers, as JavaScript template literals.

Run after changing the Swift scripts:  python3 -I scripts/gen-schwaebisch-hall-qml.py
scripts/test-schwaebisch-hall-portal.cjs (CI) fails while both differ.
"""
import pathlib
import re

ROOT = pathlib.Path(__file__).resolve().parent.parent
SWIFT = ROOT / "GiroCrabApp/Sources/GiroCrabUI/SchwaebischHallUI.swift"
QML = ROOT / "GiroCrabLinux/qml/SchwaebischHallWebLoginFlow.qml"
NAMES = ["prelude", "probe", "snapshot", "documents", "pdf"]
BEGIN, END = "    // BEGIN generated: SchwaebischHallScripts", "    // END generated"


def swift_scripts():
    scripts = {}
    for m in re.finditer(r'static let (\w+) = #"""\n([\s\S]*?)\n    """#', SWIFT.read_text()):
        # Swift strips the closing delimiter's indentation (4 spaces) from every line.
        lines = m.group(2).split("\n")
        scripts[m.group(1)] = "\n".join(l[4:] if l.startswith("    ") else l.lstrip(" ") for l in lines)
    missing = set(NAMES) - set(scripts)
    if missing:
        raise SystemExit(f"{SWIFT.name}: scripts not found: {sorted(missing)}")
    return scripts


def template_literal(s):
    return s.replace("\\", "\\\\").replace("`", "\\`").replace("${", "\\${")


def main():
    scripts = swift_scripts()
    block = "\n".join(f"    readonly property string {n}: `{template_literal(scripts[n])}`" for n in NAMES)
    text = QML.read_text()
    i, j = text.index(BEGIN), text.index(END)
    QML.write_text(text[:i] + BEGIN + " (SchwaebischHallUI.swift)\n" + block + "\n" + text[j:])
    print(f"updated {QML.relative_to(ROOT)}")


if __name__ == "__main__":
    main()
