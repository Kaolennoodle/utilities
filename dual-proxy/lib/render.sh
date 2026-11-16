#!/usr/bin/env bash
# =============================================================================
# render.sh — render config templates into /etc/... with placeholder substitution.
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

TEMPLATE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../templates" 2>/dev/null && pwd)"
[[ -d "$TEMPLATE_DIR" ]] || die "找不到模板目录：$TEMPLATE_DIR" 1

# substitute <template> <dest> <KEY=VALUE>...
subst() {
  local src="$1" dst="$2"; shift 2
  # Values travel over stdin, never through process arguments.
  printf '%s\0' "$@" | python3 -c '
import os, re, sys, tempfile
src, dst = sys.argv[1:]
pairs = [item.decode() for item in sys.stdin.buffer.read().split(b"\0") if item]
values = dict(pair.split("=", 1) for pair in pairs)
text = open(src).read()
text = re.sub(r"__([A-Z_]+)__", lambda m: values.get(m[1], m[0]), text)
if re.search(r"__[A-Z_]+__", text):
    raise SystemExit("Unresolved template placeholder: " + src)
fd, staged = tempfile.mkstemp(dir=os.path.dirname(os.path.abspath(dst)))
try:
    with os.fdopen(fd, "w") as output:
        output.write(text)
    os.replace(staged, dst)
finally:
    if os.path.exists(staged): os.unlink(staged)
' "$src" "$dst"
}

# ---------------------------------------------------------------------------
# JSON fragment builders
# ---------------------------------------------------------------------------
build_clients_json() {
  jq -cnRe --rawfile id "$DP_VLESS_UUID" \
    'if ($id | test("^[0-9a-f-]{36}$")) then [{id: $id, flow: "xtls-rprx-vision"}] else error("invalid UUID") end'
}

# Addresses of this VPS itself. Proxy traffic to them would reach local
# services through "lo".
local_host_ips() {
  local ip
  if have_cmd ip; then
    ip -o addr show scope global 2>/dev/null | awk '{split($4,a,"/"); print a[1]}' || true
  fi
  ip=$(state_get detected_public_ipv4)
  [[ -z "$ip" ]] || printf '%s\n' "$ip"
}

block_ip_list() { # block_ip_list -> one CIDR per line
  local ip
  local ips=(
    "0.0.0.0/8"        # "this host": 0.0.0.0 connects to local services on Linux
    "127.0.0.0/8"
    "169.254.0.0/16"   # link-local, incl. most cloud metadata endpoints
    "100.64.0.0/10"    # CGNAT, incl. Alibaba Cloud metadata 100.100.100.200
    "192.0.0.0/24"
    "198.18.0.0/15"
    "224.0.0.0/4"
    "240.0.0.0/4"
    "::/128"
    "::1/128"
    "fe80::/10"
    "ff00::/8"
  )
  if [[ "${BLOCK_PRIVATE:-1}" == "1" ]]; then
    ips+=("10.0.0.0/8" "172.16.0.0/12" "192.168.0.0/16" "fc00::/7")
  fi
  while IFS= read -r ip; do
    [[ -n "$ip" ]] || continue
    if [[ "$ip" == *:* ]]; then ips+=("$ip/128"); else ips+=("$ip/32"); fi
  done < <(local_host_ips | sort -u)
  printf '%s\n' "${ips[@]}"
}

build_block_ips_json() { # -> "a","b",... (JSON strings, comma separated)
  local out=() ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && out+=("\"$ip\"")
  done < <(block_ip_list)
  join_by "," "${out[@]}"
}

build_acl_rules_yaml() { # -> indented YAML list lines
  local ip
  while IFS= read -r ip; do
    [[ -n "$ip" ]] && printf '    - reject(%s)\n' "$ip"
  done < <(block_ip_list)
  printf '    - direct(all)\n'
}

# ---------------------------------------------------------------------------
# Renderers
# ---------------------------------------------------------------------------
render_xray() {
  local clients privkey shortid blockips
  clients=$(build_clients_json)
  privkey=$(cat "$DP_XRAY_PRIVKEY")
  shortid=$(cat "$DP_SECRETS/reality-shortid")
  blockips=$(build_block_ips_json)
  [[ -n "$clients" && -n "$privkey" && -n "$shortid" ]] || { err "渲染 Xray 配置缺少必要数据"; return 1; }

  install -d -m 0700 /etc/xray
  subst "$TEMPLATE_DIR/xray-config.json" "$XRAY_CONF" \
    "CLIENTS=$clients" \
    "DOMAIN=$DOMAIN" \
    "PRIVATE_KEY=$privkey" \
    "SHORT_ID=$shortid" \
    "BLOCK_IPS=$blockips" || return $?
  chmod 600 "$XRAY_CONF"
  ok "已渲染 Xray 配置：$XRAY_CONF"
}

render_hysteria() {
  local pass acl
  pass=$(cat "$DP_HY_PASS")
  acl=$(build_acl_rules_yaml)
  [[ -n "$pass" ]] || { err "渲染 Hysteria2 配置缺少密码"; return 1; }

  local cert_full="$DP_CERTS/$DOMAIN.fullchain.pem"
  local cert_key="$DP_CERTS/$DOMAIN.key"

  install -d -m 0700 /etc/hysteria
  subst "$TEMPLATE_DIR/hysteria-config.yaml" "$HY_CONF" \
    "CERT_FULLCHAIN=$cert_full" \
    "CERT_KEY=$cert_key" \
    "HY_PASSWORD=$pass" \
    "SITE_CURRENT=$SITE_CURRENT" \
    "ACL_RULES=$acl" || return $?
  chmod 600 "$HY_CONF"
  ok "已渲染 Hysteria2 配置：$HY_CONF"
}

render_nginx() {
  local cert_full="$DP_CERTS/$DOMAIN.fullchain.pem"
  local cert_key="$DP_CERTS/$DOMAIN.key"
  mkdir -p /etc/nginx/sites-available
  subst "$TEMPLATE_DIR/nginx-site.conf" "$NGINX_SITE" \
    "DOMAIN=$DOMAIN" \
    "CERT_FULLCHAIN=$cert_full" \
    "CERT_KEY=$cert_key" \
    "SITE_CURRENT=$SITE_CURRENT" || return $?
  chmod 644 "$NGINX_SITE"
  ok "已渲染 Nginx 站点配置：$NGINX_SITE"
}

# ---------------------------------------------------------------------------
# Config syntax validation (no runtime)
# ---------------------------------------------------------------------------
validate_xray() {
  /usr/local/bin/xray run -test -config "$XRAY_CONF" >/dev/null 2>&1 \
    || { err "Xray 配置校验失败：$XRAY_CONF"; return 3; }
  ok "Xray 配置语法校验通过"
}

validate_hysteria() {
  # Hysteria2 has no dedicated check command; validate YAML syntax with python3
  # if available, and rely on startup smoke-test in healthcheck otherwise.
  if have_cmd python3 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1]))' "$HY_CONF" \
      || { err "Hysteria2 配置 YAML 解析失败：$HY_CONF"; return 3; }
    ok "Hysteria2 配置 YAML 语法校验通过"
  else
    err "缺少 python3-yaml，不能跳过配置校验"; return 3
  fi
}

validate_nginx() {
  local out
  if ! out=$(nginx -t 2>&1); then
    err "Nginx 配置校验失败："
    printf '%s\n' "$out" | while IFS= read -r l; do warn "  $l"; done
    die "Nginx 配置校验失败" 3
  fi
  ok "Nginx 配置语法校验通过"
}
