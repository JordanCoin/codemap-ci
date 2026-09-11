#!/usr/bin/env python3
"""ledger.py: the morning read for a fleet of agent PRs across repos.

For each repo: what opened, merged and is still open in the window, grouped by
the Claude session that authored it, with importer counts for merged PRs (how many
files depend on what they touched) and codemap's predicted collisions among the
PRs still open. One message, to Slack or stdout.

Stdlib only. Reads GitHub through `gh`, which takes GH_TOKEN from the env.

  python3 scripts/ledger.py --hours 24 --slack-webhook "$SLACK_LEDGER_WEBHOOK"
"""
import argparse
import concurrent.futures
import datetime as dt
import json
import os
import platform
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import urllib.request

DEFAULT_REPOS = "aswb-backend,ASWB-Web-App,SWTPA-iOS,community-os,codemap"
CODEMAP_VERSION = "4.5.1"
PR_CAP = 20  # merged PRs measured per repo
FILE_CAP = 30  # files measured per PR
UNIQUE_FILE_CAP = 80  # distinct files measured per repo; burst PRs overlap heavily
SESSION_RE = re.compile(r"claude\.ai/code/session_([A-Za-z0-9]+)")


def gh(*args, cwd=None, timeout=120):
    proc = subprocess.run(["gh", *args], cwd=cwd, capture_output=True, text=True, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args[:2])}: {proc.stderr.strip()[:300]}")
    return proc.stdout


def when(s):
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")) if s else None


def codemap_bin(work):
    """A codemap binary: CODEMAP_BIN, else the release tarball (ast-grep included)."""
    if os.environ.get("CODEMAP_BIN"):
        return os.environ["CODEMAP_BIN"]
    system = platform.system().lower()
    arch = {"x86_64": "amd64", "amd64": "amd64", "aarch64": "arm64", "arm64": "arm64"}[platform.machine()]
    asset = f"codemap-full_{CODEMAP_VERSION}_{system}_{arch}.tar.gz"
    url = f"https://github.com/JordanCoin/codemap/releases/download/v{CODEMAP_VERSION}/{asset}"
    dist = os.path.join(work, "codemap-dist")
    os.makedirs(dist, exist_ok=True)
    path = os.path.join(work, asset)
    urllib.request.urlretrieve(url, path)
    with tarfile.open(path) as tar:
        tar.extractall(dist)
    os.environ["PATH"] = dist + os.pathsep + os.environ["PATH"]
    return os.path.join(dist, "codemap")


def importers(codemap, checkout, path):
    """(count, is_hub) for one file, (0, False) when codemap cannot say."""
    if not os.path.isfile(os.path.join(checkout, path)):
        return 0, False
    proc = subprocess.run([codemap, "--json", "--importers", path], cwd=checkout,
                          capture_output=True, text=True, timeout=60)
    if proc.returncode != 0:
        return 0, False
    try:
        data = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return 0, False
    return int(data.get("importer_count") or 0), bool(data.get("is_hub"))


def blast_level(files):
    """codemap calls 3 importers a hub; 9 (3x) or two hubs in one PR is high."""
    if not files:
        return "low", None
    top = max(files, key=lambda f: f[1])
    hubs = sum(1 for f in files if f[2])
    if top[1] >= 9 or hubs >= 2:
        return "high", top
    if hubs >= 1:
        return "medium", top
    return "low", top


def hubs_word(files):
    n = sum(1 for f in files if f[2])
    return f"{n} hub{'s' if n != 1 else ''} touched"


def repo_section(owner, name, since, work, codemap):
    full = f"{owner}/{name}"
    prs = json.loads(gh("pr", "list", "--repo", full, "--state", "all", "--limit", "100",
                        "--json", "number,title,body,createdAt,mergedAt,closedAt,url,files"))
    now = dt.datetime.now(dt.timezone.utc)
    opened = [p for p in prs if when(p["createdAt"]) >= since]
    merged = [p for p in prs if p["mergedAt"] and when(p["mergedAt"]) >= since]
    closed = [p for p in prs if p["closedAt"] and not p["mergedAt"] and when(p["closedAt"]) >= since]
    still_open = [p for p in prs if not p["closedAt"]]

    lines = [f"{name:<14} opened {len(opened)} · merged {len(merged)} · closed {len(closed)} · open {len(still_open)}"]
    highs = 0

    checkout = None
    measured = merged[:PR_CAP]
    if measured:
        checkout = os.path.join(work, name)
        gh("repo", "clone", full, checkout, "--", "--depth", "50", "--quiet", timeout=300)
    # One lookup per distinct file, in parallel: every call rescans the repo, and
    # a session's burst of PRs touches the same handful of files.
    wanted = []
    for p in measured:
        for f in p["files"][:FILE_CAP]:
            if f["path"] not in wanted:
                wanted.append(f["path"])
    capped = len(wanted) > UNIQUE_FILE_CAP
    wanted = wanted[:UNIQUE_FILE_CAP]
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        counts = dict(zip(wanted, pool.map(lambda path: importers(codemap, checkout, path), wanted)))
    for p in measured:
        files = []
        for f in p["files"][:FILE_CAP]:
            n, hub = counts.get(f["path"], (0, False))
            if n:
                files.append((f["path"], n, hub))
        level, top = blast_level(files)
        if level in ("high", "medium"):
            highs += level == "high"
            lines.append(f"  #{p['number']} \"{p['title'][:48]}\" touched {top[0]} · {top[1]} importers · {hubs_word(files)} · blast {level}")
    if len(merged) > PR_CAP:
        lines.append(f"  {len(merged) - PR_CAP} more merged PRs not measured (cap {PR_CAP})")
    if capped:
        lines.append(f"  files beyond the first {UNIQUE_FILE_CAP} distinct not measured")

    sessions = {}
    for p in merged:
        m = SESSION_RE.search(p.get("body") or "")
        key = m.group(1)[:6] if m else "no session"
        sessions.setdefault(key, []).append(p["number"])
    for key, nums in sorted(sessions.items(), key=lambda kv: -len(kv[1])):
        if len(nums) >= 2:
            lines.append(f"  session {key}…  {len(nums)} PRs landed")

    if len(still_open) >= 2:
        if checkout is None:
            checkout = os.path.join(work, name)
            gh("repo", "clone", full, checkout, "--", "--depth", "50", "--quiet", timeout=300)
        try:
            proc = subprocess.run([codemap, "collide", "--json", "--repo", full], cwd=checkout,
                                  capture_output=True, text=True, timeout=300)
            report = json.loads(proc.stdout or "{}")
        except (json.JSONDecodeError, subprocess.TimeoutExpired):
            report = {}
        for pair in report.get("pairs") or []:
            top_n = pair.get("top_importer_count") if pair.get("top_importers_known") else None
            lines.append(f"  predicted: #{pair['a']} + #{pair['b']} share {pair['shared_file_count']} file(s) "
                         f"({pair['top_file']}, {top_n if top_n is not None else 'importers unknown'}{' importers' if top_n is not None else ''})")

    return lines, len(opened), len(merged), len(still_open), highs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--owner", default="JordanCoin")
    ap.add_argument("--repos", default=DEFAULT_REPOS)
    ap.add_argument("--hours", type=int, default=24)
    ap.add_argument("--slack-webhook", default=os.environ.get("SLACK_LEDGER_WEBHOOK", ""))
    ap.add_argument("--summary-file", default=os.environ.get("GITHUB_STEP_SUMMARY", ""))
    args = ap.parse_args()

    if shutil.which("gh") is None:
        sys.exit("ledger: gh not found on PATH")
    since = dt.datetime.now(dt.timezone.utc) - dt.timedelta(hours=args.hours)
    work = tempfile.mkdtemp(prefix="ledger.")
    try:
        codemap = codemap_bin(work)
        out = [f"codemap ledger · {dt.datetime.now().strftime('%a %b %d')} · last {args.hours}h"]
        totals = [0, 0, 0, 0]
        for name in [r.strip() for r in args.repos.split(",") if r.strip()]:
            try:
                lines, o, m, s, h = repo_section(args.owner, name, since, work, codemap)
            except RuntimeError as exc:
                lines, o, m, s, h = [f"{name:<14} {exc}"], 0, 0, 0, 0
            out.extend(lines)
            for i, v in enumerate((o, m, s, h)):
                totals[i] += v
        out.append(f"Fleet: {totals[0]} opened · {totals[1]} merged · {totals[2]} open · {totals[3]} PRs touched a file with 9+ importers or 2 hubs")
        text = "\n".join(out)
    finally:
        shutil.rmtree(work, ignore_errors=True)

    print(text)
    if args.summary_file:
        with open(args.summary_file, "a") as fh:
            fh.write("## codemap ledger\n\n```\n" + text + "\n```\n")
    if args.slack_webhook:
        req = urllib.request.Request(args.slack_webhook, data=json.dumps({"text": f"```{text}```"}).encode(),
                                     headers={"content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            if resp.status >= 300:
                sys.exit(f"ledger: slack returned {resp.status}")


if __name__ == "__main__":
    main()
