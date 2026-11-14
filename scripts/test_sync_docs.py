"""Tests for scripts/sync_docs.py: python3 -m unittest scripts/test_sync_docs.py"""
import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import sync_docs as sd  # noqa: E402

CATALOG = '''
ConnectorKind::A => BankDescriptor { name: "Volksbank X".into(), protocol: "FinTS 3.0 PIN/TAN".into(), }
ConnectorKind::B => BankDescriptor { name: "bunq".into(), protocol: tr("bunq Public API").into(), }
ConnectorKind::C => BankDescriptor { name: tr("Amazon Bestellungen").into(), protocol: tr("Web").into(), }
'''
BLK = f"{sd.START}old{sd.END}"


class SyncDocs(unittest.TestCase):
    def test_catalog_skips_fints(self):
        names = sd.direct_connectors(sd.parse_catalog(CATALOG))
        self.assertEqual(names, ["bunq", "Amazon Bestellungen"])

    def test_fints_count_ignores_comments(self):
        self.assertEqual(sd.fints_count("# c\n\n1\ta\tu\n2\tb\tu\n"), 2)

    def test_version_only_touches_known_patterns(self):
        t = "alt v0.6.1 · Apple Silicon (.dmg) · ✓ Version v0.6.1\nAktuelle Version: **v0.6.1**. Neu in v0.6.1 bleibt"
        out = sd.replace_version(t, "v0.7.0")
        self.assertEqual(out.count("v0.7.0"), 3)
        self.assertIn("Neu in v0.6.1 bleibt", out)

    def test_connector_text_languages(self):
        self.assertIn("Amazon orders", sd.connector_text("en", ["Amazon Bestellungen"], 2010))
        self.assertIn("2.010 Institute", sd.connector_text("de", ["bunq"], 2010))

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
            self.assertIn("Direkte Konnektoren", first)
            self.assertIn("Direct connectors", first)


if __name__ == "__main__":
    unittest.main()
