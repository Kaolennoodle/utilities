#!/usr/bin/env bash
#
# hy2.sh - Hysteria2 installer & manager (upgrade bridge to nodectl.sh)
#
# NOTE: The '# hy2.sh - Hysteria2' header and SCRIPT_VERSION declaration are
# preserved intentionally so existing hy2.sh installations (v1.4.0 - v1.6.0)
# pass validation during automatic self-update and transition seamlessly to
# nodectl.sh.
#

SCRIPT_VERSION="2.0.0"
NODECTL_URL="https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/nodectl.sh"
NODECTL_SHORTCUT=/usr/local/bin/nodectl
LEGACY_HY2_SHORTCUT=/usr/local/bin/hy2
LEGACY_HY_STATE=/etc/hysteria/.hy2-script.env
NODECTL_STATE=/etc/nodectl/state.env

FROM_PIPE=0
[[ -z ${BASH_SOURCE[0]:-} ]] && FROM_PIPE=1

bridge_err() { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
bridge_info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }

bridge_main() {
  local lang=${NODECTL_LANG:-${HY2_LANG:-}} a prev=""
  for a in "$@"; do
    if [[ $prev == --lang ]]; then lang=$a; break; fi
    prev=$a
  done

  if [[ $EUID -ne 0 ]]; then
    if [[ ${lang,,} == zh* || ${lang,,} == cn ]]; then
      bridge_err "请使用 root 权限运行此脚本（例如：curl -fsSL $NODECTL_URL | sudo bash -s -- --lang zh）。"
    else
      bridge_err "This script must be run as root (try: curl -fsSL $NODECTL_URL | sudo bash)."
    fi
    exit 1
  fi

  local tmp ver
  tmp=$(mktemp "${TMPDIR:-/tmp}/nodectl.XXXXXX") || { bridge_err "mktemp failed"; exit 1; }
  if [[ ${lang,,} == zh* || ${lang,,} == cn ]]; then
    bridge_info "hy2.sh 已升级并更名为 nodectl.sh (v$SCRIPT_VERSION)，正在获取最新版本……"
  else
    bridge_info "hy2.sh has been upgraded and renamed to nodectl.sh (v$SCRIPT_VERSION); fetching latest script..."
  fi

  if ! curl -fsSL --retry 3 --max-time 25 "$NODECTL_URL" -o "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    bridge_err "Failed to download $NODECTL_URL"
    exit 1
  fi

  ver=$(sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$tmp" 2>/dev/null | head -n 1)
  if [[ -z $ver ]] || ! grep -q '^# nodectl\.sh -' "$tmp" || ! bash -n "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    bridge_err "Downloaded file is not a valid nodectl.sh."
    exit 1
  fi

  # If this server already has a legacy hy2 installation or nodectl state, install
  # /usr/local/bin/nodectl right away and hand over so adopt_installation migrates
  # state, displays the changelog, and removes /usr/local/bin/hy2.
  if [[ -f $LEGACY_HY_STATE || -f $NODECTL_STATE || -e $LEGACY_HY2_SHORTCUT ]]; then
    if ! { chmod 755 "$tmp" && mv -f "$tmp" "$NODECTL_SHORTCUT"; }; then
      rm -f "$tmp"; exit 1
    fi
    # If there is no state file at all, remove stray /usr/local/bin/hy2 directly
    if [[ ! -f $LEGACY_HY_STATE && ! -f $NODECTL_STATE && -e $LEGACY_HY2_SHORTCUT ]]; then
      rm -f "$LEGACY_HY2_SHORTCUT"
    fi
    if ((FROM_PIPE)) && [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
      NODECTL_NO_UPDATE_CHECK=1 exec bash "$NODECTL_SHORTCUT" "$@" </dev/tty
    else
      NODECTL_NO_UPDATE_CHECK=1 exec bash "$NODECTL_SHORTCUT" "$@"
    fi
  fi

  # Fresh machine with nothing installed yet: run from temp file (nodectl will
  # install /usr/local/bin/nodectl once a node is actually installed).
  local rc=0
  if ((FROM_PIPE)) && [[ ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
    NODECTL_NO_UPDATE_CHECK=1 bash "$tmp" "$@" </dev/tty || rc=$?
  else
    NODECTL_NO_UPDATE_CHECK=1 bash "$tmp" "$@" || rc=$?
  fi
  rm -f "$tmp"
  exit "$rc"
}

bridge_main "$@"
