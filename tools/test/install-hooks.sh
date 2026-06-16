#!/usr/bin/env bash
# Install the FS25_SoilFertilizer git pre-commit hook (Lua 5.1 syntax + lint).
# Opt-in: nothing runs on your commits until you run this. Remove with:
#   rm "$(git rev-parse --git-path hooks)/pre-commit"
set -e
repo_root="$(git rev-parse --show-toplevel)"
hooks_dir="$(git rev-parse --git-path hooks)"
src="$repo_root/tools/git-hooks/pre-commit"

mkdir -p "$hooks_dir"
if [ -e "$hooks_dir/pre-commit" ] && ! cmp -s "$src" "$hooks_dir/pre-commit"; then
  echo "A different pre-commit hook already exists at $hooks_dir/pre-commit"
  echo "Back it up or merge manually; not overwriting."
  exit 1
fi
cp "$src" "$hooks_dir/pre-commit"
chmod +x "$hooks_dir/pre-commit"
echo "Installed pre-commit hook -> $hooks_dir/pre-commit"
echo "Runs 'npm run check' (syntax + lint) when .lua files are staged. Skip once with: git commit --no-verify"
