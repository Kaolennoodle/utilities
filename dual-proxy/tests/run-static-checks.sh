#!/usr/bin/env bash
# =============================================================================
# run-static-checks.sh — developer-side static checks.
#
# Runs on the developer machine (also works on the target VPS for the
# protocol-level checks). Protocol-level validation that requires the actual
# binaries/services (xray -test, hysteria, nginx -t, systemd-analyze)
# is exercised automatically during install.sh and via manage.sh check.
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

rc=0
fail() { echo "  ✗ $*"; rc=1; }
pass() { echo "  ✓ $*"; }

echo "== 1. bash -n 语法检查 =="
for f in install.sh manage.sh deploy.sh lib/*.sh templates/*.sh tests/*.sh; do
  if bash -n "$f" 2>/dev/null; then pass "$f"; else fail "$f"; fi
done

echo "== 2. ShellCheck =="
if command -v shellcheck >/dev/null 2>&1; then
  for f in install.sh manage.sh deploy.sh lib/*.sh templates/*.sh tests/*.sh; do
    if shellcheck -S warning "$f"; then pass "shellcheck $f"; else fail "shellcheck $f"; fi
  done
else
  fail "shellcheck 未安装，不能完成静态验收"
fi

echo "== 3. JSON 模板结构校验（示例渲染后 jq 解析）=="
XRAY_TMP="$(mktemp)"
sed -e 's|__CLIENTS__|[{"id":"00000000-0000-0000-0000-000000000000","flow":"xtls-rprx-vision"}]|' \
    -e 's|__DOMAIN__|example.com|' \
    -e 's|__PRIVATE_KEY__|MDEyMzQ1Njc4OWFiY2RlZg|' \
    -e 's|__SHORT_ID__|0123456789abcdef|' \
    -e 's|__BLOCK_IPS__|"169.254.0.0\/16","127.0.0.0\/8","::1\/128"|' \
    templates/xray-config.json > "$XRAY_TMP"
if jq empty "$XRAY_TMP" 2>/dev/null; then pass "xray-config.json 渲染后为合法 JSON"; else fail "xray-config.json JSON 不合法"; fi
rm -f "$XRAY_TMP"

echo "== 4. Runtime regression: complete rendered YAML and entrypoints =="
if (( BASH_VERSINFO[0] >= 4 )); then
  if bash tests/run-regression.sh; then pass "regression checks"; else fail "regression checks"; fi
else
  echo "  - Runtime regression requires Bash >= 4; run on Linux (NOT verified here)"
fi

echo
if (( rc == 0 )); then echo "可执行的静态检查通过；跳过项不代表已验证"; else echo "静态检查存在失败项"; fi
exit "$rc"
