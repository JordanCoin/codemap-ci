#!/usr/bin/env bash
#
# codemap-bin.sh: resolve $CODEMAP_BIN, downloading the release tarball
# (which also carries ast-grep) when it is unset.
#
# Sourced, not run: the caller must already have `set -euo pipefail`, a
# `die()` function, a $WORK_ROOT scratch directory, and $CODEMAP_VERSION set.
# Leaves CODEMAP_BIN pointing at an executable and CODEMAP_VERSION_SEEN set
# to its reported version; puts the extracted dist dir on PATH.

if [ -z "$CODEMAP_BIN" ]; then
	os="$(uname -s | tr '[:upper:]' '[:lower:]')"
	case "$(uname -m)" in
	x86_64 | amd64) arch=amd64 ;;
	aarch64 | arm64) arch=arm64 ;;
	*) die "unsupported architecture $(uname -m)" ;;
	esac
	asset="codemap-full_${CODEMAP_VERSION}_${os}_${arch}.tar.gz"
	base_url="https://github.com/JordanCoin/codemap/releases/download/v${CODEMAP_VERSION}"
	echo "codemap-bin: downloading $asset" >&2
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
