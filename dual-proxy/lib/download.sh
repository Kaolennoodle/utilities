#!/usr/bin/env bash
# =============================================================================
# download.sh — download, SHA256-verify and install Xray / Hysteria2 / acme.sh.
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

DL_TMP="${DL_TMP:-}"
ensure_download_dir() {
  if [[ -z "$DL_TMP" ]]; then install -d -m 0700 "$DP_ROOT/tmp"; DL_TMP=$(mktemp -d "$DP_ROOT/tmp/download.XXXXXX"); chmod 700 "$DL_TMP"; DL_TMP_OWNED=1; fi
}

cleanup_downloads() {
  if [[ ${DL_TMP_OWNED:-0} == 1 && -d "$DL_TMP" ]]; then rm -rf -- "$DL_TMP"; fi
}

record_component_manifest() {
  local component="$1" version="$2" digest="$3" binary
  case "$component" in xray) binary=/usr/local/bin/xray;; hysteria) binary=/usr/local/bin/hysteria;; *) return 1;; esac
  mkdir -p "$DP_MANIFESTS"
  jq -n --arg version "$version" --arg archive_sha256 "$digest" \
    --arg binary_sha256 "$(sha256sum "$binary" | awk '{print $1}')" \
    --arg architecture "$(detect_arch)" --arg build "$("$binary" version)" \
    '{version:$version,archive_sha256:$archive_sha256,binary_sha256:$binary_sha256,architecture:$architecture,build:$build}' \
    > "$DP_MANIFESTS/$component.json"
}

# ---------------------------------------------------------------------------
# Generic verified download
# ---------------------------------------------------------------------------
download_verify() { # download_verify <url> <expected_sha256> <dest_file>
  local url="$1" sha="$2" dest="$3"
  mkdir -p "$(dirname "$dest")"
  info "下载：$(basename "$dest")"
  # Bundled assets (deploy.sh) are looked up by the destination file name.
  local asset="${dest##*/}"
  if [[ -n ${DP_ASSET_DIR:-} && -f "$DP_ASSET_DIR/$asset" ]]; then
    cp "$DP_ASSET_DIR/$asset" "$dest" || die "复制随包资产失败：$asset" 4
  else
    curl -fL --retry 3 --retry-delay 2 --connect-timeout 15 -o "$dest" "$url" \
      || die "下载失败：$url" 4
  fi

  local actual
  actual=$(sha256sum "$dest" | awk '{print $1}')
  if [[ "$actual" != "$sha" ]]; then
    rm -f "$dest"
    err "SHA256 校验失败：$(basename "$dest")"
    err "  期望：$sha"
    err "  实际：$actual"
    die "校验失败，已删除损坏文件。" 4
  fi
  ok "SHA256 校验通过：$(basename "$dest")"
}

# ---------------------------------------------------------------------------
# Xray
# ---------------------------------------------------------------------------
xray_installed_version() {
  local v
  v=$(/usr/local/bin/xray version 2>/dev/null | awk '/Xray/{print $2; exit}' || true)
  printf '%s' "$v"
}

install_xray() {
  ensure_download_dir
  local arch asset sha zip
  arch=$(detect_arch)
  asset="${XRAY_ASSET[$arch]}"
  sha="${XRAY_SHA256[$arch]}"
  [[ -n "$asset" && -n "$sha" ]] || die "无 $arch 架构的 Xray 资产定义" 2

  zip="$DL_TMP/$asset"

  # Skip if the requested version is already installed.
  if [[ "$(xray_installed_version)" == "${XRAY_VERSION#v}" ]]; then
    ok "Xray $XRAY_VERSION 已安装，跳过下载"
    return 0
  fi

  download_verify "$XRAY_DL_BASE/$asset" "$sha" "$zip"

  local extract="$DL_TMP/xray-extract"
  rm -rf "$extract"; mkdir -p "$extract"
  unzip -q -o "$zip" xray -d "$extract" </dev/null || die "解压 Xray 失败" 4
  install -m 0755 "$extract/xray" /usr/local/bin/xray.new
  mv -f /usr/local/bin/xray.new /usr/local/bin/xray
  ok "已安装 Xray $XRAY_VERSION → /usr/local/bin/xray"

  state_set xray_version "$XRAY_VERSION"
  state_set xray_sha256 "$sha"
  record_component_manifest xray "$XRAY_VERSION" "$sha"
}

# ---------------------------------------------------------------------------
# Hysteria2
# ---------------------------------------------------------------------------
hysteria_installed_version() {
  local v
  v=$(/usr/local/bin/hysteria version 2>/dev/null | head -n1 || true)
  printf '%s' "$v"
}

install_hysteria() {
  ensure_download_dir
  local arch asset sha dest
  arch=$(detect_arch)
  asset="${HY_ASSET[$arch]}"
  sha="${HY_SHA256[$arch]}"
  [[ -n "$asset" && -n "$sha" ]] || die "无 $arch 架构的 Hysteria2 资产定义" 2

  dest="$DL_TMP/$asset"

  if [[ "$(hysteria_installed_version)" == *"$HYSTERIA_VERSION"* ]]; then
    ok "Hysteria2 $HYSTERIA_VERSION 已安装，跳过下载"
    return 0
  fi

  download_verify "$HY_DL_BASE/$asset" "$sha" "$dest"

  install -m 0755 "$dest" /usr/local/bin/hysteria.new
  mv -f /usr/local/bin/hysteria.new /usr/local/bin/hysteria
  ok "已安装 Hysteria2 $HYSTERIA_VERSION → /usr/local/bin/hysteria"

  state_set hysteria_version "$HYSTERIA_VERSION"
  state_set hysteria_sha256 "$sha"
  record_component_manifest hysteria "$HYSTERIA_VERSION" "$sha"
}

# ---------------------------------------------------------------------------
# acme.sh
# ---------------------------------------------------------------------------
install_acme() {
  if [[ -x "$ACME_BIN" ]]; then
    ok "acme.sh 已安装"
    return 0
  fi
  info "安装 acme.sh"
  ensure_download_dir
  local archive="$DL_TMP/acme.sh-3.1.6.tar.gz"
  download_verify 'https://github.com/acmesh-official/acme.sh/archive/807da6498377ee5e0cf43a78091f46f12dc59a89.tar.gz' \
    ddbe1bcbd1a44a2623a2af167ebdc678669e6e2eb396742f2d1d28e02dc14220 "$archive"
  local acme_source="$DL_TMP/acme"
  mkdir -p "$acme_source" "$DP_ROOT/acme"
  tar -xzf "$archive" -C "$acme_source" --strip-components=1
  ( cd "$acme_source"; sh ./acme.sh --install --home "$ACME_HOME" --config-home "$DP_ROOT/acme" --nocron --noprofile ) \
    || die "acme.sh 安装失败" 4
  "$ACME_BIN" --config-home "$DP_ROOT/acme" --set-default-ca --server letsencrypt >/dev/null 2>&1 || true
  state_set acme_installed_by_project 1
  ok "acme.sh 已安装：$ACME_BIN"
}
