#!/usr/bin/env bash
# =============================================================================
# manage.sh — maintenance entry point for the dual-proxy deployment.
# Usage: manage.sh <command> [args]
#
# Changes are validated before services are restarted, but nothing is backed
# up or rolled back automatically.
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/download.sh
source "$SCRIPT_DIR/lib/download.sh"
# shellcheck source=lib/render.sh
source "$SCRIPT_DIR/lib/render.sh"
# shellcheck source=lib/crypto.sh
source "$SCRIPT_DIR/lib/crypto.sh"
# shellcheck source=lib/cert.sh
source "$SCRIPT_DIR/lib/cert.sh"
# shellcheck source=lib/systemd.sh
source "$SCRIPT_DIR/lib/systemd.sh"
# shellcheck source=lib/healthcheck.sh
source "$SCRIPT_DIR/lib/healthcheck.sh"
# shellcheck source=lib/site.sh
source "$SCRIPT_DIR/lib/site.sh"
# shellcheck source=lib/uninstall.sh
source "$SCRIPT_DIR/lib/uninstall.sh"

settings_load

usage() {
  cat <<'HELP'
用法：manage.sh <command> [args]

状态/检查：
  status                          概览（服务、版本、证书、站点）
  check                           运行健康检查
  diagnose                        收集诊断信息

凭据（输出新的连接参数，旧凭据立即失效）：
  vless-reset                     重新生成 VLESS UUID
  hysteria-reset                  重新生成 Hysteria2 密码

证书：
  cert-status                     查看证书状态
  cert-renew                      强制续期（注意 CA 频率限制）

站点：
  site-update --dir <dir>         原子替换站点内容（不保留旧版本）

升级：
  upgrade                         安装本脚本 lib/common.sh 中固定的
                                  Xray/Hysteria2 版本并重启（无自动回滚）

卸载：
  uninstall [--purge-site] [--purge-acme] [--yes]
                                  永久删除，不做备份；需输入域名确认
HELP
}

cmd_status() {
  info "==== dual-proxy 状态 ===="
  info "域名：$DOMAIN"
  info "Xray 版本：$(xray_installed_version 2>/dev/null || echo unknown)（固定 $XRAY_VERSION）"
  info "Hysteria2 版本：$(hysteria_installed_version 2>/dev/null || echo unknown)（固定 $HYSTERIA_VERSION）"
  info "服务状态："
  for s in xray hysteria-server nginx; do svc_status_line "$s"; done
  info "站点：$(readlink "$SITE_CURRENT" 2>/dev/null || echo '(未部署)')"
  cert_status || true
  if [[ -f "$DP_SECRETS/client-params.txt" ]]; then
    info "连接参数：$DP_SECRETS/client-params.txt（敏感，root 可读）"
  fi
}

cmd_diagnose() {
  info "==== 诊断信息 ===="
  for s in xray hysteria-server nginx; do
    echo "--- systemctl status $s ---"
    systemctl status "$s" --no-pager -n 5 2>&1 | sed 's/^/  /' || true
  done
  echo "--- 监听端口 80/443 ---"
  ss -H -tlnp 'sport = :80' 2>/dev/null | sed 's/^/  /' || true
  ss -H -tlnp 'sport = :443' 2>/dev/null | sed 's/^/  /' || true
  ss -H -ulnp 'sport = :443' 2>/dev/null | sed 's/^/  /' || true
  echo "--- 证书到期 ---"
  openssl x509 -in "$DP_CERTS/$DOMAIN.fullchain.pem" -noout -enddate 2>/dev/null | sed 's/^/  /' || true
  echo "--- 安装日志（末尾 20 行） ---"
  tail -n 20 "$LOG_FILE" 2>/dev/null | sed 's/^/  /' || true
}

# Rotate one credential: write it, re-render, validate, restart, report.
cmd_vless_reset() {
  vless_uuid_new
  render_xray && validate_xray && svc_restart xray \
    || die "新 UUID 已写入但 Xray 未能生效，请执行 manage.sh diagnose 排查" 3
  emit_client_params
}

cmd_hysteria_reset() {
  gen_password > "$DP_HY_PASS"
  chmod 600 "$DP_HY_PASS"
  render_hysteria && validate_hysteria && svc_restart hysteria-server \
    || die "新密码已写入但 Hysteria2 未能生效，请执行 manage.sh diagnose 排查" 3
  emit_client_params
}

cmd_site_update() {
  local dir=""
  while (($# > 0)); do
    case "$1" in
      --dir) [[ $# -ge 2 ]] || die "--dir 需要参数" 1; dir="$2"; shift 2 ;;
      *) die "未知参数 $1" 1 ;;
    esac
  done
  site_deploy "$dir"
}

cmd_upgrade() {
  install_xray
  install_hysteria
  validate_xray && validate_hysteria || die "现有配置未通过新版本校验" 3
  svc_restart xray && svc_restart hysteria-server || die "服务重启失败，请执行 manage.sh diagnose 排查" 1
  run_healthcheck
}

cmd_uninstall() {
  local purge_site=0 purge_acme=0 yes=0
  while (($# > 0)); do
    case "$1" in
      --purge-site) purge_site=1 ;;
      --purge-acme) purge_acme=1 ;;
      --yes) yes=1 ;;
      *) die "未知参数：$1（uninstall [--purge-site] [--purge-acme] [--yes]）" 1 ;;
    esac
    shift
  done
  uninstall "$purge_site" "$purge_acme" "$yes"
}

main() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  local cmd="$1"; shift
  case "$cmd" in -h|--help) usage; exit 0 ;; esac
  trap cleanup_downloads EXIT
  require_root; ensure_log
  exec 9>/run/lock/dual-proxy.lock
  flock -n 9 || die "另一个维护操作正在运行" 1
  case "$cmd" in
    status) cmd_status ;;
    check) run_healthcheck ;;
    diagnose) cmd_diagnose ;;
    vless-reset) cmd_vless_reset ;;
    hysteria-reset) cmd_hysteria_reset ;;
    cert-status) cert_status ;;
    cert-renew) cert_renew ;;
    site-update) cmd_site_update "$@" ;;
    upgrade) cmd_upgrade ;;
    uninstall) cmd_uninstall "$@" ;;
    *) die "未知命令：${cmd}（见 --help）" 1 ;;
  esac
}

main "$@"
