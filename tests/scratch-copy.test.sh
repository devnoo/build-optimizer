#!/usr/bin/env bash
# shellcheck disable=SC2016  # check() evals its second argument later, so those quotes are single on purpose
# Checks that scratch-copy.sh makes an isolated, working git checkout and removes it cleanly.
# Usage: bash tests/scratch-copy.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/skills/optimize-build/scripts/scratch-copy.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
fail=0
check() { if eval "$2"; then echo "ok   $1"; else echo "FAIL $1"; fail=1; fi; }

git init -q "$TMP/main"
git -C "$TMP/main" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
mkdir -p "$TMP/main/src"; echo a > "$TMP/main/src/a.txt"; echo node_modules > "$TMP/main/.gitignore"
git -C "$TMP/main" add -A; git -C "$TMP/main" -c user.email=t@t -c user.name=t commit -q -m files
printf '#!/bin/sh\necho hook-ran >> "%s/hook.log"\n' "$TMP" > "$TMP/main/.git/hooks/post-checkout"
chmod +x "$TMP/main/.git/hooks/post-checkout"
git -C "$TMP/main" -c core.hooksPath=/dev/null worktree add -q --detach "$TMP/repo" HEAD
mkdir -p "$TMP/repo/node_modules/dep"; echo x > "$TMP/repo/node_modules/dep/index.js"

bash "$SCRIPT" "$TMP/repo" "$TMP/copy" >/dev/null
check "copy keeps ignored files"            '[ -f "$TMP/copy/node_modules/dep/index.js" ]'
check "copy is its own git root"            '[ "$(cd "$TMP/copy" && git rev-parse --show-toplevel)" = "$(cd "$TMP/copy" && pwd -P)" ]'
check "copy starts clean"                   '[ -z "$(git -C "$TMP/copy" status --porcelain)" ]'
check "copy is at the same commit"          '[ "$(git -C "$TMP/copy" rev-parse HEAD)" = "$(git -C "$TMP/repo" rev-parse HEAD)" ]'
echo edit >> "$TMP/copy/src/a.txt"
check "edits in the copy show in its diff"  '[ -n "$(git -C "$TMP/copy" diff --stat)" ]'
check "edits do not reach the source"       '[ -z "$(git -C "$TMP/repo" status --porcelain)" ]'
check "no git hook ran"                     '[ ! -e "$TMP/hook.log" ]'
check "refuses an existing destination"     '! bash "$SCRIPT" "$TMP/repo" "$TMP/copy" >/dev/null 2>&1'

bash "$SCRIPT" --remove "$TMP/copy"
check "remove deletes the copy"             '[ ! -e "$TMP/copy" ]'
check "remove unregisters the worktree"     '! git -C "$TMP/main" worktree list | grep -q "/copy "'
check "source worktree is still there"      'git -C "$TMP/main" worktree list | grep -q "/repo "'

mkdir -p "$TMP/plain/sub"; echo p > "$TMP/plain/sub/f"
bash "$SCRIPT" "$TMP/plain" "$TMP/plain-copy" >/dev/null
check "copies a directory that is not git"  '[ -f "$TMP/plain-copy/sub/f" ]'
bash "$SCRIPT" --remove "$TMP/plain-copy"
check "removes a non-git copy"              '[ ! -e "$TMP/plain-copy" ]'

exit $fail
