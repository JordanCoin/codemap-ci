#!/usr/bin/env bash
#
# collide-check.sh — pair-build the open PRs that codemap predicts will collide.
#
# CI builds every PR against the base branch and never against its siblings.
# This script closes that blind spot: it asks `codemap collide` which open PRs
# touch the same files, then actually merges each predicted pair into a throwaway
# worktree and runs the repo's build command on the result.
#
# Environment (all set by action.yml, all overridable when run by hand):
#   TARGET_REPO     owner/name whose open PRs are read (required)
#   TARGET_DIR      path to a git checkout of TARGET_REPO (default: $PWD)
#   BUILD_COMMAND   command run in each merged worktree
#   MIN_IMPORTERS   passed to codemap collide --min-importers
#   BASE_BRANCH     branch the pairs are merged onto (default: repo default branch)
#   CODEMAP_REPO    git URL to build codemap from
#   CODEMAP_REF     ref of CODEMAP_REPO to build
#   CODEMAP_BIN     path to a prebuilt codemap; skips the build when set
#   SUMMARY_FILE    markdown destination (default: $GITHUB_STEP_SUMMARY, else stdout)
#   GH_TOKEN        token gh uses to read TARGET_REPO's open PRs
#
# Exit status: 0 when every predicted pair builds, 1 when any pair fails.

set -euo pipefail

TARGET_REPO="${TARGET_REPO:-}"
TARGET_DIR="${TARGET_DIR:-$PWD}"
BUILD_COMMAND="${BUILD_COMMAND:-go build ./... && go vet ./...}"
MIN_IMPORTERS="${MIN_IMPORTERS:-0}"
BASE_BRANCH="${BASE_BRANCH:-}"
CODEMAP_REPO="${CODEMAP_REPO:-https://github.com/JordanCoin/codemap.git}"
CODEMAP_REF="${CODEMAP_REF:-main}"
CODEMAP_BIN="${CODEMAP_BIN:-}"
SUMMARY_FILE="${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-}}"
THIS_PR="${THIS_PR:-}" # when set, only a failing pair that includes this PR fails the run

die() {
	echo "collide-check: $*" >&2
	exit 2
}

for tool in git gh jq; do
	command -v "$tool" >/dev/null || die "$tool not found on PATH"
done
[ -n "$TARGET_REPO" ] || die "TARGET_REPO is required (owner/name)"
[ -d "$TARGET_DIR/.git" ] || die "TARGET_DIR ($TARGET_DIR) is not a git checkout"

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/collide-check.XXXXXX")"
cleanup() {
	# Worktrees live inside WORK_ROOT; drop git's registrations before the files.
	if [ -d "$TARGET_DIR/.git" ]; then
		git -C "$TARGET_DIR" worktree prune
	fi
	rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# 1. codemap binary
# ---------------------------------------------------------------------------
if [ -z "$CODEMAP_BIN" ]; then
	command -v go >/dev/null || die "go not found on PATH and CODEMAP_BIN is unset"
	echo "collide-check: building codemap from $CODEMAP_REPO@$CODEMAP_REF" >&2
	# codemap's go.mod declares `module codemap`, not a github.com/... path, so
	# `go install github.com/JordanCoin/codemap@ref` cannot resolve it. Clone.
	git clone --depth 1 --branch "$CODEMAP_REF" "$CODEMAP_REPO" "$WORK_ROOT/codemap-src"
	( cd "$WORK_ROOT/codemap-src" && go build -o "$WORK_ROOT/codemap" . )
	CODEMAP_BIN="$WORK_ROOT/codemap"
fi
[ -x "$CODEMAP_BIN" ] || die "codemap binary $CODEMAP_BIN is not executable"

# ---------------------------------------------------------------------------
# 2. base branch
# ---------------------------------------------------------------------------
if [ -z "$BASE_BRANCH" ]; then
	BASE_BRANCH="$(gh repo view "$TARGET_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')"
fi
[ -n "$BASE_BRANCH" ] || die "could not determine the base branch of $TARGET_REPO"

# ---------------------------------------------------------------------------
# 3. predict
# ---------------------------------------------------------------------------
REPORT="$WORK_ROOT/collide.json"
echo "collide-check: codemap collide --repo $TARGET_REPO --min-importers $MIN_IMPORTERS" >&2
( cd "$TARGET_DIR" && "$CODEMAP_BIN" collide --json --repo "$TARGET_REPO" --min-importers "$MIN_IMPORTERS" ) >"$REPORT"

TRUST="$(jq -r '.trust // "UNKNOWN"' "$REPORT")"
COVERAGE="$(jq -r '.coverage.status // "unknown"' "$REPORT")"
PR_COUNT="$(jq -r '.prs | length' "$REPORT")"
PAIR_COUNT="$(jq -r '.pairs | length' "$REPORT")"
HIDDEN="$(jq -r '.hidden_by_min_importers // 0' "$REPORT")"

# ---------------------------------------------------------------------------
# 4. fetch every PR head named in a predicted pair
# ---------------------------------------------------------------------------
PAIR_PRS="$(jq -r '[.pairs[] | .a, .b] | unique | .[]' "$REPORT")"
if [ -n "$PAIR_PRS" ]; then
	while read -r number; do
		[ -n "$number" ] || continue
		git -C "$TARGET_DIR" fetch --force origin \
			"pull/$number/head:refs/collide-check/pr-$number"
	done <<<"$PAIR_PRS"
fi
git -C "$TARGET_DIR" fetch --force origin "$BASE_BRANCH:refs/collide-check/base"

# Merges need an identity. Passed per-command with -c rather than written with
# `git config`, so running this against a working checkout leaves no trace.
GIT_ID=(-c "user.name=codemap-ci" -c "user.email=codemap-ci@users.noreply.github.com")

# ---------------------------------------------------------------------------
# 5. pair builds
# ---------------------------------------------------------------------------
RESULTS="$WORK_ROOT/results.tsv" # a<TAB>b<TAB>status<TAB>errfile
: >"$RESULTS"
FAILED=0
FAILED_MINE=0

build_pair() {
	local a="$1" b="$2"
	local wt="$WORK_ROOT/pair-$a-$b"
	local err="$WORK_ROOT/pair-$a-$b.log"
	local status="pass"

	git -C "$TARGET_DIR" worktree add --detach "$wt" "refs/collide-check/base" >&2

	local merged=1
	local ref
	for ref in "refs/collide-check/pr-$a" "refs/collide-check/pr-$b"; do
		if ! git -C "$wt" "${GIT_ID[@]}" merge --no-edit "$ref" >"$err.merge" 2>&1; then
			status="merge conflict"
			cp "$err.merge" "$err"
			merged=0
			break
		fi
	done

	if [ "$merged" -eq 1 ]; then
		if ! ( cd "$wt" && bash -c "$BUILD_COMMAND" ) >"$err" 2>&1; then
			status="build failed"
		fi
	fi

	git -C "$TARGET_DIR" worktree remove --force "$wt"
	printf '%s\t%s\t%s\t%s\n' "$a" "$b" "$status" "$err" >>"$RESULTS"
	if [ "$status" != "pass" ]; then
		FAILED=$((FAILED + 1))
		if [ -n "$THIS_PR" ] && { [ "$a" = "$THIS_PR" ] || [ "$b" = "$THIS_PR" ]; }; then
			FAILED_MINE=$((FAILED_MINE + 1))
		fi
	fi
	echo "collide-check: #$a + #$b -> $status" >&2
}

if [ "$PAIR_COUNT" -gt 0 ]; then
	while read -r a b; do
		[ -n "$a" ] || continue
		build_pair "$a" "$b"
	done < <(jq -r '.pairs[] | "\(.a) \(.b)"' "$REPORT")
fi

# ---------------------------------------------------------------------------
# 6. markdown summary (format: codemap issue #134)
# ---------------------------------------------------------------------------
MD="$WORK_ROOT/summary.md"
{
	echo "## codemap collide — merge-order hazard"
	echo
	echo "\`$TARGET_REPO\` · base \`$BASE_BRANCH\` · $PR_COUNT open PR(s) · trust \`$TRUST\` · coverage \`$COVERAGE\` · \`--min-importers $MIN_IMPORTERS\`"
	echo
	echo "> CI builds every PR against \`$BASE_BRANCH\` and never against its siblings."
	echo

	echo "### SHARED FILES (each = a merge-order hazard)"
	echo
	echo '```'
	if [ "$(jq -r '.shared_files | length' "$REPORT")" -eq 0 ]; then
		echo "  none"
	else
		jq -r '.shared_files[] |
			"  \(.prs | length) PRs   \(.path)   <- " +
			(.prs | map("#" + (. | tostring)) | join(", ")) +
			"   [" + (if .importers_known then ((.importer_count | tostring) + " " + .importer_scope + " importers") else "importers unknown" end) + "]"' "$REPORT"
	fi
	if [ "$HIDDEN" -gt 0 ]; then
		echo "  ($HIDDEN shared file(s) hidden by --min-importers $MIN_IMPORTERS)"
	fi
	echo '```'
	echo

	echo "### PREDICTED COLLIDING PAIRS"
	echo
	echo '```'
	if [ "$PAIR_COUNT" -eq 0 ]; then
		echo "  none"
	else
		jq -r '.pairs[] |
			"  #\(.a) + #\(.b)  ->  \(.shared_file_count) shared file(s)   top: \(.top_file)"' "$REPORT"
	fi
	echo '```'
	echo

	echo "### Pair builds"
	echo
	echo "| Pair | Result | Error |"
	echo "| --- | --- | --- |"
	if [ ! -s "$RESULTS" ]; then
		echo "| — | no predicted pairs to build | |"
	else
		while IFS=$'\t' read -r a b status err; do
			if [ "$status" = "pass" ]; then
				echo "| #$a + #$b | ✅ pass | |"
			else
				# First 20 lines of the failure, flattened into one table cell.
				detail="$(head -20 "$err" | sed 's/|/\\|/g' | sed 's/$/<br>/' | tr -d '\n')"
				echo "| #$a + #$b | ❌ $status | <pre>$detail</pre> |"
			fi
		done <"$RESULTS"
	fi
	echo

	if [ "$FAILED" -gt 0 ]; then
		echo "**$FAILED predicted pair(s) do not build together.** Each one is green on its own."
		if [ -n "$THIS_PR" ]; then
			if [ "$FAILED_MINE" -gt 0 ]; then
				echo
				echo "PR #$THIS_PR is part of $FAILED_MINE of them, so this check fails for it."
			else
				echo
				echo "PR #$THIS_PR is not part of any failing pair, so this check passes for it. The failing pairs belong to other open PRs."
			fi
		fi
	else
		echo "All predicted pairs build together."
	fi
} >"$MD"

if [ -n "$SUMMARY_FILE" ]; then
	cat "$MD" >>"$SUMMARY_FILE"
fi
cat "$MD"

if [ -n "$THIS_PR" ]; then
	if [ "$FAILED_MINE" -gt 0 ]; then
		exit 1
	fi
	exit 0
fi
if [ "$FAILED" -gt 0 ]; then
	exit 1
fi
exit 0
