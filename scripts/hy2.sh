#!/usr/bin/env bash
#
# hy2.sh - Hysteria2 one-click installer & manager
#
# Target    : fresh Ubuntu 26.04 LTS, run as root
# Features  : official core install, Let's Encrypt cert via Hysteria built-in ACME,
#             proxy on UDP 443, your own masquerade site, systemd autostart,
#             node share link, self-update, EN / 中文 UI.
#
# Usage:
#   curl -fsSL <raw-url>/hy2.sh | bash -s -- --lang zh    run via pipe
#   bash hy2.sh                      interactive menu (asks for language first)
#   bash hy2.sh --lang zh            interactive menu in Chinese
#   bash hy2.sh install --domain hy.example.com --masq https://www.example.com \
#        [--email me@example.com] [--password xxx] [--name MyNode] \
#        [--bw-mode client|limit|bbr] [--up 100] [--down 100] [--yes]
#   hy2 link | status | update | self-update | uninstall
#

SCRIPT_VERSION="1.4.0"
# Oldest installed version this script can take over in place. Installs made by
# older versions must be uninstalled and installed again.
MIN_UPGRADE_VERSION="1.3.1"
# Raw URL of this script: used for self-update and to install the 'hy2'
# shortcut when the script is run through a pipe (curl ... | bash).
SCRIPT_URL="https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/hy2.sh"
# 1 when the script itself is read from stdin (curl ... | bash); $0 is then the
# shell (e.g. /bin/bash), not this script.
FROM_PIPE=0
[[ -z ${BASH_SOURCE[0]:-} ]] && FROM_PIPE=1

HY_BIN=/usr/local/bin/hysteria
HY_DIR=/etc/hysteria
HY_CONF=$HY_DIR/config.yaml
HY_STATE=$HY_DIR/.hy2-script.env
HY_BACKUP_DIR=$HY_DIR/backup
HY_DATA=/var/lib/hysteria
HY_ACME_DIR=$HY_DATA/acme
HY_SERVICE=hysteria-server.service
SYSCTL_FILE=/etc/sysctl.d/99-hysteria.conf
SHORTCUT=/usr/local/bin/hy2
INSTALLER_URL=https://get.hy2.sh/
PORT=443

# Runtime state (persisted in $HY_STATE)
DOMAIN="" EMAIL="" PASSWORD="" MASQ_URL="" NODE_NAME="" TCP_MASQ="yes" UFW_MANAGED=0
BW_MODE="" BW_UP=0 BW_DOWN=0   # BW_MODE: client | limit | bbr

# CLI options
CMD=menu UI_LANG=${HY2_LANG:-en} LANG_SET=${HY2_LANG:+1} ASSUME_YES=0
OPT_DOMAIN="" OPT_MASQ="" OPT_EMAIL="" OPT_EMAIL_SET="" OPT_PASSWORD="" OPT_NAME=""
OPT_UP="" OPT_DOWN="" OPT_BW_MODE=""
PUB_IP4="" PUB_IP6="" IPS_DETECTED="" LAST_BACKUP_TS=""
INSTALLED_VERSION="" REMOTE_VERSION=""

# ---------------------------------------------------------------------------
# i18n
# ---------------------------------------------------------------------------
declare -A M_EN M_ZH

M_EN=(
  [need_root]="This script must be run as root (try: %s)."
  [no_systemd]="systemd is required but was not found."
  [os_unsupported]="Unsupported OS: %s. This script targets Ubuntu 26.04 LTS."
  [os_untested]="Detected %s. This script is designed for Ubuntu 26.04 LTS; continuing anyway."
  [no_input]="No input received, exiting."
  [installing_deps]="Installing dependencies: %s"
  [deps_failed]="Failed to install dependencies."
  [ask_domain]="Domain bound to this server (e.g. hy.example.com)"
  [bad_domain]="Invalid domain format."
  [checking_dns]="Checking DNS records of %s ..."
  [server_ip]="Server public IP : IPv4=%s  IPv6=%s"
  [dns_records]="Domain resolves to: A=%s  AAAA=%s"
  [none]="(none)"
  [dns_ok]="DNS check passed."
  [dns_mismatch]="The domain does not resolve to this server."
  [dns_cf_hint]="If you use Cloudflare, set the record to 'DNS only' (grey cloud). Proxied records cannot carry Hysteria's UDP traffic."
  [dns_aaaa_warn]="The domain has an AAAA record that does not point to this server. Let's Encrypt prefers IPv6, so issuance will likely fail. Remove or fix the AAAA record."
  [continue_anyway]="Continue anyway?"
  [ask_email]="Email for Let's Encrypt (optional, Enter to skip)"
  [bad_email]="Invalid email address (use a plain ASCII address such as me@example.com)."
  [ask_masq]="Your masquerade site URL (e.g. https://www.example.com)"
  [bad_url]="Invalid URL. Spaces, quotes and backslashes are not allowed."
  [masq_loop]="The masquerade site must not use the same domain as this server."
  [masq_http_warn]="A plain HTTP masquerade site is not recommended; prefer HTTPS."
  [checking_masq]="Checking masquerade site %s ..."
  [masq_ok]="Masquerade site is reachable (HTTP %s)."
  [masq_redirect]="The site redirects to: %s  -- consider using the final URL directly."
  [masq_fail]="Masquerade site check failed (HTTP %s). It must be reachable from this server with a valid certificate."
  [use_anyway]="Use this URL anyway?"
  [ask_password]="Proxy password (Enter = random)"
  [ask_password_keep]="Proxy password (Enter = keep current)"
  [bad_password]="Password must be 8-128 characters of: letters, digits, . _ ~ -"
  [ask_name]="Node name shown in clients"
  [bw_title]="Bandwidth / congestion control"
  [bw_intro1]="How it works: a client that sets its own bandwidth uses Brutal for that direction;"
  [bw_intro2]="a client that sets nothing uses BBR. The server can only cap or override this."
  [bw_opt_client]="Let clients decide, no server limit (recommended)"
  [bw_opt_limit]="Limit bandwidth per client on the server"
  [bw_opt_bbr]="Force BBR for all clients (ignore client bandwidth settings)"
  [bw_choose]="Choose bandwidth mode [1-3]"
  [bw_dir1]="!! Directions are reversed between server and client:"
  [bw_dir2]="     server UPLOAD   = data sent to the client   = client DOWNLOAD"
  [bw_dir3]="     server DOWNLOAD = data sent by the client   = client UPLOAD"
  [bw_dir4]="   The limit applies to each client separately, and only to clients using Brutal"
  [bw_dir5]="   (clients that set bandwidth); the lower of client and server value wins."
  [bw_dir6]="   Clients on BBR are NOT limited. Do not exceed the server's real bandwidth. 0 = no limit."
  [ask_bw_up]="Server UPLOAD limit = client DOWNLOAD limit (Mbps, 0 = no limit)"
  [ask_bw_down]="Server DOWNLOAD limit = client UPLOAD limit (Mbps, 0 = no limit)"
  [bad_bw]="Bandwidth must be an integer from 0 to 100000 Mbps (units like 500m or 1g are accepted)."
  [bad_bw_mode]="Invalid --bw-mode: %s (use client, limit or bbr)."
  [bw_limit_none]="Both directions are unlimited, using \"let clients decide\" instead."
  [sum_bw]="Bandwidth / CC"
  [bw_client]="Clients decide (no server limit)"
  [bw_limit]="Server limit: upload %s (= client download) / download %s (= client upload)"
  [bw_bbr]="Force BBR (client bandwidth ignored)"
  [bw_unlimited]="unlimited"
  [port_busy]="Port %s/%s is already in use:"
  [port80_required]="TCP 80 is required for certificate issuance (ACME HTTP-01). Free it and try again."
  [udp443_required]="UDP 443 is required by Hysteria2. Free it and try again."
  [tcp443_busy]="TCP 443 is busy; the TCP masquerade listener will be disabled."
  [summary_title]="Installation summary"
  [sum_domain]="Domain"
  [sum_email]="Email"
  [sum_masq]="Masquerade"
  [sum_password]="Password"
  [sum_name]="Node name"
  [sum_cert]="Certificate"
  [sum_cert_val]="Let's Encrypt (Hysteria built-in ACME, HTTP-01 on TCP 80)"
  [sum_listen]="Listen"
  [sum_listen_val]="UDP %s (proxy)"
  [sum_listen_tcp]=" + TCP %s (masquerade)"
  [proceed]="Proceed with installation?"
  [aborted]="Aborted."
  [installing_core]="Installing Hysteria2 core via the official installer ..."
  [core_failed]="Failed to install the Hysteria2 core."
  [writing_config]="Writing configuration ..."
  [sysctl_done]="UDP buffer tuning applied."
  [sysctl_fail]="Failed to apply sysctl settings (ignored)."
  [fw_ufw]="ufw is active, allowed: %s"
  [fw_none]="No active host firewall (ufw) detected, nothing to open."
  [fw_cloud]="Remember to allow UDP 443 and TCP 80/443 in your cloud provider's security group."
  [starting]="Starting service and requesting certificate (up to 3 minutes) "
  [start_ok]="Hysteria2 is up and running."
  [start_fail]="Hysteria2 failed to start. Recent logs:"
  [start_timeout]="Timed out waiting for Hysteria2. Recent logs:"
  [fail_hints]="Common causes: DNS not pointing here, TCP 80 blocked by the security group, Let's Encrypt rate limit."
  [install_done]="Installation complete! Run 'hy2' to open this menu again."
  [shortcut_ok]="Shortcut installed: %s"
  [shortcut_skip]="Could not install the 'hy2' shortcut; run the script again later."
  [not_installed]="Hysteria2 is not installed. Please install it first."
  [no_state]="Hysteria2 was not installed by this script (state file missing). Please reinstall with this script."
  [already_installed]="Hysteria2 is already installed. Reinstall and overwrite the current configuration?"
  [share_title]="Node link"
  [updating]="Updating Hysteria2 core ..."
  [update_done]="Core version: %s -> %s"
  [uninstall_confirm]="This removes Hysteria2, its configuration and certificates. Continue?"
  [remove_warn]="Official removal script failed, cleaning up manually."
  [uninstall_done]="Hysteria2 has been uninstalled."
  [ver_installed]="Installed by"
  [ver_new_avail]="New script version available: v%s"
  [ver_legacy1]="This server was set up by hy2.sh %s, which is too old to be upgraded in place (v%s or later required)."
  [ver_legacy2]="Please uninstall completely, then install again with this script. Note down the node link first if you want to reuse the password."
  [ver_legacy_short]="too old, reinstall required"
  [ver_unknown]="an unknown older version"
  [ver_newer]="This server is managed by a newer hy2.sh (v%s). Please run the latest script: %s"
  [ver_blocked]="Not available for this installation."
  [ver_adopted]="Management script upgraded: v%s -> v%s (node configuration unchanged)."
  [su_checking]="Checking for script updates..."
  [su_fetch_fail]="Could not download the script from %s."
  [su_invalid]="The downloaded file is not a valid hy2.sh, update aborted."
  [su_latest]="Already up to date (v%s)."
  [su_confirm]="Update the management script from v%s to v%s now?"
  [su_done]="Management script updated to v%s, restarting it..."
  [su_prompt]="A new version v%s is available (current v%s). Update now?"
  [backup_restored]="Change failed, the previous configuration has been restored."
  [no_change]="No change."
  [saved]="Saved."
  [press_enter]="Press Enter to continue..."
  [invalid_choice]="Invalid choice"
  [choose]="Please choose"
  [cert_auto]="Certificates are issued and renewed automatically by Hysteria's built-in ACME."
  [cert_not_found]="Certificate file not found yet."
  [cert_path]="File"
  [cert_days]="Days remaining: %s"
  [reissue_confirm]="Delete the current certificate and request a new one? (Let's Encrypt allows 5 duplicate certificates per week)"
  [logs_hint]="Live logs, press Ctrl+C to return."
  [listening]="Listening sockets"
  [tcpmasq_now]="TCP masquerade listener: %s"
  [on]="on"
  [off]="off"
  [yes]="yes"
  [no]="no"
  [current]="current"
  [st_running]="running"
  [st_stopped]="stopped"
  [st_notinst]="not installed"
  [st_partial]="not managed by this script"
  [lbl_status]="Status"
  [lbl_version]="Core"
  [lbl_autostart]="Autostart"
  [lbl_endpoint]="Endpoint"
  [m_title]="Hysteria2 Manager"
  [m_install]="Install Hysteria2 (fresh install & configure)"
  [m_update]="Update Hysteria2 core"
  [m_uninstall]="Uninstall Hysteria2"
  [m_sec_common]="-- Common --"
  [m_sec_config]="-- Configuration --"
  [m_sec_maint]="-- Maintenance --"
  [m_reinstall]="Reinstall (overwrites current configuration)"
  [m_modify_h]="Modify configuration"
  [m_cert_h]="Certificate"
  [m_service_h]="Start / Stop / Restart"
  [m_share]="Show node link"
  [m_selfupdate]="Update this management script"
  [m_modify]="Modify configuration  >"
  [m_cert]="Certificate  >"
  [m_service]="Start / Stop / Restart  >"
  [m_status]="Service status"
  [m_logs]="Live logs"
  [m_lang]="切换到中文"
  [m_exit]="Exit"
  [mm_password]="Change password"
  [mm_masq]="Change masquerade site"
  [mm_domain]="Change domain (re-issues certificate)"
  [mm_name]="Change node name"
  [mm_tcpmasq]="Toggle TCP 443 masquerade listener"
  [mm_bw]="Bandwidth / congestion control"
  [mc_info]="Show certificate info"
  [mc_reissue]="Force re-issue certificate"
  [ms_start]="Start"
  [ms_stop]="Stop"
  [ms_restart]="Restart"
  [stopped_ok]="Service stopped."
  [back]="Back"
  [unknown_arg]="Unknown argument: %s"
  [missing_val]="Option %s requires a value."
)

M_ZH=(
  [need_root]="请使用 root 权限运行此脚本（例如：%s）。"
  [no_systemd]="未检测到 systemd，本脚本依赖 systemd。"
  [os_unsupported]="不支持的系统：%s。本脚本面向 Ubuntu 26.04 LTS。"
  [os_untested]="检测到 %s。本脚本按 Ubuntu 26.04 LTS 设计，将继续执行。"
  [no_input]="未读取到输入，退出。"
  [installing_deps]="正在安装依赖：%s"
  [deps_failed]="依赖安装失败。"
  [ask_domain]="请输入已解析到本机的域名（例如 hy.example.com）"
  [bad_domain]="域名格式不正确。"
  [checking_dns]="正在检查 %s 的 DNS 解析……"
  [server_ip]="本机公网 IP：IPv4=%s  IPv6=%s"
  [dns_records]="域名解析结果：A=%s  AAAA=%s"
  [none]="（无）"
  [dns_ok]="DNS 解析检查通过。"
  [dns_mismatch]="域名没有解析到本机。"
  [dns_cf_hint]="如果使用 Cloudflare，请将记录设为「仅 DNS」（灰色云朵），开启代理的记录无法转发 Hysteria 的 UDP 流量。"
  [dns_aaaa_warn]="域名存在未指向本机的 AAAA 记录。Let's Encrypt 会优先通过 IPv6 验证，证书很可能申请失败，请删除或修正该记录。"
  [continue_anyway]="仍然继续？"
  [ask_email]="Let's Encrypt 通知邮箱（可选，直接回车跳过）"
  [bad_email]="邮箱格式不正确（请使用常规英文邮箱，如 me@example.com）。"
  [ask_masq]="请输入你的伪装站点 URL（例如 https://www.example.com）"
  [bad_url]="URL 格式不正确，不能包含空格、引号或反斜杠。"
  [masq_loop]="伪装站点不能与本机使用同一个域名。"
  [masq_http_warn]="不建议使用 HTTP 伪装站点，推荐使用 HTTPS。"
  [checking_masq]="正在检查伪装站点 %s ……"
  [masq_ok]="伪装站点可以访问（HTTP %s）。"
  [masq_redirect]="该站点会重定向到：%s，建议直接填写最终地址。"
  [masq_fail]="伪装站点检查失败（HTTP %s），请确认本机可以访问该站点且证书有效。"
  [use_anyway]="仍然使用该地址？"
  [ask_password]="代理密码（直接回车随机生成）"
  [ask_password_keep]="代理密码（直接回车保留当前密码）"
  [bad_password]="密码须为 8-128 位，只能包含字母、数字及 . _ ~ -"
  [ask_name]="客户端显示的节点名称"
  [bw_title]="带宽 / 拥塞控制"
  [bw_intro1]="说明：客户端填写了带宽的方向使用 Brutal，未填写的方向使用 BBR；"
  [bw_intro2]="服务器只能对其限速或强制改用 BBR，不能替客户端开启 Brutal。"
  [bw_opt_client]="由客户端决定，服务器不限速（推荐）"
  [bw_opt_limit]="在服务器端限制每个客户端的带宽"
  [bw_opt_bbr]="强制所有客户端使用 BBR（忽略客户端带宽设置）"
  [bw_choose]="请选择带宽模式 [1-3]"
  [bw_dir1]="!! 服务器与客户端的上传/下载方向相反："
  [bw_dir2]="     服务器【上传】= 服务器发给客户端的数据 = 客户端【下载】"
  [bw_dir3]="     服务器【下载】= 客户端发给服务器的数据 = 客户端【上传】"
  [bw_dir4]="   上限对每个客户端单独生效，且只限制使用 Brutal 的客户端（即填写了带宽的客户端），"
  [bw_dir5]="   实际速度取客户端设置与服务器上限中较小的值。"
  [bw_dir6]="   使用 BBR 的客户端不受此限制。请勿超过服务器的实际带宽；填 0 表示该方向不限制。"
  [ask_bw_up]="服务器【上传】上限 = 客户端【下载】上限（Mbps，0 = 不限）"
  [ask_bw_down]="服务器【下载】上限 = 客户端【上传】上限（Mbps，0 = 不限）"
  [bad_bw]="带宽须为 0 到 100000 之间的整数，单位 Mbps（也可写 500m、1g）。"
  [bad_bw_mode]="无效的 --bw-mode：%s（可选 client、limit、bbr）。"
  [bw_limit_none]="两个方向都不限制，已改为「由客户端决定」。"
  [sum_bw]="带宽 / 拥塞控制"
  [bw_client]="由客户端决定（服务器不限速）"
  [bw_limit]="服务器限速：上传 %s（= 客户端下载）/ 下载 %s（= 客户端上传）"
  [bw_bbr]="强制 BBR（忽略客户端带宽设置）"
  [bw_unlimited]="不限"
  [port_busy]="端口 %s/%s 已被占用："
  [port80_required]="申请证书（ACME HTTP-01）需要使用 TCP 80 端口，请释放后重试。"
  [udp443_required]="Hysteria2 需要使用 UDP 443 端口，请释放后重试。"
  [tcp443_busy]="TCP 443 已被占用，将不启用 TCP 伪装监听。"
  [summary_title]="安装信息确认"
  [sum_domain]="域名"
  [sum_email]="邮箱"
  [sum_masq]="伪装站点"
  [sum_password]="密码"
  [sum_name]="节点名称"
  [sum_cert]="证书"
  [sum_cert_val]="Let's Encrypt（Hysteria 内置 ACME，通过 TCP 80 进行 HTTP-01 验证）"
  [sum_listen]="监听"
  [sum_listen_val]="UDP %s（代理）"
  [sum_listen_tcp]=" + TCP %s（伪装）"
  [proceed]="确认开始安装？"
  [aborted]="已取消。"
  [installing_core]="正在通过官方脚本安装 Hysteria2 内核……"
  [core_failed]="Hysteria2 内核安装失败。"
  [writing_config]="正在写入配置文件……"
  [sysctl_done]="已应用 UDP 缓冲区优化。"
  [sysctl_fail]="sysctl 参数应用失败（已忽略）。"
  [fw_ufw]="检测到 ufw 已启用，已放行：%s"
  [fw_none]="本机未启用 ufw 防火墙，无需放行。"
  [fw_cloud]="请记得在云服务商安全组中放行 UDP 443 和 TCP 80/443。"
  [starting]="正在启动服务并申请证书（最长约 3 分钟）"
  [start_ok]="Hysteria2 已成功运行。"
  [start_fail]="Hysteria2 启动失败，最近日志如下："
  [start_timeout]="等待 Hysteria2 启动超时，最近日志如下："
  [fail_hints]="常见原因：域名未解析到本机、安全组未放行 TCP 80、触发 Let's Encrypt 频率限制。"
  [install_done]="安装完成！之后输入 hy2 即可再次打开本菜单。"
  [shortcut_ok]="已安装快捷命令：%s"
  [shortcut_skip]="无法安装 hy2 快捷命令，请稍后重新运行本脚本。"
  [not_installed]="Hysteria2 尚未安装，请先安装。"
  [no_state]="当前 Hysteria2 不是由本脚本安装的（缺少状态文件），请使用本脚本重新安装。"
  [already_installed]="Hysteria2 已安装，是否重新安装并覆盖当前配置？"
  [share_title]="节点链接"
  [updating]="正在更新 Hysteria2 内核……"
  [update_done]="内核版本：%s -> %s"
  [uninstall_confirm]="将删除 Hysteria2 及其配置和证书，是否继续？"
  [remove_warn]="官方卸载脚本执行失败，改为手动清理。"
  [uninstall_done]="Hysteria2 已卸载。"
  [ver_installed]="安装版本"
  [ver_new_avail]="管理脚本有新版本：v%s"
  [ver_legacy1]="本机由 hy2.sh %s 安装，版本过旧，无法直接升级（需要 v%s 或更新）。"
  [ver_legacy2]="请先完全卸载，再用本脚本重新安装。如需沿用原密码，请先记下节点链接。"
  [ver_legacy_short]="版本过旧，需重新安装"
  [ver_unknown]="未知的旧版本"
  [ver_newer]="本机由更新的 hy2.sh（v%s）管理，请运行最新脚本：%s"
  [ver_blocked]="当前安装不支持此操作。"
  [ver_adopted]="管理脚本已升级：v%s -> v%s（节点配置未改变）。"
  [su_checking]="正在检查脚本更新……"
  [su_fetch_fail]="无法从 %s 下载脚本。"
  [su_invalid]="下载的文件不是有效的 hy2.sh，已取消更新。"
  [su_latest]="已是最新版本（v%s）。"
  [su_confirm]="将管理脚本从 v%s 更新到 v%s？"
  [su_done]="管理脚本已更新到 v%s，正在重新启动……"
  [su_prompt]="发现新版本 v%s（当前 v%s），是否立即更新？"
  [backup_restored]="修改失败，已恢复之前的配置。"
  [no_change]="没有变化。"
  [saved]="已保存。"
  [press_enter]="按回车键继续……"
  [invalid_choice]="无效选项"
  [choose]="请选择"
  [cert_auto]="证书由 Hysteria 内置 ACME 自动签发和续期。"
  [cert_not_found]="暂未找到证书文件。"
  [cert_path]="文件"
  [cert_days]="剩余天数：%s"
  [reissue_confirm]="删除当前证书并重新申请？（Let's Encrypt 每周最多签发 5 张相同证书）"
  [logs_hint]="实时日志，按 Ctrl+C 返回。"
  [listening]="监听中的端口"
  [tcpmasq_now]="TCP 伪装监听：%s"
  [on]="开启"
  [off]="关闭"
  [yes]="是"
  [no]="否"
  [current]="当前"
  [st_running]="运行中"
  [st_stopped]="已停止"
  [st_notinst]="未安装"
  [st_partial]="非本脚本管理"
  [lbl_status]="状态"
  [lbl_version]="内核"
  [lbl_autostart]="开机自启"
  [lbl_endpoint]="地址"
  [m_title]="Hysteria2 管理脚本"
  [m_install]="安装 Hysteria2（全新安装并配置）"
  [m_update]="更新 Hysteria2 内核"
  [m_uninstall]="卸载 Hysteria2"
  [m_sec_common]="—— 常用 ——"
  [m_sec_config]="—— 配置 ——"
  [m_sec_maint]="—— 维护 ——"
  [m_reinstall]="重新安装（覆盖当前配置）"
  [m_modify_h]="修改配置"
  [m_cert_h]="证书管理"
  [m_service_h]="启动 / 停止 / 重启"
  [m_share]="查看节点链接"
  [m_selfupdate]="更新管理脚本"
  [m_modify]="修改配置  ▶"
  [m_cert]="证书管理  ▶"
  [m_service]="启动 / 停止 / 重启  ▶"
  [m_status]="查看运行状态"
  [m_logs]="查看实时日志"
  [m_lang]="Switch to English"
  [m_exit]="退出"
  [mm_password]="修改密码"
  [mm_masq]="修改伪装站点"
  [mm_domain]="修改域名（将重新申请证书）"
  [mm_name]="修改节点名称"
  [mm_tcpmasq]="开启 / 关闭 TCP 443 伪装监听"
  [mm_bw]="带宽 / 拥塞控制"
  [mc_info]="查看证书信息"
  [mc_reissue]="强制重新申请证书"
  [ms_start]="启动"
  [ms_stop]="停止"
  [ms_restart]="重启"
  [stopped_ok]="服务已停止。"
  [back]="返回"
  [unknown_arg]="未知参数：%s"
  [missing_val]="参数 %s 需要一个值。"
)

t() {
  local key=$1 fmt
  shift
  if [[ $UI_LANG == zh ]]; then
    fmt=${M_ZH[$key]:-${M_EN[$key]:-$key}}
  else
    fmt=${M_EN[$key]:-$key}
  fi
  # "--" keeps formats such as "-- Common --" from being parsed as options.
  # shellcheck disable=SC2059
  printf -- "$fmt" "$@"
}

# ---------------------------------------------------------------------------
# Output / input helpers
# ---------------------------------------------------------------------------
info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }
title() { printf '\n\033[36m===== %s =====\033[0m\n' "$*"; }

pause() { [[ -t 0 ]] && read -rp "$(t press_enter)" _; }

# ask VAR "prompt" [default]
ask() {
  local __var=$1 __prompt=$2 __def=$3 __ans
  if [[ -n $__def ]]; then
    read -rp "$__prompt [$__def]: " __ans || die "$(t no_input)"
    __ans=${__ans:-$__def}
  else
    read -rp "$__prompt: " __ans || die "$(t no_input)"
  fi
  printf -v "$__var" '%s' "$__ans"
}

# confirm "prompt" [y|n]  -> 0 = yes
confirm() {
  local p=$1 def=${2:-n} a hint
  ((ASSUME_YES)) && return 0
  if [[ $def == y ]]; then hint="Y/n"; else hint="y/N"; fi
  read -rp "$p [$hint]: " a || return 1
  a=${a:-$def}
  [[ $a == [yY]* ]]
}

choose_language() {
  echo "Select language / 选择语言:"
  echo "  1) English (default)"
  echo "  2) 中文"
  local c
  read -rp "[1/2]: " c
  [[ $c == 2 ]] && UI_LANG=zh || UI_LANG=en
}

# ---------------------------------------------------------------------------
# Validation / utilities
# ---------------------------------------------------------------------------
valid_domain()   { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
# Common ASCII address form; rejects YAML-special leading characters and
# malformed domains (e.g. "a@b:c.com") that the CA would refuse anyway.
valid_email() {
  local re='^[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}$'
  [[ $1 =~ $re ]]
}
# yaml_str VALUE -> VALUE as a double-quoted YAML scalar.
yaml_str() {
  local v=${1//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}
valid_password() { [[ $1 =~ ^[A-Za-z0-9._~-]{8,128}$ ]]; }
# parse_bw "500" | "500 Mbps" | "500m" | "1g" -> Mbps as a plain integer.
# Leading zeros are dropped (bash would otherwise read "08" as octal).
parse_bw() {
  local v=${1//[[:space:]]/} n
  v=${v,,}
  [[ $v =~ ^([0-9]{1,6})(m|mb|mbps|g|gb|gbps)?$ ]] || return 1
  n=$((10#${BASH_REMATCH[1]}))
  [[ ${BASH_REMATCH[2]} == g* ]] && n=$((n * 1000))
  ((n <= 100000)) || return 1
  printf '%s' "$n"
}
bw_value() { if (($1 > 0)); then printf '%s Mbps' "$1"; else t bw_unlimited; fi; }
bw_label() {
  case $BW_MODE in
    limit) t bw_limit "$(bw_value "$BW_UP")" "$(bw_value "$BW_DOWN")" ;;
    bbr) t bw_bbr ;;
    *) t bw_client ;;
  esac
}
valid_url() {
  local re='^https?://[A-Za-z0-9.-]+(:[0-9]{1,5})?(/[^[:space:]"\\]*)?$'
  [[ $1 =~ $re ]]
}
normalize_url() {
  local u=${1//[[:space:]]/}
  [[ -z $u ]] && return 0
  [[ $u =~ ^[A-Za-z]+:// ]] || u="https://$u"
  printf '%s' "$u"
}
url_host() { local h=${1#*://}; h=${h%%/*}; h=${h%%:*}; printf '%s' "${h,,}"; }
gen_password() { openssl rand -hex 16; }

# RFC 3986 percent-encoding, byte-wise (handles UTF-8 node names)
urlencode() {
  local b out=""
  for b in $(printf '%s' "$1" | od -An -v -tx1); do
    case $b in
      3[0-9] | 4[1-9a-f] | 5[0-9a] | 6[1-9a-f] | 7[0-9a] | 2d | 2e | 5f | 7e)
        # shellcheck disable=SC2059
        out+=$(printf "\\x$b") ;;
      *) out+="%${b^^}" ;;
    esac
  done
  printf '%s' "$out"
}

join_lines() {
  local s
  s=$(printf '%s' "$1" | tr '\n' ' ')
  s=${s% }
  printf '%s' "${s:-$(t none)}"
}

is_installed() { [[ -x $HY_BIN && -f $HY_CONF ]]; }

need_installed() {
  if ! is_installed; then err "$(t not_installed)"; return 1; fi
  if [[ ! -f $HY_STATE ]]; then err "$(t no_state)"; return 1; fi
  load_state
}

core_version() { "$HY_BIN" version 2>/dev/null | awk -F'[:[:space:]]+' '/^Version/{print $2; exit}'; }
hy_group() { id -gn hysteria 2>/dev/null || echo root; }
on_off() { if [[ $1 == yes ]]; then t on; else t off; fi; }

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
save_state() {
  mkdir -p "$HY_DIR"
  (
    umask 077
    {
      printf 'INSTALLED_VERSION=%q\n' "$SCRIPT_VERSION"
      printf 'DOMAIN=%q\n' "$DOMAIN"
      printf 'EMAIL=%q\n' "$EMAIL"
      printf 'PASSWORD=%q\n' "$PASSWORD"
      printf 'MASQ_URL=%q\n' "$MASQ_URL"
      printf 'NODE_NAME=%q\n' "$NODE_NAME"
      printf 'TCP_MASQ=%q\n' "$TCP_MASQ"
      printf 'UFW_MANAGED=%q\n' "$UFW_MANAGED"
      printf 'BW_MODE=%q\n' "$BW_MODE"
      printf 'BW_UP=%q\n' "$BW_UP"
      printf 'BW_DOWN=%q\n' "$BW_DOWN"
    } >"$HY_STATE"
  )
  chmod 600 "$HY_STATE"
}

load_state() {
  INSTALLED_VERSION=""
  if [[ -f $HY_STATE ]]; then
    # shellcheck disable=SC1090
    . "$HY_STATE"
    BW_UP=$(parse_bw "${BW_UP:-0}") || BW_UP=0
    BW_DOWN=$(parse_bw "${BW_DOWN:-0}") || BW_DOWN=0
    # State written before BW_MODE existed: 0/0 meant ignoreClientBandwidth
    # (forced BBR), anything else meant server limits.
    if [[ $BW_MODE != client && $BW_MODE != limit && $BW_MODE != bbr ]]; then
      if ((BW_UP == 0 && BW_DOWN == 0)); then BW_MODE=bbr; else BW_MODE=limit; fi
    fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------
require_root() {
  [[ $EUID -eq 0 ]] && return 0
  local hint="sudo bash $0"
  ((FROM_PIPE)) || [[ ! -f $0 ]] && hint="curl -fsSL $SCRIPT_URL | sudo bash"
  die "$(t need_root "$hint")"
}

check_os() {
  if [[ ! -d /run/systemd/system ]] || ! command -v systemctl >/dev/null; then die "$(t no_systemd)"; fi
  local id="" ver="" pretty="unknown"
  if [[ -r /etc/os-release ]]; then
    id=$(. /etc/os-release; echo "$ID")
    ver=$(. /etc/os-release; echo "$VERSION_ID")
    pretty=$(. /etc/os-release; echo "$PRETTY_NAME")
  fi
  command -v apt-get >/dev/null || die "$(t os_unsupported "$pretty")"
  if [[ $id != ubuntu || $ver != 26.04 ]]; then warn "$(t os_untested "$pretty")"; fi
}

install_deps() {
  local p missing=()
  for p in curl ca-certificates openssl bind9-dnsutils iproute2; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  ((${#missing[@]})) || return 0
  info "$(t installing_deps "${missing[*]}")"
  export DEBIAN_FRONTEND=noninteractive
  if ! { apt-get update -qq && apt-get install -y -qq "${missing[@]}" >/dev/null; }; then die "$(t deps_failed)"; fi
}

detect_ips() {
  [[ -n $IPS_DETECTED ]] && return 0
  local svc ip
  for svc in https://api64.ipify.org https://icanhazip.com https://ifconfig.co; do
    ip=$(curl -4 -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
    [[ $ip =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] && { PUB_IP4=$ip; break; }
  done
  for svc in https://api64.ipify.org https://icanhazip.com https://ifconfig.co; do
    ip=$(curl -6 -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
    [[ $ip == *:* ]] && { PUB_IP6=${ip,,}; break; }
  done
  IPS_DETECTED=1
}

# resolve DOMAIN A|AAAA  (prefer public resolver to avoid stale local cache)
resolve() {
  local out
  out=$(dig +short +time=3 +tries=1 "$1" "$2" @1.1.1.1 2>/dev/null)
  [[ -z $out ]] && out=$(dig +short +time=3 +tries=1 "$1" "$2" 2>/dev/null)
  if [[ $2 == A ]]; then
    grep -E '^[0-9]+(\.[0-9]+){3}$' <<<"$out"
  else
    grep ':' <<<"$out" | tr 'A-F' 'a-f'
  fi
}

check_domain_dns() {
  local d=$1 a4 a6 ok=0 aaaa_bad=0
  info "$(t checking_dns "$d")"
  detect_ips
  a4=$(resolve "$d" A)
  a6=$(resolve "$d" AAAA)
  echo "  $(t server_ip "${PUB_IP4:-$(t none)}" "${PUB_IP6:-$(t none)}")"
  echo "  $(t dns_records "$(join_lines "$a4")" "$(join_lines "$a6")")"
  [[ -n $PUB_IP4 ]] && grep -qxF "$PUB_IP4" <<<"$a4" && ok=1
  [[ -n $PUB_IP6 ]] && grep -qxF "$PUB_IP6" <<<"$a6" && ok=1
  if [[ -n $a6 ]] && ! { [[ -n $PUB_IP6 ]] && grep -qxF "$PUB_IP6" <<<"$a6"; }; then aaaa_bad=1; fi
  if ((ok && !aaaa_bad)); then info "$(t dns_ok)"; return 0; fi
  if ((!ok)); then warn "$(t dns_mismatch)"; warn "$(t dns_cf_hint)"; fi
  ((aaaa_bad)) && warn "$(t dns_aaaa_warn)"
  confirm "$(t continue_anyway)" n
}

check_masquerade() {
  local url=$1 code="" loc=""
  if [[ $(url_host "$url") == "$DOMAIN" ]]; then err "$(t masq_loop)"; return 2; fi
  [[ $url == http://* ]] && warn "$(t masq_http_warn)"
  info "$(t checking_masq "$url")"
  read -r code loc < <(curl -sS -o /dev/null --max-time 10 -A "Mozilla/5.0" \
    -w '%{http_code} %{redirect_url}\n' "$url" 2>/dev/null)
  code=${code:-000}
  if [[ $code =~ ^[23][0-9][0-9]$ ]]; then
    info "$(t masq_ok "$code")"
    [[ $code == 3* && -n $loc ]] && warn "$(t masq_redirect "$loc")"
    return 0
  fi
  err "$(t masq_fail "$code")"
  return 1
}

# Listeners on a port, excluding Hysteria itself.  $1 = t|u
port_users() { ss -H -"$1"lnp "sport = :$2" 2>/dev/null | grep -v '"hysteria"'; }

check_ports() {
  local out
  out=$(port_users u "$PORT")
  [[ -n $out ]] && { err "$(t port_busy "$PORT" udp)"; echo "$out"; die "$(t udp443_required)"; }
  out=$(port_users t 80)
  [[ -n $out ]] && { err "$(t port_busy 80 tcp)"; echo "$out"; die "$(t port80_required)"; }
  TCP_MASQ=yes
  out=$(port_users t "$PORT")
  if [[ -n $out ]]; then
    warn "$(t port_busy "$PORT" tcp)"; echo "$out"; warn "$(t tcp443_busy)"
    TCP_MASQ=no
  fi
}

# ---------------------------------------------------------------------------
# Input collection
# ---------------------------------------------------------------------------
collect_domain() {
  local d=$OPT_DOMAIN
  while :; do
    [[ -z $d ]] && ask d "$(t ask_domain)" "$DOMAIN"
    d=${d,,}; d=${d%.}
    if ! valid_domain "$d"; then
      err "$(t bad_domain)"; [[ -n $OPT_DOMAIN ]] && exit 1; d=""; continue
    fi
    if check_domain_dns "$d"; then DOMAIN=$d; return 0; fi
    [[ -n $OPT_DOMAIN ]] && exit 1
    d=""
  done
}

collect_email() {
  local e
  if [[ -n $OPT_EMAIL_SET ]]; then
    e=$OPT_EMAIL
  elif ((ASSUME_YES)); then
    e=$EMAIL
  else
    while :; do
      ask e "$(t ask_email)" "$EMAIL"
      { [[ -z $e ]] || valid_email "$e"; } && break
      err "$(t bad_email)"
    done
  fi
  [[ -n $e ]] && ! valid_email "$e" && die "$(t bad_email)"
  EMAIL=$e
}

collect_masq() {
  local u=$OPT_MASQ rc
  while :; do
    [[ -z $u ]] && ask u "$(t ask_masq)" "$MASQ_URL"
    u=$(normalize_url "$u")
    if ! valid_url "$u"; then
      err "$(t bad_url)"; [[ -n $OPT_MASQ ]] && exit 1; u=""; continue
    fi
    check_masquerade "$u"; rc=$?
    if ((rc == 0)) || { ((rc == 1)) && confirm "$(t use_anyway)" n; }; then
      MASQ_URL=$u; return 0
    fi
    [[ -n $OPT_MASQ ]] && exit 1
    u=""
  done
}

# collect_password keep|new
collect_password() {
  local p
  if [[ -n $OPT_PASSWORD ]]; then
    p=$OPT_PASSWORD
  elif ((ASSUME_YES)); then
    p=${PASSWORD:-$(gen_password)}
  else
    while :; do
      if [[ $1 == keep && -n $PASSWORD ]]; then
        read -rp "$(t ask_password_keep): " p || die "$(t no_input)"
        p=${p:-$PASSWORD}
      else
        read -rp "$(t ask_password): " p || die "$(t no_input)"
        p=${p:-$(gen_password)}
      fi
      valid_password "$p" && break
      err "$(t bad_password)"
    done
  fi
  valid_password "$p" || die "$(t bad_password)"
  PASSWORD=$p
}

collect_name() {
  local n def=${NODE_NAME:-hy2-$DOMAIN}
  if [[ -n $OPT_NAME ]]; then n=$OPT_NAME
  elif ((ASSUME_YES)); then n=$def
  else ask n "$(t ask_name)" "$def"; fi
  NODE_NAME=${n:-$def}
}

# ask_bw VAR "prompt" [default] - repeat until a valid bandwidth is entered.
ask_bw() {
  local __var=$1 __v
  while :; do
    ask __v "$2" "$3"
    __v=$(parse_bw "$__v") && break
    err "$(t bad_bw)"
  done
  printf -v "$__var" '%s' "$__v"
}

print_bw_directions() {
  local k
  for k in bw_dir1 bw_dir2 bw_dir3 bw_dir4 bw_dir5 bw_dir6; do
    if [[ $k == bw_dir1 ]]; then echo -e "\033[33m$(t $k)\033[0m"; else echo "$(t $k)"; fi
  done
}

# Sets BW_MODE / BW_UP / BW_DOWN from --bw-mode/--up/--down, or interactively.
# With --yes and no options the current values (default: client) are kept.
collect_bandwidth() {
  local mode=${BW_MODE:-client} up=$BW_UP down=$BW_DOWN c def
  if [[ -n $OPT_BW_MODE$OPT_UP$OPT_DOWN ]]; then
    up=0 down=0
    if [[ -n $OPT_UP ]]; then up=$(parse_bw "$OPT_UP") || die "$(t bad_bw)"; fi
    if [[ -n $OPT_DOWN ]]; then down=$(parse_bw "$OPT_DOWN") || die "$(t bad_bw)"; fi
    case ${OPT_BW_MODE,,} in
      client | limit | bbr) mode=${OPT_BW_MODE,,} ;;
      # --up/--down alone mean server limits; "--up 0 --down 0" keeps its
      # historical meaning of forced BBR.
      '') if ((up == 0 && down == 0)); then mode=bbr; else mode=limit; fi ;;
      *) die "$(t bad_bw_mode "$OPT_BW_MODE")" ;;
    esac
  elif ((!ASSUME_YES)); then
    title "$(t bw_title)"
    echo "$(t bw_intro1)"
    echo "$(t bw_intro2)"
    echo "  1. $(t bw_opt_client)"
    echo "  2. $(t bw_opt_limit)"
    echo "  3. $(t bw_opt_bbr)"
    case $mode in limit) def=2 ;; bbr) def=3 ;; *) def=1 ;; esac
    while :; do
      ask c "$(t bw_choose)" "$def"
      case ${c//[[:space:]]/} in
        1) mode=client; break ;;
        2) mode=limit; break ;;
        3) mode=bbr; break ;;
        *) err "$(t invalid_choice)" ;;
      esac
    done
    if [[ $mode == limit ]]; then
      echo
      print_bw_directions
      if [[ $BW_MODE == limit ]]; then
        ask_bw up "$(t ask_bw_up)" "$BW_UP"
        ask_bw down "$(t ask_bw_down)" "$BW_DOWN"
      else
        ask_bw up "$(t ask_bw_up)"
        ask_bw down "$(t ask_bw_down)"
      fi
    fi
  fi
  if [[ $mode == limit ]] && ((up == 0 && down == 0)); then
    info "$(t bw_limit_none)"
    mode=client
  fi
  [[ $mode == limit ]] || { up=0; down=0; }
  BW_MODE=$mode BW_UP=$up BW_DOWN=$down
}

print_summary() {
  local listen
  listen=$(t sum_listen_val "$PORT")
  [[ $TCP_MASQ == yes ]] && listen+=$(t sum_listen_tcp "$PORT")
  title "$(t summary_title)"
  printf '  %-14s: %s\n' "$(t sum_domain)" "$DOMAIN" \
    "$(t sum_email)" "${EMAIL:-$(t none)}" \
    "$(t sum_masq)" "$MASQ_URL" \
    "$(t sum_password)" "$PASSWORD" \
    "$(t sum_name)" "$NODE_NAME" \
    "$(t sum_bw)" "$(bw_label)" \
    "$(t sum_cert)" "$(t sum_cert_val)" \
    "$(t sum_listen)" "$listen"
  echo
}

# ---------------------------------------------------------------------------
# Core / config / system
# ---------------------------------------------------------------------------
run_official_installer() {
  local tmp rc
  tmp=$(mktemp) || return 1
  if ! curl -fsSL --retry 3 --max-time 60 "$INSTALLER_URL" -o "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  bash "$tmp" "$@"; rc=$?
  rm -f "$tmp"
  return $rc
}

install_core() {
  info "$(t installing_core)"
  run_official_installer || die "$(t core_failed)"
  [[ -x $HY_BIN ]] || die "$(t core_failed)"
}

prepare_dirs() {
  mkdir -p "$HY_DIR" "$HY_BACKUP_DIR" "$HY_ACME_DIR"
  chmod 700 "$HY_BACKUP_DIR"
  if id hysteria >/dev/null 2>&1; then chown -R hysteria:hysteria "$HY_DATA"; fi
}

write_config() {
  local tmp
  tmp=$(mktemp) || die "mktemp failed"
  {
    echo "# Generated by hy2.sh v$SCRIPT_VERSION on $(date '+%F %T')"
    echo "# Manual edits will be overwritten when the configuration is changed via the script."
    echo
    echo "listen: :$PORT"
    echo
    echo "acme:"
    echo "  domains:"
    echo "    - $DOMAIN"
    [[ -n $EMAIL ]] && echo "  email: $(yaml_str "$EMAIL")"
    echo "  ca: letsencrypt"
    echo "  dir: $HY_ACME_DIR"
    echo "  type: http"
    echo
    echo "auth:"
    echo "  type: password"
    echo "  password: $(yaml_str "$PASSWORD")"
    echo
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: $(yaml_str "$MASQ_URL")"
    echo "    rewriteHost: true"
    [[ $TCP_MASQ == yes ]] && echo "  listenHTTPS: :$PORT"
    case $BW_MODE in
      limit)
        # Per-client caps. Server "up" = traffic to the client (client download),
        # server "down" = traffic from the client (client upload). Only Brutal
        # connections are capped; BBR connections are not affected.
        echo
        echo "bandwidth:"
        ((BW_UP > 0)) && echo "  up: ${BW_UP} mbps"
        ((BW_DOWN > 0)) && echo "  down: ${BW_DOWN} mbps"
        ;;
      bbr)
        echo
        echo "ignoreClientBandwidth: true"
        ;;
    esac
  } >"$tmp"
  install -m 640 -o root -g "$(hy_group)" "$tmp" "$HY_CONF"
  rm -f "$tmp"
}

tune_sysctl() {
  cat >"$SYSCTL_FILE" <<'EOF'
# Added by hy2.sh: larger UDP buffers for QUIC (recommended by Hysteria)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  if sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1; then info "$(t sysctl_done)"; else warn "$(t sysctl_fail)"; fi
}

ufw_active() { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }

sync_firewall() {
  if ufw_active; then
    local opened="80/tcp $PORT/udp"
    ufw allow 80/tcp comment 'hysteria2 acme' >/dev/null
    ufw allow "$PORT/udp" comment 'hysteria2' >/dev/null
    if [[ $TCP_MASQ == yes ]]; then
      ufw allow "$PORT/tcp" comment 'hysteria2 masquerade' >/dev/null
      opened+=" $PORT/tcp"
    elif ((UFW_MANAGED)); then
      ufw delete allow "$PORT/tcp" >/dev/null 2>&1
    fi
    UFW_MANAGED=1
    info "$(t fw_ufw "$opened")"
  else
    info "$(t fw_none)"
  fi
  warn "$(t fw_cloud)"
}

# Install this script as /usr/local/bin/hy2. When run through a pipe there is
# no local file, so the published script is downloaded and validated first.
# The shortcut is replaced atomically (never left half-written).
install_shortcut() {
  local src="" tmp
  ((FROM_PIPE)) || src=$(readlink -f "$0" 2>/dev/null)
  [[ $src == "$SHORTCUT" ]] && return 0
  tmp=$(mktemp "$SHORTCUT.XXXXXX") || { warn "$(t shortcut_skip)"; return 1; }
  if [[ -f $src ]] && grep -q '^# hy2.sh - Hysteria2' "$src"; then
    cp "$src" "$tmp"
  elif ! fetch_script "$tmp" >/dev/null; then
    rm -f "$tmp"; warn "$(t shortcut_skip)"; return 1
  fi
  chmod 755 "$tmp" && mv -f "$tmp" "$SHORTCUT" && info "$(t shortcut_ok "$SHORTCUT")"
}

# Restart the service and wait until it is serving (certificate obtained).
restart_and_verify() {
  local since state logs i
  since=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl daemon-reload
  systemctl enable "$HY_SERVICE" >/dev/null 2>&1
  systemctl restart "$HY_SERVICE"
  printf '\033[32m[INFO]\033[0m %s' "$(t starting)"
  for ((i = 0; i < 90; i++)); do
    sleep 2
    printf '.'
    logs=$(journalctl -u "$HY_SERVICE" --since "$since" --no-pager -o cat 2>/dev/null)
    state=$(systemctl is-active "$HY_SERVICE" 2>/dev/null)
    # Only trust the log line: the UDP socket is opened before ACME finishes.
    if grep -q 'server up and running' <<<"$logs"; then
      echo
      info "$(t start_ok)"
      return 0
    fi
    if grep -q 'FATAL' <<<"$logs" || [[ $state == failed || $state == inactive ]]; then
      echo
      err "$(t start_fail)"
      tail -n 30 <<<"$logs"
      warn "$(t fail_hints)"
      return 1
    fi
  done
  echo
  err "$(t start_timeout)"
  tail -n 30 <<<"$logs"
  warn "$(t fail_hints)"
  return 1
}

backup_config() {
  LAST_BACKUP_TS=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$HY_BACKUP_DIR"
  cp -a "$HY_CONF" "$HY_BACKUP_DIR/config.yaml.$LAST_BACKUP_TS"
  cp -a "$HY_STATE" "$HY_BACKUP_DIR/state.env.$LAST_BACKUP_TS"
  # keep the 10 most recent backups
  local f
  while read -r f; do
    [[ -n $f ]] && rm -f "$f" "${f/config.yaml./state.env.}"
  done < <(ls -1t "$HY_BACKUP_DIR"/config.yaml.* 2>/dev/null | tail -n +11)
}

restore_backup() {
  local ts=$1
  install -m 640 -o root -g "$(hy_group)" "$HY_BACKUP_DIR/config.yaml.$ts" "$HY_CONF"
  install -m 600 "$HY_BACKUP_DIR/state.env.$ts" "$HY_STATE"
  load_state
}

# Write config from current variables, restart, roll back on failure.
apply_change() {
  backup_config
  write_config
  save_state
  sync_firewall
  if restart_and_verify; then
    show_share
    return 0
  fi
  restore_backup "$LAST_BACKUP_TS"
  sync_firewall >/dev/null
  restart_and_verify >/dev/null
  warn "$(t backup_restored)"
  return 1
}

# ---------------------------------------------------------------------------
# Versioning / self-update
# ---------------------------------------------------------------------------
# ver_cmp A B -> prints -1, 0 or 1 (numeric dotted versions, e.g. 1.10.0 > 1.9.2)
ver_cmp() {
  local i a b x y
  IFS=. read -ra x <<<"$1"
  IFS=. read -ra y <<<"$2"
  for ((i = 0; i < 3; i++)); do
    a=$((10#${x[i]:-0})) b=$((10#${y[i]:-0}))
    ((a > b)) && { echo 1; return; }
    ((a < b)) && { echo -1; return; }
  done
  echo 0
}
ver_lt() { [[ $(ver_cmp "$1" "$2") == -1 ]]; }

# Version that manages the current installation. v1.4.0+ records it in the
# state file; v1.3.1 is recognised by its config header plus BW_MODE in state.
detect_installed_version() {
  [[ -f $HY_STATE ]] || return 1
  if [[ -n $INSTALLED_VERSION ]]; then echo "$INSTALLED_VERSION"; return; fi
  local v
  v=$(sed -n '1s/^# Generated by hy2.sh v\([0-9.]*\) .*/\1/p' "$HY_CONF" 2>/dev/null)
  if [[ -n $v ]] && grep -q '^BW_MODE=' "$HY_STATE"; then echo "$v"; else echo "${v:-unknown}"; fi
}

# none | partial | legacy | newer | current
#   legacy : installed by a version older than MIN_UPGRADE_VERSION
#   newer  : installed by a newer version than this script
version_state() {
  local v
  if ! is_installed || [[ ! -f $HY_STATE ]]; then
    if [[ -x $HY_BIN || -d $HY_DIR ]]; then echo partial; else echo none; fi
    return
  fi
  v=$(detect_installed_version)
  if [[ $v == unknown ]] || ver_lt "$v" "$MIN_UPGRADE_VERSION"; then echo legacy
  elif ver_lt "$SCRIPT_VERSION" "$v"; then echo newer
  else echo current; fi
}

legacy_notice() {
  local v
  v=$(detect_installed_version)
  if [[ $v == unknown ]]; then v=$(t ver_unknown); else v="v$v"; fi
  warn "$(t ver_legacy1 "$v" "$MIN_UPGRADE_VERSION")"
  warn "$(t ver_legacy2)"
}

# Take over an installation made by an older (supported) version: record the
# new version in the state file and refresh the 'hy2' shortcut. The Hysteria
# config and the service are left untouched, so the node stays the same.
# Future format migrations go here, keyed on $from.
adopt_installation() {
  local from
  [[ $(version_state) == current ]] || return 0
  from=$(detect_installed_version)
  [[ $from == "$SCRIPT_VERSION" ]] && { sync_shortcut; return 0; }
  save_state
  sync_shortcut
  info "$(t ver_adopted "$from" "$SCRIPT_VERSION")"
}

# script_file_version FILE -> SCRIPT_VERSION declared in FILE
script_file_version() { sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

# Keep /usr/local/bin/hy2 at least as new as this script (it may be missing,
# outdated, or not a hy2.sh at all).
sync_shortcut() {
  local v
  v=$(script_file_version "$SHORTCUT")
  [[ -n $v ]] && ! ver_lt "$v" "$SCRIPT_VERSION" && return 0
  install_shortcut
}

# fetch_script FILE -> download and validate the latest script; prints version
fetch_script() {
  local v
  curl -fsSL --max-time "${2:-20}" "$SCRIPT_URL" -o "$1" 2>/dev/null || { err "$(t su_fetch_fail "$SCRIPT_URL")"; return 1; }
  v=$(script_file_version "$1")
  if [[ -z $v ]] || ! grep -q '^# hy2.sh - Hysteria2' "$1" || ! bash -n "$1" 2>/dev/null; then
    err "$(t su_invalid)"; return 1
  fi
  echo "$v"
}

# Quick, silent check used by the menu (skipped with HY2_NO_UPDATE_CHECK=1).
check_remote_version() {
  [[ -n ${HY2_NO_UPDATE_CHECK:-} ]] && return 0
  REMOTE_VERSION=$(curl -fsSL --max-time 3 "$SCRIPT_URL" 2>/dev/null |
    sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' | head -n 1)
}

update_available() { [[ -n $REMOTE_VERSION ]] && ver_lt "$SCRIPT_VERSION" "$REMOTE_VERSION"; }

# self_update [--yes] - replace the hy2 shortcut with the latest script and
# restart into it. The new version then adopts the installation on start.
self_update() {
  local tmp v
  info "$(t su_checking)"
  tmp=$(mktemp "$SHORTCUT.XXXXXX") || return 1
  if ! v=$(fetch_script "$tmp"); then rm -f "$tmp"; return 1; fi
  if ! ver_lt "$SCRIPT_VERSION" "$v"; then
    info "$(t su_latest "$SCRIPT_VERSION")"; rm -f "$tmp"; sync_shortcut; return 0
  fi
  if [[ $1 != --yes ]] && ! confirm "$(t su_confirm "$SCRIPT_VERSION" "$v")" y; then
    rm -f "$tmp"; info "$(t aborted)"; return 0
  fi
  chmod 755 "$tmp" && mv -f "$tmp" "$SHORTCUT" || { rm -f "$tmp"; return 1; }
  info "$(t su_done "$v")"
  # Hand over to the new version; it adopts the installation when it starts.
  [[ $CMD == menu ]] && HY2_NO_UPDATE_CHECK=1 exec bash "$SHORTCUT" --lang "$UI_LANG"
  exit 0
}

# Refuse commands that would modify an installation this script cannot manage.
require_manageable() {
  case $(version_state) in
    legacy) legacy_notice; return 1 ;;
    newer) err "$(t ver_newer "$(detect_installed_version)" "curl -fsSL $SCRIPT_URL | sudo bash")"; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_install() {
  require_manageable || return 1
  check_os
  if is_installed; then
    load_state
    confirm "$(t already_installed)" n || { info "$(t aborted)"; return 0; }
  fi
  install_deps
  check_ports
  collect_domain
  collect_email
  collect_masq
  collect_password keep
  collect_name
  collect_bandwidth
  print_summary
  confirm "$(t proceed)" y || { info "$(t aborted)"; return 0; }

  install_core
  prepare_dirs
  tune_sysctl
  info "$(t writing_config)"
  write_config
  sync_firewall
  save_state
  install_shortcut
  if restart_and_verify; then
    show_share
    info "$(t install_done)"
  else
    return 1
  fi
}

do_update() {
  need_installed || return 1
  require_manageable || return 1
  local old new
  old=$(core_version)
  info "$(t updating)"
  run_official_installer || { err "$(t core_failed)"; return 1; }
  new=$(core_version)
  info "$(t update_done "${old:--}" "${new:--}")"
  prepare_dirs
  restart_and_verify
}

do_uninstall() {
  if [[ ! -x $HY_BIN && ! -d $HY_DIR ]]; then err "$(t not_installed)"; return 1; fi
  load_state
  confirm "$(t uninstall_confirm)" n || { info "$(t aborted)"; return 0; }
  systemctl disable --now "$HY_SERVICE" >/dev/null 2>&1
  run_official_installer --remove || warn "$(t remove_warn)"
  if ((UFW_MANAGED)) && ufw_active; then
    ufw delete allow 80/tcp >/dev/null 2>&1
    ufw delete allow "$PORT/udp" >/dev/null 2>&1
    ufw delete allow "$PORT/tcp" >/dev/null 2>&1
  fi
  rm -rf "$HY_DIR" "$HY_DATA"
  rm -f "$HY_BIN" /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
  rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service
  rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
  userdel hysteria >/dev/null 2>&1
  rm -f "$SYSCTL_FILE"
  systemctl daemon-reload
  info "$(t uninstall_done)"
  rm -f "$SHORTCUT"
  exit 0
}

show_share() {
  need_installed || return 1
  title "$(t share_title)"
  echo "hysteria2://$(urlencode "$PASSWORD")@$DOMAIN:$PORT/?sni=$DOMAIN#$(urlencode "$NODE_NAME")"
}

show_status() {
  need_installed || return 1
  systemctl status "$HY_SERVICE" --no-pager -l 2>/dev/null | head -n 12
  title "$(t listening)"
  ss -H -ulnp "sport = :$PORT" 2>/dev/null
  ss -H -tlnp "sport = :$PORT" 2>/dev/null
}

show_logs() {
  need_installed || return 1
  info "$(t logs_hint)"
  trap ':' INT
  journalctl -u "$HY_SERVICE" -n 50 -f --no-pager
  trap - INT
}

find_cert() { find "$HY_ACME_DIR" -type f -name "$DOMAIN.crt" 2>/dev/null | head -n 1; }

show_cert_info() {
  need_installed || return 1
  info "$(t cert_auto)"
  local crt end end_ts
  crt=$(find_cert)
  if [[ -z $crt ]]; then warn "$(t cert_not_found)"; return 0; fi
  echo "  $(t cert_path): $crt"
  openssl x509 -in "$crt" -noout -subject -issuer -startdate -enddate | sed 's/^/  /'
  end=$(openssl x509 -in "$crt" -noout -enddate | cut -d= -f2)
  if end_ts=$(date -d "$end" +%s 2>/dev/null); then
    echo "  $(t cert_days "$(((end_ts - $(date +%s)) / 86400))")"
  fi
}

reissue_cert() {
  need_installed || return 1
  confirm "$(t reissue_confirm)" n || return 0
  systemctl stop "$HY_SERVICE"
  find "$HY_ACME_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/certificates/*' -name "$DOMAIN" \
    -exec rm -rf {} + 2>/dev/null
  restart_and_verify
}

# ---------------------------------------------------------------------------
# Menus
# ---------------------------------------------------------------------------
# Menu engine. Layout and behaviour follow docs/menu-standard.md:
#   builder function  -> declares items for the current state (menu_item ...)
#   menu_loop         -> renders, reads one choice, dispatches, repeats
# Item kinds: act = action (pause afterwards), sub = submenu (no pause),
#             danger = destructive action (shown in red, pause afterwards).
MENU_KIND=() MENU_FN=() MENU_TXT=() MENU_MAP=() MENU_MSG=""

menu_begin()   { MENU_KIND=(); MENU_FN=(); MENU_TXT=(); }
menu_section() { MENU_KIND+=(sec); MENU_FN+=(""); MENU_TXT+=("$1"); }
menu_item()    { MENU_KIND+=("$1"); MENU_FN+=("$2"); MENU_TXT+=("$3"); }

# managed = installed by this script; partial = core/config present but not
# manageable (foreign install or leftovers); none = nothing installed.
install_state() { version_state; }

toggle_lang() { if [[ $UI_LANG == zh ]]; then UI_LANG=en; else UI_LANG=zh; fi; }

# read_choice VAR - trimmed, lower-cased input; returns 1 on EOF.
read_choice() {
  local __c
  read -rp "$(t choose): " __c || return 1
  __c=${__c//[[:space:]]/}
  printf -v "$1" '%s' "${__c,,}"
}

print_header() {
  local st ver="-" auto="-"
  local vs
  vs=$(install_state)
  case $vs in
    current | legacy | newer | partial)
      if systemctl is-active --quiet "$HY_SERVICE"; then
        st="\033[32m● $(t st_running)\033[0m"
      else
        st="\033[31m● $(t st_stopped)\033[0m"
      fi
      ver=$(core_version)
      if systemctl is-enabled --quiet "$HY_SERVICE" 2>/dev/null; then auto=$(t yes); else auto=$(t no); fi
      [[ $vs == partial ]] && st+=" \033[33m($(t st_partial))\033[0m"
      [[ $vs == legacy ]] && st+=" \033[31m($(t ver_legacy_short))\033[0m"
      ;;
    none) st="\033[33m● $(t st_notinst)\033[0m" ;;
  esac
  echo "=============================================="
  echo "   $(t m_title)  v$SCRIPT_VERSION"
  echo -e "   $(t lbl_status): $st   $(t lbl_version): ${ver:--}   $(t lbl_autostart): $auto"
  [[ -f $HY_STATE && -n $DOMAIN ]] && echo "   $(t lbl_endpoint): $DOMAIN:$PORT/udp"
  if update_available; then echo -e "   \033[33m$(t ver_new_avail "$REMOTE_VERSION")\033[0m"; fi
  echo "=============================================="
  [[ $vs == legacy ]] && legacy_notice
  [[ $vs == newer ]] && err "$(t ver_newer "$(detect_installed_version)" "curl -fsSL $SCRIPT_URL | sudo bash")"
}

# menu_render HEADING - HEADING is empty for the main menu.
menu_render() {
  local i n=0
  MENU_MAP=()
  clear
  print_header
  [[ -n $1 ]] && echo -e " \033[36m$1\033[0m"
  for i in "${!MENU_KIND[@]}"; do
    case ${MENU_KIND[i]} in
      sec) echo " ${MENU_TXT[i]}" ;;
      danger) n=$((n + 1)); MENU_MAP[n]=$i; printf '  %2d. \033[31m%s\033[0m\n' "$n" "${MENU_TXT[i]}" ;;
      *) n=$((n + 1)); MENU_MAP[n]=$i; printf '  %2d. %s\n' "$n" "${MENU_TXT[i]}" ;;
    esac
  done
  echo "----------------------------------------------"
  echo "   L. $(t m_lang)"
  if [[ -n $1 ]]; then echo "   0. $(t back)"; else echo "   0. $(t m_exit)"; fi
  echo "=============================================="
  if [[ -n $MENU_MSG ]]; then warn "$MENU_MSG"; MENU_MSG=""; fi
}

# menu_loop BUILDER [HEADING] - main menu when HEADING is empty.
# 0 / q / EOF leaves the menu (exits the script from the main menu).
menu_loop() {
  local builder=$1 heading=$2 c idx
  while :; do
    "$builder"
    menu_render "${heading:+$(t "$heading")}"
    if ! read_choice c; then [[ -z $heading ]] && exit 0; return 0; fi
    case $c in
      '') continue ;;
      0 | q) [[ -z $heading ]] && exit 0; return 0 ;;
      l) toggle_lang; continue ;;
    esac
    idx=""
    [[ $c =~ ^[1-9][0-9]*$ ]] && idx=${MENU_MAP[c]:-}
    if [[ -z $idx ]]; then MENU_MSG="$(t invalid_choice): $c"; continue; fi
    echo
    if [[ ${MENU_KIND[idx]} == sub ]]; then
      "${MENU_FN[idx]}" || pause
    else
      "${MENU_FN[idx]}"
      pause
    fi
  done
}

# --- main menu --------------------------------------------------------------
build_main() {
  menu_begin
  case $(install_state) in
    current)
      menu_section "$(t m_sec_common)"
      menu_item act show_share "$(t m_share)"
      menu_item act show_status "$(t m_status)"
      menu_item act show_logs "$(t m_logs)"
      menu_section "$(t m_sec_config)"
      menu_item sub menu_modify "$(t m_modify)"
      menu_item sub menu_cert "$(t m_cert)"
      menu_item sub menu_service "$(t m_service)"
      menu_section "$(t m_sec_maint)"
      menu_item act self_update "$(t m_selfupdate)"
      menu_item act do_update "$(t m_update)"
      menu_item danger do_install "$(t m_reinstall)"
      menu_item danger do_uninstall "$(t m_uninstall)"
      ;;
    legacy)
      menu_item act show_share "$(t m_share)"
      menu_item danger do_uninstall "$(t m_uninstall)"
      ;;
    newer)
      menu_item act show_share "$(t m_share)"
      menu_item act self_update "$(t m_selfupdate)"
      ;;
    partial)
      menu_item act do_install "$(t m_install)"
      menu_item act self_update "$(t m_selfupdate)"
      menu_item danger do_uninstall "$(t m_uninstall)"
      ;;
    none)
      menu_item act do_install "$(t m_install)"
      menu_item act self_update "$(t m_selfupdate)"
      ;;
  esac
}

# Check for a newer script once per menu session and offer to update.
main_menu() {
  ((FROM_PIPE)) || check_remote_version
  if update_available && [[ -t 0 ]] && confirm "$(t su_prompt "$REMOTE_VERSION" "$SCRIPT_VERSION")" y; then
    self_update --yes
  fi
  menu_loop build_main
}

# --- modify -----------------------------------------------------------------
modify_password() { collect_password new; apply_change; }

modify_masq() {
  local old=$MASQ_URL
  collect_masq
  if [[ $MASQ_URL == "$old" ]]; then info "$(t no_change)"; else apply_change; fi
}

modify_domain() {
  local old=$DOMAIN
  collect_domain
  if [[ $DOMAIN == "$old" ]]; then info "$(t no_change)"; return 0; fi
  # masquerade site must not point at the new domain
  [[ $(url_host "$MASQ_URL") == "$DOMAIN" ]] && collect_masq
  apply_change
}

modify_name() {
  local old=$NODE_NAME
  ask NODE_NAME "$(t ask_name)" "$NODE_NAME"
  NODE_NAME=${NODE_NAME:-$old}
  save_state; info "$(t saved)"; show_share
}

toggle_tcp_masq() {
  local users
  if [[ $TCP_MASQ == yes ]]; then
    TCP_MASQ=no
  else
    users=$(port_users t "$PORT")
    if [[ -n $users ]]; then err "$(t port_busy "$PORT" tcp)"; echo "$users"; return 1; fi
    TCP_MASQ=yes
  fi
  apply_change && info "$(t tcpmasq_now "$(on_off "$TCP_MASQ")")"
}

modify_bw() {
  local old="$BW_MODE $BW_UP $BW_DOWN"
  collect_bandwidth
  if [[ "$BW_MODE $BW_UP $BW_DOWN" == "$old" ]]; then info "$(t no_change)"; else apply_change; fi
}

build_modify() {
  menu_begin
  menu_item act modify_password "$(t mm_password)"
  menu_item act modify_masq "$(t mm_masq)   ($(t current): $MASQ_URL)"
  menu_item act modify_domain "$(t mm_domain)   ($(t current): $DOMAIN)"
  menu_item act modify_name "$(t mm_name)   ($(t current): $NODE_NAME)"
  menu_item act toggle_tcp_masq "$(t mm_tcpmasq)   ($(t current): $(on_off "$TCP_MASQ"))"
  menu_item act modify_bw "$(t mm_bw)   ($(t current): $(bw_label))"
}

menu_modify() { need_installed || return 1; require_manageable || return 1; menu_loop build_modify m_modify_h; }

# --- certificate --------------------------------------------------------------
build_cert() {
  menu_begin
  menu_item act show_cert_info "$(t mc_info)"
  menu_item danger reissue_cert "$(t mc_reissue)"
}

menu_cert() { need_installed || return 1; require_manageable || return 1; menu_loop build_cert m_cert_h; }

# --- service ------------------------------------------------------------------
service_stop() { systemctl stop "$HY_SERVICE" && info "$(t stopped_ok)"; }

# Only offer what makes sense for the current service state.
build_service() {
  menu_begin
  if systemctl is-active --quiet "$HY_SERVICE"; then
    menu_item act restart_and_verify "$(t ms_restart)"
    menu_item act service_stop "$(t ms_stop)"
  else
    menu_item act restart_and_verify "$(t ms_start)"
  fi
}

menu_service() { need_installed || return 1; require_manageable || return 1; menu_loop build_service m_service_h; }

usage() {
  cat <<EOF
hy2.sh v$SCRIPT_VERSION - Hysteria2 installer & manager

Usage: hy2 [command] [options]

Commands:
  menu         Interactive menu (default)
  install      Install and configure Hysteria2
  link         Show the node link
  status       Show service status
  update       Update Hysteria2 core
  self-update  Update this management script (keeps the node configuration)
  uninstall    Remove Hysteria2

Options:
  --lang en|zh         UI language (default: en, or env HY2_LANG)
  --domain DOMAIN      Domain bound to this server
  --masq URL           Your masquerade site URL
  --email EMAIL        Email for Let's Encrypt (optional)
  --password PASS      Proxy password (default: random)
  --name NAME          Node name shown in clients
  --bw-mode MODE       Bandwidth mode (default: client):
                         client  clients decide, no server limit (recommended)
                         limit   per-client limits from --up / --down
                         bbr     force BBR, ignore client bandwidth settings
  --up MBPS            Server UPLOAD limit = client DOWNLOAD limit (0 = no limit)
  --down MBPS          Server DOWNLOAD limit = client UPLOAD limit (0 = no limit)
                       Limits only apply to clients using Brutal. --up/--down
                       without --bw-mode imply "limit" ("--up 0 --down 0" = bbr).
  -y, --yes            Answer yes to all confirmations
  -h, --help           Show this help
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      menu | install | link | status | update | self-update | uninstall) CMD=$1 ;;
      --lang | --domain | --masq | --email | --password | --name | --up | --down | --bw-mode)
        [[ $# -ge 2 ]] || die "$(t missing_val "$1")"
        case $1 in
          --lang) UI_LANG=$2; LANG_SET=1 ;;
          --domain) OPT_DOMAIN=$2 ;;
          --masq) OPT_MASQ=$2 ;;
          --email) OPT_EMAIL=$2; OPT_EMAIL_SET=1 ;;
          --password) OPT_PASSWORD=$2 ;;
          --name) OPT_NAME=$2 ;;
          --up) OPT_UP=$2 ;;
          --down) OPT_DOWN=$2 ;;
          --bw-mode) OPT_BW_MODE=$2 ;;
        esac
        shift ;;
      -y | --yes) ASSUME_YES=1 ;;
      -h | --help) usage; exit 0 ;;
      *) err "$(t unknown_arg "$1")"; usage; exit 1 ;;
    esac
    shift
  done
  case ${UI_LANG,,} in zh | cn | zh_cn | zh-cn) UI_LANG=zh ;; *) UI_LANG=en ;; esac
}

main() {
  parse_args "$@"
  require_root
  if [[ -z $LANG_SET && -t 0 ]] && ((!ASSUME_YES)) && [[ $CMD == menu || $CMD == install ]]; then
    choose_language
  fi
  load_state
  adopt_installation
  case $CMD in
    menu) main_menu ;;
    self-update) if ((ASSUME_YES)); then self_update --yes; else self_update; fi ;;
    install) do_install ;;
    link) show_share ;;
    status) show_status ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
  esac
}

# When the script itself arrives on stdin (curl ... | bash), stdin is the pipe:
# read prompts from the terminal instead. Without a terminal (e.g. cloud-init),
# keep stdin so non-interactive "install ... --yes" still works.
if [[ -z ${BASH_SOURCE[0]:-} && ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
  main "$@" </dev/tty
else
  main "$@"
fi
