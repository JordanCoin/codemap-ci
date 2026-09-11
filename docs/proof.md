# Proof: a real failing check on a real colliding PR pair

Two PRs in this repo. Each is green on its own. Git merges them without a
textual conflict. They do not compile together, and the `collide` check says so
before either one lands.

| | |
| --- | --- |
| PR A | [#1 feat(demo): Widen Greet with a loud flag](https://github.com/JordanCoin/codemap-ci/pull/1) |
| PR B | [#2 feat(demo): Add greetAgain, a second caller of Greet](https://github.com/JordanCoin/codemap-ci/pull/2) |
| Failing run (PR B) | [33887772782](https://github.com/JordanCoin/codemap-ci/actions/runs/33887772782) — **failure** |
| Failing run (PR A) | [33887759499](https://github.com/JordanCoin/codemap-ci/actions/runs/33887759499) — **failure** |

Both runs are red, which is the point: the hazard belongs to the *pair*, not to
either PR, so it surfaces on whichever one you look at.

## What each PR does

- **#1** widens `Greet(name string)` to `Greet(name string, loud bool)` and
  updates its one caller in `main.go`.
- **#2** adds `cmd2.go` with `greetAgain()`, which calls `Greet("x")` — the
  signature `main` has today — and wires it into `report()` in `main.go`.

They share `main.go`, which is what `codemap collide` keys on. The edits are far
enough apart in the file that git's merge is clean. This is the shape that hit
codemap for real in #117/#118.

## Step summary from run 33887772782

Rendered into the job summary (and echoed to stdout, which is where this copy
was taken from):

<!-- begin step summary -->

## codemap collide — merge-order hazard

`JordanCoin/codemap-ci` · base `main` · 2 open PR(s) · trust `low` · coverage `partial` · `--min-importers 0`

> CI builds every PR against `main` and never against its siblings.

### SHARED FILES (each = a merge-order hazard)

```
  2 PRs   main.go   <- #1, #2   [importers unknown]
```

### PREDICTED COLLIDING PAIRS

```
  #1 + #2  ->  1 shared file(s)   top: main.go
```

### Pair builds

| Pair | Result | Error |
| --- | --- | --- |
| #1 + #2 | ❌ build failed | <pre># github.com/JordanCoin/codemap-ci/demo<br>./cmd2.go:6:15: not enough arguments in call to Greet<br>	have (string)<br>	want (string, bool)<br></pre> |

**1 predicted pair(s) do not build together.** Each one is green on its own.

<!-- end step summary -->

> `trust low` / `coverage partial` is codemap being honest: this repo is mostly YAML
> and Markdown, so the Go graph does not cover it and importer counts are reported as
> unknown rather than invented. The pair build does not depend on that number.

## Run log excerpt

`gh run view 33887772782 --repo JordanCoin/codemap-ci --log`, trimmed to the check itself:

```
collide-check: building codemap from https://github.com/JordanCoin/codemap.git@main
collide-check: codemap collide --repo JordanCoin/codemap-ci --min-importers 0
 * [new ref]         refs/pull/1/head -> refs/collide-check/pr-1
 * [new ref]         refs/pull/2/head -> refs/collide-check/pr-2
 * [new branch]      main       -> refs/collide-check/base
Preparing worktree (detached HEAD a5981b0)
collide-check: #1 + #2 -> build failed
Process completed with exit code 1.
```

The last two lines are the whole product: codemap predicted the pair, the pair was
built, the build failed, the check exited 1.

## Reproduce locally

```
git clone https://github.com/JordanCoin/codemap-ci && cd codemap-ci
git worktree add --detach /tmp/pair main
cd /tmp/pair
git merge --no-edit origin/demo/pr-a-widen-greet
git merge --no-edit origin/demo/pr-b-new-caller   # clean merge
go build ./...                                    # fails
```

## The other direction

`demo-run-codemap.md` is the same check pointed at JordanCoin/codemap, where all three
predicted pairs *do* build. A check that only ever goes red is not a check.
