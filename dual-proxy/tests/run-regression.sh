#!/usr/bin/env bash
# Safe regression suite: only writes into its own temporary directory.
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
export DP_ROOT="$work/opt" DP_ETC="$work/etc" LOG_DIR="$work/log" SITE_ROOT="$work/site"
source "$ROOT/lib/common.sh"
ensure_log
unset DOMAIN
source "$ROOT/lib/cert.sh"
export DOMAIN=example.test
cert_paths
[[ "$CERT_FULLCHAIN" == "$DP_CERTS/example.test.fullchain.pem" ]]
echo 'PASS domain paths are lazy'
source "$ROOT/lib/crypto.sh"
xray() { printf 'PrivateKey: TEST_PRIVATE\nPassword (PublicKey): TEST_PUBLIC\nHash32: TEST_HASH\n'; }
gen_x25519
[[ "$X25519_PRIVATE" == TEST_PRIVATE && "$X25519_PUBLIC" == TEST_PUBLIC ]]
echo 'PASS pinned Xray key output'
source "$ROOT/lib/render.sh"
acl=$(build_acl_rules_yaml)
subst "$ROOT/templates/hysteria-config.yaml" "$work/hysteria.yaml" \
  "CERT_FULLCHAIN=/test/cert" "CERT_KEY=/test/key" 'HY_PASSWORD=testpass' \
  "SITE_CURRENT=/site/current" "ACL_RULES=$acl"
python3 - "$work/hysteria.yaml" <<'PY'
import sys,yaml
c=yaml.safe_load(open(sys.argv[1]))
assert len(c['acl']['inline']) >= 10
assert c['auth']['password']=='testpass'
PY
printf '__VALUE__' > "$work/literal"
subst "$work/literal" "$work/output" $'VALUE=line1\nline2|&\\$'
[[ $(cat "$work/output") == $'line1\nline2|&\\$' ]]
if subst "$work/literal" "$work/output" 2>/dev/null; then echo 'FAIL unresolved placeholder accepted'; exit 1; fi
echo 'PASS literal/multiline rendering; unresolved placeholders rejected'
source "$ROOT/lib/env-check.sh"
( detect_os() { echo 'ubuntu 26.04'; }; detect_arch() { echo x86_64; }; check_os_support )
if ( detect_os() { echo 'ubuntu 99.99'; }; detect_arch() { echo x86_64; }; check_os_support ) >/dev/null 2>&1; then
  echo 'FAIL unsupported OS accepted'; exit 1
fi
echo 'PASS Ubuntu 26.04 support and unsupported OS rejection'
ss() { return 1; }
if check_port tcp 443 test; then echo 'FAIL failed port probe accepted'; exit 1; fi
ss() { [[ "$*" == '-H -l -n -t sport = :443' ]]; }
check_port tcp 443 test
echo 'PASS port probe errors fail closed and uses correct flags'
settings_set DOMAIN 'example.test'
settings_set SITE_NOTE 'a b; $(false)'
unset SITE_NOTE
settings_load
[[ "$SITE_NOTE" == 'a b; $(false)' ]]
echo 'PASS settings round trip without shell execution'
source "$ROOT/lib/download.sh"
ensure_download_dir
[[ -d "$DL_TMP" && $(stat -c %a "$DL_TMP") == 700 ]]
rm -rf "$DL_TMP"
echo 'PASS private download workspace'
# Entries must parse without privileged actions or a pre-set domain.
bash "$ROOT/install.sh" --help >/dev/null
bash "$ROOT/manage.sh" --help >/dev/null
echo 'PASS both CLI help entrypoints'

# A failed renderer invoked in an if/&& chain must not accept a stale config.
TEMPLATE_DIR="$work/templates"
mkdir -p "$TEMPLATE_DIR"
printf '__MISSING__' > "$TEMPLATE_DIR/hysteria-config.yaml"
printf 'old-valid-config' > "$work/old.yaml"
HY_CONF="$work/old.yaml"
mkdir -p "$DP_SECRETS"
printf 'test-password' > "$DP_HY_PASS"
install() { :; } # isolate the fixed /etc directory creation only
if render_hysteria 2>/dev/null; then echo 'FAIL stale config accepted after rendering failure'; exit 1; fi
[[ $(cat "$HY_CONF") == old-valid-config ]]
echo 'PASS renderer failures propagate to the caller'
unset -f install

# Outbound block list covers "this host", CGNAT metadata and the VPS itself.
state_set detected_public_ipv4 203.0.113.7
blocked=$(block_ip_list)
for cidr in 0.0.0.0/8 127.0.0.0/8 169.254.0.0/16 100.64.0.0/10 ::/128 ::1/128 203.0.113.7/32; do
  grep -qxF "$cidr" <<<"$blocked" || { echo "FAIL block list lacks $cidr"; exit 1; }
done
echo 'PASS outbound block list covers local host, metadata and own addresses'

# CAA parsing (RFC 8659 semantics for non-wildcard certificates).
caa_allows_letsencrypt '0 issue "letsencrypt.org"'
caa_allows_letsencrypt '0 issue "letsencrypt.org; validationmethods=http-01"'
caa_allows_letsencrypt '0 iodef "mailto:a@example.test"'
caa_allows_letsencrypt $'0 issue "digicert.com"\n0 issue "letsencrypt.org"'
if caa_allows_letsencrypt '0 issue "digicert.com"'; then echo 'FAIL foreign CAA accepted'; exit 1; fi
if caa_allows_letsencrypt '0 issue ";"'; then echo 'FAIL forbidding CAA accepted'; exit 1; fi
echo 'PASS CAA evaluation'

# Single VLESS user: the UUID file becomes the only Xray client.
xray() { return 1; }  # force the kernel UUID source
vless_uuid_new
[[ $(stat -c %a "$DP_VLESS_UUID") == 600 ]]
clients=$(build_clients_json)
[[ $(jq -r 'length' <<<"$clients") == 1 && $(jq -r '.[0].id' <<<"$clients") == "$(cat "$DP_VLESS_UUID")" ]]
printf 'not-a-uuid' > "$DP_VLESS_UUID"
if build_clients_json >/dev/null 2>&1; then echo 'FAIL invalid UUID accepted'; exit 1; fi
unset -f xray
echo 'PASS single VLESS UUID rendering and validation'

# Site deploy: atomic swap, previous content removed, symlinks rejected.
source "$ROOT/lib/site.sh"
mkdir -p "$SITE_ROOT"
for v in 1 2; do
  mkdir -p "$work/src$v"; printf 'v%s' "$v" > "$work/src$v/index.html"
done
site_deploy "$work/src1" >/dev/null
site_deploy "$work/src2" >/dev/null
[[ $(cat "$SITE_CURRENT/index.html") == v2 ]]
[[ $(find "$SITE_RELEASES" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ') == 1 ]]
[[ $(cat "$work/src1/index.html") == v1 ]]
ln -s /etc/passwd "$work/src2/leak"
if (site_deploy "$work/src2" >/dev/null 2>&1); then echo 'FAIL symlink accepted'; exit 1; fi
[[ $(cat "$SITE_CURRENT/index.html") == v2 ]]
echo 'PASS site deploy replaces content atomically and rejects symlinks'
