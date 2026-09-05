# codemap-ci

**CI builds every PR against main and never against its siblings.**

That one sentence is the whole gap. Every open PR is green, every merge is
individually safe, and the pair that does not compile together is invisible
until someone merges both. codemap-ci closes it: on every PR event it asks
`codemap collide` which open PRs touch the same files, then actually merges each
predicted pair into a throwaway worktree and runs your build. If a pair does not
build, the check goes red — before either one lands.

## Why now

Concurrent PRs used to be a human-scale problem. Agent fleets changed the
denominator:

- **79.4%** of agent PRs are open concurrently with at least one other agent PR,
  and per-agent conflict rates run **15% to 32%** —
  [arXiv:2607.04697](https://arxiv.org/abs/2607.04697)
- **27.67%** conflict rate in the AgenticFlict measurements —
  [arXiv:2604.03551](https://arxiv.org/abs/2604.03551)

The failure is not exotic. In codemap itself, PRs #117 and #118 were both green
and did not compile together: one changed `discoverCargoManifests`' signature,
the other added a caller using the old one. Four other PRs (#124–#127) turned
out to be mutually exclusive, which took six hand-built worktrees and about
fifteen minutes to discover.

## What it does

1. Runs `codemap collide --json` against the target repo's open PRs. That gives
   the shared files, weighted by how many files import them, and the predicted
   colliding pairs.
2. For each predicted pair above `--min-importers`, creates a git worktree from
   the base branch, merges both PR heads, and runs the repo's build command.
3. Writes a markdown summary to the job summary: `SHARED FILES`, `PREDICTED
   COLLIDING PAIRS`, and a **Pair builds** table naming the failing pair and the
   first 20 lines of its error.
4. Exits non-zero when any pair fails, so the check is red.

A pair that will not merge cleanly is reported as `merge conflict` rather than
being silently skipped — that is also a merge-order hazard, just a cheaper one.

## Free vs. what this adds

The prediction is free. `codemap collide` is part of
[codemap](https://github.com/JordanCoin/codemap) (shipped in #180) and you can
run it by hand any time:

```
codemap collide --repo owner/name
```

What codemap-ci adds is the part you will not do by hand on every push: it
**pair-builds** the predicted pairs, on every PR event, and fails the check. A
prediction you have to remember to run is a prediction nobody runs. The
prediction tells you which pairs are worth the compute; the pair build is the
proof.

## Install on another repo

Add a workflow. Nothing else — no app, no service.

```yaml
name: collide
on: [pull_request]
permissions:
  contents: read
  pull-requests: read
jobs:
  collide:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with: { path: codemap-ci-action, repository: JordanCoin/codemap-ci }
      - uses: actions/checkout@v4
        with: { path: target, fetch-depth: 0 }   # full history: worktrees need it
      - uses: ./codemap-ci-action
        with:
          target-dir: ${{ github.workspace }}/target
          build-command: "go build ./... && go vet ./..."
          github-token: ${{ github.token }}
```

### Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `target-repo` | the running repo | `owner/name` whose open PRs are read |
| `target-dir` | `github.workspace` | full checkout of `target-repo` |
| `build-command` | `go build ./... && go vet ./...` | run in each merged worktree |
| `min-importers` | `0` | hide shared files below this importer count |
| `base-branch` | repo default branch | branch the pairs merge onto |
| `codemap-ref` | `main` | ref of codemap to build the CLI from |
| `github-token` | required | reads PRs, fetches their heads |

### Secrets

None for the same-repo path — the default `GITHUB_TOKEN` is enough.

Pointing the check at a **different** repo (this repo's `workflow_dispatch` with
`target-repo`) needs a repo-scoped PAT stored as **`CODEMAP_TARGET_TOKEN`**,
because `GITHUB_TOKEN` is scoped to the repo running the workflow and cannot
read another repo's PRs. This repository does not create that secret; add it
under Settings → Secrets and variables → Actions.

## The demo in this repo

`lib.go` and `main.go` are a two-file Go program that exists only to produce the
#117/#118 shape on demand:

- **PR A** widens `Greet(name string)` to `Greet(name string, loud bool)` and
  updates its caller in `main.go`.
- **PR B** adds a new caller, `cmd2.go`, that calls `Greet("x")` with the old
  signature, and wires it into `main.go`.

Each builds green alone. Git merges them without a textual conflict. The
compiler does not: `not enough arguments in call to Greet`. The pair share
`main.go`, which is what `codemap collide` keys on, so the pair is predicted and
then proven. See `docs/proof.md`.

## Non-goals

It does not merge, rebase, close, or comment on anything. It builds throwaway
worktrees and reports.

## Live brief

Each commit on the default branch recomputes the facts and posts them to the brief webhook; the live page picks it up within about a minute.
