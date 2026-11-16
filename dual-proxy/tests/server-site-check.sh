#!/usr/bin/env bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/site.sh"
settings_load
work=$(mktemp -d /root/reality-site-test.XXXXXX)
original=$(mktemp -d /root/reality-site-original.XXXXXX)
cp -a "$SITE_CURRENT/." "$original/"
# No history is kept, so restore by redeploying a copy of the original.
cleanup() {
  site_deploy "$original" >/dev/null
  rm -rf "$work" "$original"
}
trap cleanup EXIT
cp -a "$original/." "$work/"
mkdir -p "$work/__dual_proxy_test__/nested"
printf '<!doctype html><title>subpage</title>test' > "$work/__dual_proxy_test__/nested/index.html"
printf 'body { color: #123456; }' > "$work/__dual_proxy_test__/style.css"
printf 'window.dualProxyTest = true;' > "$work/__dual_proxy_test__/app.js"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="1" height="1"><rect width="1" height="1"/></svg>' > "$work/__dual_proxy_test__/image.svg"
site_deploy "$work"
for path in / /__dual_proxy_test__/nested/ /__dual_proxy_test__/style.css /__dual_proxy_test__/app.js /__dual_proxy_test__/image.svg; do
  curl --noproxy '*' -fsS --resolve "$DOMAIN:443:127.0.0.1" --max-time 10 "https://$DOMAIN$path" > /dev/null
  echo "PASS HTTP/2 static resource $path"
done
HTTP3_CONNECT_IP=127.0.0.1 "$ROOT/test-venv/bin/python" "$ROOT/tests/http3-check.py" "$DOMAIN" / /__dual_proxy_test__/nested/ /__dual_proxy_test__/style.css /__dual_proxy_test__/app.js /__dual_proxy_test__/image.svg /does-not-exist-test-404
echo 'PASS atomic site update serves all resource types'
for port in 443 8443; do
  if timeout 8 openssl s_client -connect "127.0.0.1:$port" -servername wrong.invalid </dev/null >/dev/null 2>&1; then echo 'FAIL unknown SNI accepted'; exit 1; fi
  if timeout 8 openssl s_client -connect "127.0.0.1:$port" -noservername </dev/null >/dev/null 2>&1; then echo 'FAIL absent SNI accepted'; exit 1; fi
  echo "PASS unknown and absent SNI rejected on TCP $port"
done
