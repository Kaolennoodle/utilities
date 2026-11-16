#!/usr/bin/env bash
# Upload/extract entrypoint; no Node.js needed on the target.
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() {
  cat <<'HELP'
Usage: sudo bash deploy.sh --domain blog.example.com [options]
  --email ADDRESS
  --non-interactive         deploy without interactive prompts
  --update-site             replace only the site on an existing node
  --verify-only             verify all packaged files without deploying
  --help
HELP
}
args=(); domain=''; update=0; verify=0; noninteractive=0
while (($#)); do
  case "$1" in
    --help|-h) usage; exit 0;;
    --domain|--email)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "Missing value: $1" >&2; exit 2; }
      [[ "$1" != --domain ]] || domain=$2
      args+=("$1" "$2")
      shift 2;;
    --non-interactive) noninteractive=1; args+=("$1"); shift;;
    --update-site) update=1; shift;;
    --verify-only) verify=1; shift;;
    *) echo "Unknown option: $1" >&2; exit 2;;
  esac
done
[[ -f "$ROOT/SHA256SUMS" ]] || { echo 'Run the release package, not the source wrapper.' >&2; exit 2; }
(cd "$ROOT"; sha256sum -c SHA256SUMS > /dev/null)
echo 'Package SHA256 integrity: OK'
[[ "$verify" == 0 ]] || exit 0
[[ $(uname -s) == Linux && $EUID == 0 && ${BASH_VERSINFO[0]} -ge 4 ]] || { echo 'Requires Linux, root and Bash >=4.' >&2; exit 2; }
# shellcheck disable=SC1091
source /etc/os-release
case "$ID:${VERSION_ID:-}" in debian:12|debian:13|ubuntu:24.04|ubuntu:26.04|ubuntu:26.10) :;; *) echo 'Unsupported OS' >&2; exit 2;; esac
case $(uname -m) in x86_64|aarch64|arm64) :;; *) echo 'Unsupported architecture' >&2; exit 2;; esac
[[ -f "$ROOT/site/index.html" ]] || { echo 'Missing bundled site' >&2; exit 2; }
if [[ "$update" == 1 ]]; then
  [[ -f /opt/dual-proxy/state/installed ]] || { echo 'No managed installation to update' >&2; exit 2; }
  # Use the installed maintenance scripts, not the copies in this bundle.
  exec bash /opt/dual-proxy/scripts/manage.sh site-update --dir "$ROOT/site"
fi
if [[ -z "$domain" ]]; then
  [[ "$noninteractive" == 0 ]] || { echo '--domain required' >&2; exit 2; }
  read -r -p 'Domain pointing to this VPS: ' domain
  args+=(--domain "$domain")
fi
# Bootstrap only missing prerequisite tools. No proxy service is changed here.
missing=0
for tool in curl python3 openssl ss flock dig; do command -v "$tool" >/dev/null || missing=1; done
if [[ "$missing" == 1 ]]; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get -o DPkg::Lock::Timeout=120 update
  apt-get -o DPkg::Lock::Timeout=120 install -y curl python3 openssl iproute2 util-linux ca-certificates bind9-dnsutils
fi
export DP_ASSET_DIR="$ROOT/vendor"
exec bash "$ROOT/install.sh" "${args[@]}" --site "$ROOT/site"
