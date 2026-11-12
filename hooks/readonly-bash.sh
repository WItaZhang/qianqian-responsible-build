#!/bin/bash
# 给审查员用：只允许只读的 shell 命令（看 diff、看日志、搜索、跑测试除外的一律拦住）。
cmd="$(jq -r '.tool_input.command // empty')"
# 不允许重定向写文件、管道到 shell、命令串联
if printf '%s' "$cmd" | grep -Eq '(>|;|&&|\|\||`|\$\(|\| *(sh|bash|zsh|xargs)| -delete| -exec| -ok)'; then
  echo "已拦截：审查员只能运行单条只读命令（不能重定向、串联或执行子命令）。" >&2
  exit 2
fi
case "$cmd" in
  "git diff"*|"git status"*|"git log"*|"git show"*|"git blame"*|"ls"*|"cat "*|"head "*|"tail "*|"wc "*|"rg "*|"grep "*|"find "*)
    exit 0 ;;
esac
echo "已拦截：审查员只能运行只读命令（git diff/status/log/show/blame、ls、cat、head、tail、wc、rg、grep、find）。" >&2
exit 2
