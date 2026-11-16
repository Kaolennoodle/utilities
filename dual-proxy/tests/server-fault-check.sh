#!/usr/bin/env bash
# Authorized disposable-server fault injection; always restore changed files.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/common.sh"
source "$ROOT/lib/render.sh"
source "$ROOT/lib/systemd.sh"
source "$ROOT/lib/healthcheck.sh"
settings_load
cert="$DP_CERTS/$DOMAIN.fullchain.pem"
work=$(mktemp -d /root/reality-fault.XXXXXX)
cp -aL "$cert" "$work/cert.pem"
cp -a "$HY_CONF" "$work/hysteria.yaml"
cleanup() {
  cp "$work/cert.pem" "$cert"
  cp -a "$work/hysteria.yaml" "$HY_CONF"
  command -v nft >/dev/null && nft delete table inet dualproxy_fault 2>/dev/null || true
  systemctl start nginx xray hysteria-server
  rm -rf "$work"
}
trap cleanup EXIT
systemctl stop nginx
if check_local_https >/dev/null 2>&1; then echo 'FAIL stopped target accepted'; exit 1; fi
systemctl is-active --quiet hysteria-server
echo 'PASS Nginx target outage detected; Hysteria2 stays active'
systemctl start nginx
for service in xray hysteria-server; do
  before=$(systemctl show "$service" -p MainPID --value)
  systemctl kill --kill-whom=main --signal=SIGKILL "$service"
  recovered=0
  for _ in $(seq 1 15); do
    sleep 1
    after=$(systemctl show "$service" -p MainPID --value)
    if [[ "$after" != 0 && "$after" != "$before" ]] && systemctl is-active --quiet "$service"; then recovered=1; break; fi
  done
  [[ "$recovered" == 1 ]]
  echo "PASS $service crash auto-restarted"
done
printf 'invalid-certificate' > "$cert"
if check_cert >/dev/null 2>&1; then echo 'FAIL invalid certificate accepted'; exit 1; fi
cp "$work/cert.pem" "$cert"
echo 'PASS invalid certificate detected and restored'
printf 'tls: [invalid' > "$HY_CONF"
if validate_hysteria >/dev/null 2>&1; then echo 'FAIL corrupt YAML accepted'; exit 1; fi
cp -a "$work/hysteria.yaml" "$HY_CONF"
echo 'PASS corrupted Hysteria YAML rejected'
if command -v nft >/dev/null; then
  nft add table inet dualproxy_fault
  nft 'add chain inet dualproxy_fault input { type filter hook input priority -10; policy accept; }'
  nft add rule inet dualproxy_fault input udp dport 443 drop
  if HTTP3_CONNECT_IP=127.0.0.1 "$ROOT/test-venv/bin/python" "$ROOT/tests/http3-check.py" "$DOMAIN" >/dev/null 2>&1; then echo 'FAIL UDP drop ineffective'; exit 1; fi
  curl --noproxy '*' -fsS --resolve "$DOMAIN:443:127.0.0.1" --max-time 8 "https://$DOMAIN/" >/dev/null
  echo 'PASS UDP 443 outage breaks HTTP/3 while TCP HTTPS survives'
  nft delete table inet dualproxy_fault
else
  echo 'SKIP UDP outage injection (nft not installed; this project no longer installs it)'
fi
HTTP3_CONNECT_IP=127.0.0.1 "$ROOT/test-venv/bin/python" "$ROOT/tests/http3-check.py" "$DOMAIN"
run_healthcheck
echo 'PASS restored services after all fault injections'
