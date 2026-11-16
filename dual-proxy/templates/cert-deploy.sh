#!/usr/bin/env bash
# Verify the certificate acme.sh just wrote to incoming/, then atomically
# replace the live pair and reload Nginx. Hysteria2 reads the files on each
# handshake. An invalid pair is rejected and the live pair is left untouched.
set -euo pipefail
umask 077
source /etc/dual-proxy/settings.conf
[[ "$DOMAIN" =~ ^[A-Za-z0-9.-]+$ ]] || exit 1
base=/etc/dual-proxy/certs
cert="$base/incoming/$DOMAIN.fullchain.pem"
key="$base/incoming/$DOMAIN.key"
fail() { logger -t dual-proxy-cert "Certificate deployment rejected: $*"; echo "$*" >&2; exit 1; }
openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null || fail "domain mismatch"
openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null || fail "expired or expiring"
[[ $(openssl x509 -in "$cert" -noout -pubkey) == "$(openssl pkey -in "$key" -pubout)" ]] || fail "key mismatch"
for pair in "$cert:$DOMAIN.fullchain.pem" "$key:$DOMAIN.key"; do
  src=${pair%%:*}; dst="$base/${pair#*:}"
  install -m 0600 "$src" "$dst.new"
  mv -f "$dst.new" "$dst"
done
if systemctl is-active --quiet nginx; then
  nginx -t && systemctl reload nginx || fail "nginx reload failed"
fi
