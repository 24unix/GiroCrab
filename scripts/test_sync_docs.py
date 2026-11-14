"""Tests for scripts/sync_docs.py: python3 -m unittest scripts/test_sync_docs.py"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync_docs as sd  # noqa: E402

CATALOG = '''
pub const BANK_MATRIX: &[MatrixEntry] = &[
    MatrixEntry {
        name: "Volksbank X",
        kind: Some(ConnectorKind::A),
        interface: Interface::Fints,
        capabilities: &[Capability::Transactions, Capability::Balances, Capability::Transfers],
        status: Status::Verified,
        issues: &[],
    },
    MatrixEntry {
        name: "ING",
        kind: None,
        interface: Interface::Fints,
        capabilities: &[Capability::Transactions],
        status: Status::TestingWanted,
        issues: &[313],
    },
    MatrixEntry {
        name: "Amazon Bestellungen",
        kind: Some(ConnectorKind::C),
        interface: Interface::WebPortal,
        capabilities: &[Capability::Transactions],
        status: Status::Limited,
        issues: &[1, 2],
    },
];
'''
BLK = f"{sd.START}old{sd.END}"


class SyncDocs(unittest.TestCase):
    def test_parse_matrix(self):
        m = sd.parse_matrix(CATALOG)
        self.assertEqual([e["name"] for e in m], ["Volksbank X", "ING", "Amazon Bestellungen"])
        self.assertEqual(m[0]["capabilities"], ["Transactions", "Balances", "Transfers"])
        self.assertEqual((m[1]["status"], m[1]["issues"]), ("TestingWanted", [313]))
        self.assertEqual(m[2]["issues"], [1, 2])

    def test_parse_matrix_rejects_unknown_values(self):
        with self.assertRaises(SystemExit):
            sd.parse_matrix(CATALOG.replace("Status::Verified", "Status::Bogus"))

    def test_matrix_markdown(self):
        m = sd.parse_matrix(CATALOG)
        de = sd.matrix_text("de", m, 2010)
        self.assertIn("| Volksbank X | FinTS 3.0 | ✓ | ✓ | – | ✓ | – | – | ✅ Verifiziert |", de)
        self.assertIn("🧪 Test gesucht [#313](https://github.com/GiroCrab/GiroCrab/issues/313)", de)
        self.assertIn("2.010 Institute", de)
        en = sd.matrix_text("en", m, 2010)
        self.assertIn("| Amazon orders | Web-Portal |", en)
        self.assertIn("⚠️ Limited [#1](", en)
        self.assertIn("2,010 institutions", en)
        self.assertEqual(de.count("\n|"), len(m) + 1)  # header + separator + rows

    def test_matrix_html_is_inert(self):
        m = sd.parse_matrix(CATALOG.replace("Volksbank X", "A <b>&</b>"))
        out = sd.matrix_text("de", m, 1, "html")
        self.assertIn("A &lt;b&gt;&amp;&lt;/b&gt;", out)
        self.assertIn('<a href="https://github.com/GiroCrab/GiroCrab/issues/313">#313</a>', out)
        for banned in ("<script", " style=", " onclick=", "javascript:"):
            self.assertNotIn(banned, out)

    def test_matrix_sorts_within_interface_groups_for_markdown_and_html(self):
        matrix = sd.parse_matrix(CATALOG)
        # Interleave interfaces to verify grouping, and use mixed case names.
        extra = dict(matrix[0], name="alpha Bank")
        matrix = [matrix[0], matrix[2], matrix[1], extra]
        original_order = [e["name"] for e in matrix]
        for fmt in ("md", "html"):
            for lang in ("de", "en"):
                out = sd.matrix_text(lang, matrix, 1, fmt)
                names = ["alpha Bank", "ING", "Volksbank X", sd.NAMES[lang].get("Amazon Bestellungen", "Amazon Bestellungen")]
                offsets = [out.index(name) for name in names]
                self.assertEqual(offsets, sorted(offsets))
        self.assertEqual([e["name"] for e in matrix], original_order)

    def test_fints_count_ignores_comments(self):
        self.assertEqual(sd.fints_count("# c\n\n1\ta\tu\n2\tb\tu\n"), 2)

    def test_version_only_touches_known_patterns(self):
        t = "alt v0.6.1 · Apple Silicon (.dmg) · ✓ Version v0.6.1\nAktuelle Version: **v0.6.1**. Neu in v0.6.1 bleibt"
        out = sd.replace_version(t, "v0.7.0")
        self.assertEqual(out.count("v0.7.0"), 3)
        self.assertIn("Neu in v0.6.1 bleibt", out)

    def test_block_replace_idempotent(self):
        once, n = sd.replace_block(f"a {BLK} b", lambda m: "X")
        twice, _ = sd.replace_block(once, lambda m: "X")
        self.assertEqual((once, n), (twice, 1))

    def test_readme_end_to_end_idempotent(self):
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            (root / "girocrab-core/src/connectors").mkdir(parents=True)
            (root / "girocrab-core/data").mkdir()
            (root / "docs/assets").mkdir(parents=True)
            (root / "girocrab-core/src/connectors/catalog.rs").write_text(CATALOG)
            (root / "girocrab-core/data/fints_directory.tsv").write_text("1\ta\tu\n")
            (root / "docs/assets/download-macos.svg").write_text("v0.1.0 · Apple Silicon")
            readme = root / "README.md"
            readme.write_text(f"{BLK}\n{BLK}\nAktuelle Version: **v0.1.0**")
            sd.run_readme(root, "v0.2.0")
            first = readme.read_text()
            sd.run_readme(root, "v0.2.0")
            self.assertEqual(first, readme.read_text())
            self.assertIn("v0.2.0", first)
            self.assertIn("| Volksbank X | FinTS 3.0 |", first)
            self.assertIn("| Amazon orders | Web-Portal |", first)


if __name__ == "__main__":
    unittest.main()
