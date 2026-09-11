#!/usr/bin/env bash
#
# collide-check.sh: pair-build the open PRs that codemap predicts will collide.
#
# CI builds every PR against the base branch and never against its siblings.
# This script closes that blind spot: it asks `codemap collide` which open PRs
# touch the same files, then actually merges each predicted pair into a throwaway
# worktree and runs the repo's build command on the result.
#
# Environment (all set by action.yml, all overridable when run by hand):
#   TARGET_REPO      owner/name whose open PRs are read (required)
#   TARGET_DIR       path to a git checkout of TARGET_REPO (default: $PWD)
#   BUILD_COMMAND    command run in each merged worktree
#   MIN_IMPORTERS    passed to codemap collide --min-importers
#   BASE_BRANCH      branch the pairs are merged onto (default: repo default branch)
#   CODEMAP_VERSION  codemap release to download (default: 4.5.1)
#   CODEMAP_BIN      path to a prebuilt codemap; skips the download when set
#   THIS_PR          the PR this run belongs to; scopes builds and the exit code
#   ALL_PAIRS        "true" builds every predicted pair even when THIS_PR is set
#   PAIR_TIMEOUT     seconds allowed per pair build (default: 600)
#   COMMENT          "true" posts a sticky comment on THIS_PR (default: true)
#   SUMMARY_FILE     markdown destination (default: $GITHUB_STEP_SUMMARY, else none)
#   GH_TOKEN         token gh uses to read TARGET_REPO's open PRs
#   CALIBRATION_OUT  copy calibration.jsonl (one line per built pair) here when set
#
# Exit status: 0 when every built pair passes, 1 when a pair fails. With THIS_PR
# set, only a failing pair that includes THIS_PR fails the run.

set -euo pipefail

TARGET_REPO="${TARGET_REPO:-}"
TARGET_DIR="${TARGET_DIR:-$PWD}"
BUILD_COMMAND="${BUILD_COMMAND:-go build ./... && go vet ./...}"
MIN_IMPORTERS="${MIN_IMPORTERS:-0}"
BASE_BRANCH="${BASE_BRANCH:-}"
CODEMAP_VERSION="${CODEMAP_VERSION:-4.5.1}"
CODEMAP_BIN="${CODEMAP_BIN:-}"
THIS_PR="${THIS_PR:-}"
ALL_PAIRS="${ALL_PAIRS:-false}"
PAIR_TIMEOUT="${PAIR_TIMEOUT:-600}"
COMMENT="${COMMENT:-true}"
SUMMARY_FILE="${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-}}"

die() {
	echo "collide-check: $*" >&2
	exit 2
}

for tool in git gh jq curl tar python3; do
	command -v "$tool" >/dev/null || die "$tool not found on PATH"
done
[ -n "$TARGET_REPO" ] || die "TARGET_REPO is required (owner/name)"
[ -d "$TARGET_DIR/.git" ] || die "TARGET_DIR ($TARGET_DIR) is not a git checkout"

TARGET_DIR="$(cd "$TARGET_DIR" && pwd)"

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/collide-check.XXXXXX")"
cleanup() {
	if [ -d "$TARGET_DIR/.git" ]; then
		git -C "$TARGET_DIR" worktree prune
	fi
	rm -rf "$WORK_ROOT"
}
trap cleanup EXIT

# Merges need an identity; passed per command so the target checkout's
# .git/config is never written.
GIT_ID=(-c user.name=codemap-ci -c user.email=codemap-ci@users.noreply.github.com)

# ---------------------------------------------------------------------------
# 1. codemap binary: a release tarball that also carries ast-grep and the rules
# ---------------------------------------------------------------------------
if [ -z "$CODEMAP_BIN" ]; then
	os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) die "unsupported architecture $(uname -m)" ;;
	esac
	asset="codemap-full_${CODEMAP_VERSION}_${os}_${arch}.tar.gz"
	base_url="https://github.com/JordanCoin/codemap/releases/download/v${CODEMAP_VERSION}"
	echo "collide-check: downloading $asset" >&2
	mkdir -p "$WORK_ROOT/codemap-dist"
	curl -fsSL --retry 3 -o "$WORK_ROOT/$asset" "$base_url/$asset" ||
		die "could not download $base_url/$asset"
	if curl -fsSL -o "$WORK_ROOT/checksums.txt" "$base_url/checksums.txt" 2>/dev/null; then
		expected="$(awk -v a="$asset" '$2 == a { print $1 }' "$WORK_ROOT/checksums.txt")"
		if [ -n "$expected" ]; then
			actual="$(sha256sum "$WORK_ROOT/$asset" 2>/dev/null || shasum -a 256 "$WORK_ROOT/$asset")"
			actual="${actual%% *}"
			[ "$actual" = "$expected" ] || die "sha256 mismatch for $asset"
		fi
	fi
	tar xzf "$WORK_ROOT/$asset" -C "$WORK_ROOT/codemap-dist"
	export PATH="$WORK_ROOT/codemap-dist:$PATH"
	CODEMAP_BIN="$WORK_ROOT/codemap-dist/codemap"
fi
[ -x "$CODEMAP_BIN" ] || die "codemap binary $CODEMAP_BIN is not executable"
CODEMAP_VERSION_SEEN="$("$CODEMAP_BIN" --version 2>/dev/null | awk '{print $2}')"

# ---------------------------------------------------------------------------
# 2. base branch and the open PR list (titles and authors for the summary)
# ---------------------------------------------------------------------------
if [ -z "$BASE_BRANCH" ]; then
	BASE_BRANCH="$(gh repo view "$TARGET_REPO" --json defaultBranchRef --jq '.defaultBranchRef.name')"
fi
[ -n "$BASE_BRANCH" ] || die "could not determine the base branch of $TARGET_REPO"

PRS="$WORK_ROOT/prs.json"
gh pr list --repo "$TARGET_REPO" --state open --limit 100 \
	--json number,title,author,headRefName >"$PRS"
pr_title() { jq -r --argjson n "$1" '.[] | select(.number == $n) | .title' "$PRS"; }
pr_author() { jq -r --argjson n "$1" '.[] | select(.number == $n) | .author.login' "$PRS"; }

# ---------------------------------------------------------------------------
# 3. predict
# ---------------------------------------------------------------------------
REPORT="$WORK_ROOT/collide.json"
echo "collide-check: codemap collide --repo $TARGET_REPO --min-importers $MIN_IMPORTERS" >&2
(cd "$TARGET_DIR" && "$CODEMAP_BIN" collide --json --repo "$TARGET_REPO" --min-importers "$MIN_IMPORTERS") >"$REPORT"

TRUST="$(jq -r '.trust // "unknown"' "$REPORT")"
COVERAGE="$(jq -r '.coverage.status // "unknown"' "$REPORT")"
PR_COUNT="$(jq -r '.prs | length' "$REPORT")"
SHARED_COUNT="$(jq -r '.shared_files | length' "$REPORT")"
HIDDEN="$(jq -r '.hidden_by_min_importers // 0' "$REPORT")"

# Pairs to build in this run, and the ones left to their own PRs' runs.
if [ -n "$THIS_PR" ] && [ "$ALL_PAIRS" != "true" ]; then
	BUILD_PAIRS="$(jq -c --argjson n "$THIS_PR" '[.pairs[] | select(.a == $n or .b == $n)]' "$REPORT")"
	OTHER_PAIRS="$(jq -c --argjson n "$THIS_PR" '[.pairs[] | select(.a != $n and .b != $n)]' "$REPORT")"
else
	BUILD_PAIRS="$(jq -c '.pairs' "$REPORT")"
	OTHER_PAIRS='[]'
fi
BUILD_COUNT="$(jq 'length' <<<"$BUILD_PAIRS")"

# ---------------------------------------------------------------------------
# 4. fetch base and every PR head we will merge (plus THIS_PR for blast radius)
# ---------------------------------------------------------------------------
git -C "$TARGET_DIR" fetch --force --quiet origin "$BASE_BRANCH:refs/collide-check/base"
FETCH_PRS="$(jq -r '[.[] | .a, .b] | unique | .[]' <<<"$BUILD_PAIRS")"
if [ -n "$THIS_PR" ]; then
	FETCH_PRS="$(printf '%s\n%s\n' "$FETCH_PRS" "$THIS_PR" | sort -un)"
fi
while read -r number; do
	[ -n "$number" ] || continue
	git -C "$TARGET_DIR" fetch --force --quiet origin "pull/$number/head:refs/collide-check/pr-$number"
done <<<"$FETCH_PRS"

# ---------------------------------------------------------------------------
# 5. pair builds. Every failure mode becomes a status; the summary always runs.
# ---------------------------------------------------------------------------
RESULTS="$WORK_ROOT/results.tsv" # a<TAB>b<TAB>status<TAB>logfile
: >"$RESULTS"
FAILED=0
FAILED_MINE=0

# ponytail: shared-file heuristic, calibrate from calibration.jsonl once there
# are ~50 built pairs. Until then this is a prior, not a measurement.
pair_likelihood() { # a b -> high|medium|low|unknown
	jq -r --argjson a "$1" --argjson b "$2" '.pairs[] | select(.a == $a and .b == $b) |
		if .shared_file_count >= 3 or (.top_importers_known and .top_importer_count >= 3) then "high"
		elif .shared_file_count == 2 then "medium"
		elif .top_importers_known then "low"
		else "unknown" end' "$REPORT"
}

CALIBRATION="$WORK_ROOT/calibration.jsonl"
: >"$CALIBRATION"

build_pair() {
	local a="$1" b="$2"
	local wt="$WORK_ROOT/pair-$a-$b"
	local log="$WORK_ROOT/pair-$a-$b.log"
	local status="pass"
	local started
	started="$(date +%s)"

	if ! git -C "$TARGET_DIR" worktree add --detach "$wt" "refs/collide-check/base" >"$log" 2>&1; then
		status="worktree failed"
	else
		local ref
		for ref in "refs/collide-check/pr-$a" "refs/collide-check/pr-$b"; do
			if ! git "${GIT_ID[@]}" -C "$wt" merge --no-edit "$ref" >"$log" 2>&1; then
				status="merge conflict"
				break
			fi
		done
		if [ "$status" = "pass" ]; then
			set +e
			(cd "$wt" && timeout "$PAIR_TIMEOUT" bash -c "$BUILD_COMMAND") >"$log" 2>&1
			local rc=$?
			set -e
			if [ "$rc" -eq 124 ]; then
				status="timed out"
				echo "build exceeded ${PAIR_TIMEOUT}s" >>"$log"
			elif [ "$rc" -ne 0 ]; then
				status="build failed"
			fi
		fi
		git -C "$TARGET_DIR" worktree remove --force "$wt" >/dev/null 2>&1 || true
	fi

	printf '%s\t%s\t%s\t%s\n' "$a" "$b" "$status" "$log" >>"$RESULTS"
	jq -c -n --arg repo "$TARGET_REPO" --argjson a "$a" --argjson b "$b" --arg status "$status" \
		--arg likelihood "$(pair_likelihood "$a" "$b")" --argjson seconds "$(($(date +%s) - started))" \
		--argjson pair "$(jq -c --argjson a "$a" --argjson b "$b" '.pairs[] | select(.a == $a and .b == $b)' "$REPORT")" \
		'{repo: $repo, a: $a, b: $b, shared_file_count: $pair.shared_file_count,
		  top_importer_count: (if $pair.top_importers_known then $pair.top_importer_count else null end),
		  any_hub: ($pair.top_importers_known and $pair.top_importer_count >= 3),
		  likelihood: $likelihood, outcome: $status, seconds: $seconds}' >>"$CALIBRATION"
	if [ "$status" != "pass" ]; then
		FAILED=$((FAILED + 1))
		if [ -n "$THIS_PR" ] && { [ "$a" = "$THIS_PR" ] || [ "$b" = "$THIS_PR" ]; }; then
			FAILED_MINE=$((FAILED_MINE + 1))
		fi
	fi
	echo "collide-check: #$a + #$b -> $status" >&2
}

while read -r a b; do
	[ -n "$a" ] || continue
	build_pair "$a" "$b"
done < <(jq -r '.[] | "\(.a) \(.b)"' <<<"$BUILD_PAIRS")
if [ -n "${CALIBRATION_OUT:-}" ]; then
	cp "$CALIBRATION" "$CALIBRATION_OUT"
fi

# ---------------------------------------------------------------------------
# 6. blast radius of THIS_PR: which of its files do other files depend on
# ---------------------------------------------------------------------------
BLAST="$WORK_ROOT/blast.tsv" # count<TAB>hub<TAB>path
: >"$BLAST"
BLAST_NOTE=""
BLAST_LEVEL=""
BLAST_LINE=""
if [ -n "$THIS_PR" ]; then
	changed="$(git -C "$TARGET_DIR" diff --name-only "refs/collide-check/base...refs/collide-check/pr-$THIS_PR" 2>/dev/null || true)"
	changed_count="$(printf '%s' "$changed" | grep -c . || true)"
	if [ "$changed_count" -gt 30 ]; then
		BLAST_NOTE="$changed_count files changed; importer lookup skipped above 30."
	else
		while read -r path; do
			[ -n "$path" ] || continue
			[ -f "$TARGET_DIR/$path" ] || continue
			row="$(cd "$TARGET_DIR" && "$CODEMAP_BIN" --json --importers "$path" 2>/dev/null |
				jq -r '"\(.importer_count // 0)\t\(if .is_hub then 1 else 0 end)\t\(.coverage_status // "unknown")"' || echo "0	0	unavailable")"
			n="${row%%	*}"
			case "$row" in *unavailable) BLAST_UNAVAILABLE=1 ;; esac
			[ "${n:-0}" -gt 0 ] && printf '%s\t%s\n' "$row" "$path" >>"$BLAST"
		done <<<"$changed"
		sort -rn -o "$BLAST" "$BLAST"
	fi
	# Level: codemap calls 3 importers a hub; 9 (3x) or two hubs in one PR is high.
	top="$(head -1 "$BLAST" | cut -f1)"
	hubs="$(awk -F'\t' '$2 == 1' "$BLAST" | wc -l | tr -d ' ')"
	if [ -n "$BLAST_NOTE" ] || { [ "${BLAST_UNAVAILABLE:-0}" -eq 1 ] && [ ! -s "$BLAST" ]; }; then
		BLAST_LEVEL="unknown"
	elif [ "${top:-0}" -ge 9 ] || [ "$hubs" -ge 2 ]; then
		BLAST_LEVEL="high"
	elif [ "$hubs" -ge 1 ]; then
		BLAST_LEVEL="medium"
	else
		BLAST_LEVEL="low"
	fi
	BLAST_LINE="Blast radius: $(tr '[:lower:]' '[:upper:]' <<<"$BLAST_LEVEL")"
	if [ -s "$BLAST" ]; then
		BLAST_LINE="$BLAST_LINE · $(head -1 "$BLAST" | awk -F'\t' '{ printf "%s %s importers", $4, $1 }') · $hubs hub(s) touched"
	fi
fi

# ---------------------------------------------------------------------------
# 7. verdict, annotations, summary
# ---------------------------------------------------------------------------
pair_shared() { # top file line for a pair from the report
	jq -r --argjson a "$1" --argjson b "$2" '.pairs[] | select(.a == $a and .b == $b) |
		"\(.top_file) (" + (if .top_importers_known then (.top_importer_count | tostring) + " importers" else "importers unknown" end) + ")" +
		(if .shared_file_count > 1 then " · +\(.shared_file_count - 1) more" else "" end)' "$REPORT"
}

# ponytail: greedy order (fewest failing edges first, older first on ties), not
# optimal. Fine below ~15 open PRs; switch to a proper feedback-arc solver past that.
merge_order() {
	python3 - "$RESULTS" "$THIS_PR" <<'PY'
import sys
results, this_pr = sys.argv[1], sys.argv[2]
edges = set()
nodes = set()
for line in open(results):
    a, b, status, _ = line.rstrip("\n").split("\t")
    a, b = int(a), int(b)
    nodes |= {a, b}
    if status != "pass":
        edges.add(frozenset((a, b)))
if this_pr:
    nodes.add(int(this_pr))
if not edges:
    print("Every built pair passes; any order works.")
    sys.exit(0)
bad = {n: {next(iter(e - {n})) for e in edges if n in e} for n in nodes}
landed, order = [], []
remaining = set(nodes)
while remaining:
    pick = min(remaining, key=lambda n: (len(bad[n] & remaining), n))
    after = sorted(bad[pick] & set(landed))
    order.append((pick, after))
    landed.append(pick)
    remaining.remove(pick)
me = int(this_pr) if this_pr else None
if me is not None and bad[me]:
    pos = {n: i for i, (n, _) in enumerate(order)}
    before = sorted(n for n in bad[me] if pos[n] < pos[me])
    if before:
        print(f"Land {', '.join(f'#{n}' for n in before)} first, then rebase this PR (#{me}).")
    else:
        others = sorted(bad[me])
        if others:
            print(f"Land this PR (#{me}) first; {', '.join(f'#{n}' for n in others)} must rebase after it.")
    print()
for i, (n, after) in enumerate(order, 1):
    tail = f" (rebase after {', '.join(f'#{a}' for a in after)})" if after else ""
    print(f"{i}. #{n}{tail}")
# Pairs where neither side can land as-is on top of the other: the human picks one.
for e in sorted(edges, key=lambda e: tuple(sorted(e))):
    a, b = sorted(e)
    print(f"\n#{a} and #{b}: only one can land as-is; keep the older (#{a}) unless told otherwise.")
PY
}

VERDICT=""
if [ -n "$THIS_PR" ]; then
	if [ "$FAILED_MINE" -gt 0 ]; then
		others="$(awk -F'\t' -v me="$THIS_PR" '$3 != "pass" { print ($1 == me) ? $2 : $1 }' "$RESULTS" | sort -un)"
		parts=()
		while read -r o; do
			[ -n "$o" ] || continue
			parts+=("#$o \"$(pr_title "$o")\" by @$(pr_author "$o")")
		done <<<"$others"
		joined="$(IFS=';' && printf '%s' "${parts[*]}" | sed 's/;/ and /g')"
		# A textual conflict and a compile failure are different news: the first
		# blocks whoever merges second, the second lets both merge and breaks main.
		if awk -F'\t' -v me="$THIS_PR" '($1 == me || $2 == me) && $3 != "pass" && $3 != "merge conflict" { found = 1 } END { exit !found }' "$RESULTS"; then
			VERDICT="This PR (#$THIS_PR) does not build together with $joined. Each is green alone. Whichever merges second breaks $BASE_BRANCH."
		else
			VERDICT="This PR (#$THIS_PR) conflicts with $joined. Git will refuse whichever merges second, so one of them needs a rebase."
		fi
	elif [ "$BUILD_COUNT" -gt 0 ]; then
		VERDICT="No merge-order hazard for #$THIS_PR. Built against $BUILD_COUNT open PR(s) that share files with it; all pass."
	else
		VERDICT="No open PR shares a file with #$THIS_PR."
	fi
else
	VERDICT="$PR_COUNT open PR(s), $SHARED_COUNT shared file(s), $BUILD_COUNT pair(s) built, $FAILED failing."
fi
echo "::notice title=codemap collide::$VERDICT${BLAST_LEVEL:+ · blast radius $BLAST_LEVEL}"

# Inline annotations on THIS_PR's diff for compiler-style "path:line: msg" lines.
if [ -n "$THIS_PR" ] && [ "$FAILED_MINE" -gt 0 ]; then
	while IFS=$'\t' read -r a b status log; do
		[ "$status" = "pass" ] && continue
		{ [ "$a" = "$THIS_PR" ] || [ "$b" = "$THIS_PR" ]; } || continue
		head -10 "$log" | sed -E -n 's#^\.?/?([^:[:space:]]+\.[A-Za-z0-9]+):([0-9]+)(:[0-9]+)?:[[:space:]]*(.+)$#\1\t\2\t\4#p' |
			while IFS=$'\t' read -r file line msg; do
				echo "::error file=$file,line=$line,title=collide #$a + #$b::$msg"
			done
	done <"$RESULTS"
fi

BODY="$WORK_ROOT/body.md" # summary without the H2, reused for the comment
{
	echo "**$VERDICT**${BLAST_LEVEL:+ · blast radius \`$BLAST_LEVEL\`}"
	echo

	if awk -F'\t' '$3 != "pass"' "$RESULTS" | grep -q .; then
		echo "### Failing pairs"
		echo
		while IFS=$'\t' read -r a b status log; do
			[ "$status" = "pass" ] && continue
			echo "**#$a + #$b** · $status · likelihood \`$(pair_likelihood "$a" "$b")\` · shared: $(pair_shared "$a" "$b")"
			echo
			echo '```'
			head -12 "$log"
			echo '```'
			echo
		done <"$RESULTS"
	fi

	if awk -F'\t' '$3 == "pass"' "$RESULTS" | grep -q .; then
		echo "### Passing pairs"
		echo
		while IFS=$'\t' read -r a b status log; do
			[ "$status" = "pass" ] || continue
			echo "- #$a + #$b · likelihood \`$(pair_likelihood "$a" "$b")\` · shared: $(pair_shared "$a" "$b")"
		done <"$RESULTS"
		echo
	fi

	if awk -F'\t' '$3 != "pass"' "$RESULTS" | grep -q .; then
		echo "### Merge order"
		echo
		merge_order
		echo
	fi

	if [ "$(jq 'length' <<<"$OTHER_PAIRS")" -gt 0 ]; then
		echo "### Predicted, not built in this run"
		echo
		while read -r a b; do
			[ -n "$a" ] || continue
			echo "- #$a + #$b · likelihood \`$(pair_likelihood "$a" "$b")\` · shared: $(pair_shared "$a" "$b")"
		done < <(jq -r '.[] | "\(.a) \(.b)"' <<<"$OTHER_PAIRS")
		echo
		echo "These pairs do not include #$THIS_PR; their own PRs' runs build them."
		echo
	fi

	if [ -n "$BLAST_LEVEL" ]; then
		echo "### Files in this PR that others depend on"
		echo
		echo "$BLAST_LINE"
		echo
		if [ -n "$BLAST_NOTE" ]; then
			echo "$BLAST_NOTE"
		else
			head -5 "$BLAST" | awk -F'\t' '{ printf "- `%s` · %s importers%s\n", $4, $1, ($2 == 1 ? " (hub)" : "") }'
		fi
		echo
	fi

	echo "### Coverage"
	echo
	echo "trust \`$TRUST\` · coverage \`$COVERAGE\` · $PR_COUNT open PRs · $SHARED_COUNT shared files · codemap $CODEMAP_VERSION_SEEN"
	if [ "$HIDDEN" -gt 0 ]; then
		echo "· $HIDDEN shared file(s) hidden by \`--min-importers $MIN_IMPORTERS\`"
	fi
	case "$TRUST/$COVERAGE" in
	*low* | */partial | */unavailable)
		echo
		echo "Importer counts may be missing for some files, so a hazard can be under-ranked. Tune \`.codemap/config.json\` in the target repo to cover its source tree."
		;;
	esac
} >"$BODY"

MD="$WORK_ROOT/summary.md"
{
	echo "## codemap collide"
	echo
	cat "$BODY"
} >"$MD"

if [ -n "$SUMMARY_FILE" ]; then
	cat "$MD" >>"$SUMMARY_FILE"
fi
cat "$MD"

# ---------------------------------------------------------------------------
# 8. sticky comment on THIS_PR and on the other half of each failing pair
# ---------------------------------------------------------------------------
MARKER="<!-- codemap-ci:collide -->"
upsert_comment() {
	local number="$1"
	local payload="$WORK_ROOT/comment-$number.json"
	jq -n --arg body "$MARKER"$'\n'"$(cat "$BODY")" '{body: $body}' >"$payload"
	local existing
	existing="$(gh api "repos/$TARGET_REPO/issues/$number/comments" --paginate \
		--jq "[.[] | select(.body | startswith(\"$MARKER\"))] | .[0].id // empty" 2>/dev/null || true)"
	local out rc
	set +e
	if [ -n "$existing" ]; then
		out="$(gh api -X PATCH "repos/$TARGET_REPO/issues/comments/$existing" --input "$payload" 2>&1)"
	else
		out="$(gh api -X POST "repos/$TARGET_REPO/issues/$number/comments" --input "$payload" 2>&1)"
	fi
	rc=$?
	set -e
	if [ "$rc" -ne 0 ]; then
		echo "::warning title=codemap collide::could not comment on #$number (needs pull-requests: write): ${out:0:200}"
	else
		echo "collide-check: commented on #$number" >&2
	fi
}

if [ "$COMMENT" = "true" ] && [ -n "$THIS_PR" ]; then
	upsert_comment "$THIS_PR"
	awk -F'\t' -v me="$THIS_PR" '$3 != "pass" && ($1 == me || $2 == me) { print ($1 == me) ? $2 : $1 }' "$RESULTS" |
		sort -un | while read -r other; do
		[ -n "$other" ] && upsert_comment "$other"
	done
fi

if [ -n "$THIS_PR" ]; then
	[ "$FAILED_MINE" -gt 0 ] && exit 1
	exit 0
fi
[ "$FAILED" -gt 0 ] && exit 1
exit 0
