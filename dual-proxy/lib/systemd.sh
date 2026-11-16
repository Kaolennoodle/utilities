#!/usr/bin/env bash
# =============================================================================
# systemd.sh — service accounts, unit installation, service lifecycle.
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" 2>/dev/null && pwd)"

# Services run as root (sandboxed by their unit files); only log dirs are needed.
prepare_runtime_dirs() {
  install -d -m 0750 "$DP_ETC" /var/log/xray /var/log/hysteria
  touch /var/log/xray/error.log
  chmod 640 /var/log/xray/error.log
}

install_units() {
  install -m 0644 "$TEMPLATE_DIR/xray.service" /etc/systemd/system/xray.service
  install -m 0644 "$TEMPLATE_DIR/hysteria-server.service" /etc/systemd/system/hysteria-server.service
  systemctl daemon-reload
  ok "已安装 systemd 单元 xray.service / hysteria-server.service"
}

validate_units() {
  systemd-analyze verify /etc/systemd/system/xray.service >/dev/null 2>&1 \
    || { err "xray.service systemd 校验失败"; return 3; }
  systemd-analyze verify /etc/systemd/system/hysteria-server.service >/dev/null 2>&1 \
    || { err "hysteria-server.service systemd 校验失败"; return 3; }
  ok "systemd 单元校验完成"
}

svc_restart() { systemctl restart "$1" || return $?; sleep 0.5; svc_active "$1"; }
svc_enable() { systemctl enable "$1" >/dev/null 2>&1 || true; }

svc_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

svc_status_line() {
  local s="$1"
  printf '  %-22s %s\n' "$s" "$(systemctl is-active "$s" 2>/dev/null || echo unknown)"
}

enable_all() {
  svc_enable xray
  svc_enable hysteria-server
}
