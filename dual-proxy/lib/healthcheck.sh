#!/usr/bin/env bash
# =============================================================================
# healthcheck.sh — post-install / runtime health checks.
# =============================================================================

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Check a TCP port is listening (optionally restricted to a specific address).
check_listen_tcp() { # <addr_or_empty> <port> <label>
  local addr="$1" port="$2" label="$3"
  local found=0 line laddr lport
  if have_cmd ss; then
    while IFS= read -r line; do
      laddr=$(awk '{print $4}' <<<"$line")
      lport="${laddr##*:}"
      if [[ "$lport" == "$port" ]]; then
        if [[ -z "$addr" || "$laddr" == "$addr:$port" || "$laddr" == "[$addr]:$port" ]]; then
          found=1; break
        fi
      fi
    done < <(ss -H -tln 2>/dev/null)
  fi
  if (( found )); then ok "${label}：TCP $port 监听中"; return 0; fi
  err "${label}：TCP $port 未监听"; return 1
}

check_listen_udp() {
  local port="$1" label="$2"
  local found=0 line laddr lport
  if have_cmd ss; then
    while IFS= read -r line; do
      laddr=$(awk '{print $4}' <<<"$line")
      lport="${laddr##*:}"
      [[ "$lport" == "$port" ]] && { found=1; break; }
    done < <(ss -H -uln 2>/dev/null)
  fi
  if (( found )); then ok "${label}：UDP $port 监听中"; return 0; fi
  err "${label}：UDP $port 未监听"; return 1
}

# Verify Nginx serves the blog on the loopback HTTPS port.
check_local_https() {
  curl --noproxy '*' -fsS --max-time 10 --resolve "$DOMAIN:8443:127.0.0.1" \
    -o /dev/null "https://$DOMAIN:8443/" || { err "本机 HTTPS 校验失败"; return 1; }
  ok "本机 HTTPS、SNI 与证书链校验通过"
}

check_cert() {
  local cert="$DP_CERTS/$DOMAIN.fullchain.pem" key="$DP_CERTS/$DOMAIN.key"
  openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null &&
    openssl x509 -in "$cert" -noout -checkend 0 >/dev/null || return 1
  local certpub keypub
  certpub=$(openssl x509 -in "$cert" -pubkey -noout) || return 1
  keypub=$(openssl pkey -in "$key" -pubout) || return 1
  [[ "$certpub" == "$keypub" ]] || { err "证书与私钥不匹配"; return 1; }
  ok "证书域名、有效期及密钥匹配"
}

check_sni_handshake() {
  timeout 12 openssl s_client -connect 127.0.0.1:8443 -servername "$DOMAIN" \
    -verify_hostname "$DOMAIN" -verify_return_error -tls1_3 -alpn h2 \
    </dev/null >/dev/null 2>&1 || return 1
  ok "Nginx TLS 1.3 / SNI 验证通过"
}

run_healthcheck() {
  info "==== 健康检查 ===="
  local rc=0
  validate_xray || rc=1
  validate_hysteria || rc=1
  nginx -t >/dev/null 2>&1 || rc=1

  check_listen_tcp "" 443 "Xray (公网 TCP)" || rc=1
  check_listen_udp 443 "Hysteria2 (公网 UDP)" || rc=1
  check_listen_tcp "127.0.0.1" 8443 "Nginx (本机)" || rc=1

  if ss -H -tln 'sport = :8443' | awk '$4 != "127.0.0.1:8443" {bad=1} END {exit !bad}'; then
    err "8443 存在非回环监听"; rc=1
  fi

  curl --noproxy '*' -fsS --max-time 10 --resolve "$DOMAIN:443:127.0.0.1" \
    -o /dev/null "https://$DOMAIN/" || rc=1

  local unit
  for unit in xray hysteria-server; do
    [[ -z $(systemctl show "$unit" -p DropInPaths --value) ]] || { err "$unit 存在未审核的覆盖项"; rc=1; }
  done

  # Service states
  info "服务状态："
  for s in xray hysteria-server nginx; do
    svc_status_line "$s"
    svc_active "$s" || rc=1
  done

  check_cert || rc=1
  check_local_https || rc=1
  check_sni_handshake || rc=1

  if (( rc == 0 )); then
    ok "==== 健康检查全部通过 ===="
  else
    err "==== 健康检查存在失败项 ===="
  fi
  return $rc
}
