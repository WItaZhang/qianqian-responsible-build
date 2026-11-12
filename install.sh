#!/bin/bash
# Install into ~/.claude (or $CLAUDE_HOME). Safe to re-run.
#   - Existing files that would be overwritten are backed up first.
#   - Hooks and permissions are merged into settings.json; other settings and hooks are left alone.
#   - CLAUDE.md is only installed if you don't have one; otherwise it is copied next to yours for you to merge.
# Requires: bash, git, jq, shasum.
set -euo pipefail

src="$(cd "$(dirname "$0")" && pwd)"
dest="${CLAUDE_HOME:-$HOME/.claude}"
stamp="$(date +%Y%m%d-%H%M%S)"
backup="$dest/backups/responsible-build-$stamp"

for cmd in git jq shasum; do
  command -v "$cmd" >/dev/null || { echo "missing dependency: $cmd" >&2; exit 1; }
done

mkdir -p "$dest"

put() {  # put <source file> <destination path>
  local from="$src/$1" to="$dest/$2"
  if [ -f "$to" ] && ! cmp -s "$from" "$to"; then
    mkdir -p "$backup/$(dirname "$2")"
    cp -p "$to" "$backup/$2"
  fi
  mkdir -p "$(dirname "$to")"
  cp "$from" "$to"
}

for f in hooks/*.sh; do put "$f" "$f"; chmod 755 "$dest/$f"; done
for s in spec build retro idea-kickoff; do put "skills/$s/SKILL.md" "skills/$s/SKILL.md"; done
put agents/reviewer.md agents/reviewer.md

if [ -f "$dest/CLAUDE.md" ]; then
  if ! cmp -s "$src/CLAUDE.md" "$dest/CLAUDE.md"; then
    cp "$src/CLAUDE.md" "$dest/CLAUDE.responsible-build.md"
    echo "You already have a CLAUDE.md. The rules were copied to $dest/CLAUDE.responsible-build.md; merge them by hand."
  fi
else
  cp "$src/CLAUDE.md" "$dest/CLAUDE.md"
fi

# Merge hooks and permissions into settings.json. Entries already present (same command) are not added twice.
settings="$dest/settings.json"
[ -f "$settings" ] || echo '{}' > "$settings"
if [ -s "$settings" ]; then
  mkdir -p "$backup"; cp -p "$settings" "$backup/settings.json"
fi
tmp="$(mktemp)"
jq --slurpfile ex "$src/settings.example.json" '
  reduce ($ex[0].hooks | to_entries[]) as $e (.;
    (.hooks[$e.key] // []) as $have
    | [$have[].hooks[]?.command] as $installed
    | .hooks[$e.key] = $have + [$e.value[] | select(all(.hooks[].command; . as $c | any($installed[]; . == $c) | not))])
  # keep order: a "!" carve-out only works when it comes after the rule it carves from
  | (.permissions.deny // []) as $d
  | .permissions.deny = $d + [$ex[0].permissions.deny[] | select(. as $x | any($d[]; . == $x) | not)]
' "$settings" > "$tmp"
jq empty "$tmp"
cat "$tmp" > "$settings"; rm -f "$tmp"

# Keep the test-lock file out of every repository.
ignore="$(git config --global core.excludesFile || true)"
ignore="${ignore:-${XDG_CONFIG_HOME:-$HOME/.config}/git/ignore}"
ignore="${ignore/#\~/$HOME}"
mkdir -p "$(dirname "$ignore")"; touch "$ignore"
grep -qxF '**/.claude/tests-locked' "$ignore" || echo '**/.claude/tests-locked' >> "$ignore"

echo "Installed into $dest."
[ -d "$backup" ] && echo "Backups of replaced files: $backup"
echo "Next: add a .claude/verify.sh to your project (the command that decides \"done\"), then try /spec."
