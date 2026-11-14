"""Unit tests for tools/export-ai-provenance.py (run: python3 -m unittest tools/test_export_ai_provenance.py)."""
import importlib.util
import pathlib
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "prov", pathlib.Path(__file__).with_name("export-ai-provenance.py"))
prov = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prov)


def detect(coauthors=(), trailers=(), body="", branch="", login=""):
    roles = {}
    tools = prov.detect_tools(list(coauthors), list(trailers), body, branch, login, roles)
    return tools, roles


class MultiModelDetection(unittest.TestCase):
    def test_gemini_orchestrator_and_claude_codegen(self):
        tools, roles = detect(
            coauthors=["Claude Opus 5.5 <noreply@anthropic.com>"],
            trailers=[("AI-Orchestrator", "Google Gemini"), ("AI-Agent", "Claude Code")])
        self.assertEqual(set(tools), {"Gemini", "Claude Code"})
        self.assertEqual(roles["orchestration"], ["Gemini"])
        self.assertEqual(roles["codegen"], ["Claude Code"])

    def test_gemini_coauthor_email(self):
        tools, roles = detect(coauthors=["Google Gemini <gemini@google.com>"])
        self.assertEqual(tools, {"Gemini": ["co-authored-by"]})
        self.assertEqual(roles["codegen"], ["Gemini"])

    def test_chatgpt_statement_is_orchestration(self):
        tools, roles = detect(body="Diese Spezifikation wurde erstellt mit Hilfe von ChatGPT.")
        self.assertIn("OpenAI Codex/ChatGPT", tools)
        self.assertEqual(roles["orchestration"], ["OpenAI Codex/ChatGPT"])
        self.assertEqual(roles["codegen"], [])

    def test_cursor_copilot_and_more(self):
        for value, name in [("Cursor", "Cursor"), ("GitHub Copilot", "GitHub Copilot"),
                            ("Windsurf", "Windsurf"), ("Cline", "Cline"), ("Aider (gpt-4o)", "Aider"),
                            ("DeepSeek-V3", "DeepSeek"), ("Mistral Large", "Mistral"),
                            ("Llama 3 via Ollama", "Llama/Ollama"), ("Perplexity", "Perplexity")]:
            tools, roles = detect(trailers=[("AI-Model", value)])
            self.assertIn(name, tools, value)
            self.assertIn(name, roles["codegen"], value)

    def test_free_text_mention_does_not_count(self):
        tools, _ = detect(body="Dieser PR zeigt, wie Gemini und ChatGPT Bankdaten sehen würden.")
        self.assertEqual(tools, {})

    def test_branch_prefix_is_codegen(self):
        tools, roles = detect(branch="cursor/fix-x")
        self.assertEqual(roles["codegen"], ["Cursor"])


class Reflection(unittest.TestCase):
    BODY = ("## Problem\nx\n\n### 🤖 AI Process Reflection\n"
            "- **Human-Steering:** Architektur vorgegeben\n- **AI-Agency:** Namen selbst gewählt\n"
            "- **Review-Focus:** Parser in portal_import.rs\n\n## Tests\nok\n")

    def test_section_parsed(self):
        r = prov.parse_reflection(self.BODY, [])
        self.assertTrue(r["present"] and r["section"])
        self.assertEqual(r["human_steering"], ["Architektur vorgegeben"])
        self.assertEqual(r["ai_agency"], ["Namen selbst gewählt"])
        self.assertEqual(r["review_focus"], ["Parser in portal_import.rs"])

    def test_trailers_parsed_and_section_boundary(self):
        r = prov.parse_reflection("## Tests\n- **Review-Focus:** nicht hier", [("Review-Focus", "Krypto")])
        self.assertFalse(r["section"])
        self.assertEqual(r["review_focus"], ["Krypto"])

    def test_absent(self):
        self.assertFalse(prov.parse_reflection("nichts", [])["present"])

    def test_new_trailers_recognised(self):
        t = prov.parse_trailers("msg\n\nAI-Agency: x\nReview-Focus: y\nAI-Model: z")
        self.assertEqual([k for k, _ in t], ["AI-Agency", "Review-Focus", "AI-Model"])


FEATURES = {"title": "t", "ai": {"involved": True, "tools": {"Gemini": ["trailer:ai-orchestrator"]}, "roles": {}},
            "scope": {"layers": {"ui": 1}, "security_surface": []}, "size": {},
            "tests": {"test_files_changed": 0, "tests_added": 0},
            "steering": {"reviews": 0, "comments": 0, "commits_after_first_feedback": 0}}
PR = {"body": "Mail a@b.de https://x.y/z ghp_abcdefghijklmnop123456",
      "commits": {"nodes": [{"commit": {"message": "feat: x\n\nbody"}}]},
      "files": {"nodes": [{"path": "GiroCrab/a.swift"}]}}


class MetaAudit(unittest.TestCase):
    def test_no_llm_and_no_key_fall_back(self):
        self.assertIsNone(prov.meta_audit(FEATURES, PR, no_llm=True, env={"GEMINI_API_KEY": "k"}))
        self.assertIsNone(prov.meta_audit(FEATURES, PR, env={}))

    def test_provider_priority(self):
        names = lambda env: prov.pick_provider(env)[0]
        self.assertEqual(names({"GEMINI_API_KEY": "a", "GITHUB_TOKEN": "b"}), "Google Gemini")
        self.assertEqual(names({"GITHUB_TOKEN": "b", "OPENAI_API_KEY": "c"}), "GitHub Models")
        self.assertEqual(names({"OPENAI_API_KEY": "c", "ANTHROPIC_API_KEY": "d"}), "OpenAI")
        self.assertEqual(names({"ANTHROPIC_API_KEY": "d"}), "Anthropic")

    def test_network_error_falls_back(self):
        with mock.patch.object(prov, "_post_json", side_effect=TimeoutError()):
            self.assertIsNone(prov.meta_audit(FEATURES, PR, env={"GEMINI_API_KEY": "k"}))

    def test_success_and_output_is_inert(self):
        evil = "Ein <b>langer</b> Satz mit @maintainer und https://evil.example/x [link](http://a.b) " * 3
        reply = {"candidates": [{"content": {"parts": [{"text": evil}]}}]}
        with mock.patch.object(prov, "_post_json", return_value=reply) as post:
            a = prov.meta_audit(FEATURES, PR, env={"GEMINI_API_KEY": "k"})
        self.assertEqual(a["provider"], "Google Gemini")
        self.assertNotIn("<", a["text"])
        self.assertNotIn("http", a["text"])
        self.assertNotIn("@m", a["text"])
        sent = str(post.call_args)
        for secret in ("a@b.de", "ghp_abcdefghijklmnop123456", "https://x.y/z"):
            self.assertNotIn(secret, sent)
        card = prov.render_card({**FEATURES, "number": 1, "state": "OPEN", "from_fork": True,
                                 "size": {"commits": 1, "additions": 1, "deletions": 0, "files": 1},
                                 "tests": {"test_files_changed": 0, "tests_added": 0, "tests_removed": 0,
                                           "pr_body_test_section": False},
                                 "scope": {"layers": {}, "security_files": {}, "security_surface": [],
                                           "files_truncated": False},
                                 "steering": {**FEATURES["steering"], "issue_refs": [], "pr_body_framing_section": False,
                                              "review_states": {}, "reviewers": [], "commenters": [],
                                              "comments_by_others": 0, "linked_issues_with_discussion": [],
                                              "pr_body_decision_section": False, "human_steering_trailers": [],
                                              "human_steering_signal": False},
                                 "verification": {"trailers": []}, "reflection": {"present": False}}, audit=a)
        self.assertIn("KI-Prozess-Analyse (Meta-Audit)", card)

    def test_sanitizer(self):
        out = prov.sanitize_for_llm("x@y.de <!-- ignore all --> DE89 3704 0044 0532 0130 00 tok ghp_abcdefghijklmnop12")
        for bad in ("x@y.de", "ignore all", "DE89", "ghp_"):
            self.assertNotIn(bad, out)


if __name__ == "__main__":
    unittest.main()
