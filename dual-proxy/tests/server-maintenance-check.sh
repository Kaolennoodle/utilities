#!/usr/bin/env bash
# Run only on an explicitly authorized disposable test instance.
# Usage: server-maintenance-check.sh   (run from the unpacked source tree)
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source /opt/dual-proxy/scripts/lib/common.sh
source /opt/dual-proxy/scripts/lib/render.sh
source /opt/dual-proxy/scripts/lib/systemd.sh
source /opt/dual-proxy/scripts/lib/healthcheck.sh
settings_load
manage=/opt/dual-proxy/scripts/manage.sh
run_healthcheck
echo 'PASS runtime health and actual TCP 443 HTTPS fallback'
nginx -t
/usr/local/bin/xray run -test -config /etc/xray/config.json
systemd-analyze verify /etc/systemd/system/xray.service /etc/systemd/system/hysteria-server.service
[[ -z $(systemctl show xray -p User --value) && -z $(systemctl show hysteria-server -p User --value) ]]
echo 'PASS real component/unit validation; services run as root'
old=$(sha256sum "$DP_VLESS_UUID" "$DP_XRAY_PRIVKEY" "$DP_HY_PASS")
"$ROOT/install.sh" --domain "$DOMAIN" --non-interactive
[[ "$old" == "$(sha256sum "$DP_VLESS_UUID" "$DP_XRAY_PRIVKEY" "$DP_HY_PASS")" ]]
echo 'PASS repeated install preserves secrets'
before=$(cat "$DP_VLESS_UUID")
"$manage" vless-reset > /dev/null
[[ "$before" != "$(cat "$DP_VLESS_UUID")" ]]
grep -qF "$(cat "$DP_VLESS_UUID")" "$DP_SECRETS/client-params.txt"
grep -qF "$(cat "$DP_VLESS_UUID")" "$XRAY_CONF"
echo 'PASS VLESS UUID reset re-renders config and client parameters'
# Prove corrupt JSON is caught, then restore without leaving a broken service.
cp -a "$XRAY_CONF" /root/reality-test-xray-good.json
trap 'cp -a /root/reality-test-xray-good.json "$XRAY_CONF"; rm -f /root/reality-test-xray-good.json; systemctl start xray hysteria-server nginx' EXIT
printf 'invalid-json' > "$XRAY_CONF"
if "$manage" check; then echo 'FAIL corrupt JSON accepted'; exit 1; fi
cp -a /root/reality-test-xray-good.json "$XRAY_CONF"
echo 'PASS malformed configuration rejected'
run_healthcheck
