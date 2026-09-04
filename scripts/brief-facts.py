#!/usr/bin/env python3
"""Compute the facts behind a live codebase brief.

Standard library only. Shells out to `codemap` (and `git` / `go` for the pair
builds) and writes one facts.json:

    {
      "coverage":    <the coverage object from `codemap --deps --json .`>,
      "files":       [{"id", "importers", "imports", "test"}],
      "areas":       {path: area name},
      "collide":     <`codemap collide --json`, or null when gh is unauthenticated>,
      "pair_builds": {"#a+#b": {"merge": "clean|conflict", "build": "ok|FAIL"}},
      "capped":      bool
    }

Usage: brief-facts.py [--repo PATH] [--out facts.json] [--codemap BIN]
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

# Guard rail. Asking codemap for the importers of every file is one process per
# file, so a large repo would otherwise run unbounded in CI. When the repo has
# more files than this we take the first IMPORTER_FILE_CAP and say so in the
# facts via "capped": true. Do not remove this.
IMPORTER_FILE_CAP = 400

# Top-level folder (or first route segment) -> the words a person would use for
# that part of the product. Anything not listed falls back to the folder name,
# capitalised.
AREA_RULES = {
    "": "Root",
    "api": "API",
    "app": "App",
    "pages": "Pages",
    "cmd": "Entry points",
    "internal": "Core",
    "pkg": "Core",
    "lib": "Core",
    "src": "Source",
    "scanner": "Scanner",
    "analysis": "Analysis",
    "config": "Configuration",
    "hooks": "Editor hooks",
    "handoff": "Handoff",
    "skills": "Skills",
    "scripts": "Tooling",
    "tools": "Tooling",
    "docs": "Documentation",
    "doc": "Documentation",
    "test": "Tests",
    "tests": "Tests",
    "testdata": "Test fixtures",
    "fixtures": "Test fixtures",
    "components": "Components",
    "ui": "Components",
    "db": "Data",
    "drizzle": "Data",
    "migrations": "Data",
    "emails": "Email",
    "public": "Assets",
    "assets": "Assets",
    "static": "Assets",
    "styles": "Styles",
    "types": "Types",
    ".github": "CI",
}

TEST_PATH_RE = re.compile(
    r"(^|/)(tests?|testdata|__tests__|fixtures)(/|$)"
    r"|_test\.(go|py|rb)$"
    r"|\.(test|spec)\.(js|jsx|ts|tsx|mjs|cjs)$"
    r"|(^|/)test_[^/]+\.py$"
)


def run(cmd, cwd=None, check=True, timeout=600):
    """Run a command and return (rc, stdout, stderr) with text output."""
    proc = subprocess.run(
        cmd,
        cwd=cwd,
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if check and proc.returncode != 0:
        raise RuntimeError(
            f"command failed ({proc.returncode}): {' '.join(cmd)}\n{proc.stderr.strip()}"
        )
    return proc.returncode, proc.stdout, proc.stderr


def run_json(cmd, cwd=None, timeout=600):
    """Run a command that prints JSON. Returns None when it fails or prints junk."""
    try:
        proc = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=timeout)
    except (OSError, subprocess.TimeoutExpired) as exc:
        print(f"note: {' '.join(cmd)} did not run: {exc}", file=sys.stderr)
        return None
    if proc.returncode != 0:
        print(
            f"note: {' '.join(cmd)} exited {proc.returncode}: {proc.stderr.strip()[:400]}",
            file=sys.stderr,
        )
        return None
    text = proc.stdout.strip()
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        print(f"note: {' '.join(cmd)} did not print JSON: {exc}", file=sys.stderr)
        return None


def area_for(path: str) -> str:
    """Name the part of the product a file belongs to."""
    head = path.split("/", 1)[0] if "/" in path else ""
    key = head.lower()
    if key in AREA_RULES:
        return AREA_RULES[key]
    # Fallback: the folder name in words, capitalised. "user_profile" -> "User profile".
    words = re.sub(r"[-_.]+", " ", head).strip()
    return words[:1].upper() + words[1:] if words else "Root"


def is_test(path: str) -> bool:
    return bool(TEST_PATH_RE.search(path))


def collect_files(codemap: str, repo: str):
    """Return (coverage, [repo-relative paths]) from `codemap --deps --json`."""
    deps = run_json([codemap, "--deps", "--json", repo])
    if deps is None:
        raise RuntimeError("codemap --deps --json produced no usable output")
    coverage = deps.get("coverage")
    paths = []
    for entry in deps.get("files") or []:
        p = entry.get("path") if isinstance(entry, dict) else entry
        if isinstance(p, str) and p:
            paths.append(p)
    return coverage, sorted(set(paths))


def file_facts(codemap: str, repo: str, paths: list[str]):
    """Ask codemap who imports each file, bounded by IMPORTER_FILE_CAP."""
    capped = len(paths) > IMPORTER_FILE_CAP
    subject = paths[:IMPORTER_FILE_CAP]
    in_repo = set(paths)
    files = []
    for i, path in enumerate(subject, 1):
        if i % 50 == 0:
            print(f"  importers {i}/{len(subject)}", file=sys.stderr)
        answer = run_json([codemap, "-C", repo, "--importers", path, "--json"]) or {}
        importers = [p for p in (answer.get("importers") or []) if p in in_repo]
        imports = [p for p in (answer.get("imports") or []) if p in in_repo]
        files.append(
            {
                "id": path,
                "importers": sorted(set(importers)),
                "imports": sorted(set(imports)),
                "test": is_test(path),
            }
        )
    return files, capped


def gh_is_authenticated() -> bool:
    if shutil.which("gh") is None:
        return False
    rc, _, _ = run(["gh", "auth", "status"], check=False, timeout=60)
    return rc == 0


def pair_builds(repo: str, collide: dict | None):
    """Merge each predicted pair onto main in a throwaway worktree and build it."""
    results = {}
    if not collide:
        return results
    pairs = collide.get("pairs") or []
    if not pairs:
        print("note: no predicted pairs, skipping pair builds", file=sys.stderr)
        return results
    if shutil.which("go") is None:
        print("note: go is not installed, skipping pair builds", file=sys.stderr)
        return results

    for pair in pairs:
        a, b = pair.get("a"), pair.get("b")
        if a is None or b is None:
            continue
        key = f"#{a}+#{b}"
        refs = {}
        ok = True
        for n in (a, b):
            local = f"refs/brief/pr{n}"
            rc, _, err = run(
                ["git", "fetch", "--force", "origin", f"refs/pull/{n}/head:{local}"],
                cwd=repo,
                check=False,
                timeout=180,
            )
            if rc != 0:
                print(f"note: could not fetch PR #{n}: {err.strip()[:200]}", file=sys.stderr)
                ok = False
                break
            refs[n] = local
        if not ok:
            continue

        worktree = tempfile.mkdtemp(prefix=f"brief-pair-{a}-{b}-")
        # git refuses to add a worktree at a path that already exists.
        os.rmdir(worktree)
        try:
            run(
                ["git", "worktree", "add", "--detach", worktree, "origin/main"],
                cwd=repo,
                timeout=180,
            )
            merge = "clean"
            for n in (a, b):
                rc, _, _ = run(
                    [
                        "git",
                        "-c", "user.name=brief-facts",
                        "-c", "user.email=brief-facts@localhost",
                        "merge", "--no-edit", refs[n],
                    ],
                    cwd=worktree,
                    check=False,
                    timeout=180,
                )
                if rc != 0:
                    merge = "conflict"
                    break
            if merge == "conflict":
                # Nothing to compile, and the schema only carries ok/FAIL, so a
                # pair that will not merge is recorded as a failing build.
                results[key] = {"merge": "conflict", "build": "FAIL"}
            else:
                rc, _, err = run(["go", "build", "./..."], cwd=worktree, check=False, timeout=600)
                if rc != 0:
                    print(f"note: {key} build failed: {err.strip()[:300]}", file=sys.stderr)
                results[key] = {"merge": "clean", "build": "ok" if rc == 0 else "FAIL"}
        finally:
            run(["git", "worktree", "remove", "--force", worktree], cwd=repo, check=False)
            shutil.rmtree(worktree, ignore_errors=True)

    return results


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--repo", default=".", help="repository to describe")
    ap.add_argument("--out", default="facts.json", help="where to write the facts")
    ap.add_argument("--codemap", default=os.environ.get("CODEMAP_BIN", "codemap"))
    args = ap.parse_args()

    repo = os.path.abspath(args.repo)
    codemap = args.codemap

    print(f"describing {repo}", file=sys.stderr)
    coverage, paths = collect_files(codemap, repo)
    print(f"  {len(paths)} files in the graph", file=sys.stderr)

    files, capped = file_facts(codemap, repo, paths)
    areas = {f["id"]: area_for(f["id"]) for f in files}

    collide = None
    if gh_is_authenticated():
        collide = run_json([codemap, "-C", repo, "collide", "--json"], timeout=900)
    else:
        print("note: gh is not authenticated, collide is null", file=sys.stderr)

    builds = pair_builds(repo, collide)

    facts = {
        "coverage": coverage,
        "files": files,
        "areas": areas,
        "collide": collide,
        "pair_builds": builds,
        "capped": capped,
    }

    with open(args.out, "w") as fh:
        json.dump(facts, fh)
    size = os.path.getsize(args.out)
    print(
        f"wrote {args.out}: {len(files)} files, {len(set(areas.values()))} areas, "
        f"{len(builds)} pair builds, capped={capped}, {size} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
