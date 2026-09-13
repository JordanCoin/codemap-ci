#!/usr/bin/env bash
#
# review-gate.sh: collect free facts about a PR's changed files with codemap,
# then ask the paid review-gate API whether an AI agent review is worth
# running. The decision logic lives server-side: this script only builds a
# body of paths and counts and sends it. It never reads or sends file
# contents.
#
# Environment (all set by action.yml, all overridable when run by hand):
#   LICENSE_KEY      codemap Team license key. Empty -> facts only, review=unknown.
#   API_URL          base URL of the review-gate API (default codemap-brief-webhook.vercel.app)
#   BASE_REF         ref the changed files are diffed against (default: PR base)
#   CODEMAP_VERSION  codemap release to download (default 4.5.1)
#   CODEMAP_BIN      path to a prebuilt codemap; skips the download when set
#   SUMMARY_FILE     markdown destination (default: $GITHUB_STEP_SUMMARY, else none)
#   GITHUB_OUTPUT    step outputs destination (default: none, prints instead)
#
# Exit status: always 0. codemap-ci is a gate, not a judge: an invalid key,
# a rate limit, or a network failure sets review=unknown and moves on rather
# than failing the job.

set -euo pipefail

API_URL="${API_URL:-https://codemap-brief-webhook.vercel.app}"
BASE_REF="${BASE_REF:-}"
CODEMAP_VERSION="${CODEMAP_VERSION:-4.5.1}"
CODEMAP_BIN="${CODEMAP_BIN:-}"
LICENSE_KEY="${LICENSE_KEY:-}"
SUMMARY_FILE="${SUMMARY_FILE:-${GITHUB_STEP_SUMMARY:-}}"
CHANGED_FILE_CAP=30

die() {
	echo "review-gate: $*" >&2
	exit 2
}

for tool in git jq curl; do
	command -v "$tool" >/dev/null || die "$tool not found on PATH"
done

WORK_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/review-gate.XXXXXX")"
trap 'rm -rf "$WORK_ROOT"' EXIT

# ---------------------------------------------------------------------------
# 1. repo, pr, base_sha, head_sha: from the pull_request event payload when
#    present, else from BASE_REF / HEAD.
# ---------------------------------------------------------------------------
REPO="${GITHUB_REPOSITORY:-}"
PR=""
BASE_SHA=""
HEAD_SHA=""

if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ]; then
	PR="$(jq -r '.pull_request.number // empty' "$GITHUB_EVENT_PATH")"
	BASE_SHA="$(jq -r '.pull_request.base.sha // empty' "$GITHUB_EVENT_PATH")"
	HEAD_SHA="$(jq -r '.pull_request.head.sha // empty' "$GITHUB_EVENT_PATH")"
	[ -n "$BASE_REF" ] || BASE_REF="$(jq -r '.pull_request.base.ref // empty' "$GITHUB_EVENT_PATH")"
fi
[ -n "$HEAD_SHA" ] || HEAD_SHA="$(git rev-parse HEAD)"
if [ -z "$BASE_SHA" ]; then
	[ -n "$BASE_REF" ] || die "no PR base found (set base-ref, or run this on a pull_request event)"
	git fetch --force --quiet origin "$BASE_REF" 2>/dev/null || true
	BASE_SHA="$(git rev-parse "origin/$BASE_REF" 2>/dev/null || git rev-parse "$BASE_REF")" ||
		die "could not resolve base ref $BASE_REF"
fi

# ---------------------------------------------------------------------------
# 2. codemap binary: shared with collide-check.sh
# ---------------------------------------------------------------------------
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codemap-bin.sh"

# ---------------------------------------------------------------------------
# 3. changed files: path, added, removed, language, is_test, importers
# ---------------------------------------------------------------------------
is_test_path() {
	case "$1" in
	test/* | */test/* | tests/* | */tests/* | __tests__/* | */__tests__/* | *_test.go | *.test.* | *.spec.*) return 0 ;;
	*) return 1 ;;
	esac
}

language_of() {
	case "$1" in
	*.go) echo go ;;
	*.py) echo python ;;
	*.rb) echo ruby ;;
	*.rs) echo rust ;;
	*.java) echo java ;;
	*.kt | *.kts) echo kotlin ;;
	*.swift) echo swift ;;
	*.c) echo c ;;
	*.h | *.hpp | *.cc | *.cpp | *.cxx) echo cpp ;;
	*.ts) echo typescript ;;
	*.tsx) echo tsx ;;
	*.js | *.mjs | *.cjs) echo javascript ;;
	*.jsx) echo jsx ;;
	*.php) echo php ;;
	*.cs) echo csharp ;;
	*.sh | *.bash) echo shell ;;
	*.md) echo markdown ;;
	*.yml | *.yaml) echo yaml ;;
	*.json) echo json ;;
	*) echo "" ;;
	esac
}

NUMSTAT="$WORK_ROOT/numstat.tsv"
git diff --numstat "$BASE_SHA...$HEAD_SHA" >"$NUMSTAT"
CHANGED_TOTAL="$(grep -c . "$NUMSTAT" || true)"

CHANGED="$WORK_ROOT/changed.jsonl"
: >"$CHANGED"
measured=0
while IFS=$'\t' read -r added removed path; do
	[ -n "$path" ] || continue
	[ "$measured" -lt "$CHANGED_FILE_CAP" ] || continue
	importers=0
	is_hub=false
	if [ -f "$path" ]; then
		row="$("$CODEMAP_BIN" --json --importers "$path" 2>/dev/null || echo '{}')"
		importers="$(jq -r '.importer_count // 0' <<<"$row")"
		is_hub="$(jq -r 'if .is_hub then true else false end' <<<"$row")"
	fi
	is_test=false
	is_test_path "$path" && is_test=true
	lang="$(language_of "$path")"
	[ "$added" = "-" ] && added=0
	[ "$removed" = "-" ] && removed=0
	jq -c -n --arg path "$path" --argjson importers "$importers" --argjson is_hub "$is_hub" \
		--argjson is_test "$is_test" --arg language "$lang" --argjson added "$added" --argjson removed "$removed" \
		'{path: $path, importers: $importers, is_hub: $is_hub, is_test: $is_test, language: $language, added: $added, removed: $removed}' \
		>>"$CHANGED"
	measured=$((measured + 1))
done <"$NUMSTAT"

# ---------------------------------------------------------------------------
# 4. body: paths and counts only, never file contents
# ---------------------------------------------------------------------------
COVERAGE_JSON="$("$CODEMAP_BIN" --deps --json . 2>/dev/null | jq -c '{status: (.coverage.status // "unknown"), notes: (.coverage.issues // [])}' 2>/dev/null || echo '{"status":"unknown","notes":[]}')"

BODY="$WORK_ROOT/body.json"
jq -c -n \
	--arg repo "$REPO" --argjson pr "${PR:-null}" --arg base_sha "$BASE_SHA" --arg head_sha "$HEAD_SHA" \
	--arg codemap_version "$CODEMAP_VERSION_SEEN" --slurpfile changed "$CHANGED" \
	--argjson coverage "$COVERAGE_JSON" --argjson changed_total "$CHANGED_TOTAL" --argjson changed_measured "$measured" \
	'{repo: $repo, pr: $pr, base_sha: $base_sha, head_sha: $head_sha, codemap_version: $codemap_version,
	  changed: $changed, coverage: $coverage, collide: null,
	  caps: {changed_total: $changed_total, changed_measured: $changed_measured}}' \
	>"$BODY"

# ---------------------------------------------------------------------------
# 5. outputs and summary
# ---------------------------------------------------------------------------
DECISION_JSON="$WORK_ROOT/decision.json"
SUMMARY="$WORK_ROOT/summary.md"
REVIEW="unknown"
REASONS=""

emit_outputs() {
	{
		echo "review=$REVIEW"
		echo "reasons=$REASONS"
		echo "decision-json=$DECISION_JSON"
	} >>"${GITHUB_OUTPUT:-/dev/stdout}"
}

finish() {
	[ -n "$SUMMARY_FILE" ] && cat "$SUMMARY" >>"$SUMMARY_FILE"
	cat "$SUMMARY"
	emit_outputs
	exit 0
}

if [ -z "$LICENSE_KEY" ]; then
	REASONS="no license key: facts only"
	jq -n --arg reasons "$REASONS" '{review: "unknown", reasons: [{rule: "no-license-key", fact: $reasons}]}' >"$DECISION_JSON"
	{
		echo "## codemap review gate"
		echo
		echo "**review: unknown**"
		echo
		echo "### Changed files (by importer count)"
		echo
		jq -s 'sort_by(-.importers)' "$CHANGED" |
			jq -r '.[] | "- `" + .path + "` · " + (.importers | tostring) + " importers" + (if .is_hub then " (hub)" else "" end)'
		echo
		echo "The review decision, its policy, and calibration from your past reviews are part of codemap Team: https://codemap-site.vercel.app/offer"
	} >"$SUMMARY"
	finish
fi

RESPONSE="$WORK_ROOT/response.json"
set +e
http_code="$(
	printf 'header = "authorization: Bearer %s"\n' "$LICENSE_KEY" |
		curl -sS -K - \
			-X POST \
			-H 'content-type: application/json' \
			--data "@$BODY" \
			-o "$RESPONSE" \
			-w '%{http_code}' \
			--max-time 30 \
			"$API_URL/api/review-gate"
)"
curl_rc=$?
set -e

if [ "$curl_rc" -ne 0 ]; then
	REASONS="network failure calling $API_URL"
	jq -n --arg reasons "$REASONS" '{review: "unknown", reasons: [{rule: "network-failure", fact: $reasons}]}' >"$DECISION_JSON"
	{
		echo "## codemap review gate"
		echo
		echo "**review: unknown**"
		echo
		echo "Could not reach $API_URL: network failure."
	} >"$SUMMARY"
	finish
fi

if [ "$http_code" = "401" ] || [ "$http_code" = "402" ]; then
	if [ "$http_code" = "401" ]; then
		REASONS="401: invalid license key"
	else
		REASONS="402: license key needs payment"
	fi
	jq -n --arg code "$http_code" --arg reasons "$REASONS" '{review: "unknown", reasons: [{rule: ("http-" + $code), fact: $reasons}]}' >"$DECISION_JSON"
	{
		echo "## codemap review gate"
		echo
		echo "**review: unknown**"
		echo
		echo "$API_URL returned $http_code: $REASONS."
	} >"$SUMMARY"
	finish
fi

if ! jq -e . "$RESPONSE" >/dev/null 2>&1; then
	REASONS="$API_URL returned a response codemap-ci could not parse (HTTP $http_code)"
	jq -n --arg reasons "$REASONS" '{review: "unknown", reasons: [{rule: "bad-response", fact: $reasons}]}' >"$DECISION_JSON"
	{
		echo "## codemap review gate"
		echo
		echo "**review: unknown**"
		echo
		echo "$REASONS."
	} >"$SUMMARY"
	finish
fi

cp "$RESPONSE" "$DECISION_JSON"
REVIEW="$(jq -r '.review // "unknown"' "$RESPONSE")"
REASONS="$(jq -r '[.reasons[]?.fact] | join("; ")' "$RESPONSE")"
{
	echo "## codemap review gate"
	echo
	echo "**review: $REVIEW**"
	echo
	if jq -e '(.reasons // []) | length > 0' "$RESPONSE" >/dev/null 2>&1; then
		echo "### Reasons"
		echo
		jq -r '.reasons[] | "- " + .rule + ": " + .fact' "$RESPONSE"
		echo
	fi
	if jq -e '(.skip_reasons // []) | length > 0' "$RESPONSE" >/dev/null 2>&1; then
		echo "### Skipped"
		echo
		jq -r '.skip_reasons[] | "- " + .fact' "$RESPONSE"
		echo
	fi
	if jq -e '.policy' "$RESPONSE" >/dev/null 2>&1; then
		echo "### Policy"
		echo
		jq -r '.policy | "`" + (.name // "unknown") + "` v" + ((.version // "unknown") | tostring)' "$RESPONSE"
		if jq -e '.policy.thresholds' "$RESPONSE" >/dev/null 2>&1; then
			jq -r '.policy.thresholds | to_entries[] | "- " + .key + ": " + (.value | tostring)' "$RESPONSE"
		fi
		echo
	fi
	if jq -e '(.limits // []) | length > 0' "$RESPONSE" >/dev/null 2>&1; then
		echo "### Limits"
		echo
		jq -r '.limits[]' "$RESPONSE"
		echo
	fi
} >"$SUMMARY"
finish
