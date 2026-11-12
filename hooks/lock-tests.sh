#!/bin/bash
# 锁住测试：记录当前所有测试文件的指纹。
# 锁住之后：
#   1. guard.sh 会拦住对测试文件的修改；
#   2. stop-verify.sh 会在 agent 每次停下时检查测试没被改过，并运行 .claude/verify.sh。
# 解锁：先 cd 到项目目录，再在终端里自己运行 `~/.claude/hooks/lock-tests.sh --unlock`（agent 被禁止解锁）。
set -e
# 项目根目录 = 当前目录所在 git 仓库的根目录（guard.sh、stop-verify.sh 用同一个规则）；不在 git 仓库里就用当前目录。
root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
lock="${root}/.claude/tests-locked"

if [ "${1-}" = "--unlock" ]; then
  if [ ! -f "$lock" ]; then
    echo "这里没有上锁：${root}。先 cd 到上锁的项目目录，再运行一次。" >&2
    exit 1
  fi
  rm -f "$lock"
  echo "已解锁测试：${root}"
  exit 0
fi

if [ -f "$lock" ]; then
  echo "测试已经锁住了。要重新上锁，先由用户在终端里解锁：~/.claude/hooks/lock-tests.sh --unlock" >&2
  exit 1
fi

mkdir -p "${root}/.claude"
files="$("$HOME/.claude/hooks/test-files.sh" "${root}")"
if [ -z "$files" ]; then
  echo "没找到测试文件，没有上锁。先写测试，再锁。" >&2
  exit 1
fi
hash="$(cd "${root}" && printf '%s\n' "$files" | while IFS= read -r f; do shasum -a 256 "${f}"; done | shasum -a 256 | cut -d' ' -f1)"
printf '%s\n' "$hash" > "$lock"
echo "已锁住 $(printf '%s\n' "$files" | wc -l | tr -d ' ') 个测试文件：${root}"
[ -x "${root}/.claude/verify.sh" ] || echo "提醒：这个项目还没有可执行的 .claude/verify.sh，停下时不会自动跑测试。"
