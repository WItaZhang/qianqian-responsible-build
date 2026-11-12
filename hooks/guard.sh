#!/bin/bash
# PreToolUse 守卫：在 agent 动手之前拦截越界操作。exit 2 = 拦住，stderr 的内容会告诉 agent 原因。
#   - 任何时候：不许改 .env / 密钥类文件；不许删除或伪造测试锁。
#   - 测试锁住时：不许用 Edit/Write 改测试文件。
input="$(cat)"
tool="$(printf '%s' "$input" | jq -r '.tool_name // empty')"

block() { echo "$1" >&2; exit 2; }

case "$tool" in
  Edit|Write|MultiEdit|NotebookEdit)
    f="$(printf '%s' "$input" | jq -r '.tool_input.file_path // .tool_input.notebook_path // empty')"
    [ -z "${f}" ] && exit 0
    base="$(basename "${f}")"
    case "${base}" in
      .env|.env.*)
        [ "${base}" = ".env.example" ] || block "已拦截：不允许修改 ${base}（密钥文件）。需要改的话请让用户自己改。" ;;
      *.pem|*.key|id_rsa*|credentials.json)
        block "已拦截：不允许修改 ${base}（凭证文件）。" ;;
      tests-locked)
        block "已拦截：测试锁只能由用户在终端里解除。" ;;
    esac
    # 项目根目录 = Claude 当前所在目录的 git 仓库根目录（lock-tests.sh、stop-verify.sh 用同一个规则）。
    # 不直接用 CLAUDE_PROJECT_DIR：会话在子目录启动、或中途进了 worktree 时，它和上锁的位置对不上。
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty')"; cwd="${cwd:-${CLAUDE_PROJECT_DIR:-$PWD}}"
    root="$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null || printf '%s' "$cwd")"
    lock="${root}/.claude/tests-locked"
    if [ -f "$lock" ]; then
      rel="${f#"${root}"/}"
      if "$HOME/.claude/hooks/test-files.sh" "${root}" | grep -Fqx "./${rel}"; then
        block "已拦截：测试已锁住，实现阶段不许修改测试文件（${rel}）。如果你认为测试本身有错，在回复里写【需要你决定】并说明理由，由用户决定是否解锁。"
      fi
      # 锁住时新建测试文件也不行
      case "${rel}" in
        */tests/*|tests/*|*/test/*|test/*|*/__tests__/*|__tests__/*|*/spec/*|spec/*|test_*.py|*/test_*.py|*_test.py|*_test.go|*.test.*|*.spec.*)
          block "已拦截：测试已锁住，实现阶段不许新增或修改测试文件（${rel}）。如果你认为缺测试，在回复里写【需要你决定】并说明理由。" ;;
      esac
    fi
    ;;
  Bash)
    cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // empty')"
    if printf '%s' "$cmd" | grep -q 'tests-locked' || printf '%s' "$cmd" | grep -q 'lock-tests.sh.*--unlock'; then
      block "已拦截：测试锁只能由用户在终端里解除，agent 不能删除或改写它。"
    fi
    ;;
esac
exit 0
