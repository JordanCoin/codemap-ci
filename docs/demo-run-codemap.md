# Demo run: codemap-ci pointed at JordanCoin/codemap

`workflow_dispatch` against a **different** repo needs the `CODEMAP_TARGET_TOKEN` secret,
which does not exist on this repository (this repo does not create secrets). So this run was
produced by running `scripts/collide-check.sh` locally with the maintainer's `gh` auth:

```
TARGET_REPO=JordanCoin/codemap \
TARGET_DIR=<a full clone of codemap> \
CODEMAP_BIN=<codemap built from main> \
BUILD_COMMAND='go build ./... && go vet ./...' \
  bash scripts/collide-check.sh
```

Run date: 2026-09-04. codemap main at `a4b071e` (the commit that merged #180, which is where
`codemap collide` shipped). Exit status: **0** — every predicted pair built.

## Reading this result honestly

This is a **negative** result and it is worth keeping as one. codemap's three open PRs overlap
heavily — 47 shared files, every pair — and they still compile together. The prediction says
"these are worth checking"; the pair build is what turns that into an answer.

The overlap is real rather than an artifact: #171 touches 47 files, #181 touches 63, #182
touches 58, and #171's whole changeset is a subset of the other two. Large sibling refactors
of the same packages are exactly the case where shared-file count alone would cry wolf, and
exactly why the check builds instead of just warning.

For the case where a pair genuinely does not compile, see `proof.md`.

## Output

## codemap collide — merge-order hazard

`JordanCoin/codemap` · base `main` · 3 open PR(s) · trust `high` · coverage `complete` · `--min-importers 0`

> CI builds every PR against `main` and never against its siblings.

### SHARED FILES (each = a merge-order hazard)

```
  3 PRs   scanner/cargofallback.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/cue.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/deps_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/filegraph.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/filegraph_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/hotpath_benchmark_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/jsworkspace.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/outcome.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/outcome_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/rustaskama_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/rustbuildscript.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/rustbuildscript_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/rustcargo.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/rustcargo_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/rustgraph.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/types.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/types_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/walker.go   <- #171, #181, #182   [74 package importers]
  3 PRs   scanner/walker_test.go   <- #171, #181, #182   [74 package importers]
  3 PRs   config/config.go   <- #171, #181, #182   [38 package importers]
  3 PRs   config/config_test.go   <- #171, #181, #182   [38 package importers]
  3 PRs   watch/daemon.go   <- #171, #181, #182   [31 package importers]
  3 PRs   watch/events.go   <- #171, #181, #182   [31 package importers]
  3 PRs   watch/graph_state_test.go   <- #171, #181, #182   [31 package importers]
  3 PRs   watch/publication.go   <- #171, #181, #182   [31 package importers]
  3 PRs   watch/publication_benchmark_test.go   <- #171, #181, #182   [31 package importers]
  3 PRs   watch/state_test.go   <- #171, #181, #182   [31 package importers]
  3 PRs   cmd/context_evidence.go   <- #171, #181, #182   [24 package importers]
  3 PRs   cmd/context_routing.go   <- #171, #181, #182   [24 package importers]
  3 PRs   cmd/context_routing_benchmark_test.go   <- #171, #181, #182   [24 package importers]
  3 PRs   cmd/context_routing_test.go   <- #171, #181, #182   [24 package importers]
  3 PRs   topology/cache.go   <- #171, #181, #182   [22 package importers]
  3 PRs   topology/cache_test.go   <- #171, #181, #182   [22 package importers]
  3 PRs   topology/graph.go   <- #171, #181, #182   [22 package importers]
  3 PRs   topology/graph_test.go   <- #171, #181, #182   [22 package importers]
  3 PRs   topology/graph_windows_test.go   <- #171, #181, #182   [22 package importers]
  3 PRs   topology/provider.go   <- #171, #181, #182   [22 package importers]
  3 PRs   topology/provider_benchmark_test.go   <- #171, #181, #182   [22 package importers]
  3 PRs   topology/provider_test.go   <- #171, #181, #182   [22 package importers]
  3 PRs   internal/runtimefile/runtimefile.go   <- #171, #181, #182   [9 package importers]
  3 PRs   internal/runtimefile/runtimefile_test.go   <- #171, #181, #182   [9 package importers]
  3 PRs   render/hotpath_benchmark_test.go   <- #171, #181, #182   [7 package importers]
  3 PRs   render/skyline.go   <- #171, #181, #182   [7 package importers]
  3 PRs   render/skyline_test.go   <- #171, #181, #182   [7 package importers]
  3 PRs   render/tree.go   <- #171, #181, #182   [7 package importers]
  3 PRs   render/tree_test.go   <- #171, #181, #182   [7 package importers]
  3 PRs   mcp/main_more_test.go   <- #171, #181, #182   [4 package importers]
```

### PREDICTED COLLIDING PAIRS

```
  #171 + #181  ->  47 shared file(s)   top: scanner/cargofallback.go
  #171 + #182  ->  47 shared file(s)   top: scanner/cargofallback.go
  #181 + #182  ->  47 shared file(s)   top: scanner/cargofallback.go
```

### Pair builds

| Pair | Result | Error |
| --- | --- | --- |
| #171 + #181 | ✅ pass | |
| #171 + #182 | ✅ pass | |
| #181 + #182 | ✅ pass | |

All predicted pairs build together.
