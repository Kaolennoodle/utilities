#!/usr/bin/env bash
# ssh-manager.sh —— 交互式 SSH 公钥 & sshd 配置管理工具
# 支持 Linux / macOS，兼容 bash 3.2+
#   普通用户运行：可管理自己的 authorized_keys
#   sudo 运行   ：还可管理其他用户的公钥，以及修改 sshd 配置
#
# 修改 sshd_config 的方式：在文件顶部维护一个受管区块
#   # >>> ssh-manager >>>  ...  # <<< ssh-manager <<<
# sshd 对同一选项取"第一次出现"的值，因此该区块会覆盖后面的设置以及
# sshd_config.d/*.conf 中的设置；主文件中（Match 块之前）的同名旧配置会被注释掉。
# 每次修改前自动备份，并用 `sshd -t` 校验，校验失败不会写入。

SSHD_CONFIG="${SSHD_CONFIG:-/etc/ssh/sshd_config}"
SSHD_BIN="$(command -v sshd 2>/dev/null || echo /usr/sbin/sshd)"
OS="$(uname -s)"
TARGET_USER="${SUDO_USER:-$(id -un)}"

if [ -t 1 ]; then
  R=$'\e[31m'; G=$'\e[32m'; Y=$'\e[33m'; C=$'\e[36m'; D=$'\e[2m'; BOLD=$'\e[1m'; N=$'\e[0m'
else
  R=; G=; Y=; C=; D=; BOLD=; N=
fi

info()    { printf '%s\n' "${G}✔${N} $*"; }
warn()    { printf '%s\n' "${Y}!${N} $*"; }
err()     { printf '%s\n' "${R}✘${N} $*" >&2; }
pause()   { printf '\n%s' "${D}按回车继续...${N}"; read -r _; }
confirm() { local a; printf '%s [y/N]: ' "$1"; read -r a; [[ $a =~ ^[Yy]$ ]]; }
is_root() { [ "$(id -u)" -eq 0 ]; }
need_root() { is_root && return 0; err "此操作需要 root 权限，请使用 sudo $0 运行"; return 1; }

# ---------------------------------------------------------------- 公钥管理

user_home() {
  [[ $1 =~ ^[A-Za-z_][A-Za-z0-9._-]*$ ]] || return 1
  local h; h=$(eval echo "~$1" 2>/dev/null)
  [[ $h != "~"* && -d $h ]] && echo "$h"
}

auth_file() { echo "$(user_home "$TARGET_USER")/.ssh/authorized_keys"; }

fix_perms() {
  local f d; f=$(auth_file); d=$(dirname "$f")
  chmod 700 "$d" 2>/dev/null; chmod 600 "$f" 2>/dev/null
  is_root && chown "$TARGET_USER" "$d" "$f" 2>/dev/null
}

ensure_auth_file() {
  local f; f=$(auth_file)
  mkdir -p "$(dirname "$f")" && touch "$f" || { err "无法创建 $f（权限不足？）"; return 1; }
  fix_perms
}

# 读取有效公钥行：KEY_LNO[i]=行号，KEY_TXT[i]=内容
load_keys() {
  KEY_LNO=(); KEY_TXT=()
  local f n=0 line; f=$(auth_file)
  [ -r "$f" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
    KEY_LNO+=("$n"); KEY_TXT+=("$line")
  done < "$f"
}

fingerprint() {  # $1 = 公钥行
  local tmp out; tmp=$(mktemp)
  printf '%s\n' "$1" > "$tmp"
  out=$(ssh-keygen -lf "$tmp" 2>/dev/null); local rc=$?
  rm -f "$tmp"; echo "$out"; return $rc
}

key_blob() { awk '{for(i=1;i<NF;i++) if($i ~ /^(ssh-|ecdsa-|sk-)/){print $(i+1); exit}}' <<< "$1"; }

list_keys() {
  load_keys
  echo "${BOLD}用户 $TARGET_USER 的公钥${N} ${D}($(auth_file))${N}"
  if [ ${#KEY_TXT[@]} -eq 0 ]; then warn "暂无公钥"; return 1; fi
  local i fp
  for i in "${!KEY_TXT[@]}"; do
    fp=$(fingerprint "${KEY_TXT[$i]}") || fp="${R}[无法解析]${N} ${KEY_TXT[$i]:0:60}..."
    printf '  %s%2d)%s %s\n' "$C" $((i + 1)) "$N" "$fp"
  done
}

add_keys_from_text() {  # $1 = 多行文本，每行一个公钥
  ensure_auth_file || return
  local f line blob fp added=0; f=$(auth_file)
  while IFS= read -r line; do
    line=${line%$'\r'}
    [[ -z ${line//[[:space:]]/} || $line =~ ^[[:space:]]*# ]] && continue
    if ! fp=$(fingerprint "$line"); then err "无效公钥，已跳过: ${line:0:50}..."; continue; fi
    blob=$(key_blob "$line")
    if [ -n "$blob" ] && grep -qF -- "$blob" "$f"; then warn "已存在，跳过: $fp"; continue; fi
    [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ] && echo >> "$f"   # 保证以换行结尾
    printf '%s\n' "$line" >> "$f" || { err "写入失败"; return 1; }
    added=$((added + 1)); info "已添加: $fp"
  done <<< "$1"
  fix_perms
  echo "共添加 $added 个公钥"
}

add_key_paste() {
  echo "请粘贴公钥（支持多行），输入空行结束："
  local text="" line
  while IFS= read -r line; do [ -z "$line" ] && break; text+="$line"$'\n'; done
  [ -n "$text" ] && add_keys_from_text "$text"
}

add_key_file() {
  local p; read -r -e -p "公钥文件路径 (如 ~/.ssh/id_ed25519.pub): " p
  p=${p/#\~/$HOME}
  [ -f "$p" ] || { err "文件不存在: $p"; return; }
  add_keys_from_text "$(cat "$p")"
}

add_key_github() {
  local u t; read -r -p "GitHub 用户名: " u
  [[ $u =~ ^[A-Za-z0-9-]+$ ]] || { err "用户名无效"; return; }
  t=$(curl -fsSL --max-time 15 "https://github.com/$u.keys") || { err "获取失败（网络或用户不存在）"; return; }
  [ -z "$t" ] && { warn "该用户在 GitHub 上没有公钥"; return; }
  add_keys_from_text "$(awk -v c="github:$u" 'NF==2{$0=$0" "c}1' <<< "$t")"
}

delete_key() {
  list_keys || return
  local nums n del=""
  read -r -p "要删除的编号（多个用空格分隔，回车取消）: " nums
  [ -z "$nums" ] && return
  for n in $nums; do
    if ! [[ $n =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt ${#KEY_LNO[@]} ]; then err "无效编号: $n"; return; fi
    del+="${KEY_LNO[$((n - 1))]} "
  done
  [ "$(wc -w <<< "$del")" -ge ${#KEY_LNO[@]} ] && warn "这将删除全部公钥，若已禁用密码登录，你将无法再登录该用户！"
  confirm "确认删除？" || return
  local f; f=$(auth_file)
  cp -p "$f" "$f.bak"
  awk -v d=" $del" 'index(d, " " NR " ") == 0' "$f.bak" > "$f" && fix_perms
  info "已删除（备份: $f.bak）"
}

edit_keys() {
  ensure_auth_file || return
  local f; f=$(auth_file); cp -p "$f" "$f.bak"
  "${EDITOR:-vi}" "$f"; fix_perms
  list_keys
}

switch_user() {
  local u; read -r -p "目标用户名 [当前 $TARGET_USER]: " u
  [ -z "$u" ] && return
  user_home "$u" >/dev/null || { err "用户不存在或没有家目录: $u"; return; }
  if [ "$u" != "$(id -un)" ] && ! is_root; then err "管理其他用户的公钥需要 root 权限"; return; fi
  TARGET_USER=$u; info "已切换到用户 $u"
}

# ---------------------------------------------------------------- sshd 配置

SSHD_T=""
refresh_effective() { SSHD_T=""; is_root && SSHD_T=$("$SSHD_BIN" -T 2>/dev/null); }

get_opt() {  # 优先取 sshd -T 的实际生效值
  local k v; k=$(tr 'A-Z' 'a-z' <<< "$1")
  [ -n "$SSHD_T" ] && v=$(awk -v k="$k" '$1==k{print $2; exit}' <<< "$SSHD_T")
  [ -z "$v" ] && v=$(awk -v k="$k" 'tolower($1)==k{print $2; exit}' "$SSHD_CONFIG" 2>/dev/null)
  echo "${v:-默认}"
}

backup_config() {
  local b; b="$SSHD_CONFIG.bak.$(date +%Y%m%d%H%M%S)"
  cp -p "$SSHD_CONFIG" "$b" && echo "$b"
}

# 校验临时文件 → 备份 → 写入 → 重载
apply_config() {  # $1 = 新配置临时文件
  local out b
  if ! out=$("$SSHD_BIN" -t -f "$1" 2>&1); then
    err "配置校验失败，未做任何修改："; echo "$out"; rm -f "$1"; return 1
  fi
  b=$(backup_config) || { err "备份失败"; rm -f "$1"; return 1; }
  cat "$1" > "$SSHD_CONFIG"; rm -f "$1"
  info "已写入 $SSHD_CONFIG（备份: $b）"
  reload_sshd
  warn "建议保持当前会话，新开终端测试登录正常后再断开。"
}

# set_opt KEY VALUE [KEY VALUE ...]；VALUE 为空表示删除该项
set_opt() {
  need_root || return 1
  local tmp; tmp=$(mktemp)
  awk -v pairs="$*" '
    BEGIN { n = split(pairs, a, " "); for (i = 1; i <= n; i += 2) { kv[tolower(a[i])] = a[i+1]; ks[++m] = a[i] } }
    /^# >>> ssh-manager >>>/ { inb = 1; next }
    /^# <<< ssh-manager <<</ { inb = 0; next }
    inb { if (!(tolower($1) in kv)) blk[++nb] = $0; next }
    tolower($1) == "match" { inm = 1 }
    !inm && (tolower($1) in kv) { rest[++nr] = "# [ssh-manager 已停用] " $0; next }
    { rest[++nr] = $0 }
    END {
      print "# >>> ssh-manager >>>"
      for (i = 1; i <= nb; i++) print blk[i]
      for (i = 1; i <= m; i++) if (kv[tolower(ks[i])] != "") print ks[i] " " kv[tolower(ks[i])]
      print "# <<< ssh-manager <<<"
      for (i = 1; i <= nr; i++) print rest[i]
    }' "$SSHD_CONFIG" > "$tmp"
  apply_config "$tmp"
}

reload_sshd() {
  if [ "$OS" = Darwin ]; then
    info "macOS 的 sshd 由 launchd 按连接启动，新配置对新连接自动生效"
    systemsetup -getremotelogin 2>/dev/null | grep -q On || warn "远程登录未开启：系统设置 → 通用 → 共享 → 远程登录"
    return
  fi
  local s
  if command -v systemctl >/dev/null 2>&1; then
    for s in ssh sshd; do
      systemctl is-active --quiet "$s" && systemctl reload "$s" && { info "已重载 $s 服务"; return; }
    done
    systemctl is-active --quiet ssh.socket && { info "ssh.socket 套接字激活模式，新连接自动使用新配置"; return; }
  fi
  for s in ssh sshd; do service "$s" reload >/dev/null 2>&1 && { info "已重载 $s 服务"; return; }; done
  warn "未能自动重载 sshd，请手动重启 SSH 服务"
}

choose() {  # choose "标题" 选项1 选项2 ... → 输出所选项
  local title=$1 i c; shift
  echo "$title" >&2
  for ((i = 1; i <= $#; i++)); do printf '  %d) %s\n' "$i" "${!i}" >&2; done
  read -r -p "选择 (回车取消): " c
  [[ $c =~ ^[0-9]+$ ]] && [ "$c" -ge 1 ] && [ "$c" -le $# ] && echo "${!c}"
}

cfg_root_login() {
  need_root || return
  local c; c=$(choose "Root 登录（当前: $(get_opt PermitRootLogin)）" \
    "prohibit-password  仅允许密钥登录（推荐）" "no  完全禁止" "yes  允许（含密码）")
  [ -n "$c" ] && set_opt PermitRootLogin "${c%% *}"
}

cfg_password() {
  need_root || return
  local c; c=$(choose "密码登录（当前: $(get_opt PasswordAuthentication)）" "开启" "关闭")
  case $c in
    开启) set_opt PasswordAuthentication yes KbdInteractiveAuthentication yes ;;
    关闭)
      load_keys
      if [ ${#KEY_TXT[@]} -eq 0 ]; then
        warn "用户 $TARGET_USER 尚未配置任何公钥，关闭密码登录后可能无法登录！"
        confirm "仍然关闭？" || return
      fi
      # 同时关闭键盘交互认证，否则 PAM 仍可能允许输入密码
      set_opt PasswordAuthentication no KbdInteractiveAuthentication no ;;
  esac
}

cfg_pubkey() {
  need_root || return
  local c; c=$(choose "公钥/证书登录（当前: $(get_opt PubkeyAuthentication)）" "开启" "关闭")
  case $c in
    开启) set_opt PubkeyAuthentication yes ;;
    关闭)
      [ "$(get_opt PasswordAuthentication)" = no ] && warn "密码登录也已关闭，关闭公钥登录将导致无法登录！"
      confirm "确认关闭公钥登录？" && set_opt PubkeyAuthentication no ;;
  esac
}

cfg_ca() {
  need_root || return
  echo "CA 证书登录：信任某个 CA 签发的用户证书（ssh-keygen -s ca -I id -n 用户 key.pub）"
  local c p; c=$(choose "当前 TrustedUserCAKeys: $(get_opt TrustedUserCAKeys)" "设置 CA 公钥文件" "移除 CA 配置")
  case $c in
    设置*)
      read -r -e -p "CA 公钥路径 (如 /etc/ssh/user_ca.pub): " p
      [ -f "$p" ] && fingerprint "$(head -n1 "$p")" >/dev/null || { err "不是有效的公钥文件: $p"; return; }
      [[ $p == *" "* ]] && { err "路径不能包含空格"; return; }
      set_opt TrustedUserCAKeys "$p" ;;
    移除*) set_opt TrustedUserCAKeys "" ;;
  esac
}

cfg_port() {
  need_root || return
  local p; read -r -p "新端口（当前: $(get_opt Port)，回车取消）: " p
  [ -z "$p" ] && return
  [[ $p =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || { err "无效端口"; return; }
  warn "请确保防火墙/安全组已放行 $p 端口（SELinux 还需: semanage port -a -t ssh_port_t -p tcp $p）"
  confirm "确认修改端口为 $p？" || return
  set_opt Port "$p" || return
  if command -v systemctl >/dev/null 2>&1 && systemctl is-enabled --quiet ssh.socket 2>/dev/null; then
    systemctl daemon-reload && systemctl restart ssh.socket && info "已重启 ssh.socket 以监听新端口"
  fi
}

show_effective() {
  need_root || return
  "$SSHD_BIN" -T 2>&1 | grep -Ei '^(port|listenaddress|permitrootlogin|passwordauthentication|kbdinteractiveauthentication|pubkeyauthentication|authorizedkeysfile|trustedusercakeys|permitemptypasswords|usepam|maxauthtries|allowusers|denyusers)( |$)'
}

edit_config() {
  need_root || return
  local tmp; tmp=$(mktemp); cp "$SSHD_CONFIG" "$tmp"
  "${EDITOR:-vi}" "$tmp"
  cmp -s "$tmp" "$SSHD_CONFIG" && { info "未做修改"; rm -f "$tmp"; return; }
  apply_config "$tmp"
}

restore_config() {
  need_root || return
  local b; b=$(ls -1t "$SSHD_CONFIG".bak.* 2>/dev/null | head -n1)
  [ -z "$b" ] && { warn "没有找到备份"; return; }
  echo "最近备份: $b"; diff -u "$SSHD_CONFIG" "$b" | head -n 40
  confirm "恢复此备份？" || return
  local tmp; tmp=$(mktemp); cp "$b" "$tmp"; apply_config "$tmp"
}

# ---------------------------------------------------------------- 主菜单

menu() {
  refresh_effective
  clear 2>/dev/null
  local cfg_hint=""
  is_root || cfg_hint=" ${D}(需 sudo 运行)${N}"
  load_keys
  cat <<EOF
${BOLD}════════════ SSH 管理工具 ════════════${N}
 目标用户: ${C}$TARGET_USER${N}   已有公钥: ${C}${#KEY_TXT[@]}${N} 个

 ${BOLD}[ 公钥管理 ]${N}
   1) 查看公钥              5) 删除公钥
   2) 粘贴添加公钥          6) 用编辑器手动编辑
   3) 从文件添加公钥        7) 切换目标用户
   4) 从 GitHub 导入公钥

 ${BOLD}[ SSH 服务配置 ]${N}$cfg_hint
   8) Root 登录         当前: ${Y}$(get_opt PermitRootLogin)${N}
   9) 密码登录          当前: ${Y}$(get_opt PasswordAuthentication)${N}
  10) 公钥/证书登录     当前: ${Y}$(get_opt PubkeyAuthentication)${N}
  11) CA 证书登录       当前: ${Y}$(get_opt TrustedUserCAKeys)${N}
  12) SSH 端口          当前: ${Y}$(get_opt Port)${N}
  13) 查看生效配置     14) 手动编辑 sshd_config     15) 恢复配置备份

   0) 退出
EOF
}

main() {
  command -v ssh-keygen >/dev/null || { err "未找到 ssh-keygen，请先安装 OpenSSH"; exit 1; }
  local c
  while true; do
    menu
    read -r -p "请选择: " c || exit 0
    echo
    case $c in
      1) list_keys ;;  2) add_key_paste ;;  3) add_key_file ;;  4) add_key_github ;;
      5) delete_key ;; 6) edit_keys ;;      7) switch_user ;;
      8) cfg_root_login ;; 9) cfg_password ;; 10) cfg_pubkey ;; 11) cfg_ca ;; 12) cfg_port ;;
      13) show_effective ;; 14) edit_config ;; 15) restore_config ;;
      0|q|Q) exit 0 ;;
      *) continue ;;
    esac
    pause
  done
}

[[ ${BASH_SOURCE[0]} == "$0" ]] && main "$@"
