#!/usr/bin/env bash
# =============================================================================
# crypto.sh — secret generation (UUID, X25519 keypair, shortId, password).
# =============================================================================

# X25519_PRIVATE / X25519_PUBLIC are set here and consumed by install.sh.
# shellcheck disable=SC2034

# shellcheck disable=SC1091
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# Generate a UUIDv4. Prefers the installed xray binary, falls back to the kernel.
gen_uuid() {
  local u
  if have_cmd xray && u=$(xray uuid 2>/dev/null) && [[ -n "$u" ]]; then
    printf '%s' "$u"
  else
    cat /proc/sys/kernel/random/uuid
  fi
}

# Generate an X25519 keypair using the installed xray binary.
# Sets the globals X25519_PRIVATE and X25519_PUBLIC.
gen_x25519() {
  local out priv pub
  out=$(xray x25519 2>/dev/null) || die "xray x25519 生成密钥失败" 1
  priv=$(sed -n -E 's/^(PrivateKey|Private key): *//p' <<<"$out")
  pub=$(sed -n -E 's/^(Password \(PublicKey\)|PublicKey|Public key): *//p' <<<"$out")
  [[ -n "$priv" && -n "$pub" ]] || die "解析 xray x25519 输出失败" 1
  X25519_PRIVATE="$priv"
  X25519_PUBLIC="$pub"
}

# Generate a 16-hex-char (8-byte) Reality shortId.
gen_shortid() { openssl rand -hex 8; }

# Generate a strong random hex password (192 bits).
gen_password() { openssl rand -hex 24; }

# Write a fresh VLESS UUID to the single-user store.
# The value travels through a private temp file, never through argv.
vless_uuid_new() {
  local tmp
  mkdir -p "$DP_SECRETS"
  tmp=$(mktemp "$DP_SECRETS/.uuid.XXXXXX")
  gen_uuid | tr -d '\n' > "$tmp"
  [[ -s "$tmp" ]] || { rm -f "$tmp"; err "生成 UUID 失败"; return 1; }
  chmod 600 "$tmp"
  mv -f "$tmp" "$DP_VLESS_UUID"
}
