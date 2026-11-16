#!/usr/bin/env bash
set -euo pipefail
source /etc/dual-proxy/settings.conf
log=/var/log/dual-proxy/cert.log
mkdir -p /var/log/dual-proxy
result=0
( umask 022; /root/.acme.sh/acme.sh --cron --home /root/.acme.sh --config-home /opt/dual-proxy/acme --server letsencrypt >>"$log" 2>&1 ) || result=1
cert="/etc/dual-proxy/certs/$DOMAIN.fullchain.pem"
if ! openssl x509 -in "$cert" -noout -checkend 2592000 >/dev/null 2>&1; then result=1; fi
if (( result )); then
  logger -p daemon.err -t dual-proxy-cert "Certificate renewal/expiry alarm: $DOMAIN; see $log"
  exit 1
fi
