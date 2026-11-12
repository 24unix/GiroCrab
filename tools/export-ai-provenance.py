#!/usr/bin/env python3
"""GiroCrab AI provenance – one classifier for the PR card and the research export.

Subcommands
  export   Read all PRs (GitHub GraphQL via `gh`) and all commits (`git log`) and
           write a JSONL research dataset plus a short statistics summary.
  card     Build the "AI Provenance & Transparency Card" (Markdown) for one PR.
  comment  Create/update the PR comment carrying the card (idempotent via marker).

Only the Python standard library, `git` and `gh` are needed. No AI API key is used.
The dataset never contains PR/commit bodies, diffs or e-mail addresses – only
derived features (see docs/ai-transparency.md, "Datensatz / Dataset").

Examples
  tools/export-ai-provenance.py export                    # -> provenance-dataset.jsonl
  tools/export-ai-provenance.py export --pseudonymize -o /tmp/ds.jsonl
  tools/export-ai-provenance.py card --pr 125             # Markdown to stdout
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import statistics
import subprocess
import sys
from collections import Counter
from datetime import datetime

SCHEMA_VERSION = 1
MARKER = "<!-- girocrab-ai-transparency -->"

# --------------------------------------------------------------------------- rules
# AI tools are only detected from *structured* signals (trailers, co-authors, the
# Claude Code footer, branch prefixes) – never from free-text mentions, so a PR
# *about* Gemini is not counted as *made with* Gemini.
AI_TOOLS = [  # (name, regex over a co-author / trailer value / footer)
    ("Claude Code", r"\bclaude\b|anthropic"),
    ("Gemini", r"\bgemini\b|google\s*ai"),
    ("GitHub Copilot", r"copilot"),
    ("OpenAI Codex/ChatGPT", r"\bcodex\b|chatgpt|openai|\bgpt-?\d"),
    ("Cursor", r"\bcursor\b"),
    ("Devin", r"\bdevin\b"),
    ("Aider", r"\baider\b"),
]
BRANCH_PREFIXES = {"claude/": "Claude Code", "copilot/": "GitHub Copilot",
                   "codex/": "OpenAI Codex/ChatGPT", "cursor/": "Cursor",
                   "gemini/": "Gemini", "devin/": "Devin"}
# Provenance trailers defined in docs/ai-transparency.md (+ common conventions).
TRAILER_RE = re.compile(
    r"^(Co-Authored-By|AI-Orchestrator|AI-Agent|AI-Assisted|Assisted-By|Generated-By|"
    r"Human-Steering|Verification|AI-Data-Policy)\s*:\s*(.+?)\s*$", re.I | re.M)
FOOTER_RE = re.compile(r"Generated with \[?(Claude Code|[\w .-]+?)\]?\(", re.I)

LAYERS = [  # first match wins
    ("legacy", r"^(cashcrab-core|CashCrabApp)/"),
    ("core-connectors", r"^girocrab-core/src/connectors/"),
    ("core", r"^(girocrab-core|src)/"),
    ("ui", r"^GiroCrabApp/"),
    ("ci", r"^\.github/"),
    ("build-packaging", r"^(Cargo\.(toml|lock)|build[^/]*|package-[^/]*|packaging/|uniffi-bindgen/|generated/)"),
    ("scripts-tools", r"^(scripts|tools)/"),
    ("docs", r"(^docs/|\.md$)"),
]
SECURITY = [  # (tag, regex) – a path may hit several tags
    ("vault", r"^girocrab-core/src/vault\.rs$"),
    ("crypto-secrets", r"crypto|secret\.rs$|cipher|argon|zeroize"),
    ("keychain", r"keychain|VaultKeyManager"),
    ("connectors", r"^girocrab-core/src/connectors/"),
    ("cloud-sync", r"CloudSync|user_groups"),
    ("supply-chain", r"(^|/)(Cargo\.(toml|lock)|Package\.(swift|resolved))$"),
    ("ci-pipeline", r"^\.github/workflows/"),
    ("entitlements", r"\.entitlements$|Info\.plist$"),
]
TEST_FILE_RE = re.compile(
    r"(^|/)(tests?|Tests|[^/]*Tests)/|_tests?\.rs$|Tests?\.swift$|(^|/)test[-_][^/]+\.(c?js|py|sh)$|\.test\.[jt]s$")
TEST_FN_RE = re.compile(
    r"^\s*(#\[(tokio::)?test\b|@Test\b|func test\w*\s*\(|(test|it)\s*\(\s*['\"`])")
TEST_SECTION_RE = re.compile(r"^#{1,6}\s*[^\n]*\b(test\w*|getestet|verifi\w*|prüfung|qa)\b", re.I | re.M)
FRAMING_SECTION_RE = re.compile(
    r"^#{1,6}\s*[^\n]*\b(problem|motivation|hintergrund|background|warum|why|ziel|goal|kontext|context)\b",
    re.I | re.M)
# Decision/alignment sections = human steering written into the PR body.
DECISION_SECTION_RE = re.compile(
    r"^#{1,6}\s*[^\n]*\b(entscheidung\w*|abzustimmen|abstimmung|decisions?|to decide|"
    r"offene fragen|open questions|design[- ]entscheidung\w*|trade-?offs?)\b", re.I | re.M)
ISSUE_REF_RE = re.compile(r"(?<![\w/])#(\d+)\b|github\.com/[\w.-]+/[\w.-]+/issues/(\d+)")


def classify_paths(paths):
    layers, security = Counter(), {}
    for p in paths:
        layers[next((n for n, rx in LAYERS if re.search(rx, p)), "other")] += 1
        for tag, rx in SECURITY:
            if re.search(rx, p, re.I):
                security.setdefault(tag, []).append(p)
    return dict(layers), {k: sorted(v) for k, v in security.items()}


def detect_tools(coauthors, trailers, body, branch, author_login):
    """-> {tool: sorted evidence sources}"""
    found = {}

    def hit(text, source):
        for name, rx in AI_TOOLS:
            if re.search(rx, text, re.I):
                found.setdefault(name, set()).add(source)

    for c in coauthors:
        hit(c, "co-authored-by")
    for key, val in trailers:
        if key.lower() != "co-authored-by" and not key.lower().startswith(("human", "verification")):
            hit(val, "trailer:" + key.lower())
    for m in FOOTER_RE.finditer(body or ""):
        hit(m.group(1), "pr-body-footer")
    for prefix, name in BRANCH_PREFIXES.items():
        if (branch or "").startswith(prefix):
            found.setdefault(name, set()).add("branch-prefix")
    if author_login and author_login.endswith("[bot]"):
        found.setdefault("Automation bot", set()).add("author")
    return {k: sorted(v) for k, v in sorted(found.items())}


def is_bot(actor):
    actor = actor or {}
    return actor.get("__typename") == "Bot" or (actor.get("login") or "").endswith("[bot]")


def parse_trailers(text):
    return [(m.group(1), m.group(2)) for m in TRAILER_RE.finditer(text or "")]


def count_tests_in_patch(patch):
    added = removed = 0
    for line in (patch or "").splitlines():
        if line.startswith(("+++", "---")):
            continue
        if line[:1] == "+" and TEST_FN_RE.match(line[1:]):
            added += 1
        elif line[:1] == "-" and TEST_FN_RE.match(line[1:]):
            removed += 1
    return added, removed


def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def hours_between(a, b):
    a, b = ts(a), ts(b)
    return round((b - a).total_seconds() / 3600, 2) if a and b else None


# --------------------------------------------------------------------------- shell
def run(cmd, check=True):
    r = subprocess.run(cmd, capture_output=True, text=True)
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd[:3])} …: {r.stderr.strip()[:400]}")
    return r.stdout if r.returncode == 0 else None


def repo_slug(explicit=None):
    if explicit or os.environ.get("GITHUB_REPOSITORY"):
        return explicit or os.environ["GITHUB_REPOSITORY"]
    return run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).strip()


PR_FIELDS = """
  number title url state isDraft createdAt mergedAt closedAt headRefName baseRefName
  isCrossRepository additions deletions changedFiles body
  author { login }
  labels(first: 20) { nodes { name } }
  mergeCommit { oid }
  closingIssuesReferences(first: 20) { nodes { number comments { totalCount } } }
  reviews(first: 100) { totalCount nodes { state author { login } submittedAt } }
  comments(first: 100) { totalCount nodes { author { login __typename } createdAt } }
  files(first: 100) { totalCount nodes { path additions deletions } }
  commits(first: 100) { totalCount nodes { commit {
    oid message committedDate
    authors(first: 10) { nodes { name user { login } } } } } }
"""


def gql(query, **variables):
    cmd = ["gh", "api", "graphql", "-f", f"query={query}"]
    for k, v in variables.items():
        cmd += ["-F", f"{k}={v}"]
    data = json.loads(run(cmd))
    if data.get("errors"):
        raise RuntimeError(data["errors"][0].get("message"))
    return data["data"]


def fetch_pr(repo, number):
    owner, name = repo.split("/")
    q = f"query($o:String!,$n:String!,$num:Int!){{repository(owner:$o,name:$n){{pullRequest(number:$num){{{PR_FIELDS}}}}}}}"
    return gql(q, o=owner, n=name, num=number)["repository"]["pullRequest"]


def fetch_all_prs(repo, limit):
    owner, name = repo.split("/")
    q = (f"query($o:String!,$n:String!,$after:String){{repository(owner:$o,name:$n){{"
         f"pullRequests(first:20,after:$after,orderBy:{{field:CREATED_AT,direction:ASC}}){{"
         f"pageInfo{{hasNextPage endCursor}} nodes{{{PR_FIELDS}}}}}}}}}")
    out, after = [], None
    while len(out) < limit:
        vars_ = {"o": owner, "n": name}
        if after:
            vars_["after"] = after
        page = gql(q, **vars_)["repository"]["pullRequests"]
        out += page["nodes"]
        print(f"\r  PRs fetched: {len(out)}", end="", file=sys.stderr)
        if not page["pageInfo"]["hasNextPage"]:
            break
        after = page["pageInfo"]["endCursor"]
    print(file=sys.stderr)
    return out[:limit]


def local_patch_for_pr(pr):
    """Diff of a merged PR from the local clone (first parent..merge commit)."""
    oid = (pr.get("mergeCommit") or {}).get("oid")
    if not oid or run(["git", "cat-file", "-e", oid], check=False) is None:
        return None
    return run(["git", "diff", "--unified=0", f"{oid}^1", oid], check=False)


# --------------------------------------------------------------------------- PR features
def pr_features(pr, patch=None, pseudo=None):
    pseudo = pseudo or (lambda x: x)
    body = pr.get("body") or ""
    author = (pr.get("author") or {}).get("login") or "ghost"
    commits = [n["commit"] for n in pr["commits"]["nodes"]]
    paths = [f["path"] for f in pr["files"]["nodes"]]

    coauthors, trailers, human_commits, ai_commits = [], [], 0, 0
    for c in commits:
        t = parse_trailers(c["message"])
        trailers += t
        names = [a["name"] for a in c["authors"]["nodes"]] + [v for k, v in t if k.lower() == "co-authored-by"]
        coauthors += names
        is_ai = any(re.search(rx, n, re.I) for n in names for _, rx in AI_TOOLS)
        ai_commits += is_ai
        human_commits += not is_ai
    trailers += parse_trailers(body)
    tools = detect_tools(coauthors, trailers, body, pr.get("headRefName"), author)

    layers, security = classify_paths(paths)
    test_files = [p for p in paths if TEST_FILE_RE.search(p)]
    tests_added, tests_removed = count_tests_in_patch(patch) if patch is not None else (None, None)

    reviews = [r for r in pr["reviews"]["nodes"] if (r.get("author") or {}).get("login") != author]
    review_states = Counter(r["state"] for r in reviews)
    # GiroCrab steers mostly through plain PR comments, not formal reviews.
    comments = [c for c in pr["comments"]["nodes"] if not is_bot(c.get("author"))]
    commenters = {(c.get("author") or {}).get("login") or "ghost" for c in comments}
    # first human feedback by someone other than the author (review or comment)
    feedback_times = [r["submittedAt"] for r in reviews if r.get("submittedAt")] + [
        c["createdAt"] for c in comments if (c.get("author") or {}).get("login") != author]
    first_feedback = min(feedback_times, default=None)
    commits_after_feedback = sum(1 for c in commits if first_feedback and c["committedDate"] > first_feedback)
    discussed_issues = sorted(n["number"] for n in pr["closingIssuesReferences"]["nodes"]
                              if n["comments"]["totalCount"] > 0)
    issues = sorted({n["number"] for n in pr["closingIssuesReferences"]["nodes"]} |
                    {int(a or b) for a, b in ISSUE_REF_RE.findall(body)} - {pr["number"]})
    steering_trailers = sorted({v for k, v in trailers if k.lower() == "human-steering"})
    verification_trailers = sorted({v for k, v in trailers if k.lower() == "verification"})

    return {
        "schema": SCHEMA_VERSION,
        "kind": "pr",
        "number": pr["number"],
        "title": pr["title"],
        "url": pr.get("url"),
        "state": pr["state"],
        "draft": pr.get("isDraft", False),
        "author": pseudo(author),
        "from_fork": pr.get("isCrossRepository", False),
        "created_at": pr["createdAt"],
        "merged_at": pr.get("mergedAt"),
        "closed_at": pr.get("closedAt"),
        "hours_to_merge": hours_between(pr["createdAt"], pr.get("mergedAt")),
        "hours_to_close": hours_between(pr["createdAt"], pr.get("closedAt")),
        "labels": [l["name"] for l in pr["labels"]["nodes"]],
        "size": {"additions": pr["additions"], "deletions": pr["deletions"],
                 "files": pr["changedFiles"], "commits": pr["commits"]["totalCount"]},
        "ai": {"involved": bool(tools), "tools": tools,
               "ai_coauthored_commits": ai_commits, "human_only_commits": human_commits},
        "scope": {"layers": layers, "security_surface": sorted(security),
                  "security_files": security, "files_truncated": pr["files"]["totalCount"] > len(paths)},
        "tests": {"test_files_changed": len(test_files), "test_files": test_files,
                  "tests_added": tests_added, "tests_removed": tests_removed,
                  "pr_body_test_section": bool(TEST_SECTION_RE.search(body))},
        "steering": {"issue_refs": issues,
                     "pr_body_framing_section": bool(FRAMING_SECTION_RE.search(body)),
                     "reviews": sum(review_states.values()),
                     "review_states": dict(review_states),
                     "reviewers": sorted({pseudo((r.get("author") or {}).get("login") or "ghost") for r in reviews}),
                     "comments": len(comments),
                     "commenters": sorted(pseudo(x) for x in commenters),
                     "comments_by_others": sum((c.get("author") or {}).get("login") != author for c in comments),
                     "linked_issues_with_discussion": discussed_issues,
                     "pr_body_decision_section": bool(DECISION_SECTION_RE.search(body)),
                     "commits_after_first_feedback": commits_after_feedback,
                     "human_steering_trailers": steering_trailers,
                     "human_steering_signal": bool(reviews or comments or discussed_issues or steering_trailers
                                                   or DECISION_SECTION_RE.search(body))},
        "verification": {"trailers": verification_trailers},
    }


def stages(f):
    """Map features onto the 4-stage taxonomy -> list of (stage, status, evidence)."""
    st, ai, t = f["steering"], f["ai"], f["tests"]
    framing = []
    if st["issue_refs"]:
        framing.append("Issue-/PR-Referenzen " + ", ".join(f"#{n}" for n in st["issue_refs"][:6]))
    if st["pr_body_framing_section"]:
        framing.append("Problem/Context-Sektion im PR-Body")
    steer = []
    if st["reviews"]:
        steer.append(f"{st['reviews']} Review(s) von {len(st['reviewers'])} Person(en)")
    if st["review_states"].get("CHANGES_REQUESTED"):
        steer.append(f"{st['review_states']['CHANGES_REQUESTED']}× Changes requested")
    if st["comments"]:
        steer.append(f"{st['comments']} PR-Kommentar(e) von {len(st['commenters'])} Person(en)"
                     + (f", davon {st['comments_by_others']} nicht vom Autor" if st["comments_by_others"] else ""))
    if st["linked_issues_with_discussion"]:
        steer.append("Diskutierte Issues " + ", ".join(f"#{n}" for n in st["linked_issues_with_discussion"][:6]))
    if st["pr_body_decision_section"]:
        steer.append("Entscheidungs-/Abstimmungs-Sektion im PR-Body")
    if st["commits_after_first_feedback"]:
        steer.append(f"{st['commits_after_first_feedback']} Commit(s) nach erstem Feedback")
    if st["human_steering_trailers"]:
        steer.append("Human-Steering: " + "; ".join(st["human_steering_trailers"][:3]))
    steer_ok = st["human_steering_signal"]
    if f["scope"]["security_surface"]:  # a requirement, not evidence -> does not set ✅
        steer.append("🔐 Security-Oberfläche berührt → menschliches Review Pflicht")
    gen = ([f"{n} ({', '.join(src)})" for n, src in ai["tools"].items()] or ["rein manuell (keine KI-Signale)"])
    ver = []
    if t["test_files_changed"]:
        ver.append(f"{t['test_files_changed']} Testdatei(en)")
    if t["tests_added"]:
        ver.append(f"+{t['tests_added']} Test(s)")
    if t["tests_removed"]:
        ver.append(f"−{t['tests_removed']} Test(s)")
    if t["pr_body_test_section"]:
        ver.append("Test-Sektion im PR-Body")
    ver += f["verification"]["trailers"][:3]
    ver.append("CI: fmt · clippy -D warnings · cargo test · swift build")
    return [
        ("1 · Problem Framing & Intent", bool(framing), framing),
        ("2 · Architectural & Security Steering", steer_ok, steer),
        ("3 · Code & Test Generation", True, gen),
        ("4 · Verification & Audit", bool(len(ver) > 1), ver),
    ]


def render_card(f, repo="GiroCrab/GiroCrab"):
    ok = lambda b: "✅" if b else "⚪️"
    layers = ", ".join(f"`{k}` ({v})" for k, v in sorted(f["scope"]["layers"].items(), key=lambda kv: -kv[1]))
    sec = f["scope"]["security_files"]
    lines = [
        MARKER,
        "## 🦀 AI Provenance & Transparency Card",
        "",
        f"**PR #{f['number']}** · {f['size']['commits']} Commit(s) · "
        f"+{f['size']['additions']}/−{f['size']['deletions']} in {f['size']['files']} Datei(en)"
        + (" · Fork-PR" if f["from_fork"] else ""),
        "",
        "| Stufe / Stage | | Evidenz / Evidence |",
        "|---|---|---|",
    ]
    for name, status, ev in stages(f):
        lines.append(f"| {name} | {ok(status)} | {'<br>'.join(ev) or '–'} |")
    lines += ["", f"**Schichten / Layers:** {layers or '–'}"]
    if sec:
        lines.append("**🔐 Security-Oberfläche:** " + ", ".join(
            f"`{tag}` ({len(p)})" for tag, p in sorted(sec.items())))
    if f["scope"]["files_truncated"]:
        lines.append("_Mehr als 100 Dateien – Pfadanalyse auf die ersten 100 begrenzt._")
    if f["tests"]["tests_added"] is None:
        lines.append("_Diff nicht verfügbar – neue Tests nicht gezählt._")
    lines += [
        "",
        "<sub>Automatisch erzeugt aus Commits, Trailern, PR-Body und Dateipfaden – ohne KI-API, ohne Diff-Inhalte "
        "in Dritt-Diensten. Format & Taxonomie: [docs/ai-transparency.md](https://github.com/" + repo + "/blob/main/docs/ai-transparency.md). "
        "Ergänzungen bitte als Git-Trailer (`AI-Orchestrator:`, `Human-Steering:`, `Verification:`).</sub>",
        "",
        "<!-- ai-provenance-json: " + json.dumps(f, ensure_ascii=False, separators=(",", ":"))
        .replace(">", "\\u003e") + " -->",
    ]
    return "\n".join(lines) + "\n"


# --------------------------------------------------------------------------- commits
def commit_records(pseudo, rev="HEAD"):
    """All commits reachable from `rev` (local git), one record each."""
    sep = "\x1e"
    fmt = f"{sep}%H%x00%an%x00%aI%x00%cI%x00%P%x00%s%x00%B%x00"
    out = run(["git", "log", rev, "--no-color", "--unified=0", "-p", "-m", "--first-parent", f"--format={fmt}"])
    for chunk in out.split(sep)[1:]:
        sha, an, ad, cd, parents, subj, msg, patch = (chunk.split("\x00", 7) + [""] * 8)[:8]
        paths = sorted(set(re.findall(r"^\+\+\+ b/(.+)$", patch, re.M)) |
                       set(re.findall(r"^--- a/(.+)$", patch, re.M)))
        trailers = parse_trailers(msg)
        coauthors = [an] + [v for k, v in trailers if k.lower() == "co-authored-by"]
        tools = detect_tools(coauthors, trailers, "", "", "")
        layers, security = classify_paths(paths)
        added, removed = count_tests_in_patch(patch)
        pr_ref = re.search(r"\(#(\d+)\)\s*$|Merge pull request #(\d+)", subj)
        yield {
            "schema": SCHEMA_VERSION, "kind": "commit", "sha": sha, "subject": subj,
            "author": pseudo(an), "authored_at": ad, "committed_at": cd,
            "is_merge": len(parents.split()) > 1,
            "pr": int(pr_ref.group(1) or pr_ref.group(2)) if pr_ref else None,
            "ai": {"involved": bool(tools), "tools": tools},
            "scope": {"layers": layers, "security_surface": sorted(security)},
            "tests": {"test_files_changed": sum(bool(TEST_FILE_RE.search(p)) for p in paths),
                      "tests_added": added, "tests_removed": removed},
            "verification": {"trailers": sorted({v for k, v in trailers if k.lower() == "verification"})},
        }


# --------------------------------------------------------------------------- CLI
def make_pseudo(enabled):
    if not enabled:
        return None
    salt = os.environ.get("PROVENANCE_SALT", "girocrab")
    return lambda x: "u_" + hashlib.sha256((salt + x).encode()).hexdigest()[:10]


def summarize(prs, commits):
    def pct(n, d):
        return f"{(100 * n / d):.0f} %" if d else "–"

    merged = [p for p in prs if p["merged_at"]]
    ai_prs = [p for p in prs if p["ai"]["involved"]]
    tool_ct = Counter(t for p in prs for t in p["ai"]["tools"])
    sec_ct = Counter(s for p in prs for s in p["scope"]["security_surface"])

    def med(xs):
        xs = [x for x in xs if x is not None]
        return f"{statistics.median(xs):.1f} h" if xs else "–"

    print("\n🦀 GiroCrab AI provenance – summary")
    print(f"  PRs:      {len(prs)} total, {len(merged)} merged, {sum(p['from_fork'] for p in prs)} from forks")
    print(f"  AI-assisted PRs: {len(ai_prs)} ({pct(len(ai_prs), len(prs))})")
    for t, n in tool_ct.most_common():
        print(f"    - {t}: {n}")
    print(f"  Security surface touched: {sum(bool(p['scope']['security_surface']) for p in prs)} PRs "
          + ", ".join(f"{k}={v}" for k, v in sec_ct.most_common()))
    print(f"  PRs with test changes: {sum(p['tests']['test_files_changed'] > 0 or (p['tests']['tests_added'] or 0) > 0 for p in prs)}"
          f"  | +tests total: {sum(p['tests']['tests_added'] or 0 for p in prs)}")
    print(f"  Human steering signal: {sum(p['steering']['human_steering_signal'] for p in prs)} PRs"
          f" (reviews {sum(p['steering']['reviews'] > 0 for p in prs)},"
          f" comments {sum(p['steering']['comments'] > 0 for p in prs)},"
          f" decision sections {sum(p['steering']['pr_body_decision_section'] for p in prs)},"
          f" discussed issues {sum(bool(p['steering']['linked_issues_with_discussion']) for p in prs)})")
    print(f"  Reviewed PRs: {sum(p['steering']['reviews'] > 0 for p in prs)}"
          f"  | issue-linked: {sum(bool(p['steering']['issue_refs']) for p in prs)}")
    print(f"  Median time to merge: AI {med(p['hours_to_merge'] for p in ai_prs)}"
          f" · manual {med(p['hours_to_merge'] for p in prs if not p['ai']['involved'])}")
    if commits:
        ai_c = sum(c["ai"]["involved"] for c in commits)
        print(f"  Commits (first-parent): {len(commits)}, AI co-authored {ai_c} ({pct(ai_c, len(commits))}),"
              f" +tests {sum(c['tests']['tests_added'] for c in commits)}")


def cmd_export(a):
    pseudo = make_pseudo(a.pseudonymize)
    repo = repo_slug(a.repo)
    print(f"Repository: {repo}", file=sys.stderr)
    prs = []
    for pr in fetch_all_prs(repo, a.limit):
        patch = local_patch_for_pr(pr)
        if patch is None and a.fetch_diffs:
            patch = run(["gh", "pr", "diff", str(pr["number"]), "-R", repo], check=False)
        prs.append(pr_features(pr, patch, pseudo))
    commits = [] if a.no_commits else list(commit_records(pseudo or (lambda x: x), a.rev))
    with open(a.output, "w", encoding="utf-8") as fh:
        for rec in prs + commits:
            fh.write(json.dumps(rec, ensure_ascii=False) + "\n")
    print(f"Wrote {len(prs)} PR + {len(commits)} commit records -> {a.output}", file=sys.stderr)
    summarize(prs, commits)


def cmd_card(a):
    repo = repo_slug(a.repo)
    pr = fetch_pr(repo, a.pr)
    patch = run(["gh", "pr", "diff", str(a.pr), "-R", repo], check=False)  # None if too large
    card = render_card(pr_features(pr, patch), repo)
    if a.out:
        open(a.out, "w", encoding="utf-8").write(card)
    else:
        sys.stdout.write(card)


def cmd_comment(a):
    repo = repo_slug(a.repo)
    body = open(a.file, encoding="utf-8").read()
    pages = run(["gh", "api", "--paginate", f"repos/{repo}/issues/{a.pr}/comments",
                 "-q", f'.[] | select(.body | contains("{MARKER}")) | .id'])
    ids = pages.split()
    if ids:
        run(["gh", "api", "-X", "PATCH", f"repos/{repo}/issues/comments/{ids[0]}", "-f", f"body={body}"])
        print(f"Updated comment {ids[0]}")
    else:
        run(["gh", "api", "-X", "POST", f"repos/{repo}/issues/{a.pr}/comments", "-f", f"body={body}"])
        print("Created comment")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--repo", help="owner/name (default: $GITHUB_REPOSITORY or current gh repo)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    e = sub.add_parser("export", help="write research dataset (JSONL) + summary")
    e.add_argument("-o", "--output", default="provenance-dataset.jsonl")
    e.add_argument("--limit", type=int, default=10_000)
    e.add_argument("--rev", default="HEAD", help="git revision for the commit records (default HEAD)")
    e.add_argument("--no-commits", action="store_true", help="skip git log commit records")
    e.add_argument("--fetch-diffs", action="store_true",
                   help="use `gh pr diff` for PRs whose merge commit is not in the local clone")
    e.add_argument("--pseudonymize", action="store_true",
                   help="replace user names/logins with salted hashes ($PROVENANCE_SALT)")
    c = sub.add_parser("card", help="render the transparency card for one PR")
    c.add_argument("--pr", type=int, required=True)
    c.add_argument("--out")
    m = sub.add_parser("comment", help="create/update the PR comment from a card file")
    m.add_argument("--pr", type=int, required=True)
    m.add_argument("--file", required=True)
    a = ap.parse_args()
    try:
        {"export": cmd_export, "card": cmd_card, "comment": cmd_comment}[a.cmd](a)
    except RuntimeError as err:
        sys.exit(f"error: {err}")


if __name__ == "__main__":
    main()
