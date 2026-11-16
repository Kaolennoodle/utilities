#!/usr/bin/env bash
# =============================================================================
# install.sh — deploy VLESS+Reality+Vision (TCP 443) and Hysteria2 (UDP 443)
# with a static HTTPS site, a Let's Encrypt certificate (HTTP-01 on TCP 80)
# and systemd management.
#
# Usage:
#   ./install.sh --domain blog.example.com [--email admin@example.com] \
#                [--site /path/to/static] [--non-interactive]
#
# There is no automatic rollback: if a step fails, fix the cause and run the
# same command again; completed steps are skipped and secrets are kept.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/env-check.sh
source "$SCRIPT_DIR/lib/env-check.sh"
# shellcheck source=lib/download.sh
source "$SCRIPT_DIR/lib/download.sh"
# shellcheck source=lib/crypto.sh
source "$SCRIPT_DIR/lib/crypto.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"
# shellcheck source=lib/cert.sh
source "$SCRIPT_DIR/lib/cert.sh"
# shellcheck source=lib/systemd.sh
source "$SCRIPT_DIR/lib/systemd.sh"
# shellcheck source=lib/healthcheck.sh
source "$SCRIPT_DIR/lib/healthcheck.sh"
# shellcheck source=lib/site.sh
source "$SCRIPT_DIR/lib/site.sh"

DOMAIN=""
EMAIL=""
SITE_SRC=""

usage() {
  cat <<'EOF'
用法：
  ./install.sh --domain <域名> [选项]

必填：
  --domain <d>        用于 Reality/Hysteria2/博客的域名，A/AAAA 须直接指向本机

可选：
  --email <e>         ACME 账号邮箱（默认 admin@<域名>）
  --site <dir>        静态博客目录（默认部署一个占位页）
  --non-interactive   非交互模式

证书通过 HTTP-01 签发，公网 TCP 80 必须可达。
安装失败不会自动回滚；排除问题后重新运行同一命令即可继续。

环境变量：
  DUALPROXY_NONINTERACTIVE=1   等价于 --non-interactive
EOF
}

parse_args() {
  while (($# > 0)); do
    case "$1" in
      --domain|--email|--site) [[ $# -ge 2 ]] || die "$1 需要参数" 1 ;;
    esac
    case "$1" in
      --domain) DOMAIN="$2"; shift 2 ;;
      --email) EMAIL="$2"; shift 2 ;;
      --site) SITE_SRC="$2"; shift 2 ;;
      --non-interactive) export DUALPROXY_NONINTERACTIVE=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "未知参数：$1（见 --help）" 1 ;;
    esac
  done

  # Env fallbacks
  DOMAIN="${DOMAIN:-${DP_DOMAIN:-}}"
  EMAIL="${EMAIL:-${DP_EMAIL:-}}"
  [[ -n "$DOMAIN" ]] || die "必须提供 --domain（或 DOMAIN 环境变量）" 1
  [[ -n "$EMAIL" ]] || EMAIL="admin@$DOMAIN"
  [[ "$DOMAIN" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$DOMAIN" == *.* && "$DOMAIN" != *..* ]] || die "非法域名" 1
}

install_deps() {
  info "安装/确认系统依赖（nginx jq openssl unzip curl ca-certificates logrotate）"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || warn "apt update 失败，继续尝试"
  apt-get -o DPkg::Lock::Timeout=120 install -y -qq \
    nginx jq openssl unzip curl ca-certificates logrotate bind9-dnsutils python3 python3-yaml cron >>"$LOG_DIR/dependencies.log" 2>&1 \
    || die "安装系统依赖失败，详见 $LOG_DIR/dependencies.log" 1
  python3 -c 'import yaml' || die "python3-yaml 不可用" 1
  ok "系统依赖就绪"
}

install_support_scripts() {
  local dest="$DP_SCRIPTS"
  mkdir -p "$dest/lib" "$dest/templates"
  cp -a "$SCRIPT_DIR/lib/." "$dest/lib/"
  cp -a "$SCRIPT_DIR/templates/." "$dest/templates/"
  install -m 0755 "$SCRIPT_DIR/manage.sh" "$dest/manage.sh"
  install -m 0755 "$SCRIPT_DIR/templates/cert-deploy.sh" "$dest/cert-deploy.sh"
  install -m 0755 "$SCRIPT_DIR/templates/renew-cert.sh" "$dest/renew-cert.sh"

  # logrotate
  install -m 0644 "$SCRIPT_DIR/templates/logrotate-xray" /etc/logrotate.d/xray
  install -m 0644 "$SCRIPT_DIR/templates/logrotate-hysteria" /etc/logrotate.d/dual-proxy

  mkdir -p "$DP_STATE" "$DP_MANIFESTS"
  ok "已安装维护脚本到 $dest"
}

ensure_secrets() {
  mkdir -p "$DP_SECRETS"
  chmod 700 "$DP_SECRETS"

  if [[ ! -f "$DP_XRAY_PRIVKEY" ]]; then
    gen_x25519
    printf '%s' "$X25519_PRIVATE" > "$DP_XRAY_PRIVKEY"
    printf '%s' "$X25519_PUBLIC" > "$DP_XRAY_PUBKEY"
    chmod 600 "$DP_XRAY_PRIVKEY" "$DP_XRAY_PUBKEY"
    ok "已生成 Reality X25519 密钥对"
  fi

  if [[ ! -f "$DP_SECRETS/reality-shortid" ]]; then
    gen_shortid > "$DP_SECRETS/reality-shortid"
    chmod 600 "$DP_SECRETS/reality-shortid"
    ok "已生成 Reality shortId"
  fi

  if [[ ! -f "$DP_HY_PASS" ]]; then
    gen_password > "$DP_HY_PASS"
    chmod 600 "$DP_HY_PASS"
    ok "已生成 Hysteria2 密码"
  fi

  if [[ ! -f "$DP_VLESS_UUID" ]]; then
    vless_uuid_new
    ok "已生成 VLESS UUID"
  fi
}

deploy_site() {
  mkdir -p "$SITE_ROOT"
  if [[ -n "$SITE_SRC" ]]; then
    site_deploy "$SITE_SRC"
  elif [[ ! -e "$SITE_CURRENT" && ! -L "$SITE_CURRENT" ]]; then
    # Minimal placeholder so the blog serves something out of the box.
    local tmp="$SITE_ROOT/.placeholder"
    mkdir -p "$tmp"
    cat > "$tmp/index.html" <<'HTML'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Coming soon</title></head>
<body style="font-family:sans-serif;padding:3rem;text-align:center">
<h1>Site under construction</h1>
<p>This is the default placeholder. Run <code>manage.sh site-update --dir /path/to/site</code> to deploy your blog.</p>
</body></html>
HTML
    site_deploy "$tmp"
    rm -rf "$tmp"
  else
    info "站点已存在，保留现状（不覆盖）"
  fi
}


install_exit() {
  cleanup_downloads || true
  (( $1 == 0 )) || err "安装未完成，未做回滚。排除问题后重新运行同一命令即可继续；放弃安装请执行：$DP_SCRIPTS/manage.sh uninstall"
}

main() {
  parse_args "$@"
  require_root
  ensure_log
  exec 9>/run/lock/dual-proxy.lock
  flock -n 9 || die "另一个安装或维护操作正在运行" 1
  info "==== dual-proxy 安装开始 $(stamp) ===="
  info "域名：$DOMAIN  架构：$(detect_arch)  OS：$(detect_os)"

  if is_installed; then
    warn "检测到已安装（$DP_STATE/installed）。请使用维护入口："
    info "  $DP_SCRIPTS/manage.sh status"
    exit 0
  fi

  # Stage 1: environment checks
  run_preinstall_checks
  mkdir -p "$DP_STATE"
  touch "$DP_STATE/install-started"
  trap 'install_exit $?' EXIT

  # Stage 2: dependencies + downloads
  install_deps
  install_support_scripts
  install_xray
  install_hysteria
  install_acme

  # Stage 3: secrets + settings (cert-deploy.sh reads settings.conf)
  prepare_runtime_dirs
  ensure_secrets
  settings_set DOMAIN "$DOMAIN"
  settings_set EMAIL "$EMAIL"

  # Stage 4: static site
  deploy_site

  # Stage 5: certificate (HTTP-01)
  if [[ -f "$DP_CERTS/$DOMAIN.fullchain.pem" ]]; then
    info "证书已存在，跳过签发"
  else
    cert_issue
  fi

  # Stage 6: render + validate configs
  render_xray
  render_hysteria
  render_nginx
  validate_xray
  validate_hysteria
  validate_nginx

  # Stage 7: enable nginx site + reload
  ln -sfn "$NGINX_SITE" "$NGINX_ENABLED"
  nginx -t || die "Nginx 配置校验失败" 3
  systemctl enable --now nginx
  systemctl reload nginx
  ok "Nginx 站点已启用并重载"

  # Stage 8: install + start services
  install_units
  validate_units
  enable_all
  systemctl restart xray hysteria-server || die "启动服务失败" 1
  sleep 2

  # Stage 9: health check
  run_healthcheck || die "健康检查未通过，详见上方输出" 1

  # Stage 10: commit state
  mark_installed
  rm -f "$DP_STATE/install-started"
  printf 'dual-proxy %s\n' "$(stamp)" > "$DP_VERSION_FILE"
  state_set domain "$DOMAIN"

  emit_client_params

  ok "==== 安装完成 ===="
  info "维护入口：$DP_SCRIPTS/manage.sh"
}

main "$@"
