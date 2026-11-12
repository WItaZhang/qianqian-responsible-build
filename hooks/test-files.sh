#!/bin/bash
# 列出项目里的测试文件（供 lock-tests.sh 和 stop-verify.sh 共用）。
# 用法：test-files.sh <项目根目录>
# 规则：tests/ test/ __tests__/ spec/ 目录下的文件，以及 test_*.py、*_test.py、*_test.go、*.test.*、*.spec.* 这类文件名。
root="${1:-.}"
cd "$root" || exit 1
find . \
  \( -name .git -o -name node_modules -o -name .venv -o -name venv -o -name __pycache__ -o -name dist -o -name build -o -name .claude \) -prune -o \
  -type f \( \
    -path '*/tests/*' -o -path '*/test/*' -o -path '*/__tests__/*' -o -path '*/spec/*' \
    -o -name 'test_*.py' -o -name '*_test.py' -o -name '*_test.go' \
    -o -name '*.test.*' -o -name '*.spec.*' \
  \) -print | LC_ALL=C sort
