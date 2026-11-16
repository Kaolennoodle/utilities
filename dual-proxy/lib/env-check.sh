#!/usr/bin/env bash
# =============================================================================
# env-check.sh — pre-install environment checks (read-only, no side effects).
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Min recommended resources
MIN_MEM_MB=512
MIN_DISK_MB=1024

# ---------------------------------------------------------------------------
# Individual checks (return 0 = pass, 1 = hard fail, print diagnostics)
# ---------------------------------------------------------------------------

check_os_support() {
  local os arch
  os=$(detect_os)
  arch=$(detect_arch)
  case "$os" in
    "debian 12"|"debian 13"|"ubuntu 24.04"|"ubuntu 26.04"|"ubuntu 26.10")
      ok "操作系统受支持：${os}（${arch}）"
      if [[ "$os" == "ubuntu 26.10" ]]; then
        warn "Ubuntu 26.10 为短期支持版本（约 9 个月）；到期前需规划迁移，升级系统后需重新验证本脚本"
      fi
      return 0 ;;
    *)
      err "不支持的操作系统：${os}。仅支持 Debian 12/13、Ubuntu 24.04 LTS / 26.04 LTS / 26.10。"
      return 1 ;;
  esac
}

check_memory() {
  local mem_kb mem_mb
  mem_kb=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
  mem_mb=$(( mem_kb / 1024 ))
  if (( mem_mb < MIN_MEM_MB )); then
    warn "内存仅 ${mem_mb}MB（建议 ≥ ${MIN_MEM_MB}MB）。低内存环境可能不稳定。"
  else
    ok "内存：${mem_mb}MB"
  fi
  return 0
}

check_disk() {
  local avail_kb avail_mb
  avail_kb=$(df -k --output=avail /var 2>/dev/null | tail -n1 | tr -d ' ')
  avail_mb=$(( avail_kb / 1024 ))
  if (( avail_mb < MIN_DISK_MB )); then
    err "/var 可用空间仅 ${avail_mb}MB（建议 ≥ ${MIN_DISK_MB}MB）。"
    return 1
  fi
  ok "磁盘：/var 可用 ${avail_mb}MB"
  return 0
}

check_systemd() {
  if [[ -d /run/systemd/system ]]; then
    ok "systemd 可用"
    return 0
  fi
  err "未检测到 systemd，无法管理服务。"
  return 1
}

check_tools() {
  local missing=()
  for c in curl wget tar unzip openssl sed awk grep; do
    have_cmd "$c" || missing+=("$c")
  done
  if ((${#missing[@]} > 0)); then
    warn "缺少基础工具：${missing[*]}（安装阶段将尝试补齐）"
  else
    ok "基础工具齐全"
  fi
  return 0
}

check_port() { # check_port <proto> <port> <label> ; returns 1 if in use
  local proto="$1" port="$2" label="$3" out
  local flag
  case "$proto" in tcp) flag=-t;; udp) flag=-u;; *) return 2;; esac
  have_cmd ss || { err "缺少 ss，无法可靠检查端口"; return 1; }
  out=$(ss -H -l -n "$flag" "sport = :$port") || { err "端口检测失败"; return 1; }
  if [[ -n "$out" ]]; then
    err "${label}：$proto/$port 已被占用。"
    printf '%s\n' "$out" | sed 's/^/    /' | while IFS= read -r l; do warn "  $l"; done
    return 1
  fi
  ok "${label}：$proto/$port 空闲"
  return 0
}

check_ports() {
  local rc=0
  check_port tcp 443 "Xray (TCP)" || rc=1
  check_port udp 443 "Hysteria2 (UDP)" || rc=1
  check_port tcp 8443 "Nginx 本机 (TCP)" || rc=1
  check_acme_port || rc=1
  return $rc
}

# HTTP-01 needs public TCP 80. Nginx may already own it (it will serve the
# challenge); any other listener is a conflict.
check_acme_port() {
  local out
  out=$(ss -H -l -n -t -p "sport = :80") || { err "端口检测失败"; return 1; }
  if [[ -z "$out" ]]; then ok "ACME HTTP-01：tcp/80 空闲"; return 0; fi
  if ! grep -qv '"nginx"' <<<"$out"; then ok "ACME HTTP-01：tcp/80 由 Nginx 提供"; return 0; fi
  err "ACME HTTP-01：tcp/80 被非 Nginx 进程占用，无法完成验证"
  printf '%s\n' "$out" | sed 's/^/    /'
  return 1
}

check_existing_services() {
  local component
  for component in xray hysteria; do
    if have_cmd "$component" || [[ -d /etc/$component ]]; then
      err "检测到已有 $component，拒绝覆盖；请先迁移或使用已安装实例的维护入口"
      return 1
    fi
  done
  local unit
  for unit in xray hysteria-server; do
    if [[ -n $(systemctl show "$unit" -p DropInPaths --value 2>/dev/null) ]]; then
      err "$unit 存在 systemd 覆盖项，拒绝静默接管"; return 1
    fi
  done
  [[ ! -e "$NGINX_SITE" && ! -L "$NGINX_ENABLED" ]] || { err "站点配置已存在"; return 1; }
  if have_cmd nginx; then warn "沿用已有 Nginx，保留其他站点配置"; fi
}

check_public_ip() {
  local ip
  ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null \
       || curl -fsS --max-time 8 https://ifconfig.me 2>/dev/null \
       || curl -fsS --max-time 8 https://icanhazip.com 2>/dev/null || true)
  if [[ -n "$ip" ]]; then
    state_set detected_public_ipv4 "$ip" 2>/dev/null || true
    ok "公网 IPv4：$ip"
    return 0
  fi
  warn "无法从外部服务获取公网 IPv4（可能为纯 IPv6 或无出站 HTTP）。"
  return 0
}

check_dns_tools() {
  if have_cmd dig; then ok "dig 可用"; return 0; fi
  warn "缺少 dig（dnsutils），域名解析检查将降级。"
  return 0
}

# Resolve domain A/AAAA records and compare against detected public IPs.
check_domain_resolution() {
  local domain="${DOMAIN:-}"
  [[ -n "$domain" ]] || { warn "未提供域名，跳过 DNS 检查。"; return 0; }

  python3 - "$domain" <<'PYDNS'
import ipaddress, socket, subprocess, sys
name=sys.argv[1]
actual={ipaddress.ip_address(a[4][0]) for a in socket.getaddrinfo(name,None,type=socket.SOCK_STREAM)}
expected=set()
for family in ('-4','-6'):
    p=subprocess.run(['curl',family,'-fsS','--max-time','8','https://api64.ipify.org'],capture_output=True,text=True)
    if p.returncode==0:
        try: expected.add(ipaddress.ip_address(p.stdout.strip()))
        except ValueError: pass
p=subprocess.run(['ip','-j','addr','show','scope','global'],capture_output=True,text=True)
if p.returncode==0:
    import json
    for interface in json.loads(p.stdout):
        for address in interface.get('addr_info',[]):
            if 'local' not in address: continue
            ip=ipaddress.ip_address(address['local'])
            if ip.is_global: expected.add(ip)
if not actual or not expected or not actual.issubset(expected):
    raise SystemExit('DNS mismatch (all A/AAAA must point to this VPS; DNS Only required)')
print('DNS A/AAAA: all records match the VPS')
PYDNS
  return $?
}

# RFC 8659: the relevant CAA set is the first non-empty one found while
# climbing from the name towards the zone apex. Only "issue" restricts a
# non-wildcard certificate; a set without "issue" tags allows any CA.
caa_allows_letsencrypt() { # caa_allows_letsencrypt <caa-rdata-lines> ; 0 = allowed
  local flag tag value has_issue=0
  while read -r flag tag value; do
    [[ "$flag" =~ ^[0-9]+$ ]] || continue
    [[ "${tag,,}" == issue ]] || continue
    has_issue=1
    value=${value//\"/}
    value=${value%%;*}
    value=${value//[[:space:]]/}
    [[ "${value,,}" == letsencrypt.org ]] && return 0
  done <<<"$1"
  (( has_issue == 0 ))
}

check_caa() { # check_caa <domain>
  local name="$1" rr
  while [[ "$name" == *.* ]]; do
    rr=$(dig +short CAA "$name" 2>/dev/null | awk '$1 ~ /^[0-9]+$/ && NF >= 3' || true)
    if [[ -n "$rr" ]]; then
      if caa_allows_letsencrypt "$rr"; then
        ok "CAA（$name）允许 Let's Encrypt 签发"; return 0
      fi
      err "CAA（$name）不允许 Let's Encrypt 签发，请先添加：0 issue \"letsencrypt.org\""
      return 1
    fi
    name=${name#*.}
  done
  ok "未设置 CAA 限制"
}

check_dns_extra_records() {
  local domain="${DOMAIN:-}"
  [[ -n "$domain" ]] || return 0
  have_cmd dig || return 0

  local svcb cname
  check_caa "$domain" || return 1

  cname=$(dig +short CNAME "$domain" 2>/dev/null || true)
  if [[ -n "$cname" ]]; then
    warn "域名 $domain 存在 CNAME 记录（${cname}）。本方案要求 A/AAAA 直连（DNS only），请确认。"
  fi

  local dnssec
  dnssec=$(dig @1.1.1.1 +dnssec "$domain" A) || return 1
  if grep -q 'status: SERVFAIL' <<<"$dnssec"; then err "DNSSEC/解析验证失败"; return 1; fi
  if grep -qE 'flags:.* ad[ ;]' <<<"$dnssec"; then ok "DNSSEC 已由验证解析器确认"; else warn "DNSSEC 未签名或未返回 AD 标志"; fi
  svcb=$( { dig +short "$domain" TYPE65; dig +short "$domain" TYPE64; } 2>/dev/null || true)
  if [[ -n "$svcb" ]]; then
    warn "检测到 HTTPS/SVCB（TYPE65）记录，可能影响 HTTP/3 协商，请确认。"
  fi
  return 0
}

check_repo_reachable() {
  local arch
  arch=$(detect_arch)
  if [[ -n ${DP_ASSET_DIR:-} && -f "$DP_ASSET_DIR/${XRAY_ASSET[$arch]}" &&
        -f "$DP_ASSET_DIR/${HY_ASSET[$arch]}" && -f "$DP_ASSET_DIR/acme.sh-3.1.6.tar.gz" ]]; then
    ok "核心与 ACME 资产已随包提供，无需访问 GitHub"
    return 0
  fi
  if curl -fsSI --max-time 10 "https://github.com" >/dev/null 2>&1; then
    ok "外部软件仓库（GitHub）可达"
    return 0
  fi
  err "无法访问 GitHub（下载 Xray/Hysteria/acme.sh 所需）。"
  return 1
}

# ---------------------------------------------------------------------------
# Orchestrator
# ---------------------------------------------------------------------------
run_preinstall_checks() {
  info "==== 安装前环境检查 ===="
  local rc=0
  local -a fails=()

  check_os_support        || fails+=("OS")
  check_memory            || fails+=("内存")
  check_disk              || fails+=("磁盘")
  check_systemd           || fails+=("systemd")
  check_tools             || fails+=("工具")
  # A previous run of this installer that failed part-way owns these ports
  # and files; resume over it instead of refusing.
  if [[ -f "$DP_STATE/install-started" ]]; then
    warn "检测到未完成的安装，跳过端口与已有服务检查，继续安装"
  else
    check_ports             || fails+=("端口占用")
    check_existing_services || fails+=("已有服务")
  fi
  check_dns_tools         || fails+=("DNS 工具")
  check_public_ip         || fails+=("公网 IP")
  check_domain_resolution || fails+=("域名解析")
  check_dns_extra_records || fails+=("DNS 额外记录")
  check_repo_reachable    || fails+=("仓库可达")

  if ((${#fails[@]} > 0)); then
    err "安装前检查未通过：${fails[*]}"
    return 2
  fi
  ok "==== 安装前环境检查全部通过 ===="
  return 0
}
