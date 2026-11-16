#!/usr/bin/env bash
# Real Hysteria2 and UDP tests on the authorized test host using fixed Mihomo.
set -euo pipefail
umask 077
ROOT=$(cd "$(dirname "$0")/.." && pwd)
source "$ROOT/lib/common.sh"
settings_load
work=$(mktemp -d /root/reality-hy-test.XXXXXX)
pid=''
trap '[[ -z "$pid" ]] || kill "$pid" 2>/dev/null || true; rm -rf "$work"' EXIT
curl -fsSL --max-time 60 -o "$work/mihomo.gz" https://github.com/MetaCubeX/mihomo/releases/download/v1.19.31/mihomo-linux-amd64-v1.19.31.gz
printf 'd5e74bbddbdfff49a1aef7775bf5911da59f0d7196ed509a0ac914b3653dd5f1  %s\n' "$work/mihomo.gz" | sha256sum -c -
gzip -dc "$work/mihomo.gz" > "$work/mihomo"; chmod 700 "$work/mihomo"
python3 - "$work" "$DOMAIN" <<'PY'
import json,pathlib,sys
p=pathlib.Path(sys.argv[1]);domain=sys.argv[2]
secret=pathlib.Path('/etc/dual-proxy/secrets/hysteria.passwd').read_text().strip()
base={'mixed-port':17891,'allow-lan':False,'bind-address':'127.0.0.1','mode':'rule','log-level':'error',
'proxies':[{'name':'test','type':'hysteria2','server':'127.0.0.1','port':443,'password':secret,'sni':domain,'skip-cert-verify':False}], 'rules':['MATCH,test']}
(p/'good.json').write_text(json.dumps(base))
base['proxies'][0]['password']='deliberately-invalid-test-password'
(p/'bad.json').write_text(json.dumps(base))
PY
"$work/mihomo" -d "$work/client" -f "$work/good.json" > "$work/client.log" 2>&1 & pid=$!
sleep 1
curl --noproxy '' -fsS --proxy socks5h://127.0.0.1:17891 --max-time 15 -o /dev/null https://example.com/
echo 'PASS Mihomo v1.19.31 Hysteria2 TCP forwarding with public CA validation'
python3 "$ROOT/tests/socks-udp-check.py" 17891
kill "$pid"; wait "$pid" || true; pid=''
"$work/mihomo" -d "$work/badclient" -f "$work/bad.json" > "$work/bad.log" 2>&1 & pid=$!
sleep 1
if curl --noproxy '' -fsS --proxy socks5h://127.0.0.1:17891 --max-time 8 -o /dev/null https://example.com/ 2>/dev/null; then echo 'FAIL bad Hysteria2 password accepted'; exit 1; fi
kill -0 "$pid"
echo 'PASS invalid Hysteria2 authentication rejected'
