#!/usr/bin/env bash
# =============================================================================
# common.sh — shared library for the dual-proxy deployment suite.
#
# This file MUST be sourced, never executed directly:
#   source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
#
# Provides: paths, version pins, logging, settings persistence, idempotency
# markers, and small helpers. No secrets are ever logged.
# =============================================================================

# Shared constants below are consumed by other sourced modules (cross-file),
# so their "unused" appearance within this file is expected.
# shellcheck disable=SC2034

# ---------------------------------------------------------------------------
# Strict mode
# ---------------------------------------------------------------------------
set -euo pipefail
if (( BASH_VERSINFO[0] < 4 )); then
  printf 'dual-proxy requires Bash >= 4 (Linux target).\n' >&2
  exit 2
fi
[[ ${DP_COMMON_LOADED:-0} == 1 ]] && return 0
DP_COMMON_LOADED=1
umask 077
shopt -s extglob

# ---------------------------------------------------------------------------
# Runtime paths (on the target VPS)
# ---------------------------------------------------------------------------
DP_ROOT=${DP_ROOT:-/opt/dual-proxy}
DP_SCRIPTS="$DP_ROOT/scripts"
DP_STATE="$DP_ROOT/state"
DP_MANIFESTS="$DP_ROOT/manifests"
DP_VERSION_FILE="$DP_ROOT/VERSION"

DP_ETC=${DP_ETC:-/etc/dual-proxy}
DP_SETTINGS="$DP_ETC/settings.conf"
DP_SECRETS="$DP_ETC/secrets"
DP_CERTS="$DP_ETC/certs"
DP_VLESS_UUID="$DP_SECRETS/vless-uuid"
DP_XRAY_PRIVKEY="$DP_SECRETS/xray-private.key"
DP_XRAY_PUBKEY="$DP_SECRETS/xray-public.key"
DP_HY_PASS="$DP_SECRETS/hysteria.passwd"

XRAY_CONF=/etc/xray/config.json
HY_CONF=/etc/hysteria/config.yaml
NGINX_SITE=/etc/nginx/sites-available/reality-site
NGINX_ENABLED=/etc/nginx/sites-enabled/reality-site

SITE_ROOT=${SITE_ROOT:-/var/www/reality-site}
SITE_CURRENT="$SITE_ROOT/current"
SITE_RELEASES="$SITE_ROOT/releases"

ACME_HOME=/root/.acme.sh
ACME_BIN="$ACME_HOME/acme.sh"

LOG_DIR=${LOG_DIR:-/var/log/dual-proxy}
LOG_FILE="$LOG_DIR/install.log"

# ---------------------------------------------------------------------------
# Version pins (see docs/01 技术可行性审查报告 §2.7)
# ---------------------------------------------------------------------------
XRAY_VERSION=v26.3.27
HYSTERIA_VERSION=v2.13.0

# arch -> (asset filename, sha256)  — verified from GitHub Release API 2026-11-13
declare -A XRAY_ASSET=(
  [x86_64]="Xray-linux-64.zip"
  [aarch64]="Xray-linux-arm64-v8a.zip"
)
declare -A XRAY_SHA256=(
  [x86_64]="23cd9af937744d97776ee35ecad4972cf4b2109d1e0fe6be9930467608f7c8ae"
  [aarch64]="4d30283ae614e3057f730f67cd088a42be6fdf91f8639d82cb69e48cde80413c"
)
declare -A HY_ASSET=(
  [x86_64]="hysteria-linux-amd64"
  [aarch64]="hysteria-linux-arm64"
)
declare -A HY_SHA256=(
  [x86_64]="907ba8c9693edb104b20582681fb7dc15639d5b64a9cbb616a7b539190a86691"
  [aarch64]="a68a61a84452ca250ce0368202521965ca9cc9d801a404f1dc9008ac6cf677a7"
)

XRAY_DL_BASE="https://github.com/XTLS/Xray-core/releases/download/${XRAY_VERSION}"
HY_DL_BASE="https://github.com/apernet/hysteria/releases/download/app%2F${HYSTERIA_VERSION}"

# ---------------------------------------------------------------------------
# Terminal output / logging
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  _C_RED=$'\033[31m'; _C_GRN=$'\033[32m'; _C_YEL=$'\033[33m'; _C_CYN=$'\033[36m'; _C_OFF=$'\033[0m'
else
  _C_RED=''; _C_GRN=''; _C_YEL=''; _C_CYN=''; _C_OFF=''
fi

log() { printf '%s\n' "$*" | tee -a "$LOG_FILE"; }
info() { printf '%s[INFO]%s %s\n' "$_C_CYN" "$_C_OFF" "$*" | tee -a "$LOG_FILE"; }
warn() { printf '%s[WARN]%s %s\n' "$_C_YEL" "$_C_OFF" "$*" | tee -a "$LOG_FILE"; }
err()  { printf '%s[ERROR]%s %s\n' "$_C_RED" "$_C_OFF" "$*" | tee -a "$LOG_FILE" >&2; }
ok()   { printf '%s[ OK ]%s %s\n' "$_C_GRN" "$_C_OFF" "$*" | tee -a "$LOG_FILE"; }

# Fatal error: print and exit.
die() { err "$*"; exit "${2:-1}"; }

# Initialize the log directory as early as possible.
ensure_log() {
  if [[ ! -d "$LOG_DIR" ]]; then
    mkdir -p "$LOG_DIR" 2>/dev/null || true
  fi
  if [[ ! -f "$LOG_FILE" ]]; then
    : > "$LOG_FILE" 2>/dev/null || true
  fi
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  [[ ${EUID:-$(id -u)} -eq 0 ]] || die "必须以 root 运行（或使用 sudo）。" 1
}

detect_arch() {
  local a
  a=$(uname -m)
  case "$a" in
    x86_64|amd64) echo x86_64 ;;
    aarch64|arm64) echo aarch64 ;;
    *) die "不支持的 CPU 架构：${a}（仅支持 x86_64 / aarch64）" 2 ;;
  esac
}

detect_os() {
  if [[ ! -r /etc/os-release ]]; then
    die "无法读取 /etc/os-release，无法确定操作系统。" 2
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  echo "${ID:-unknown} ${VERSION_ID:-unknown}"
}

# ---------------------------------------------------------------------------
# Idempotency markers
# ---------------------------------------------------------------------------
is_installed() { [[ -f "$DP_STATE/installed" ]]; }
mark_installed() {
  mkdir -p "$DP_STATE"
  date -u +"%Y-%m-%dT%H:%M:%SZ" > "$DP_STATE/installed"
  ok "已写入安装状态标记 $DP_STATE/installed"
}

state_set() { # state_set <key> <value>
  mkdir -p "$DP_STATE"
  printf '%s\n' "$2" > "$DP_STATE/$1"
}
state_get() { # state_get <key>  -> prints value or empty
  [[ -f "$DP_STATE/$1" ]] && cat "$DP_STATE/$1" || true
}

# ---------------------------------------------------------------------------
# Settings persistence (non-secret only)
# ---------------------------------------------------------------------------
settings_load() {
  # shellcheck disable=SC1090
  [[ -f "$DP_SETTINGS" ]] && . "$DP_SETTINGS" || true
}
settings_set() {
  mkdir -p "$DP_ETC"
  local f="$DP_SETTINGS" k="$1" v="$2" tmp
  [[ "$k" =~ ^[A-Z_][A-Z_0-9]*$ ]] || return 1
  tmp=$(mktemp "$DP_ETC/.settings.XXXXXX")
  if [[ -f "$f" ]]; then sed "/^${k}=/d" "$f" > "$tmp"; fi
  printf '%s=%q\n' "$k" "$v" >> "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$f"
}

# ---------------------------------------------------------------------------
# Misc
# ---------------------------------------------------------------------------
# Join an array with a delimiter (used for building JSON/IP lists).
join_by() {
  local IFS="$1"; shift; printf '%s' "$*"
}

# Non-interactive mode detection
noninteractive() { [[ "${DUALPROXY_NONINTERACTIVE:-0}" == "1" ]]; }

# UTC timestamp used in directory and state names.
stamp() { date -u +"%Y%m%dT%H%M%SZ"; }

emit_client_params() {
  local pub sid hy user_uuid
  pub=$(cat "$DP_XRAY_PUBKEY")
  sid=$(cat "$DP_SECRETS/reality-shortid")
  hy=$(cat "$DP_HY_PASS")
  user_uuid=$(cat "$DP_VLESS_UUID")

  # base64url-encode the X25519 public key for the vless:// link.
  local pub_url
  pub_url=$(printf '%s' "$pub" | tr '+/' '-_' | tr -d '=')

  local vless hysteria
  vless="vless://${user_uuid}@${DOMAIN}:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${DOMAIN}&fp=chrome&pbk=${pub_url}&sid=${sid}&type=tcp#reality-${DOMAIN}"
  hysteria="hysteria2://${hy}@${DOMAIN}:443/?sni=${DOMAIN}&insecure=0#hy2-${DOMAIN}"

  # Write to a root-only file, and print to stdout (NOT the log file).
  local params="$DP_SECRETS/client-params.txt"
  {
    echo "域名/SNI : $DOMAIN"
    echo "TCP 443  : VLESS + Reality + XTLS Vision"
    echo "UDP 443  : Hysteria2"
    echo "Reality public key : $pub"
    echo "Reality shortId    : $sid"
    echo "VLESS UUID         : $user_uuid"
    echo "Hysteria2 密码     : $hy"
    echo
    echo "# VLESS 分享链接"
    echo "$vless"
    echo
    echo "# Hysteria2 分享链接"
    echo "$hysteria"
  } > "$params"
  chmod 600 "$params"

  printf '\n'
  printf '%s================ 连接参数（敏感，请妥善保存） ================%s\n' "$_C_GRN" "$_C_OFF"
  cat "$params"
  printf '%s============================================================%s\n' "$_C_GRN" "$_C_OFF"
  printf '（已同时保存到 %s，可用 manage.sh status 查看）\n\n' "$params"
}

refresh_client_params() {
  emit_client_params >/dev/null
}
