#!/bin/bash
# Stop 钩子：agent 想停下（说"做完了"）时自动验收。只在测试锁住时生效，平时不打扰。
#   1. 测试文件和上锁时比有没有被改过（包括用 shell 命令偷偷改的）；
#   2. 运行项目的 .claude/verify.sh（比如 pytest、类型检查）。
# 任何一项不通过就 exit 2：agent 被打回去继续修。连续打回 3 次后放行，并提示用户介入，避免死循环。
# 两种停下不算交卷：
#   - agent 在回复里写了【需要你决定】：它是停下来问用户。只查测试有没有被改，不跑 verify.sh。
#   - 还有子 agent / workflow 这类会交回结果的后台任务在跑：它只是在等结果，直接放行。
#     后台开着的 shell（比如 dev server）不算，否则验收会被一直跳过。
# 同一个脚本也挂在 SubagentStop 上，用来验收在独立 worktree 里开发的子 agent（idea-kickoff 并行开发）：
#   - 只管在别的 git 根目录（自己的 worktree）里工作的子 agent；和主对话同一个目录的，交给主对话的 Stop 验收。
#   - 只读或内置的子 agent（审查员、搜索、规划等）不管。
input="$(cat)"
event="$(printf '%s' "$input" | jq -r '.hook_event_name // "Stop"')"
# 项目根目录 = Claude 当前所在目录的 git 仓库根目录（guard.sh、lock-tests.sh 用同一个规则）。
cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"; cwd="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
lock="${root}/.claude/tests-locked"
[ -f "$lock" ] || exit 0

if [ "$event" = "SubagentStop" ]; then
  case "$(printf '%s' "$input" | jq -r '.agent_type // empty')" in
    ""|reviewer|Explore|Plan|web-fetch|statusline-setup) exit 0 ;;
  esac
  main="${CLAUDE_PROJECT_DIR:-}"
  main_root="$( [ -n "$main" ] && git -C "$main" rev-parse --show-toplevel 2>/dev/null )"
  [ -n "$main_root" ] && [ "$main_root" = "$root" ] && exit 0
  # 子 agent 收到的 background_tasks 属于父对话（里面就有它自己），不能用来判断"在等结果"，所以跳过下面那条
else
  # 在等后台的子 agent / workflow：不是交卷
  waiting="$(printf '%s' "$input" | jq '[(.background_tasks // [])[] | select(.type == "subagent" or .type == "workflow" or .type == "teammate" or .type == "cloud session")] | length' 2>/dev/null)"
  [ "${waiting:-0}" -gt 0 ] 2>/dev/null && exit 0
fi

# 回复里有【需要你决定】：是在提问，不是交卷
asking=""
if printf '%s' "$input" | jq -r '.last_assistant_message // empty' | grep -Fq '【需要你决定】'; then
  asking=1
fi

# 并行的子 agent 共用父对话的 session_id，打回计数要按 agent_id 分开
session="$(printf '%s' "$input" | jq -r '(.session_id // "nosession") + (if .agent_id then "-" + .agent_id else "" end)')"
counter="${TMPDIR:-/tmp}/claude-stop-verify-$session"
fails="$(cat "$counter" 2>/dev/null || echo 0)"

problems=""

# 1. 测试有没有被改（提问时也查）
files="$("$HOME/.claude/hooks/test-files.sh" "${root}")"
now="$(cd "${root}" && printf '%s\n' "$files" | while IFS= read -r f; do [ -n "${f}" ] && shasum -a 256 "${f}"; done | shasum -a 256 | cut -d' ' -f1)"
if [ "$now" != "$(cat "$lock")" ]; then
  problems="测试文件和上锁时不一致（被修改、删除或新增了）。把测试恢复原样（例如用 git checkout 恢复测试文件），不要通过改测试来过关。"
fi

# 2. 跑项目的验收命令（提问时跳过）
if [ -z "${asking}" ] && [ -x "${root}/.claude/verify.sh" ]; then
  out="$(cd "${root}" && ./.claude/verify.sh 2>&1)"
  code=$?
  if [ ${code} -ne 0 ]; then
    problems="${problems:+${problems}
}.claude/verify.sh 没通过（exit ${code}）。输出最后 40 行：
$(printf '%s\n' "$out" | tail -40)"
  fi
fi

if [ -z "${problems}" ]; then
  rm -f "$counter"
  exit 0
fi

fails=$((fails + 1))
if [ "${fails}" -ge 4 ]; then
  rm -f "$counter"
  # 放行，但告诉用户
  jq -n --arg m "验收连续 3 次没通过，已停止自动打回，需要你介入看一下。最后的问题：${problems}" '{systemMessage: $m}'
  exit 0
fi
echo "${fails}" > "$counter"
echo "还不能算完成（第 ${fails}/3 次自动打回）：
${problems}
修好之后再结束。如果你认为是需求或测试本身有问题，在回复里写【需要你决定】并说明原因，验收会放行，由用户来决定。" >&2
exit 2
