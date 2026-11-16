#!/usr/bin/env bash
# =============================================================================
# site.sh — atomic static-site deployment (no version history is kept).
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Copy <src_dir> into a fresh directory, swap the "current" symlink to it in a
# single rename, then delete the previous directory. The source is not modified.
site_deploy() {
  local src="${1:-}" new old
  [[ -n "$src" && -d "$src" ]] || die "静态站点源目录不存在：${src:-<未提供>}" 1

  mkdir -p "$SITE_RELEASES"
  chmod 755 "$SITE_ROOT" "$SITE_RELEASES"
  new=$(mktemp -d "$SITE_RELEASES/$(stamp).XXXXXX")

  info "复制站点文件到 $new"
  cp -a "$src"/. "$new/"
  if find "$new" -type l -print -quit | grep -q .; then
    rm -rf -- "$new"
    die "静态站点不接受符号链接（防止泄露站外文件）" 1
  fi
  chmod -R u+rwX,go+rX,go-w "$new"

  old=$(readlink "$SITE_CURRENT" 2>/dev/null || true)
  ln -sfn "$new" "$SITE_CURRENT.tmp"
  mv -Tf "$SITE_CURRENT.tmp" "$SITE_CURRENT"
  ok "站点已部署：$SITE_CURRENT -> $new"

  # Remove every other release (the previous one and any leftovers).
  local d
  for d in "$SITE_RELEASES"/*; do
    [[ -d "$d" && "$d" != "$new" ]] && rm -rf -- "$d"
  done
  [[ -z "$old" ]] || info "已删除旧站点目录"
}
