#!/usr/bin/env bash
# =============================================================================
# uninstall.sh — remove everything this project installed. No backup is taken.
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

uninstall() { # uninstall <purge_site 0|1> <purge_acme 0|1> <assume_yes 0|1>
  local purge_site="${1:-0}" purge_acme="${2:-0}" assume_yes="${3:-0}" ans
  local domain="${DOMAIN:-$(state_get domain)}"

  if [[ "$assume_yes" != 1 ]]; then
    noninteractive && die "非交互卸载需要 --yes" 1
    warn "卸载将永久删除 Xray/Hysteria2、Reality 私钥、VLESS UUID、Hysteria2 密码和证书，不会做备份。"
    read -r -p "确认卸载请输入域名（${domain:-<未知>}）： " ans || ans=""
    [[ -n "$domain" && "$ans" == "$domain" ]] || die "未确认，已取消卸载" 10
  fi

  info "==== 卸载 dual-proxy ===="
  local acme_by_project s
  acme_by_project=$(state_get acme_installed_by_project)

  for s in xray hysteria-server; do
    systemctl disable --now "$s" >/dev/null 2>&1 || true
    rm -f "/etc/systemd/system/$s.service"
  done
  systemctl daemon-reload 2>/dev/null || true
  rm -f /usr/local/bin/xray /usr/local/bin/hysteria
  rm -f /etc/logrotate.d/dual-proxy /etc/logrotate.d/xray /etc/cron.d/dual-proxy-cert
  rm -f "$NGINX_SITE" "$NGINX_ENABLED" \
        /etc/nginx/sites-available/dual-proxy-acme /etc/nginx/sites-enabled/dual-proxy-acme
  rm -rf /var/www/dual-proxy-acme
  systemctl reload nginx 2>/dev/null || true
  rm -rf /etc/xray /etc/hysteria "$DP_ETC" \
         "${DP_ROOT:?}/scripts" "${DP_ROOT:?}/state" "${DP_ROOT:?}/manifests" "${DP_ROOT:?}/tmp"
  info "已移除服务、二进制、配置、凭据与证书"

  # ACME state holds the account key and issued private keys.
  if [[ "$purge_acme" == "1" ]]; then
    rm -rf "${DP_ROOT:?}/acme"
    if [[ "$acme_by_project" == 1 ]]; then rm -rf /root/.acme.sh; fi
    info "已删除 ACME 状态"
  else
    warn "保留 ${DP_ROOT}/acme（ACME 账户与证书私钥）；如需删除请加 --purge-acme"
  fi

  if [[ "$purge_site" == "1" ]]; then
    rm -rf "$SITE_ROOT"
    info "已删除站点目录 $SITE_ROOT"
  else
    warn "保留站点目录 ${SITE_ROOT}（如需删除请加 --purge-site）"
  fi
  rmdir "$DP_ROOT" 2>/dev/null || true
  ok "==== 卸载完成 ===="
}
