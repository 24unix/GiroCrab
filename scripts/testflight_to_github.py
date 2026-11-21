import json, os, re, subprocess, time, urllib.request
import jwt

ASC_ISSUER_ID = os.environ["ASC_ISSUER_ID"]
ASC_KEY_ID = os.environ["ASC_KEY_ID"]
ASC_PRIVATE_KEY = os.environ["ASC_PRIVATE_KEY"]
ASC_APP_ID = os.environ["ASC_APP_ID"]
TARGET_REPO = os.environ.get("GITHUB_REPOSITORY", "GiroCrab/GiroCrab")


def make_asc_token():
    now = int(time.time())
    payload = {
        "iss": ASC_ISSUER_ID,
        "iat": now,
        "exp": now + 900,
        "aud": "appstoreconnect-v1",
    }
    return jwt.encode(payload, ASC_PRIVATE_KEY, algorithm="ES256", headers={"kid": ASC_KEY_ID})


def asc_get(path, token):
    req = urllib.request.Request(
        f"https://api.appstoreconnect.apple.com{path}",
        headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.loads(resp.read().decode("utf-8"))


def mask_email(email):
    if not email or "@" not in email:
        return "anonymer Tester"
    local, domain = email.split("@", 1)
    return f"{local[:2]}***@{domain}"


def issue_exists(tf_id):
    out = subprocess.check_output(
        ["gh", "issue", "list", "-R", TARGET_REPO, "--state", "all", "--search", f'"TF-ID: {tf_id}"', "--json", "number"],
        text=True,
    )
    return len(json.loads(out)) > 0


def create_issue(title, body, labels):
    cmd = ["gh", "issue", "create", "-R", TARGET_REPO, "--title", title, "--body", body]
    for lbl in labels:
        cmd += ["--label", lbl]
    subprocess.run(cmd, check=True)


def run():
    token = make_asc_token()
    endpoints = [
        ("Feedback", f"/v1/apps/{ASC_APP_ID}/betaFeedbackScreenshotSubmissions?include=build,tester&limit=50"),
        ("Crash", f"/v1/apps/{ASC_APP_ID}/betaFeedbackCrashSubmissions?include=build,tester&limit=50"),
    ]

    created_count = 0
    for kind, url in endpoints:
        data = asc_get(url, token)
        included = {(item["type"], item["id"]): item.get("attributes", {}) for item in data.get("included", [])}

        for sub in data.get("data", []):
            tf_id = sub["id"]
            if issue_exists(tf_id):
                continue

            attrs = sub.get("attributes", {})
            rels = sub.get("relationships", {})

            build_rel = (rels.get("build") or {}).get("data") or {}
            build_attrs = included.get((build_rel.get("type"), build_rel.get("id")), {})
            build_ver = build_attrs.get("version", "?")

            tester_rel = (rels.get("tester") or {}).get("data") or {}
            tester_attrs = included.get((tester_rel.get("type"), tester_rel.get("id")), {})
            tester_label = mask_email(tester_attrs.get("email", ""))

            comment = (attrs.get("comment") or "(kein Textkommentar)").strip()
            device = attrs.get("deviceModel") or "Unbekanntes Gerät"
            os_ver = attrs.get("osVersion") or "?"
            app_platform = (attrs.get("appPlatform") or "IOS").lower()
            created = (attrs.get("createdDate") or "")[:19].replace("T", " ")

            screenshots_md = ""
            for idx, sc in enumerate(attrs.get("screenshots") or [], 1):
                img_url = sc.get("url")
                if img_url:
                    screenshots_md += f"\n- [Screenshot {idx}]({img_url}) *(Apple-Link zeitlich begrenzt)*"

            short_summary = re.sub(r"\s+", " ", comment)[:65]
            title = f"[TestFlight {kind}] {short_summary}"
            labels = ["testflight", "bugfix" if kind == "Crash" else "triage"]
            labels.append("macos" if "mac" in app_platform else "ios")

            body = (
                f"### TestFlight-{kind} (Build `{build_ver}`)\n\n"
                f"**Beschreibung des Testers ({tester_label}):**\n"
                f"> {comment}\n\n"
                f"**Gerätedaten:**\n"
                f"- **Plattform / OS:** `{app_platform}` `{os_ver}`\n"
                f"- **Gerät:** `{device}`\n"
                f"- **Zeitpunkt (UTC):** `{created}`\n"
                f"{screenshots_md}\n\n"
                f"<!-- TF-ID: {tf_id} -->"
            )
            create_issue(title, body, labels)
            created_count += 1
            print(f"Issue erstellt für {tf_id}")

    print(f"Fertig: {created_count} neue TestFlight-Issues erstellt.")


if __name__ == "__main__":
    run()
