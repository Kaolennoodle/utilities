#!/usr/bin/env bash
# =============================================================================
# cert.sh — ACME HTTP-01 certificate issuance / renewal / status (TCP 80).
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

ACME_WEBROOT=/var/www/dual-proxy-acme
ACME_SITE=/etc/nginx/sites-available/dual-proxy-acme
ACME_SITE_ENABLED=/etc/nginx/sites-enabled/dual-proxy-acme

cert_paths() {
  [[ -n ${DOMAIN:-} ]] || die "DOMAIN 未设置" 1
  CERT_FULLCHAIN="$DP_CERTS/$DOMAIN.fullchain.pem"
}

acme() { "$ACME_BIN" --home "$ACME_HOME" --config-home "$DP_ROOT/acme" --server letsencrypt "$@"; }

# Port 80 serves only ACME challenges and redirects everything else to HTTPS.
enable_acme_site() {
  install -d -m 0755 "$ACME_WEBROOT/.well-known/acme-challenge"
  cat > "$ACME_SITE" <<NGINX
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    location ^~ /.well-known/acme-challenge/ { root $ACME_WEBROOT; }
    location / { return 301 https://\$host\$request_uri; }
}
NGINX
  chmod 644 "$ACME_SITE"
  ln -sfn "$ACME_SITE" "$ACME_SITE_ENABLED"
  nginx -t || die "Nginx 配置校验失败（ACME 站点）" 3
  systemctl enable --now nginx
  systemctl reload nginx
}

cert_issue() {
  cert_paths
  install -d -m 0700 "$DP_ROOT/acme" "$DP_CERTS" "$DP_CERTS/incoming"
  enable_acme_site
  info "ACME HTTP-01 签发证书：$DOMAIN"
  local issued=0
  ( umask 022; acme --issue --webroot "$ACME_WEBROOT" -d "$DOMAIN" \
      --email "${EMAIL:-admin@$DOMAIN}" --keylength ec-256 ) || issued=$?
  # acme.sh returns 2 when a valid certificate already exists (skipped).
  [[ "$issued" == 0 || "$issued" == 2 ]] || die "证书签发失败，请检查域名解析及公网 TCP 80 可达性" 5

  acme --install-cert -d "$DOMAIN" \
    --fullchain-file "$DP_CERTS/incoming/$DOMAIN.fullchain.pem" \
    --key-file "$DP_CERTS/incoming/$DOMAIN.key" \
    --reloadcmd "$DP_SCRIPTS/cert-deploy.sh" \
    || die "证书安装到目标路径失败" 5
  "$DP_SCRIPTS/cert-deploy.sh" || die "证书校验或部署失败" 5

  printf '17 3 * * * root %s/renew-cert.sh\n' "$DP_SCRIPTS" > /etc/cron.d/dual-proxy-cert
  chmod 644 /etc/cron.d/dual-proxy-cert
  systemctl enable --now cron
  state_set cert_issued_at "$(stamp)"
  ok "证书已签发并安装：$CERT_FULLCHAIN"
}

cert_renew() {
  cert_paths
  [[ -x "$ACME_BIN" ]] || die "acme.sh 未安装" 1
  ( umask 022; acme --renew -d "$DOMAIN" --force ) || die "证书续期失败" 5
  "$DP_SCRIPTS/cert-deploy.sh" || die "证书校验或部署失败" 5
  ok "证书已续期"
}

cert_status() {
  cert_paths
  [[ -f "$CERT_FULLCHAIN" ]] || { warn "尚未签发证书"; return 1; }
  local end
  end=$(openssl x509 -in "$CERT_FULLCHAIN" -noout -enddate 2>/dev/null | sed 's/^notAfter=//')
  info "证书域名：$DOMAIN"
  info "证书到期：$end"
  if openssl x509 -in "$CERT_FULLCHAIN" -noout -checkend 2592000 >/dev/null 2>&1; then
    ok "证书有效期 ≥ 30 天"
  else
    warn "证书将在 30 天内过期，请执行 cert-renew"
  fi
}
