#!/bin/bash
# Self-test: install into a throwaway HOME, then drive the hooks with the same JSON Claude Code sends them.
# Nothing outside a temp directory is touched. Requires bash, git, jq, shasum, python3.
set -u
repo="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp/home"; unset XDG_CONFIG_HOME CLAUDE_HOME CLAUDE_PROJECT_DIR
mkdir -p "$HOME"
H="$HOME/.claude/hooks"
pass=0; fail=0
check() { if [ "$2" = "$3" ]; then pass=$((pass + 1)); echo "  ok   $1"; else fail=$((fail + 1)); echo "  FAIL $1 (expected $2, got $3)"; fi; }
gitc() { git -c user.email=t@example.com -c user.name=test "$@"; }

project() {  # project <dir>: a repo whose implementation has a bug
  mkdir -p "$1/src" "$1/tests" "$1/.claude"
  printf 'def add(a, b):\n    return a - b\n' > "$1/src/calc.py"
  printf 'import sys; sys.path.insert(0, "src")\nfrom calc import add\nassert add(2, 3) == 5\n' > "$1/tests/test_calc.py"
  printf '#!/bin/bash\ncd "$(dirname "$0")/.."\npython3 -I tests/test_calc.py\n' > "$1/.claude/verify.sh"
  chmod +x "$1/.claude/verify.sh"
  (cd "$1" && git init -q && gitc add -A && gitc commit -qm init)
}
lock() { (cd "$1" && "$H/lock-tests.sh" >/dev/null 2>&1); }
edit() {  # edit <tool> <file> <cwd> -> exit code of guard.sh
  jq -n --arg t "$1" --arg f "$2" --arg c "$3" '{tool_name: $t, tool_input: {file_path: $f}, cwd: $c}' \
    | CLAUDE_PROJECT_DIR="${4:-$3}" "$H/guard.sh" >/dev/null 2>&1; echo $?; }
bash_cmd() { jq -n --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}, cwd: "/"}' | "$H/guard.sh" >/dev/null 2>&1; echo $?; }
stop() {  # stop <cwd> <session> <last message> [background_tasks] [event] [agent_type] [agent_id] [main dir]
  jq -n --arg c "$1" --arg s "$2" --arg m "$3" --argjson bg "${4:-[]}" --arg e "${5:-Stop}" --arg t "${6:-}" --arg a "${7:-}" \
    '{hook_event_name: $e, session_id: $s, cwd: $c, last_assistant_message: $m, background_tasks: $bg}
     + (if $t != "" then {agent_type: $t} else {} end) + (if $a != "" then {agent_id: $a} else {} end)' \
    | CLAUDE_PROJECT_DIR="${8:-$1}" "$H/stop-verify.sh" >/dev/null 2>&1; echo $?; }
readonly_bash() { jq -n --arg c "$1" '{tool_input: {command: $c}}' | "$H/readonly-bash.sh" >/dev/null 2>&1; echo $?; }

echo "install"
mkdir -p "$HOME/.claude"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo other-tool"}]}]},"permissions":{"deny":["Read(./secrets/**)"]}}' > "$HOME/.claude/settings.json"
echo "my own rules" > "$HOME/.claude/CLAUDE.md"
"$repo/install.sh" >/dev/null && "$repo/install.sh" >/dev/null
S="$HOME/.claude/settings.json"
check "existing settings are kept" "opus" "$(jq -r .model "$S")"
check "existing Stop hook is kept, ours added once (re-run is idempotent)" "2" "$(jq '.hooks.Stop | length' "$S")"
check "SubagentStop hook added once" "1" "$(jq '.hooks.SubagentStop | length' "$S")"
check "deny list keeps order (carve-out after the rule)" '["Read(./secrets/**)","Read(.env)","Read(.env.*)","Read(!.env.example)"]' "$(jq -c .permissions.deny "$S")"
check "existing CLAUDE.md is not overwritten" "my own rules" "$(cat "$HOME/.claude/CLAUDE.md")"
check "lock file is git-ignored globally" "1" "$(grep -cxF '**/.claude/tests-locked' "$HOME/.config/git/ignore")"

echo "guard"
P="$tmp/p"; project "$P"; lock "$P"
check "edit a test while locked -> blocked" 2 "$(edit Edit "$P/tests/test_calc.py" "$P")"
check "create a new test while locked -> blocked" 2 "$(edit Write "$P/tests/test_new.py" "$P")"
check "edit implementation while locked -> allowed" 0 "$(edit Edit "$P/src/calc.py" "$P")"
check "write .env -> blocked" 2 "$(edit Write "$P/.env" "$P")"
check "write .env.example -> allowed" 0 "$(edit Write "$P/.env.example" "$P")"
check "agent tries to unlock -> blocked" 2 "$(bash_cmd "$H/lock-tests.sh --unlock")"
check "ordinary shell command -> allowed" 0 "$(bash_cmd "ls -la")"

echo "stop: verification when the agent says it is done"
check "bug still there -> sent back" 2 "$(stop "$P" s1 "done")"
check "asks the user with the marker -> allowed through" 0 "$(stop "$P" s1 "【需要你决定】include exactly 20%?")"
check "marker text without brackets -> still sent back" 2 "$(stop "$P" s1 "不需要你决定, done")"
check "waiting on a background subagent -> allowed" 0 "$(stop "$P" s1 "waiting" '[{"id":"a","type":"subagent","status":"running"}]')"
check "only a dev server in the background -> still sent back" 2 "$(stop "$P" s1 "done" '[{"id":"b","type":"shell","status":"running"}]')"
echo "# tampered" >> "$P/tests/test_calc.py"
check "test edited through the shell, plus marker -> still sent back" 2 "$(stop "$P" s1 "【需要你决定】ok?")"
(cd "$P" && git checkout -q -- tests/test_calc.py)
check "fourth failure in a row -> released to the user" 0 "$(stop "$P" s1 "done")"
sed -i.bak 's/a - b/a + b/' "$P/src/calc.py"
check "bug fixed, tests untouched -> passes" 0 "$(stop "$P" s2 "done")"
check "not locked -> hook stays out of the way" 0 "$(stop "$tmp" s3 "done")"

echo "lock location follows the git root"
P2="$tmp/sub"; mkdir -p "$P2/svc/tests"; echo 'assert True' > "$P2/svc/tests/test_x.py"; (cd "$P2" && git init -q)
(cd "$P2/svc" && "$H/lock-tests.sh" >/dev/null 2>&1)
check "session started in a subdirectory -> still blocked" 2 "$(edit Edit "$P2/svc/tests/test_x.py" "$P2/svc")"
M="$tmp/m"; project "$M"; (cd "$M" && git worktree add -q "$M-wt" -b wt 2>/dev/null); lock "$M-wt"
check "inside a worktree -> blocked" 2 "$(edit Edit "$M-wt/tests/test_calc.py" "$M-wt" "$M")"
check "main checkout not locked -> allowed" 0 "$(edit Edit "$M/tests/test_calc.py" "$M")"

echo "subagents in their own worktree"
BG='[{"id":"x","type":"subagent","status":"running"}]'
check "builder subagent with failing tests -> sent back (parent's background tasks ignored)" 2 "$(stop "$M-wt" s4 "done" "$BG" SubagentStop general-purpose A1 "$M")"
check "reviewer subagent -> ignored" 0 "$(stop "$M-wt" s4 "done" "[]" SubagentStop reviewer R1 "$M")"
check "built-in agent with empty type -> ignored" 0 "$(stop "$M-wt" s4 "done" "[]" SubagentStop "" I1 "$M")"
check "parallel subagent keeps its own retry count" 2 "$(stop "$M-wt" s4 "done" "[]" SubagentStop general-purpose A2 "$M")"
lock "$M"
check "subagent in the main checkout -> left to the main session" 0 "$(stop "$M" s4 "done" "[]" SubagentStop general-purpose G1 "$M")"

echo "reviewer is read-only"
for c in "git diff" "git log -3" "cat src/calc.py" "grep -rn add ."; do check "allowed: $c" 0 "$(readonly_bash "$c")"; done
for c in "rm -rf src" "cat a > b" "git diff && rm x" "find . -delete" "git checkout ." "pytest"; do check "blocked: $c" 2 "$(readonly_bash "$c")"; done

rm -f "${TMPDIR:-/tmp}"/claude-stop-verify-s[1-4]*
echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
