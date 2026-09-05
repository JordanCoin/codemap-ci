#!/usr/bin/env python3
"""Compute the facts behind a live codebase brief.

Standard library only. Shells out to `codemap` (and `git` / `go` for the pair
builds) and writes one facts.json:

    {
      "coverage":      <the coverage object from `codemap --deps --json .`>,
      "files":         [{"id", "importers", "imports", "test"}],
      "areas":         {path: area name},
      "index":         {path: {"text": <first 24 KB>, "lines": int}},
      "last_change":   {path: {"sha", "author", "date", "message", "patch"}},
      "collide":       <`codemap collide --json`, or null when gh is unauthenticated>,
      "pair_builds":   {"#a+#b": {"merge": "clean|conflict", "build": "ok|FAIL"}},
      "capped":        bool,
      "index_capped":  bool,
      "index_dropped": [path]
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

# The content index exists so a page can quote a line of code back at a reader.
# It is not a mirror of the repository, and every one of these bounds is load
# bearing: the whole snapshot travels over one HTTP POST.
INDEX_TEXT_CAP = 24 * 1024  # bytes of text kept per file
INDEX_FILE_SIZE_CAP = 256 * 1024  # files bigger than this are not indexed at all
INDEX_TOTAL_CAP = 3 * 1024 * 1024  # bytes of text kept across the whole index
MINIFIED_LINE_BYTES = 500  # average line this long means generated, not written
PATCH_LINE_CAP = 80  # lines of `git log -p` kept per file

# The service accepts 6 MB of facts. Stay under it with room for the JSON the
# workflow wraps around them, and shed index text until we fit.
FACTS_BYTE_BUDGET = 5_600_000

# Checked-in dependencies and build output: real files, but nobody asks a brief
# what changed in them.
VENDOR_DIRS = {
    ".git",
    ".next",
    ".nuxt",
    ".venv",
    ".yarn",
    "Pods",
    "bower_components",
    "build",
    "coverage",
    "dist",
    "node_modules",
    "out",
    "target",
    "third_party",
    "thirdparty",
    "vendor",
    "venv",
}

# Machine-written, enormous, and never the answer to "where is this used".
LOCKFILES = {
    "Cargo.lock",
    "Gemfile.lock",
    "Podfile.lock",
    "bun.lockb",
    "composer.lock",
    "flake.lock",
    "go.sum",
    "mix.lock",
    "npm-shrinkwrap.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "poetry.lock",
    "pubspec.lock",
    "uv.lock",
    "yarn.lock",
}

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


def is_vendored(path: str) -> bool:
    return any(part in VENDOR_DIRS for part in path.split("/")[:-1])


def index_skip_reason(repo: str, path: str) -> str | None:
    """Why this file is not worth indexing, or None when it is."""
    name = path.rsplit("/", 1)[-1]
    if is_vendored(path):
        return "vendored"
    if name in LOCKFILES:
        return "lockfile"
    if ".min." in name:
        return "minified"
    full = os.path.join(repo, path)
    try:
        size = os.path.getsize(full)
    except OSError as exc:
        return f"unreadable ({exc.strerror})"
    if size > INDEX_FILE_SIZE_CAP:
        return "over the per-file size cap"
    return None


def read_text_file(full: str) -> str | None:
    """Return the file's text, or None when it is binary or undecodable."""
    try:
        raw = open(full, "rb").read()
    except OSError as exc:
        print(f"note: could not read {full}: {exc}", file=sys.stderr)
        return None
    if b"\x00" in raw[:8192]:
        return None
    try:
        return raw.decode("utf-8")
    except UnicodeDecodeError:
        return None


def build_index(repo: str, paths: list[str]):
    """Copy a bounded slice of each text file so the page can quote it.

    Returns (index, capped, skipped) where `capped` says the 3 MB total was
    reached and the remaining files were left out.
    """
    index: dict[str, dict] = {}
    skipped: dict[str, int] = {}
    total = 0
    capped = False

    for path in paths:
        reason = index_skip_reason(repo, path)
        if reason is not None:
            skipped[reason] = skipped.get(reason, 0) + 1
            continue

        text = read_text_file(os.path.join(repo, path))
        if text is None:
            skipped["binary"] = skipped.get("binary", 0) + 1
            continue

        lines = text.count("\n") + (0 if text.endswith("\n") or text == "" else 1)
        encoded = text.encode("utf-8")
        if lines > 0 and len(encoded) / lines > MINIFIED_LINE_BYTES:
            skipped["minified"] = skipped.get("minified", 0) + 1
            continue

        # Cut on a character boundary: a half UTF-8 sequence is not text.
        kept = encoded[:INDEX_TEXT_CAP].decode("utf-8", "ignore")
        cost = len(kept.encode("utf-8"))
        if total + cost > INDEX_TOTAL_CAP:
            capped = True
            skipped["over the total index cap"] = skipped.get("over the total index cap", 0) + 1
            continue

        total += cost
        index[path] = {"text": kept, "lines": lines}

    if skipped:
        detail = ", ".join(f"{n} {why}" for why, n in sorted(skipped.items()))
        print(f"  index skipped {detail}", file=sys.stderr)
    print(f"  indexed {len(index)} files, {total} bytes of text", file=sys.stderr)
    return index, capped


def collect_last_change(repo: str, paths: list[str]):
    """Ask git what last touched each file, with a trimmed patch."""
    rc, _, _ = run(["git", "-C", repo, "rev-parse", "--git-dir"], check=False, timeout=60)
    if rc != 0:
        print("note: not a git checkout, last_change is empty", file=sys.stderr)
        return {}

    # Unit separator between fields, record separator before the patch: git will
    # not emit either, so the split is exact even for a subject full of quotes.
    fmt = "%H%x1f%an%x1f%aI%x1f%s%x1e"
    out: dict[str, dict] = {}
    for i, path in enumerate(paths, 1):
        if i % 100 == 0:
            print(f"  last_change {i}/{len(paths)}", file=sys.stderr)
        rc, stdout, err = run(
            ["git", "-C", repo, "log", "-1", f"--format={fmt}", "-p", "--", path],
            check=False,
            timeout=120,
        )
        if rc != 0:
            print(f"note: git log failed for {path}: {err.strip()[:200]}", file=sys.stderr)
            continue
        if "\x1e" not in stdout:
            # No commit touches this path: it is untracked, or new in the worktree.
            continue
        head, patch = stdout.split("\x1e", 1)
        fields = head.split("\x1f")
        if len(fields) != 4:
            print(f"note: unexpected git log header for {path}", file=sys.stderr)
            continue
        sha, author, date, message = fields
        trimmed = "\n".join(patch.lstrip("\n").split("\n")[:PATCH_LINE_CAP])
        out[path] = {
            "sha": sha,
            "author": author,
            "date": date,
            "message": message,
            "patch": trimmed,
        }
    print(f"  last_change for {len(out)}/{len(paths)} files", file=sys.stderr)
    return out


def fit_to_budget(facts: dict) -> tuple[list[str], list[str]]:
    """Shed the biggest index entries until the facts fit the POST budget.

    Returns (index_dropped, patches_dropped). Index text goes first because it
    is the most replaceable part of the snapshot; patches are only touched when
    dropping every indexed file still is not enough.
    """
    dropped: list[str] = []
    patches_dropped: list[str] = []

    def size() -> int:
        return len(json.dumps(facts).encode("utf-8"))

    total = size()
    if total <= FACTS_BYTE_BUDGET:
        return dropped, patches_dropped

    index = facts.get("index") or {}
    by_size = sorted(index, key=lambda p: len(index[p]["text"].encode("utf-8")), reverse=True)
    for path in by_size:
        if total <= FACTS_BYTE_BUDGET:
            break
        # The entry costs its text plus the key and the JSON punctuation.
        total -= len(json.dumps({path: index[path]}).encode("utf-8"))
        del index[path]
        dropped.append(path)

    changes = facts.get("last_change") or {}
    by_patch = sorted(
        (p for p in changes if changes[p].get("patch")),
        key=lambda p: len(changes[p]["patch"]),
        reverse=True,
    )
    for path in by_patch:
        if total <= FACTS_BYTE_BUDGET:
            break
        total -= len(changes[path]["patch"].encode("utf-8"))
        changes[path]["patch"] = ""
        patches_dropped.append(path)

    actual = size()
    if actual > FACTS_BYTE_BUDGET:
        raise RuntimeError(
            f"facts are {actual} bytes after shedding every index entry and patch, "
            f"over the {FACTS_BYTE_BUDGET} byte budget"
        )
    print(
        f"  shed {len(dropped)} index entries and {len(patches_dropped)} patches "
        f"to fit the {FACTS_BYTE_BUDGET} byte budget",
        file=sys.stderr,
    )
    return dropped, patches_dropped


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

    # The index and the git history describe the same files the graph does, so
    # every path in the snapshot lines up across all three.
    subject = [f["id"] for f in files]
    index, index_capped = build_index(repo, subject)
    last_change = collect_last_change(repo, subject)

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
        "index": index,
        "last_change": last_change,
        "collide": collide,
        "pair_builds": builds,
        "capped": capped,
        "index_capped": index_capped,
        "index_dropped": [],
    }

    dropped, patches_dropped = fit_to_budget(facts)
    facts["index_dropped"] = dropped
    if patches_dropped:
        facts["patches_dropped"] = patches_dropped

    with open(args.out, "w") as fh:
        json.dump(facts, fh)
    size = os.path.getsize(args.out)
    print(
        f"wrote {args.out}: {len(files)} files, {len(set(areas.values()))} areas, "
        f"{len(index)} indexed, {len(last_change)} with a last change, "
        f"{len(builds)} pair builds, capped={capped}, index_capped={index_capped}, "
        f"dropped={len(dropped)}, {size} bytes",
        file=sys.stderr,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
