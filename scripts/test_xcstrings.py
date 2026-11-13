"""Tests for the String Catalog merge driver: python3 -m unittest scripts/test_xcstrings.py"""
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import xcstrings  # noqa: E402


def catalog(**strings):
    return {"sourceLanguage": "de", "strings": {k: entry(v) for k, v in strings.items()}, "version": "1.0"}


def entry(en):
    return {"extractionState": "manual",
            "localizations": {"en": {"stringUnit": {"state": "translated", "value": en}}}}


class MergeDriverTests(unittest.TestCase):
    def run_merge(self, base, ours, theirs):
        """Runs the driver like git does; returns (exit code, content of %A)."""
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for name, content in (("base", base), ("ours", ours), ("theirs", theirs)):
                paths.append(os.path.join(tmp, name))
                # Unsorted on purpose: the driver must not depend on the input order.
                text = content if isinstance(content, str) else json.dumps(content, ensure_ascii=False)
                xcstrings.write(paths[-1], text)
            code = xcstrings.merge(*paths)
            return code, xcstrings.read(paths[1])

    def test_both_sides_add_keys(self):
        code, text = self.run_merge(catalog(Konto="Account"),
                                    catalog(Konto="Account", Zahlung="Payment"),
                                    catalog(Konto="Account", Übertrag="Carry-over", Bank="Bank"))
        self.assertEqual(code, 0)
        self.assertEqual(text, xcstrings.dump(catalog(Bank="Bank", Konto="Account", Zahlung="Payment",
                                                      Übertrag="Carry-over")))

    def test_delete_and_edit_of_different_keys(self):
        code, text = self.run_merge(catalog(A="a", B="b", C="c"), catalog(A="a", C="c"), catalog(A="a", B="b", C="c2"))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(text), catalog(A="a", C="c2"))

    def test_same_key_added_identically(self):
        code, text = self.run_merge(catalog(), catalog(Neu="New"), catalog(Neu="New"))
        self.assertEqual(code, 0)
        self.assertEqual(json.loads(text), catalog(Neu="New"))

    def test_different_languages_of_one_key(self):
        base, ours, theirs = catalog(Konto="Account"), catalog(Konto="Account"), catalog(Konto="Account")
        ours["strings"]["Konto"]["localizations"]["fr"] = {"stringUnit": {"state": "translated", "value": "Compte"}}
        theirs["strings"]["Konto"]["localizations"]["es"] = {"stringUnit": {"state": "translated", "value": "Cuenta"}}
        code, text = self.run_merge(base, ours, theirs)
        self.assertEqual(code, 0)
        self.assertEqual(sorted(json.loads(text)["strings"]["Konto"]["localizations"]), ["en", "es", "fr"])

    def test_conflicting_translation_keeps_clean_keys_merged(self):
        code, text = self.run_merge(catalog(Konto="Account"),
                                    catalog(Konto="Bank account", Zahlung="Payment"),
                                    catalog(Konto="Acct", Bank="Bank"))
        self.assertEqual(code, 1)
        self.assertEqual(text.count("<<<<<<< ours"), 1)
        self.assertIn('"value" : "Bank account"', text)
        self.assertIn('"value" : "Acct"', text)
        # Dropping the marker lines and "theirs" leaves a valid catalog with both clean additions.
        lines, keep = [], True
        for line in text.splitlines():
            if line.startswith("<<<<<<<"):
                continue
            if line.startswith("======="):
                keep = False
            elif line.startswith(">>>>>>>"):
                keep = True
            elif keep:
                lines.append(line)
        self.assertEqual(json.loads("\n".join(lines)), catalog(Bank="Bank", Konto="Bank account", Zahlung="Payment"))

    def test_edit_versus_delete_is_a_conflict(self):
        code, text = self.run_merge(catalog(A="a", B="b"), catalog(A="a"), catalog(A="a", B="b2"))
        self.assertEqual(code, 1)
        self.assertIn(">>>>>>> theirs", text)

    def test_non_json_falls_back_to_text_merge(self):
        code, text = self.run_merge("", "eins\n", "eins\n")
        self.assertEqual(code, 0)
        self.assertEqual(text, "eins\n")


class CanonicalFormTests(unittest.TestCase):
    def test_checked_in_catalogs_are_canonical(self):
        self.assertEqual(xcstrings.main(["xcstrings.py", "check"]), 0)

    def test_format_sorts_and_check_detects(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "T.xcstrings")
            xcstrings.write(path, json.dumps(catalog(Zahlung="Payment", Konto="Account")))
            self.assertEqual(xcstrings.main(["xcstrings.py", "check", path]), 1)
            self.assertEqual(xcstrings.main(["xcstrings.py", "format", path]), 0)
            self.assertEqual(xcstrings.main(["xcstrings.py", "check", path]), 0)
            self.assertEqual(list(json.loads(xcstrings.read(path))["strings"]), ["Konto", "Zahlung"])


if __name__ == "__main__":
    unittest.main()
