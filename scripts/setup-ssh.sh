#!/usr/bin/env bash
# Ubuntu 26.04; run as root. No packages are installed and no service is restarted.
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077

die() { printf '错误：%s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die '请在服务器上使用 root 执行。'
[[ $# -eq 0 ]] || die '本脚本不接受参数；确认和回滚请使用运行后输出的命令。'
for cmd in python3 ssh-keygen sshd systemctl systemd-run flock sha256sum; do
    command -v "$cmd" >/dev/null || die "缺少命令：$cmd（请先安装相应组件）。"
done
# shellcheck disable=SC1091
. /etc/os-release
[[ ${ID:-} == ubuntu && ${VERSION_ID:-} == 26.04 ]] || die '仅支持 Ubuntu 26.04。'
[[ $(getent passwd root | cut -d: -f6) == /root ]] || die 'root 家目录不是 /root。'
[[ -n ${SSH_CONNECTION:-} ]] || die '请从现有 root SSH 会话执行，以便测试另一条新连接。'
read -r client_ip client_port server_ip server_port <<< "$SSH_CONNECTION"
[[ -n $client_ip && -n $client_port && -n $server_ip && -n $server_port ]] || die 'SSH_CONNECTION 无效。'
[[ -d /run/systemd/system ]] || die '需要 systemd 管理 SSH 及自动回滚。'
exec 9>/run/lock/utilities-ssh.lock
flock -n 9 || die '另一个 SSH 配置或回滚操作正在运行。'
BASE=/var/lib/utilities-ssh
[[ ! -L $BASE ]] || die "$BASE 不能是符号链接。"
install -d -m 700 -o root -g root "$BASE"
[[ ! -e $BASE/pending ]] || die "存在未确认的操作，请先查看 $BASE/pending 中事务目录的 control.sh。"
CONFIG=/etc/ssh/sshd_config
AUTH=/root/.ssh/authorized_keys
for file in "$CONFIG" "$AUTH"; do
    [[ ! -L $file ]] || die "$file 不能是符号链接。"
    if [[ -e $file ]]; then
        [[ -f $file && $(stat -c %h "$file") == 1 && $(stat -c %u "$file") == 0 ]] || die "$file 必须是 root 所有的普通单链接文件。"
    fi
done
[[ -f $CONFIG && -d /root && ! -L /root && ! -L /root/.ssh ]] || die '配置或 root 目录类型不受支持。'
if [[ -e /root/.ssh ]]; then
    [[ -d /root/.ssh && $(stat -c %u /root/.ssh) == 0 ]] || die '/root/.ssh 必须是 root 所有的目录。'
fi
[[ $((8#$(stat -c %a /root) & 0022)) == 0 ]] || die '/root 不能允许组或其他用户写入。'
systemctl is-active --quiet ssh.service || die 'ssh.service 必须已在运行。'
sshd -t || die '现有 SSH 配置无效，尚未修改。'

# Ensure the live listener really uses the default file without command-line overrides.
PID=$(systemctl show ssh.service -p MainPID --value)
python3 - "$PID" <<'PY_PREFLIGHT'
import pathlib, re, shlex, sys
pid = sys.argv[1]
if not pid.isdigit() or int(pid) <= 1:
    sys.exit('无法确定 SSH 主进程，停止。')
cmd = pathlib.Path(f'/proc/{pid}/cmdline').read_bytes().replace(b'\0', b' ').decode()
# OpenSSH rewrites its process title. Standard Ubuntu is sshd: /usr/sbin/sshd -D [listener] ...
if not re.match(r'^(?:sshd: )?/usr/sbin/sshd -D(?:\s|$)', cmd):
    sys.exit('SSH 启动方式不是标准 /usr/sbin/sshd -D，停止。')
if re.search(r'\s-(?:[A-Za-z]*[fo]|[A-Za-z]*[p46])', cmd):
    sys.exit('检测到 SSH 自定义启动参数，停止。')
defaults = pathlib.Path('/etc/default/ssh')
if defaults.exists():
    for raw in defaults.read_text().splitlines():
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        if not re.fullmatch(r'''SSHD_OPTS\s*=\s*(?:""|'')?\s*(?:#.*)?''', line):
            sys.exit('/etc/default/ssh 含非空参数或自定义内容，停止。')
PY_PREFLIGHT

# A first global block beats Include/cloud-init defaults. Match can override globals:
# conservatively reject ALL active Match blocks anywhere in the Include graph.
python3 - "$CONFIG" <<'PY_AUDIT'
import glob, pathlib, re, shlex, sys
seen, stack = set(), set()
def audit(path):
    p = pathlib.Path(path).resolve(strict=True)
    if p in stack:
        raise ValueError(f'Include 循环：{p}')
    if p in seen:
        return
    stack.add(p)
    for n, raw in enumerate(p.read_text().splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith('#'):
            continue
        m = re.match(r'([^\s=]+)(?:\s*=\s*|\s+)(.*)$', line)
        if not m:
            raise ValueError(f'无法安全解析：{p}:{n}')
        name, tail = m.groups()
        args = shlex.split(tail, comments=True)
        if name.lower() == 'match':
            raise ValueError(f'存在 Match 条件配置：{p}:{n}；请先人工审查，脚本未修改 SSH 配置')
        if name.lower() == 'include':
            # Only simple path/glob syntax is supported. Avoid differences between
            # OpenSSH's lexer/glob and Python's parser hiding a conditional file.
            if '\\' in tail or any(not re.fullmatch(r'[A-Za-z0-9_./*?\[\]-]+', a) for a in args):
                raise ValueError(f'Include 路径语法需要人工审查：{p}:{n}')
            for pattern in args:
                if not pattern.startswith('/'):
                    pattern = '/etc/ssh/' + pattern
                for child in sorted(glob.glob(pattern)):
                    audit(child)
    stack.remove(p)
    seen.add(p)
try:
    audit(sys.argv[1])
except (OSError, ValueError, RecursionError) as exc:
    sys.exit(str(exc))
PY_AUDIT

STATE=$(mktemp -d "$BASE/transaction-XXXXXXXX")
UNIT="utilities-ssh-rollback-${STATE##*/}"
PUBKEY='ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDDGGejG7Vqb8azmthZFegM35GOjQlfiQ88LYo4BXPoM eddie-ubuntu26'
printf '%s\n' "$PUBKEY" > "$STATE/public-key"
ssh-keygen -lf "$STATE/public-key" || die '公钥验证失败。'
cp -a "$CONFIG" "$STATE/sshd_config.original"
if [[ -e $AUTH ]]; then cp -a "$AUTH" "$STATE/authorized_keys.original"; fi
if [[ -d /root/.ssh ]]; then
    stat -c %a /root/.ssh > "$STATE/ssh-dir-mode"
    stat -c %g /root/.ssh > "$STATE/ssh-dir-group"
fi
printf '%s\n' "$SSH_CONNECTION" > "$STATE/original-connection"
printf '%s\n' "$UNIT" > "$STATE/unit"

# The control program is independent of this download and remains available for rescue.
printf '#!/usr/bin/env bash\nSTATE=%q\n' "$STATE" > "$STATE/control.sh"
cat >> "$STATE/control.sh" <<'CONTROL'
set -Eeuo pipefail
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
export LC_ALL=C
umask 077
[[ $EUID -eq 0 ]] || exit 1
exec 9>/run/lock/utilities-ssh.lock
flock 9
BASE=/var/lib/utilities-ssh
UNIT=$(cat "$STATE/unit")
[[ -f $BASE/pending && $(cat "$BASE/pending") == "$STATE" ]] || { echo '此事务已结束，无需操作。'; exit 0; }
case "${1:-}" in
confirm)
    [[ -n ${SSH_CONNECTION:-} && $SSH_CONNECTION != "$(cat "$STATE/original-connection")" ]] || {
        echo '必须从另一条新建的 root SSH 连接执行确认；请保留原连接。' >&2; exit 1;
    }
    sshd -t
    systemctl is-active --quiet ssh.service
    sha256sum --check --status "$STATE/applied.sha256"
    # Lock serializes this with a timer already firing; confirmed transaction becomes a no-op.
    mv "$BASE/pending" "$STATE/confirmed"
    systemctl stop "$UNIT.timer" || true
    echo '已确认新 SSH 连接，保留公钥及禁用密码的配置，取消自动回滚。'
    ;;
rollback)
    cp -a "$STATE/sshd_config.original" /etc/ssh/.utilities-restore
    mv -f /etc/ssh/.utilities-restore /etc/ssh/sshd_config
    if [[ -f $STATE/authorized_keys.original ]]; then
        cp -a "$STATE/authorized_keys.original" /root/.ssh/.utilities-restore
        mv -f /root/.ssh/.utilities-restore /root/.ssh/authorized_keys
    else
        rm -f /root/.ssh/authorized_keys
    fi
    if [[ -f $STATE/ssh-dir-mode ]]; then
        chmod "$(cat "$STATE/ssh-dir-mode")" /root/.ssh
        chown "0:$(cat "$STATE/ssh-dir-group")" /root/.ssh
    else
        rmdir /root/.ssh 2>/dev/null || true
    fi
    sshd -t
    systemctl reload ssh.service
    systemctl is-active --quiet ssh.service
    mv "$BASE/pending" "$STATE/rolled-back"
    systemctl stop "$UNIT.timer" || true
    echo '已恢复原 SSH 配置、公钥文件及目录权限并重载服务。'
    ;;
*) echo '用法：control.sh confirm | rollback' >&2; exit 2 ;;
esac
CONTROL
chmod 700 "$STATE/control.sh"

cat > "$STATE/block" <<'BLOCK'
# BEGIN utilities root key-only (managed)
PubkeyAuthentication yes
PermitRootLogin prohibit-password
PasswordAuthentication no
KbdInteractiveAuthentication no
AuthenticationMethods publickey
AuthorizedKeysFile .ssh/authorized_keys
# END utilities root key-only (managed)
BLOCK
# Remove only our exact managed block on repeat runs; reject damaged markers.
python3 - "$STATE" "$CONFIG" <<'PY_CANDIDATE'
import pathlib, sys
s = pathlib.Path(sys.argv[1])
text = pathlib.Path(sys.argv[2]).read_text()
block = (s / 'block').read_text()
start = '# BEGIN utilities root key-only (managed)'
end = '# END utilities root key-only (managed)'
if start in text or end in text:
    if text.count(start) != 1 or text.count(end) != 1 or block not in text:
        sys.exit('受管配置标记不完整或已被编辑，停止。')
    text = text.replace(block, '', 1)
(s / 'candidate').write_text(block + text)
PY_CANDIDATE
sshd -t -f "$STATE/candidate"
verify_effective() {
    local file=$1 effective root_effective
    effective=$(sshd -T -f "$file" | awk '{$1=tolower($1); print}')
    root_effective=$(sshd -T -f "$file" -C "user=root,host=$client_ip,addr=$client_ip,laddr=$server_ip,lport=$server_port" | awk '{$1=tolower($1); print}')
    for effective in "$effective" "$root_effective"; do
        for pair in 'pubkeyauthentication yes' 'passwordauthentication no' \
            'kbdinteractiveauthentication no' 'authenticationmethods publickey' \
            'authorizedkeysfile .ssh/authorized_keys'; do
            grep -Fxq "$pair" <<< "$effective" || return 1
        done
        # OpenSSH commonly normalizes prohibit-password to without-password.
        grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<< "$effective" || return 1
    done
}
verify_effective "$STATE/candidate" || die '候选配置最终值验证失败，尚未修改。'

echo '即将添加公钥并禁用所有用户的 SSH 密码及键盘交互认证。'
echo '保留当前 SSH 窗口！应用后请立即测试另一条新连接；10 分钟内未确认将自动回滚。'
echo '其他用户也必须已经具备可用公钥。不要在确认前重启服务器或修改 SSH 配置。'
printf '手动回滚：bash %q rollback\n' "$STATE/control.sh"
printf '%s\n' "$STATE" > "$BASE/pending"
rollback_on_exit() {
    local status=$?
    trap - EXIT HUP INT TERM
    if [[ $status -ne 0 ]]; then
        echo '操作失败，立即回滚；独立的定时回滚仍可提供保护。' >&2
        flock -u 9
        if ! bash "$STATE/control.sh" rollback; then
            echo "自动恢复未完成！保留当前连接，执行 bash $STATE/control.sh rollback 并检查日志。" >&2
        fi
    fi
    exit "$status"
}
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP
# Arm before touching either key or sshd config. Timer survives terminal disconnection.
systemd-run --quiet --unit="$UNIT" --on-active=10m --timer-property=AccuracySec=1s \
    --property=Restart=on-failure --property=RestartSec=15s \
    --property=StartLimitIntervalSec=0 /bin/bash "$STATE/control.sh" rollback
systemctl is-active --quiet "$UNIT.timer"
install -d -m 700 -o root -g root /root/.ssh
touch "$AUTH"
chmod 600 "$AUTH"
chown root:root "$AUTH"
# Compare complete unrestricted key records. Restricted records do not count as an
# unrestricted login key; retain them and add the explicitly requested plain key.
if ! awk -v type="${PUBKEY%% *}" -v data="$(awk '{print $2}' <<< "$PUBKEY")" \
    '$1 == type && $2 == data { found=1 } END { exit !found }' "$AUTH"; then
    # Leading newline also handles an existing file missing its final newline.
    printf '\n%s\n' "$PUBKEY" >> "$AUTH"
fi
cp -a "$CONFIG" /etc/ssh/.utilities-new
cat "$STATE/candidate" > /etc/ssh/.utilities-new
mv -f /etc/ssh/.utilities-new "$CONFIG"
sshd -t
verify_effective "$CONFIG"
sha256sum "$CONFIG" "$AUTH" > "$STATE/applied.sha256"
systemctl reload ssh.service
systemctl is-active --quiet ssh.service
echo '配置已应用；尚未确认新连接。'
echo '在你的电脑另开终端，使用对应私钥和实际服务器地址/端口执行：'
echo 'ssh -o ControlPath=none -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -i /path/to/private_key -p PORT root@SERVER'
echo '登录成功后，在新连接中执行以下命令，取消 10 分钟回滚：'
printf 'bash %q confirm\n' "$STATE/control.sh"
printf '备份及回滚工具保存在：%s\n' "$STATE"
