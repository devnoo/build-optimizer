#!/usr/bin/env bash
# Make or remove a throwaway copy of a checkout for measuring a fix.
#
#   scratch-copy.sh <repoDir> <dest>     copy repoDir to dest (dest must not exist)
#   scratch-copy.sh --remove <dest>      delete a copy made by this script
#
# The copy keeps installed dependencies and build output (copy-on-write where the filesystem
# supports it) and is a real git worktree of the same repository at the same commit. So `git diff`,
# refs such as origin/main and tools that look for the repository root all work in it, and edits
# there never reach repoDir. Git hooks are not run.
set -euo pipefail

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

if [ "${1:-}" = "--remove" ]; then
  dest="${2:-}"; [ -n "$dest" ] || usage
  [ -e "$dest" ] || exit 0
  if git -C "$dest" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    common=$(cd "$dest" && cd "$(git rev-parse --git-common-dir)" && pwd)
    git --git-dir="$common" worktree remove --force "$dest" 2>/dev/null || rm -rf "$dest"
    git --git-dir="$common" worktree prune
  else
    rm -rf "$dest"
  fi
  exit 0
fi

src="${1:-}"; dest="${2:-}"
[ -n "$src" ] && [ -n "$dest" ] || usage
[ -d "$src" ] || { echo "scratch-copy: no such directory: $src" >&2; exit 1; }
[ ! -e "$dest" ] || { echo "scratch-copy: $dest already exists" >&2; exit 1; }
mkdir -p "$(dirname "$dest")"

# 1. Copy everything, including ignored files such as node_modules or target/.
if ! cp -cR "$src" "$dest" 2>/dev/null; then      # macOS APFS clone
  rm -rf "$dest"
  cp -a --reflink=auto "$src" "$dest" 2>/dev/null || cp -a "$src" "$dest"   # Linux reflink, else plain copy
fi

# 2. Not a git checkout: the plain copy is all there is.
if ! git -C "$src" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "$dest"; exit 0
fi

# 3. The copied .git still points at repoDir's own git state. Replace it with a new worktree
#    registration at the same commit, then rebuild the index without touching the files.
sha=$(git -C "$src" rev-parse HEAD)
rm -rf "$dest/.git"
reg="$dest.reg.$$"
git -C "$src" -c core.hooksPath=/dev/null worktree add --quiet --detach --no-checkout "$reg" "$sha"
mv "$reg/.git" "$dest/.git"
rmdir "$reg"
git -C "$dest" worktree repair >/dev/null 2>&1
git -C "$dest" reset --quiet
echo "$dest"
