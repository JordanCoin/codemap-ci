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
3. On a `pull_request` event it builds only the pairs that include this PR;
   the other predicted pairs belong to their own PRs' runs. `all-pairs: true`
   builds everything, which is what the `workflow_dispatch` path does.
4. Writes the verdict first, then the failing pairs with the first lines of
   their error, the passing pairs, the files in this PR that other files
   depend on, and a coverage line. The same text lands as one sticky comment
   on the PR (updated in place on every run) and on the other half of any
   failing pair. Compiler-style `path:line: message` lines become inline
   annotations on the diff.
5. Exits non-zero when a pair that includes this PR fails, so the check is red.

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

Add a workflow. Nothing else: no app, no service. The action installs only
codemap (a release tarball that also carries ast-grep). Whatever toolchain your
`build-command` needs is one step in your workflow, as the Go step is below.

```yaml
name: collide
on: [pull_request]
permissions:
  contents: read
  pull-requests: write     # read is enough if you set comment: false
concurrency:
  group: collide-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true
jobs:
  collide:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
        with: { path: codemap-ci-action, repository: JordanCoin/codemap-ci }
      - uses: actions/checkout@v7
        with: { path: target, fetch-depth: 0 }   # full history: worktrees need it
      - uses: actions/setup-go@v7
        with: { go-version: "1.24" }
      - uses: ./codemap-ci-action
        with:
          target-dir: ${{ github.workspace }}/target
          build-command: "go build ./... && go vet ./..."
          github-token: ${{ github.token }}
          this-pr: ${{ github.event.pull_request.number }}
```

### Inputs

| Input | Default | Meaning |
| --- | --- | --- |
| `target-repo` | the running repo | `owner/name` whose open PRs are read |
| `target-dir` | `github.workspace` | full checkout of `target-repo` |
| `build-command` | `go build ./... && go vet ./...` | run in each merged worktree |
| `min-importers` | `0` | hide shared files below this importer count |
| `base-branch` | repo default branch | branch the pairs merge onto |
| `codemap-version` | `4.5.1` | codemap release to download |
| `this-pr` | empty | the PR this run belongs to; scopes builds, the comment and the exit code |
| `all-pairs` | `false` | build every predicted pair, not only this PR's |
| `comment` | `true` | post the sticky comment; needs `pull-requests: write` |
| `pair-timeout` | `600` | seconds allowed per pair build |
| `github-token` | required | reads PRs, fetches their heads, posts the comment |

### What lands on the PR

One comment, replaced on every run rather than stacked:

```
This PR (#1) does not build together with #2 "Add greetAgain" by @JordanCoin.
Each is green alone. Whichever merges second breaks main.

Failing pairs
#1 + #2 · build failed · shared: main.go (1 importers)
  ./cmd2.go:6:15: not enough arguments in call to Greet

Coverage
trust high · coverage complete · 3 open PRs · 1 shared files · codemap 4.5.1
```

The same comment goes on #2, since both PRs are in the pair. The compiler
line also appears as an annotation on `cmd2.go` line 6 in the Files changed
tab. A green run says which PRs it was built against, or that no open PR
shares a file with it.

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

## What it cannot catch

Two PRs that compile together but change behavior. If one PR changes what a
function returns and the other PR adds a caller that assumes the old value,
the pair builds and the check is green. On a repo where that matters, put the
tests in `build-command` (`go build ./... && go test ./...`) and raise
`pair-timeout` to match.

## Non-goals

It does not merge, rebase, or close anything. It builds throwaway worktrees,
reports, and leaves one comment.

## Live brief

Each commit on the default branch recomputes the facts and posts them to the brief webhook; the live page picks it up within about a minute.

The facts carry a bounded copy of the code as well as the graph, so the page can
answer questions about the source and not only about its shape:

| Key | What it holds |
| --- | --- |
| `index` | `{path: {"text", "lines"}}`, the first 24 KB of each text file |
| `last_change` | `{path: {"sha", "author", "date", "message", "patch"}}` from `git log -1` |
| `index_capped` | true when the 3 MB total index cap was reached |
| `index_dropped` | paths whose text was shed to keep the POST under the size limit |

Not indexed: binaries, lockfiles, minified files, anything over 256 KB, and
anything under a vendored or build directory. Patches are trimmed to 80 lines.
The workflow checks out with `fetch-depth: 0`, which the last-change lookups
need as much as the pair builds do.
