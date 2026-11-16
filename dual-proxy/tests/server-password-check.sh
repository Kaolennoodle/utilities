#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/common.sh"
settings_load
work=$(mktemp -d /root/reality-password-test.XXXXXX)
cp -a "$DP_HY_PASS" "$work/password"
cp -a "$HY_CONF" "$work/config.yaml"
cp -a "$DP_SECRETS/client-params.txt" "$work/params"
cleanup() {
  cp -a "$work/password" "$DP_HY_PASS"
  cp -a "$work/config.yaml" "$HY_CONF"
  cp -a "$work/params" "$DP_SECRETS/client-params.txt"
  systemctl restart hysteria-server
  rm -rf "$work"
}
trap cleanup EXIT
/opt/dual-proxy/scripts/manage.sh hysteria-reset > "$work/sensitive-output"
if cmp -s "$DP_HY_PASS" "$work/password"; then echo 'FAIL password did not change'; exit 1; fi
grep -F -f "$DP_HY_PASS" "$DP_SECRETS/client-params.txt" >/dev/null
bash "$ROOT/tests/server-hysteria-check.sh"
echo 'PASS Hysteria password reset changes authentication and refreshes parameters'
