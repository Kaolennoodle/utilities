#!/usr/bin/env bash
#
# nodectl.sh - Hysteria2 & VLESS-REALITY unified installer & manager
#
# Target    : Ubuntu 26.04 LTS, run as root
# Cores     : official Hysteria2 core (UDP/QUIC + built-in ACME & HTTPS proxy)
#             official sing-box core  (VLESS + XTLS-Vision + REALITY, Mihomo-ready)
# Features  : single or dual protocol deployment, shared port 443 (UDP HY2 + TCP VLESS)
#             with zero-Nginx loopback masquerade reuse, automatic seamless migration
#             from hy2.sh (>= v1.3.1), node share links, BBR, rollback, EN / 中文 UI.
#
# Usage:
#   curl -fsSL <raw-url>/nodectl.sh | bash -s -- --lang zh
#   bash nodectl.sh                                interactive menu
#   bash nodectl.sh install both --domain hy.example.com --masq https://www.example.com --yes
#   bash nodectl.sh install hy2  --domain hy.example.com --masq https://www.example.com --yes
#   bash nodectl.sh install vless --sni www.apple.com --yes
#   nodectl link | status | update | self-update | changelog | bbr [on|off|status] | uninstall
#

SCRIPT_VERSION="2.0.0"
# Oldest installation version (including legacy hy2.sh) this script can adopt in place.
MIN_UPGRADE_VERSION="1.3.1"
SCRIPT_URL="https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/nodectl.sh"

FROM_PIPE=0
[[ -z ${BASH_SOURCE[0]:-} ]] && FROM_PIPE=1

# Shortcuts & unified state
SHORTCUT=/usr/local/bin/nodectl
LEGACY_HY2_SHORTCUT=/usr/local/bin/hy2
STATE_DIR=/etc/nodectl
STATE_FILE=$STATE_DIR/state.env
BACKUP_DIR=$STATE_DIR/backup

# Hysteria2 paths
HY_BIN=/usr/local/bin/hysteria
HY_DIR=/etc/hysteria
HY_CONF=$HY_DIR/config.yaml
LEGACY_HY_STATE=$HY_DIR/.hy2-script.env
HY_DATA=/var/lib/hysteria
HY_ACME_DIR=$HY_DATA/acme
HY_SERVICE=hysteria-server.service
HY_SYSCTL_FILE=/etc/sysctl.d/99-hysteria.conf
HY_INSTALLER_URL=https://get.hy2.sh/

# sing-box (VLESS-REALITY) paths
SB_DIR=/etc/sing-box
SB_CONF=$SB_DIR/config.json
SB_DATA=/var/lib/sing-box
SB_SERVICE=sing-box.service
SB_DROPIN_DIR=/etc/systemd/system/sing-box.service.d
SB_DROPIN_FILE=$SB_DROPIN_DIR/nodectl.conf
SB_APT_KEY=/etc/apt/keyrings/sagernet.asc
SB_APT_SRC=/etc/apt/sources.list.d/sagernet.sources
SB_GPG_URL=https://sing-box.app/gpg.key
SB_INSTALLER_URL=https://sing-box.app/install.sh

# Kernel TCP BBR paths
BBR_FILE=/etc/sysctl.d/99-nodectl-bbr.conf
BBR_MODLOAD=/etc/modules-load.d/nodectl-bbr.conf
LEGACY_BBR_FILE=/etc/sysctl.d/99-hy2-bbr.conf
LEGACY_BBR_MODLOAD=/etc/modules-load.d/hy2-bbr.conf
PROC_NET=/proc/sys/net

ALLOWED_PORTS=(443 8443 2053 2083 2087 2096)
ALLOWED_FPS=(chrome firefox safari ios edge random)

# Persisted state: Hysteria2
HY_ENABLED="no"
HY_DOMAIN="" HY_PORT=443 HY_EMAIL="" HY_PASSWORD="" HY_MASQ_URL="" HY_NAME=""
HY_TCP_MASQ="yes" HY_LOCAL_PORT=18443
HY_BW_MODE="client" HY_BW_UP=0 HY_BW_DOWN=0

# Persisted state: VLESS-REALITY
VL_ENABLED="no"
VL_PORT=443 VL_UUID="" VL_PRIVATE_KEY="" VL_PUBLIC_KEY="" VL_SHORT_ID=""
VL_FP="chrome" VL_MASQ_MODE="external" VL_SNI=""
VL_ADDR_MODE="auto" VL_CUSTOM_ADDR="" VL_NAME=""

# Runtime / CLI variables
INSTALLED_VERSION="" REMOTE_VERSION=""
MIGRATED_FROM="" UPGRADED_NOTICE_SHOWN=0
CMD=menu TARGET="" BBR_ACTION=status
_DEFAULT_LANG=${NODECTL_LANG:-${HY2_LANG:-en}}
_DEFAULT_LANG_SET=""
[[ -n ${NODECTL_LANG:-}${HY2_LANG:-} ]] && _DEFAULT_LANG_SET=1
UI_LANG=$_DEFAULT_LANG LANG_SET=$_DEFAULT_LANG_SET ASSUME_YES=0

OPT_DOMAIN="" OPT_PORT="" OPT_HY_PORT="" OPT_VL_PORT=""
OPT_MASQ="" OPT_EMAIL="" OPT_EMAIL_SET="" OPT_PASSWORD=""
OPT_NAME="" OPT_HY_NAME="" OPT_VL_NAME=""
OPT_UP="" OPT_DOWN="" OPT_BW_MODE=""
OPT_SNI="" OPT_VL_MASQ="" OPT_UUID="" OPT_FP="" OPT_ADDR=""

PUB_IP4="" PUB_IP6="" IPS_DETECTED="" LAST_BACKUP_TS=""

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
  [none]="(none)"
  [on]="on"
  [off]="off"
  [yes]="yes"
  [no]="no"
  [current]="current"
  [port_default]="default"
  [recommended]="recommended"
  [st_running]="running"
  [st_stopped]="stopped"
  [st_notinst]="not installed"
  [st_partial]="not managed by this script"
  [aborted]="Aborted."
  [no_change]="No change."
  [saved]="Saved."
  [press_enter]="Press Enter to continue..."
  [invalid_choice]="Invalid choice"
  [choose]="Please choose"
  [back]="Back"
  [m_exit]="Exit"
  [m_lang]="切换到中文"
  [unknown_arg]="Unknown argument: %s"
  [missing_val]="Option %s requires a value."
  [continue_anyway]="Continue anyway?"
  [use_anyway]="Use this anyway?"
  [proceed]="Proceed with installation?"
  [backup_restored]="Change failed, the previous configuration has been restored."

  # Domain / DNS / Masquerade / REALITY checks
  [ask_domain]="Domain bound to this server (e.g. hy.example.com)"
  [bad_domain]="Invalid domain format."
  [checking_dns]="Checking DNS records of %s ..."
  [server_ip]="Server public IP : IPv4=%s  IPv6=%s"
  [dns_records]="Domain resolves to: A=%s  AAAA=%s"
  [dns_ok]="DNS check passed."
  [dns_mismatch]="The domain does not resolve to this server."
  [dns_cf_hint]="If you use Cloudflare, set the record to 'DNS only' (grey cloud). Proxied records cannot carry Hysteria's UDP or REALITY's raw TLS traffic."
  [dns_aaaa_warn]="The domain has an AAAA record that does not point to this server. Let's Encrypt prefers IPv6, so issuance will likely fail. Remove or fix the AAAA record."
  [ask_email]="Email for Let's Encrypt (optional, Enter to skip)"
  [bad_email]="Invalid email address (use a plain ASCII address such as me@example.com)."
  [ask_masq]="Your Hysteria2 masquerade site URL (e.g. https://www.example.com)"
  [bad_url]="Invalid URL. Spaces, quotes and backslashes are not allowed."
  [masq_loop]="The masquerade site must not use the same domain as this server."
  [masq_http_warn]="A plain HTTP masquerade site is not recommended; prefer HTTPS."
  [checking_masq]="Checking masquerade site %s ..."
  [masq_ok]="Masquerade site is reachable (HTTP %s)."
  [masq_redirect]="The site redirects to: %s  -- consider using the final URL directly."
  [masq_fail]="Masquerade site check failed (HTTP %s). It must be reachable from this server with a valid certificate."

  # REALITY checks
  [ask_sni]="External REALITY target domain (TLS 1.3 & non-CDN, e.g. www.apple.com)"
  [sni_self_err]="External REALITY target must not resolve to this server's own IP."
  [checking_sni]="Checking REALITY TLS 1.3 handshake with %s:443 ..."
  [sni_ok]="REALITY target check passed (TLS 1.3%s)."
  [sni_no_h2]="Target supports TLS 1.3, but HTTP/2 (h2) ALPN was not negotiated (h2 is recommended)."
  [sni_cf_warn]="Target %s appears to be behind Cloudflare / CDN. CDN sites are strongly discouraged as external REALITY targets."
  [sni_fail]="Target %s:443 failed TLS 1.3 handshake or certificate verification."
  [vl_masq_title]="VLESS REALITY masquerade mode"
  [vl_masq_hy2]="Reuse local Hysteria2 masquerade & domain (%s) (recommended)"
  [vl_masq_ext]="Use an independent external TLS 1.3 domain"
  [vl_masq_choose]="Choose masquerade mode [1-2]"
  [vl_masq_hy2_lbl]="Reuse HY2 (%s -> 127.0.0.1:%s)"
  [vl_masq_ext_lbl]="External (%s:443)"
  [vl_adopt_hy2_ask]="Switch existing VLESS node to reuse Hysteria2's domain & masquerade (%s)?"

  # Credentials / FP / Endpoint / Names
  [ask_password]="Hysteria2 password (Enter = random)"
  [ask_password_keep]="Hysteria2 password (Enter = keep current)"
  [bad_password]="Password must be 8-128 characters of: letters, digits, . _ ~ -"
  [ask_uuid]="VLESS UUID (Enter = random)"
  [ask_uuid_keep]="VLESS UUID (Enter = keep current)"
  [bad_uuid]="Invalid UUID format (expected xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx)."
  [fp_title]="VLESS client uTLS fingerprint"
  [fp_choose]="Choose fingerprint [1-%s]"
  [bad_fp]="Invalid fingerprint: %s (allowed: %s)."
  [ask_hy_name]="Hysteria2 node name shown in clients"
  [ask_vl_name]="VLESS node name shown in clients"
  [addr_title]="VLESS client connection address"
  [addr_auto]="Auto public IP (%s)"
  [addr_ip4]="Public IPv4 (%s)"
  [addr_ip6]="Public IPv6 ([%s])"
  [addr_custom]="Custom domain or IP"
  [addr_hy2_note]="VLESS is reusing Hysteria2 masquerade; connection address uses domain: %s"
  [ask_custom_addr]="Enter custom domain or IP address"
  [bad_addr]="Invalid domain or IP address."
  [no_pub_ip]="Could not detect a public IPv4 or IPv6 address. Specify --addr manually."

  # Ports
  [port_title_both]="Shared listen port (UDP for Hysteria2 + TCP for VLESS)"
  [port_intro_both]="Hysteria2 (UDP) and VLESS-REALITY (TCP) share this HTTPS port seamlessly."
  [port_title_hy]="Hysteria2 listen port (UDP proxy & TCP masquerade)"
  [port_intro_hy]="Only common HTTPS ports are supported."
  [port_title_vl]="VLESS listen port (TCP REALITY)"
  [port_intro_vl]="Port 443 is strongly recommended for best anti-blocking camouflage."
  [port_choose]="Choose port [1-%s] (or enter port number)"
  [bad_port]="Invalid port. Allowed HTTPS ports: %s."
  [port_busy]="Port %s/%s is already in use:"
  [port_retry]="Please choose another port."
  [port80_required]="TCP 80 is required for Hysteria2 ACME certificate issuance (HTTP-01). Free it and try again."
  [udp_port_required]="UDP %s is required by Hysteria2. Free it or choose another port."
  [tcp_port_required]="TCP %s is required by VLESS. Free it or choose another port."
  [tcp_port_busy]="TCP %s is busy; Hysteria2's public TCP masquerade listener cannot use this port."
  [tcp_port_continue]="Continue with Hysteria2 public TCP masquerade disabled? (Choose N to pick another port)"
  [tcpmasq_now]="Hysteria2 public TCP masquerade listener: %s"
  [tcpmasq_loopback]="Managed automatically on 127.0.0.1:%s (shared with VLESS on TCP %s)"

  # Bandwidth
  [bw_title]="Hysteria2 bandwidth / congestion control"
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
  [bw_client]="Clients decide (no server limit)"
  [bw_limit]="Server limit: upload %s (= client download) / download %s (= client upload)"
  [bw_bbr]="Force BBR (client bandwidth ignored)"
  [bw_unlimited]="unlimited"

  # Summary
  [install_mode_title]="Select deployment mode"
  [im_both]="Install Hysteria2 + VLESS together (recommended, share port 443 & masquerade)"
  [im_hy2]="Install Hysteria2 only"
  [im_vless]="Install VLESS (REALITY) only"
  [summary_title]="Installation summary"
  [sum_mode]="Protocols"
  [sum_domain]="Domain"
  [sum_email]="ACME email"
  [sum_hy_listen]="HY2 listen"
  [sum_hy_masq]="HY2 masquerade"
  [sum_hy_pass]="HY2 password"
  [sum_hy_bw]="HY2 bandwidth"
  [sum_hy_name]="HY2 node name"
  [sum_vl_listen]="VLESS listen"
  [sum_vl_masq]="VLESS REALITY"
  [sum_vl_uuid]="VLESS UUID"
  [sum_vl_fp]="VLESS uTLS FP"
  [sum_vl_addr]="VLESS address"
  [sum_vl_name]="VLESS name"

  # Core install / service / firewall
  [installing_hy]="Installing Hysteria2 core via official installer ..."
  [hy_core_failed]="Failed to install Hysteria2 core."
  [installing_sb]="Installing sing-box core via official repository ..."
  [sb_core_failed]="Failed to install sing-box core."
  [writing_config]="Writing configuration ..."
  [sb_check_fail]="sing-box configuration validation failed:"
  [sysctl_done]="UDP buffer tuning applied."
  [sysctl_fail]="Failed to apply sysctl settings (ignored)."
  [fw_ufw_manual]="ufw is active. This script does not modify ufw rules; please allow manually: %s (e.g. %s)."
  [fw_ufw_uninstall]="ufw is active. If you added firewall rules (%s), remove them manually if no longer needed."
  [fw_cloud]="Remember to allow %s in your cloud provider's security group."
  [starting_hy]="Starting Hysteria2 and verifying certificate (up to 3 minutes) "
  [hy_start_ok]="Hysteria2 is up and running."
  [hy_start_fail]="Hysteria2 failed to start. Recent logs:"
  [hy_start_timeout]="Timed out waiting for Hysteria2. Recent logs:"
  [hy_fail_hints]="Common causes: DNS not pointing here, TCP 80 blocked by security group, Let's Encrypt rate limit."
  [starting_sb]="Starting VLESS (sing-box) service ..."
  [sb_start_ok]="VLESS (sing-box) is up and running."
  [sb_start_fail]="VLESS (sing-box) failed to start. Recent logs:"
  [install_done]="Installation complete! Run 'nodectl' anytime to open the manager."
  [shortcut_ok]="Command installed: %s"
  [shortcut_skip]="Could not install 'nodectl' shortcut; run the script again later."
  [legacy_hy2_removed]="Removed legacy command '/usr/local/bin/hy2'; please use 'nodectl' from now on."

  # Installed / share / update / uninstall
  [not_installed]="No managed node is installed yet."
  [hy_not_installed]="Hysteria2 is not installed."
  [vl_not_installed]="VLESS is not installed."
  [no_state]="Existing core was not installed by this script (state file missing). Please reinstall with nodectl."
  [already_installed_hy]="Hysteria2 is already installed. Reinstall and overwrite its configuration?"
  [already_installed_vl]="VLESS is already installed. Reinstall and overwrite its configuration?"
  [share_title]="Node share link(s)"
  [updating_hy]="Updating Hysteria2 core ..."
  [updating_sb]="Updating sing-box core ..."
  [update_done]="%s core version: %s -> %s"
  [uninstall_all_confirm]="This will remove all installed proxy cores (Hysteria2 / VLESS), configs and certificates. Continue?"
  [uninstall_hy_confirm]="Remove Hysteria2, its configuration and ACME certificates?"
  [uninstall_vl_confirm]="Remove VLESS (sing-box) and its configuration?"
  [hy_uninst_vl_dep]="VLESS is currently reusing Hysteria2's local masquerade. Please set an external REALITY domain for VLESS first:"
  [hy_stop_vl_warn]="Warning: VLESS is reusing Hysteria2's local masquerade (127.0.0.1:%s). Stopping Hysteria2 will interrupt new VLESS handshakes. Stop anyway?"
  [remove_warn]="Official removal helper returned an error, cleaning up manually."
  [uninstall_hy_done]="Hysteria2 has been uninstalled."
  [uninstall_vl_done]="VLESS (sing-box) has been uninstalled."
  [uninstall_all_done]="All managed nodes and 'nodectl' have been uninstalled."

  # Keys / Certs / Logs / Status
  [cert_auto]="Certificates are issued and renewed automatically by Hysteria's built-in ACME."
  [cert_not_found]="Certificate file not found yet."
  [cert_path]="File"
  [cert_days]="Days remaining: %s"
  [reissue_confirm]="Delete current certificate and request a new one? (Let's Encrypt allows 5 duplicate certificates per week)"
  [keys_title]="VLESS REALITY keys & ShortId"
  [lbl_pubkey]="PublicKey (pbk)"
  [lbl_shortid]="ShortId (sid)"
  [reset_keys_confirm]="Regenerate REALITY keypair and ShortId? Existing VLESS client links will stop working immediately."
  [logs_hint]="Live logs, press Ctrl+C to return."
  [listening]="Listening sockets"
  [stopped_ok]="Service stopped."

  # BBR
  [m_bbr]="Kernel TCP BBR   (current: %s)"
  [bbr_title]="Kernel TCP congestion control"
  [bbr_cur]="Current algorithm: %s   queue discipline: %s"
  [bbr_scope]="Note: directly accelerates VLESS TCP tunnel traffic (recommended) and server outbound/masquerade TCP; Hysteria2 uses its own QUIC congestion control over UDP."
  [bbr_by_us]="Kernel TCP BBR is enabled by nodectl (%s)."
  [bbr_by_other]="Kernel TCP BBR is already enabled by another system configuration; nodectl has not changed it."
  [bbr_unsupported]="The kernel does not support BBR (tcp_bbr module not available)."
  [bbr_confirm_on]="Enable kernel TCP BBR (tcp_congestion_control=bbr, default_qdisc=fq)?"
  [bbr_confirm_off]="Disable kernel TCP BBR and restore the previous setting (%s)?"
  [bbr_on_ok]="Kernel TCP BBR enabled. Takes effect immediately for new TCP connections."
  [bbr_on_fail]="Failed to apply sysctl setting (e.g. OpenVZ/LXC containers cannot modify it). Nothing changed."
  [bbr_off_ok]="Kernel TCP BBR disabled, current algorithm: %s."
  [bbr_not_ours]="BBR was not enabled by nodectl, nothing to disable."
  [bbr_keep]="Also restore the kernel TCP congestion control setting (disable BBR)?"

  # Versioning / Self-update / Migration
  [ver_new_avail]="New script version available: v%s"
  [ver_legacy1]="This server was set up by an old script (%s), which cannot be upgraded in place (v%s+ required)."
  [ver_legacy2]="Please uninstall completely, then install again with nodectl. Save your node link first if needed."
  [ver_legacy_short]="too old, reinstall required"
  [ver_unknown]="an unknown older version"
  [ver_newer]="This server is managed by a newer nodectl (v%s). Run the latest script: %s"
  [ver_adopted]="nodectl upgraded: v%s -> v%s (existing node configurations unchanged)."
  [ver_migrated]="Migrated from hy2.sh v%s -> nodectl v%s (Hysteria2 node preserved without interruption)."
  [su_checking]="Checking for script updates..."
  [su_fetch_fail]="Could not download the script from %s."
  [su_invalid]="Downloaded file is not a valid nodectl.sh, update aborted."
  [su_latest]="Already up to date (v%s)."
  [su_confirm]="Update nodectl from v%s to v%s now?"
  [su_done]="Script updated to v%s, restarting..."
  [su_prompt]="A new version v%s is available (current v%s). Update now?"
  [cl_title]="Changelog (nodectl v%s)"

  # Menus
  [m_title]="Node Manager (nodectl)"
  [m_sec_common]="-- Common --"
  [m_sec_proto]="-- Protocols & Config --"
  [m_sec_maint]="-- Maintenance --"
  [m_share]="Show node link(s)"
  [m_status]="Service status"
  [m_logs]="Live logs"
  [m_logs_sub]="Live logs  >"
  [m_logs_h]="Live logs"
  [ml_hy]="Hysteria2 live logs"
  [ml_vl]="VLESS (sing-box) live logs"
  [m_hy_mgr]="Hysteria2 settings  >"
  [m_hy_mgr_h]="Hysteria2 settings"
  [m_vl_mgr]="VLESS (REALITY) settings  >"
  [m_vl_mgr_h]="VLESS (REALITY) settings"
  [m_inst_both]="Install Hysteria2 + VLESS (recommended, shared port 443)"
  [m_inst_hy]="Install Hysteria2"
  [m_inst_hy_co]="Install Hysteria2 (can share port & masquerade with VLESS)"
  [m_inst_vl]="Install VLESS (REALITY)"
  [m_inst_vl_co]="Install VLESS (REALITY) (can reuse HY2 port & masquerade)"
  [m_selfupdate]="Update management script"
  [m_changelog]="Show changelog"
  [m_update_hy]="Update Hysteria2 core"
  [m_update_sb]="Update sing-box core"
  [m_update_sub]="Update protocol cores  >"
  [m_update_h]="Update protocol cores"
  [mu_all]="Update all installed cores"
  [m_uninstall_all]="Uninstall all nodes"
  [m_reinstall_hy]="Reinstall Hysteria2 (overwrites HY2 config)"
  [m_uninstall_hy]="Uninstall Hysteria2"
  [m_reinstall_vl]="Reinstall VLESS (overwrites VLESS config)"
  [m_uninstall_vl]="Uninstall VLESS"

  [mm_hy_pass]="Change password"
  [mm_hy_port]="Change listen port"
  [mm_hy_masq]="Change masquerade site"
  [mm_hy_domain]="Change domain (re-issues certificate)"
  [mm_hy_name]="Change node name"
  [mm_hy_tcpmasq]="Toggle public TCP %s masquerade listener"
  [mm_hy_bw]="Bandwidth / congestion control"
  [m_cert]="Certificate  >"
  [m_cert_h]="Hysteria2 ACME certificate"
  [mc_info]="Show certificate info"
  [mc_reissue]="Force re-issue certificate"
  [m_service]="Start / Stop / Restart  >"
  [m_hy_service_h]="Hysteria2 service"
  [m_vl_service_h]="VLESS (sing-box) service"
  [ms_start]="Start"
  [ms_stop]="Stop"
  [ms_restart]="Restart"

  [mm_vl_uuid]="Change UUID"
  [mm_vl_port]="Change listen port"
  [mm_vl_masq]="Change masquerade mode / target"
  [mm_vl_fp]="Change client uTLS fingerprint"
  [mm_vl_addr]="Change client connection address"
  [mm_vl_name]="Change node name"
  [m_keys]="REALITY keys & ShortId  >"
  [m_keys_h]="VLESS REALITY keys & ShortId"
  [mk_info]="Show PublicKey & ShortId"
  [mk_reset]="Regenerate keypair & ShortId"
)

M_ZH=(
  [need_root]="请使用 root 权限运行此脚本（例如：%s）。"
  [no_systemd]="未检测到 systemd，本脚本依赖 systemd。"
  [os_unsupported]="不支持的系统：%s。本脚本面向 Ubuntu 26.04 LTS。"
  [os_untested]="检测到 %s。本脚本按 Ubuntu 26.04 LTS 设计，将继续执行。"
  [no_input]="未读取到输入，退出。"
  [installing_deps]="正在安装依赖：%s"
  [deps_failed]="依赖安装失败。"
  [none]="（无）"
  [on]="开启"
  [off]="关闭"
  [yes]="是"
  [no]="否"
  [current]="当前"
  [port_default]="默认"
  [recommended]="推荐"
  [st_running]="运行中"
  [st_stopped]="已停止"
  [st_notinst]="未安装"
  [st_partial]="非本脚本管理"
  [aborted]="已取消。"
  [no_change]="没有变化。"
  [saved]="已保存。"
  [press_enter]="按回车键继续……"
  [invalid_choice]="无效选项"
  [choose]="请选择"
  [back]="返回"
  [m_exit]="退出"
  [m_lang]="Switch to English"
  [unknown_arg]="未知参数：%s"
  [missing_val]="参数 %s 需要一个值。"
  [continue_anyway]="仍然继续？"
  [use_anyway]="仍然使用该设置？"
  [proceed]="确认开始安装？"
  [backup_restored]="修改失败，已自动恢复之前的配置。"

  # Domain / DNS / Masquerade / REALITY checks
  [ask_domain]="请输入已解析到本机的域名（例如 hy.example.com）"
  [bad_domain]="域名格式不正确。"
  [checking_dns]="正在检查 %s 的 DNS 解析……"
  [server_ip]="本机公网 IP：IPv4=%s  IPv6=%s"
  [dns_records]="域名解析结果：A=%s  AAAA=%s"
  [dns_ok]="DNS 解析检查通过。"
  [dns_mismatch]="域名没有解析到本机。"
  [dns_cf_hint]="如果使用 Cloudflare，请将记录设为「仅 DNS」（灰色云朵），开启代理的记录无法承载 Hysteria UDP 或 REALITY 流量。"
  [dns_aaaa_warn]="域名存在未指向本机的 AAAA 记录。Let's Encrypt 会优先通过 IPv6 验证，证书很可能申请失败，请删除或修正该记录。"
  [ask_email]="Let's Encrypt 通知邮箱（可选，直接回车跳过）"
  [bad_email]="邮箱格式不正确（请使用常规英文邮箱，如 me@example.com）。"
  [ask_masq]="请输入 Hysteria2 伪装站点 URL（例如 https://www.example.com）"
  [bad_url]="URL 格式不正确，不能包含空格、引号或反斜杠。"
  [masq_loop]="伪装站点不能与本机使用同一个域名。"
  [masq_http_warn]="不建议使用 HTTP 伪装站点，推荐使用 HTTPS。"
  [checking_masq]="正在检查伪装站点 %s ……"
  [masq_ok]="伪装站点可以访问（HTTP %s）。"
  [masq_redirect]="该站点会重定向到：%s，建议直接填写最终地址。"
  [masq_fail]="伪装站点检查失败（HTTP %s），请确认本机可以访问该站点且证书有效。"

  # REALITY checks
  [ask_sni]="请输入外部 REALITY 伪装目标域名（需支持 TLS 1.3 且非 CDN，例如 www.apple.com）"
  [sni_self_err]="外部 REALITY 目标域名不能解析到本机自身 IP。"
  [checking_sni]="正在检测 %s:443 的 REALITY TLS 1.3 握手兼容性……"
  [sni_ok]="REALITY 目标站检测通过（支持 TLS 1.3%s）。"
  [sni_no_h2]="目标站支持 TLS 1.3，但未协商出 HTTP/2 (h2)（推荐使用支持 h2 的站点）。"
  [sni_cf_warn]="检测到 %s 位于 Cloudflare / CDN 后方，强烈不建议将 CDN 站点直接作为外部 REALITY 目标（极易穿帮或被拦截）。"
  [sni_fail]="目标站 %s:443 的 TLS 1.3 握手或证书校验失败。"
  [vl_masq_title]="VLESS REALITY 伪装模式"
  [vl_masq_hy2]="复用本机 Hysteria2 伪装站与域名（%s）（推荐，抗探测最强）"
  [vl_masq_ext]="使用独立的外部 TLS 1.3 目标域名"
  [vl_masq_choose]="请选择伪装模式 [1-2]"
  [vl_masq_hy2_lbl]="复用 HY2（%s -> 127.0.0.1:%s）"
  [vl_masq_ext_lbl]="外部站点（%s:443）"
  [vl_adopt_hy2_ask]="是否将现有 VLESS 节点同步切换为复用 Hysteria2 的域名与伪装站（%s）？"

  # Credentials / FP / Endpoint / Names
  [ask_password]="Hysteria2 代理密码（直接回车随机生成）"
  [ask_password_keep]="Hysteria2 代理密码（直接回车保留当前密码）"
  [bad_password]="密码须为 8-128 位，只能包含字母、数字及 . _ ~ -"
  [ask_uuid]="VLESS UUID（直接回车随机生成）"
  [ask_uuid_keep]="VLESS UUID（直接回车保留当前 UUID）"
  [bad_uuid]="UUID 格式不正确（应为 xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx）。"
  [fp_title]="VLESS 客户端 uTLS 指纹"
  [fp_choose]="请选择客户端指纹 [1-%s]"
  [bad_fp]="无效的指纹参数：%s（可选：%s）。"
  [ask_hy_name]="Hysteria2 客户端显示的节点名称"
  [ask_vl_name]="VLESS 客户端显示的节点名称"
  [addr_title]="VLESS 客户端连接地址"
  [addr_auto]="自动使用本机公网 IP（%s）"
  [addr_ip4]="使用公网 IPv4（%s）"
  [addr_ip6]="使用公网 IPv6（[%s]）"
  [addr_custom]="自定义域名或 IP 地址"
  [addr_hy2_note]="当前 VLESS 正在复用 Hysteria2 伪装站，连接地址固定使用本机域名：%s"
  [ask_custom_addr]="请输入客户端连接使用的域名或 IP"
  [bad_addr]="域名或 IP 地址格式不正确。"
  [no_pub_ip]="未能自动检测到本机公网 IPv4/IPv6，请使用 --addr 手动指定连接地址。"

  # Ports
  [port_title_both]="共用监听端口（Hysteria2 UDP + VLESS TCP）"
  [port_intro_both]="Hysteria2（UDP）与 VLESS-REALITY（TCP）将无缝共用此 HTTPS 端口及伪装站。"
  [port_title_hy]="Hysteria2 监听端口（代理与伪装站共用）"
  [port_intro_hy]="仅支持常见 HTTPS 端口。代理（UDP）与伪装站（TCP）同步使用该端口。"
  [port_title_vl]="VLESS 监听端口（TCP REALITY）"
  [port_intro_vl]="强烈推荐使用默认的 443 端口以获得最佳抗封锁伪装效果。"
  [port_choose]="请选择端口 [1-%s]（也可直接输入端口号）"
  [bad_port]="端口无效，仅支持以下常见 HTTPS 端口：%s。"
  [port_busy]="端口 %s/%s 已被占用："
  [port_retry]="请重新选择其他端口。"
  [port80_required]="Hysteria2 申请证书（ACME HTTP-01）需要使用 TCP 80 端口，请释放后重试。"
  [udp_port_required]="Hysteria2 需要使用 UDP %s 端口，请释放或改选其他端口。"
  [tcp_port_required]="VLESS 需要使用 TCP %s 端口，请释放或改选其他端口。"
  [tcp_port_busy]="TCP %s 已被其他进程占用，Hysteria2 无法在公网监听该 TCP 伪装端口。"
  [tcp_port_continue]="是否关闭 Hysteria2 的公网 TCP 伪装监听并继续？（选 N 可重选端口）"
  [tcpmasq_now]="Hysteria2 公网 TCP 伪装监听：%s"
  [tcpmasq_loopback]="已自动切换为本地回环 127.0.0.1:%s（由 VLESS 在公网 TCP %s 前置分流）"

  # Bandwidth
  [bw_title]="Hysteria2 带宽 / 拥塞控制"
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
  [bw_client]="由客户端决定（服务器不限速）"
  [bw_limit]="服务器限速：上传 %s（= 客户端下载）/ 下载 %s（= 客户端上传）"
  [bw_bbr]="强制 BBR（忽略客户端带宽设置）"
  [bw_unlimited]="不限"

  # Summary
  [install_mode_title]="选择安装方案"
  [im_both]="同时安装 Hysteria2 + VLESS（推荐，共用 443 端口与伪装站）"
  [im_hy2]="仅安装 Hysteria2"
  [im_vless]="仅安装 VLESS (REALITY)"
  [summary_title]="安装信息确认"
  [sum_mode]="部署协议"
  [sum_domain]="绑定域名"
  [sum_email]="证书邮箱"
  [sum_hy_listen]="HY2 监听"
  [sum_hy_masq]="HY2 伪装源"
  [sum_hy_pass]="HY2 密码"
  [sum_hy_bw]="HY2 带宽"
  [sum_hy_name]="HY2 名称"
  [sum_vl_listen]="VLESS 监听"
  [sum_vl_masq]="VLESS 伪装"
  [sum_vl_uuid]="VLESS UUID"
  [sum_vl_fp]="客户端指纹"
  [sum_vl_addr]="VLESS 地址"
  [sum_vl_name]="VLESS 名称"

  # Core install / service / firewall
  [installing_hy]="正在通过官方脚本安装 Hysteria2 内核……"
  [hy_core_failed]="Hysteria2 内核安装失败。"
  [installing_sb]="正在通过官方软件源安装 sing-box 内核……"
  [sb_core_failed]="sing-box 内核安装失败。"
  [writing_config]="正在写入配置文件……"
  [sb_check_fail]="sing-box 配置文件校验失败："
  [sysctl_done]="已应用 UDP 缓冲区优化。"
  [sysctl_fail]="sysctl 参数应用失败（已忽略）。"
  [fw_ufw_manual]="检测到 ufw 已启用，本脚本不会自动修改 ufw 规则，请手动放行：%s（例如：%s）。"
  [fw_ufw_uninstall]="检测到 ufw 已启用，如之前添加过放行规则（%s），请按需手动清理。"
  [fw_cloud]="请记得在云服务商安全组中放行：%s。"
  [starting_hy]="正在启动 Hysteria2 并验证证书（最长约 3 分钟）"
  [hy_start_ok]="Hysteria2 已成功运行。"
  [hy_start_fail]="Hysteria2 启动失败，最近日志如下："
  [hy_start_timeout]="等待 Hysteria2 启动超时，最近日志如下："
  [hy_fail_hints]="常见原因：域名未解析到本机、安全组未放行 TCP 80、触发 Let's Encrypt 频率限制。"
  [starting_sb]="正在启动 VLESS (sing-box) 服务……"
  [sb_start_ok]="VLESS (sing-box) 已成功运行。"
  [sb_start_fail]="VLESS (sing-box) 启动失败，最近日志如下："
  [install_done]="安装完成！之后输入 nodectl 即可随时打开管理菜单。"
  [shortcut_ok]="已安装快捷命令：%s"
  [shortcut_skip]="无法安装 nodectl 快捷命令，请稍后重新运行本脚本。"
  [legacy_hy2_removed]="已移除旧版快捷指令 /usr/local/bin/hy2，今后请使用 nodectl 打开菜单。"

  # Installed / share / update / uninstall
  [not_installed]="当前尚未安装任何受管节点。"
  [hy_not_installed]="Hysteria2 尚未安装。"
  [vl_not_installed]="VLESS 尚未安装。"
  [no_state]="检测到非本脚本安装的内核（缺少状态文件），请使用本脚本重新安装。"
  [already_installed_hy]="Hysteria2 已安装，是否重新安装并覆盖当前配置？"
  [already_installed_vl]="VLESS 已安装，是否重新安装并覆盖当前配置？"
  [share_title]="节点链接"
  [updating_hy]="正在更新 Hysteria2 内核……"
  [updating_sb]="正在更新 sing-box 内核……"
  [update_done]="%s 内核版本：%s -> %s"
  [uninstall_all_confirm]="将删除全部已安装的代理内核（Hysteria2 / VLESS）、配置及证书，是否继续？"
  [uninstall_hy_confirm]="将删除 Hysteria2 及其配置文件和证书，是否继续？"
  [uninstall_vl_confirm]="将删除 VLESS (sing-box) 及其配置文件，是否继续？"
  [hy_uninst_vl_dep]="VLESS 当前正在复用 Hysteria2 的本地伪装站。卸载 Hysteria2 前，请先为 VLESS 指定一个外部 REALITY 域名："
  [hy_stop_vl_warn]="注意：VLESS 正在复用 Hysteria2 的本地伪装监听（127.0.0.1:%s），停止 Hysteria2 会导致新建 VLESS 连接无法握手。仍然停止？"
  [remove_warn]="官方卸载脚本返回异常，改为手动清理。"
  [uninstall_hy_done]="Hysteria2 已卸载。"
  [uninstall_vl_done]="VLESS (sing-box) 已卸载。"
  [uninstall_all_done]="全部受管节点及 nodectl 已完全卸载。"

  # Keys / Certs / Logs / Status
  [cert_auto]="证书由 Hysteria 内置 ACME 自动签发和续期。"
  [cert_not_found]="暂未找到证书文件。"
  [cert_path]="文件"
  [cert_days]="剩余天数：%s"
  [reissue_confirm]="删除当前证书并重新申请？（Let's Encrypt 每周最多签发 5 张相同证书）"
  [keys_title]="VLESS REALITY 密钥与 ShortId"
  [lbl_pubkey]="公钥 PublicKey (pbk)"
  [lbl_shortid]="ShortId (sid)"
  [reset_keys_confirm]="重新生成 REALITY 密钥对与 ShortId？现有的 VLESS 客户端链接将立即失效。"
  [logs_hint]="实时日志，按 Ctrl+C 返回。"
  [listening]="监听中的端口"
  [stopped_ok]="服务已停止。"

  # BBR
  [m_bbr]="内核 TCP BBR   （当前: %s）"
  [bbr_title]="内核 TCP 拥塞控制"
  [bbr_cur]="当前算法：%s   队列规则：%s"
  [bbr_scope]="说明：直接加速 VLESS 节点的 TCP 代理隧道（强烈建议开启），同时也作用于服务器出站和伪装站连接；Hysteria2 走 UDP/QUIC，使用自身的拥塞控制。"
  [bbr_by_us]="内核 TCP BBR 已由 nodectl 开启（%s）。"
  [bbr_by_other]="内核 TCP BBR 已由系统其他配置开启，本脚本未做改动。"
  [bbr_unsupported]="当前内核不支持 BBR（无法加载 tcp_bbr 模块）。"
  [bbr_confirm_on]="开启内核 TCP BBR（tcp_congestion_control=bbr，default_qdisc=fq）？"
  [bbr_confirm_off]="关闭内核 TCP BBR 并恢复原设置（%s）？"
  [bbr_on_ok]="已开启内核 TCP BBR，新建的 TCP 连接立即生效。"
  [bbr_on_fail]="设置应用失败（OpenVZ/LXC 等容器通常无法修改），未做任何改动。"
  [bbr_off_ok]="已关闭内核 TCP BBR，当前算法：%s。"
  [bbr_not_ours]="BBR 不是由本脚本开启的，无需关闭。"
  [bbr_keep]="是否同时恢复内核 TCP 拥塞控制设置（关闭 BBR）？"

  # Versioning / Self-update / Migration
  [ver_new_avail]="管理脚本有新版本：v%s"
  [ver_legacy1]="本机由旧版脚本（%s）安装，版本过旧，无法直接升级（需要 v%s 或更新）。"
  [ver_legacy2]="请先执行卸载，再用 nodectl 重新安装。如需沿用原密码，请先保存节点链接。"
  [ver_legacy_short]="版本过旧，需重新安装"
  [ver_unknown]="未知的旧版本"
  [ver_newer]="本机由更新的 nodectl（v%s）管理，请运行最新脚本：%s"
  [ver_adopted]="管理脚本已升级：v%s -> v%s（现有节点配置未改变）。"
  [ver_migrated]="已从 hy2.sh v%s 平滑升级至 nodectl v%s（原有 Hysteria2 节点零中断保留）。"
  [su_checking]="正在检查脚本更新……"
  [su_fetch_fail]="无法从 %s 下载脚本。"
  [su_invalid]="下载的文件不是有效的 nodectl.sh，已取消更新。"
  [su_latest]="已是最新版本（v%s）。"
  [su_confirm]="将管理脚本从 v%s 更新到 v%s？"
  [su_done]="管理脚本已更新到 v%s，正在重新启动……"
  [su_prompt]="发现新版本 v%s（当前 v%s），是否立即更新？"
  [cl_title]="版本更新日志 (nodectl v%s)"

  # Menus
  [m_title]="节点管理脚本 (nodectl)"
  [m_sec_common]="—— 常用 ——"
  [m_sec_proto]="—— 协议与配置 ——"
  [m_sec_maint]="—— 维护 ——"
  [m_share]="查看节点链接"
  [m_status]="查看运行状态"
  [m_logs]="查看实时日志"
  [m_logs_sub]="查看实时日志  ▶"
  [m_logs_h]="查看实时日志"
  [ml_hy]="Hysteria2 实时日志"
  [ml_vl]="VLESS (sing-box) 实时日志"
  [m_hy_mgr]="Hysteria2 管理  ▶"
  [m_hy_mgr_h]="Hysteria2 管理"
  [m_vl_mgr]="VLESS (REALITY) 管理  ▶"
  [m_vl_mgr_h]="VLESS (REALITY) 管理"
  [m_inst_both]="同时安装 Hysteria2 + VLESS（推荐，共用 443 端口与伪装站）"
  [m_inst_hy]="安装 Hysteria2"
  [m_inst_hy_co]="安装 Hysteria2（可与 VLESS 共用端口与伪装站）"
  [m_inst_vl]="安装 VLESS (REALITY)"
  [m_inst_vl_co]="安装 VLESS (REALITY)（可复用 HY2 端口与伪装站）"
  [m_selfupdate]="更新管理脚本"
  [m_changelog]="查看更新日志"
  [m_update_hy]="更新 Hysteria2 内核"
  [m_update_sb]="更新 sing-box 内核"
  [m_update_sub]="更新协议内核  ▶"
  [m_update_h]="更新协议内核"
  [mu_all]="更新全部已安装内核"
  [m_uninstall_all]="卸载全部节点"
  [m_reinstall_hy]="重新安装 Hysteria2（覆盖当前 HY2 配置）"
  [m_uninstall_hy]="卸载 Hysteria2"
  [m_reinstall_vl]="重新安装 VLESS（覆盖当前 VLESS 配置）"
  [m_uninstall_vl]="卸载 VLESS"

  [mm_hy_pass]="修改密码"
  [mm_hy_port]="修改监听端口"
  [mm_hy_masq]="修改伪装站点"
  [mm_hy_domain]="修改域名（将重新申请证书）"
  [mm_hy_name]="修改节点名称"
  [mm_hy_tcpmasq]="开启 / 关闭公网 TCP %s 伪装监听"
  [mm_hy_bw]="带宽 / 拥塞控制"
  [m_cert]="证书管理  ▶"
  [m_cert_h]="Hysteria2 证书管理"
  [mc_info]="查看证书信息"
  [mc_reissue]="强制重新申请证书"
  [m_service]="启动 / 停止 / 重启  ▶"
  [m_hy_service_h]="Hysteria2 服务控制"
  [m_vl_service_h]="VLESS (sing-box) 服务控制"
  [ms_start]="启动"
  [ms_stop]="停止"
  [ms_restart]="重启"

  [mm_vl_uuid]="修改 UUID"
  [mm_vl_port]="修改监听端口"
  [mm_vl_masq]="修改伪装模式 / 目标域名"
  [mm_vl_fp]="修改客户端 TLS 指纹"
  [mm_vl_addr]="修改客户端连接地址"
  [mm_vl_name]="修改节点名称"
  [m_keys]="REALITY 密钥与 ShortId  ▶"
  [m_keys_h]="VLESS REALITY 密钥管理"
  [mk_info]="查看公钥与 ShortId"
  [mk_reset]="重新生成密钥对与 ShortId"
)

t() {
  local key=$1 fmt
  shift
  if [[ $UI_LANG == zh ]]; then
    fmt=${M_ZH[$key]:-${M_EN[$key]:-$key}}
  else
    fmt=${M_EN[$key]:-$key}
  fi
  # shellcheck disable=SC2059
  printf -- "$fmt" "$@"
}

# ---------------------------------------------------------------------------
# Output / input helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn()  { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()   { printf '\033[31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()   { err "$*"; exit 1; }
title() { printf '\n\033[36m===== %s =====\033[0m\n' "$*"; }

pause() { [[ -t 0 ]] && ((!ASSUME_YES)) && read -rp "$(t press_enter)" _; }

ask() {
  local __var=$1 __prompt=$2 __def=${3:-} __ans
  if [[ -n $__def ]]; then
    read -rp "$__prompt [$__def]: " __ans || die "$(t no_input)"
    __ans=${__ans:-$__def}
  else
    read -rp "$__prompt: " __ans || die "$(t no_input)"
  fi
  printf -v "$__var" '%s' "$__ans"
}

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

show_changelog() {
  local from=${1:-}
  title "$(t cl_title "$SCRIPT_VERSION")"
  if [[ $UI_LANG == zh ]]; then
    if [[ -n $from ]]; then
      printf '  \033[33m★ 升级说明（v%s -> v%s）\033[0m\n' "$from" "$SCRIPT_VERSION"
      echo "  - 脚本已更名为 nodectl.sh，快捷呼出指令变更为：nodectl"
      echo "  - 旧版 /usr/local/bin/hy2 指令已移除，原有 Hysteria2 节点配置与链接保持不变"
      echo
    fi
    echo "  v2.0.0 更新内容："
    echo "  1. 架构升级：由单一 Hysteria2 脚本升级为 Hysteria2 + VLESS 多协议统一管理脚本（nodectl）"
    echo "  2. 新增 VLESS 节点：采用 sing-box 内核部署 VLESS + XTLS-Vision + REALITY，完美兼容 Mihomo 系客户端"
    echo "  3. 共用 443 与伪装站：支持 UDP 443 (Hysteria2) + TCP 443 (VLESS) 无缝共存，无需 Nginx 前置，"
    echo "     由 REALITY 自动将非代理探测流量透传至 Hysteria2 本地回环伪装服务（复用本机真证书与反代站点）"
    echo "  4. 平滑接管：自动迁移旧版 hy2.sh（>= v1.3.1）配置与内核 TCP BBR 状态，零中断保留现有节点"
  else
    if [[ -n $from ]]; then
      printf '  \033[33m* Upgrade Notice (v%s -> v%s)\033[0m\n' "$from" "$SCRIPT_VERSION"
      echo "  - The script has been renamed to nodectl.sh; the new shortcut command is: nodectl"
      echo "  - Legacy '/usr/local/bin/hy2' was removed; your existing Hysteria2 node and link remain unchanged"
      echo
    fi
    echo "  v2.0.0 Highlights:"
    echo "  1. Unified Manager: upgraded from hy2.sh into a multi-protocol manager (nodectl) for Hysteria2 & VLESS"
    echo "  2. VLESS-REALITY: powered by official sing-box (VLESS + XTLS-Vision + REALITY), fully compatible with Mihomo"
    echo "  3. Shared Port 443 & Masquerade: run Hysteria2 (UDP 443) + VLESS (TCP 443) together without Nginx,"
    echo "     forwarding unauthenticated probes cleanly to Hysteria2's local loopback HTTPS masquerade"
    echo "  4. Seamless Migration: adopts existing hy2.sh (>= v1.3.1) & BBR state with zero downtime"
  fi
  echo
}

# ---------------------------------------------------------------------------
# Validation / binary & format helpers
# ---------------------------------------------------------------------------
valid_domain() { [[ $1 =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z]{2,63}$ ]]; }
valid_ipv4()   { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }
valid_ipv6()   { [[ $1 == *:* && $1 =~ ^[0-9A-Fa-f:.]+$ ]]; }
valid_host()   { valid_domain "${1,,}" || valid_ipv4 "$1" || valid_ipv6 "${1#\[}" && [[ ${1//[\[\]]/} != "" ]]; }

valid_port() {
  local p
  for p in "${ALLOWED_PORTS[@]}"; do
    [[ $1 == "$p" ]] && return 0
  done
  return 1
}

valid_fp() {
  local f
  for f in "${ALLOWED_FPS[@]}"; do
    [[ $1 == "$f" ]] && return 0
  done
  return 1
}

valid_email() {
  local re='^[A-Za-z0-9._%+-]+@([A-Za-z0-9]([A-Za-z0-9-]{0,61}[a-z0-9])?\.)+[A-Za-z]{2,63}$'
  [[ $1 =~ $re ]]
}

valid_password() { [[ $1 =~ ^[A-Za-z0-9._~-]{8,128}$ ]]; }
valid_uuid()     { [[ ${1,,} =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; }

yaml_str() {
  local v=${1//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

json_str() {
  local v=${1//\\/\\\\}
  v=${v//\"/\\\"}
  printf '"%s"' "$v"
}

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
  case $HY_BW_MODE in
    limit) t bw_limit "$(bw_value "$HY_BW_UP")" "$(bw_value "$HY_BW_DOWN")" ;;
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
gen_short_id() { openssl rand -hex 4; }
gen_uuid() {
  local sb
  sb=$(sb_bin)
  if [[ -n $sb ]]; then
    "$sb" generate uuid 2>/dev/null && return 0
  fi
  if [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  else
    local hex
    hex=$(openssl rand -hex 16)
    printf '%s-%s-4%s-a%s-%s\n' "${hex:0:8}" "${hex:8:4}" "${hex:13:3}" "${hex:17:3}" "${hex:20:12}"
  fi
}

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

sb_bin() {
  if [[ -x /usr/bin/sing-box ]]; then echo /usr/bin/sing-box
  elif [[ -x /usr/local/bin/sing-box ]]; then echo /usr/local/bin/sing-box
  elif command -v sing-box >/dev/null 2>&1; then command -v sing-box
  fi
}

hy_core_present() { [[ -x $HY_BIN && -f $HY_CONF ]]; }
sb_core_present() { [[ -n $(sb_bin) && -f $SB_CONF ]]; }

hy_installed() { [[ $HY_ENABLED == yes ]] && hy_core_present; }
vl_installed() { [[ $VL_ENABLED == yes ]] && sb_core_present; }
any_installed() { hy_installed || vl_installed; }

hy_version() { "$HY_BIN" version 2>/dev/null | awk -F'[:[:space:]]+' '/^Version/{print $2; exit}'; }
sb_version() {
  local sb
  sb=$(sb_bin)
  [[ -n $sb ]] || return 0
  "$sb" version -n 2>/dev/null && return 0
  "$sb" version 2>/dev/null | awk '/^sing-box/{print $NF; exit}'
}

hy_group() { id -gn hysteria 2>/dev/null || echo root; }
sb_group() { id -gn sing-box 2>/dev/null || echo root; }
on_off()   { if [[ $1 == yes ]]; then t on; else t off; fi; }

# Format IPv6 literals with brackets for URLs
uri_host() {
  local h=${1#\[}; h=${h%\]}
  if [[ $h == *:* ]]; then printf '[%s]' "$h"; else printf '%s' "$h"; fi
}

# Effective SNI and handshake destination for VLESS
vl_effective_sni() {
  if [[ $VL_MASQ_MODE == hy2 && $HY_ENABLED == yes ]]; then
    printf '%s' "$HY_DOMAIN"
  else
    printf '%s' "$VL_SNI"
  fi
}

# Computes Hysteria2's masquerade.listenHTTPS target:
#   - ":PORT"                 public TCP listener (when HY2 owns public TCP on HY_PORT)
#   - "127.0.0.1:LOCAL_PORT"  loopback listener (when VLESS shares HY_PORT or HY_TCP_MASQ=no while VL_MASQ_MODE=hy2)
#   - ""                      disabled
hy_effective_listen_https() {
  [[ $HY_ENABLED == yes ]] || return 0
  if [[ $VL_ENABLED == yes && $VL_PORT == "$HY_PORT" ]]; then
    if [[ $VL_MASQ_MODE == hy2 ]]; then
      printf '127.0.0.1:%s' "$HY_LOCAL_PORT"
    fi
    return 0
  fi
  if [[ $HY_TCP_MASQ == yes ]]; then
    printf ':%s' "$HY_PORT"
  elif [[ $VL_ENABLED == yes && $VL_MASQ_MODE == hy2 ]]; then
    printf '127.0.0.1:%s' "$HY_LOCAL_PORT"
  fi
}

# Computes sing-box REALITY handshake "host port" pair
vl_effective_handshake() {
  if [[ $VL_MASQ_MODE == hy2 && $HY_ENABLED == yes ]]; then
    local lhttps
    lhttps=$(hy_effective_listen_https)
    if [[ $lhttps == :* ]]; then
      printf '127.0.0.1 %s' "$HY_PORT"
    else
      printf '127.0.0.1 %s' "$HY_LOCAL_PORT"
    fi
  else
    printf '%s 443' "$VL_SNI"
  fi
}

vl_effective_addr() {
  if [[ $VL_MASQ_MODE == hy2 && $HY_ENABLED == yes && -n $HY_DOMAIN ]]; then
    printf '%s' "$HY_DOMAIN"
    return 0
  fi
  case $VL_ADDR_MODE in
    custom) [[ -n $VL_CUSTOM_ADDR ]] && { printf '%s' "${VL_CUSTOM_ADDR//[\[\]]/}"; return 0; } ;;
    ip6)    detect_ips; [[ -n $PUB_IP6 ]] && { printf '%s' "$PUB_IP6"; return 0; } ;;
    ip4)    detect_ips; [[ -n $PUB_IP4 ]] && { printf '%s' "$PUB_IP4"; return 0; } ;;
  esac
  detect_ips
  if [[ -n $PUB_IP4 ]]; then printf '%s' "$PUB_IP4"
  elif [[ -n $PUB_IP6 ]]; then printf '%s' "$PUB_IP6"
  elif [[ -n $VL_CUSTOM_ADDR ]]; then printf '%s' "${VL_CUSTOM_ADDR//[\[\]]/}"
  fi
}

vl_masq_label() {
  if [[ $VL_MASQ_MODE == hy2 && $HY_ENABLED == yes ]]; then
    local hs_host hs_port
    read -r hs_host hs_port <<<"$(vl_effective_handshake)"
    t vl_masq_hy2_lbl "$HY_DOMAIN" "$hs_port"
  else
    t vl_masq_ext_lbl "${VL_SNI:--}"
  fi
}

# ---------------------------------------------------------------------------
# State persistence & migration from hy2.sh
# ---------------------------------------------------------------------------
save_state() {
  mkdir -p "$STATE_DIR"
  chmod 700 "$STATE_DIR"
  (
    umask 077
    {
      printf 'INSTALLED_VERSION=%q\n' "$SCRIPT_VERSION"
      printf 'HY_ENABLED=%q\n' "$HY_ENABLED"
      printf 'HY_DOMAIN=%q\n' "$HY_DOMAIN"
      printf 'HY_PORT=%q\n' "$HY_PORT"
      printf 'HY_EMAIL=%q\n' "$HY_EMAIL"
      printf 'HY_PASSWORD=%q\n' "$HY_PASSWORD"
      printf 'HY_MASQ_URL=%q\n' "$HY_MASQ_URL"
      printf 'HY_NAME=%q\n' "$HY_NAME"
      printf 'HY_TCP_MASQ=%q\n' "$HY_TCP_MASQ"
      printf 'HY_LOCAL_PORT=%q\n' "$HY_LOCAL_PORT"
      printf 'HY_BW_MODE=%q\n' "$HY_BW_MODE"
      printf 'HY_BW_UP=%q\n' "$HY_BW_UP"
      printf 'HY_BW_DOWN=%q\n' "$HY_BW_DOWN"
      printf 'VL_ENABLED=%q\n' "$VL_ENABLED"
      printf 'VL_PORT=%q\n' "$VL_PORT"
      printf 'VL_UUID=%q\n' "$VL_UUID"
      printf 'VL_PRIVATE_KEY=%q\n' "$VL_PRIVATE_KEY"
      printf 'VL_PUBLIC_KEY=%q\n' "$VL_PUBLIC_KEY"
      printf 'VL_SHORT_ID=%q\n' "$VL_SHORT_ID"
      printf 'VL_FP=%q\n' "$VL_FP"
      printf 'VL_MASQ_MODE=%q\n' "$VL_MASQ_MODE"
      printf 'VL_SNI=%q\n' "$VL_SNI"
      printf 'VL_ADDR_MODE=%q\n' "$VL_ADDR_MODE"
      printf 'VL_CUSTOM_ADDR=%q\n' "$VL_CUSTOM_ADDR"
      printf 'VL_NAME=%q\n' "$VL_NAME"
    } >"$STATE_FILE"
  )
  chmod 600 "$STATE_FILE"
}

normalize_loaded_state() {
  [[ ${HY_PORT:-} =~ ^[0-9]+$ ]] || HY_PORT=443
  [[ ${HY_LOCAL_PORT:-} =~ ^[0-9]+$ ]] || HY_LOCAL_PORT=18443
  [[ ${VL_PORT:-} =~ ^[0-9]+$ ]] || VL_PORT=443
  HY_BW_UP=$(parse_bw "${HY_BW_UP:-0}") || HY_BW_UP=0
  HY_BW_DOWN=$(parse_bw "${HY_BW_DOWN:-0}") || HY_BW_DOWN=0
  if [[ $HY_BW_MODE != client && $HY_BW_MODE != limit && $HY_BW_MODE != bbr ]]; then
    if ((HY_BW_UP == 0 && HY_BW_DOWN == 0)); then HY_BW_MODE=bbr; else HY_BW_MODE=limit; fi
  fi
  valid_fp "${VL_FP:-}" || VL_FP=chrome
  [[ $VL_MASQ_MODE == hy2 || $VL_MASQ_MODE == external ]] || VL_MASQ_MODE=external
  [[ $VL_ADDR_MODE == auto || $VL_ADDR_MODE == ip4 || $VL_ADDR_MODE == ip6 || $VL_ADDR_MODE == custom ]] || VL_ADDR_MODE=auto
}

load_legacy_hy2_vars() {
  local DOMAIN="" PORT=443 EMAIL="" PASSWORD="" MASQ_URL="" NODE_NAME="" TCP_MASQ="yes"
  local BW_MODE="" BW_UP=0 BW_DOWN=0
  INSTALLED_VERSION=""
  # shellcheck disable=SC1090
  . "$LEGACY_HY_STATE"
  HY_ENABLED="yes"
  HY_DOMAIN=$DOMAIN
  HY_PORT=${PORT:-443}
  HY_EMAIL=$EMAIL
  HY_PASSWORD=$PASSWORD
  HY_MASQ_URL=$MASQ_URL
  HY_NAME=$NODE_NAME
  HY_TCP_MASQ=${TCP_MASQ:-yes}
  HY_BW_MODE=$BW_MODE
  HY_BW_UP=${BW_UP:-0}
  HY_BW_DOWN=${BW_DOWN:-0}
  VL_ENABLED="no"
  normalize_loaded_state
}

load_state() {
  INSTALLED_VERSION=""
  HY_ENABLED="no" VL_ENABLED="no"
  HY_PORT=443 HY_LOCAL_PORT=18443 VL_PORT=443
  if [[ -f $STATE_FILE ]]; then
    # shellcheck disable=SC1090
    . "$STATE_FILE"
    normalize_loaded_state
  elif [[ -f $LEGACY_HY_STATE ]]; then
    load_legacy_hy2_vars
  fi
  return 0
}

need_any_installed() {
  if ! any_installed; then
    if [[ -x $HY_BIN || -n $(sb_bin) || -d $HY_DIR || -d $SB_DIR ]]; then
      err "$(t no_state)"
    else
      err "$(t not_installed)"
    fi
    return 1
  fi
  if [[ ! -f $STATE_FILE && ! -f $LEGACY_HY_STATE ]]; then err "$(t no_state)"; return 1; fi
  load_state
}

need_hy_installed() {
  need_any_installed || return 1
  hy_installed || { err "$(t hy_not_installed)"; return 1; }
}

need_vl_installed() {
  need_any_installed || return 1
  vl_installed || { err "$(t vl_not_installed)"; return 1; }
}

# ---------------------------------------------------------------------------
# Environment & network checks
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
    # shellcheck disable=SC1091
    id=$(. /etc/os-release; echo "$ID")
    # shellcheck disable=SC1091
    ver=$(. /etc/os-release; echo "$VERSION_ID")
    # shellcheck disable=SC1091
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
    valid_ipv4 "$ip" && { PUB_IP4=$ip; break; }
  done
  for svc in https://api64.ipify.org https://icanhazip.com https://ifconfig.co; do
    ip=$(curl -6 -fsS --max-time 5 "$svc" 2>/dev/null | tr -d '[:space:]')
    valid_ipv6 "$ip" && { PUB_IP6=${ip,,}; break; }
  done
  IPS_DETECTED=1
}

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
  local url=$1 cmp_domain=${2:-$HY_DOMAIN} code="" loc=""
  if [[ -n $cmp_domain && $(url_host "$url") == "$cmp_domain" ]]; then err "$(t masq_loop)"; return 2; fi
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

# Validate an external REALITY target domain: must not point to this server,
# must negotiate TLS 1.3 cleanly on port 443, and warns on Cloudflare / non-h2.
check_reality_sni() {
  local sni=$1 a4 a6 tls_out hdrs h2_tag="" cf_hit=0
  detect_ips
  a4=$(resolve "$sni" A)
  a6=$(resolve "$sni" AAAA)
  if { [[ -n $PUB_IP4 ]] && grep -qxF "$PUB_IP4" <<<"$a4"; } ||
     { [[ -n $PUB_IP6 ]] && grep -qxF "$PUB_IP6" <<<"$a6"; }; then
    err "$(t sni_self_err)"
    return 2
  fi
  info "$(t checking_sni "$sni")"
  tls_out=$(timeout 8 openssl s_client -connect "$sni:443" -servername "$sni" -tls1_3 -alpn h2 </dev/null 2>/dev/null)
  if ! grep -qE 'Protocol[[:space:]]*:[[:space:]]*TLSv1\.3|New, TLSv1\.3,' <<<"$tls_out" ||
     ! grep -q 'Verify return code: 0 (ok)' <<<"$tls_out"; then
    err "$(t sni_fail "$sni")"
    return 1
  fi
  if grep -qE 'ALPN protocol:[[:space:]]*h2' <<<"$tls_out"; then
    h2_tag=", h2"
  else
    warn "$(t sni_no_h2)"
  fi
  hdrs=$(curl -sSI --max-time 6 -A "Mozilla/5.0" "https://$sni" 2>/dev/null | tr '[:upper:]' '[:lower:]')
  if grep -qE '^(server:[[:space:]]*cloudflare|cf-ray:)' <<<"$hdrs"; then
    cf_hit=1
    warn "$(t sni_cf_warn "$sni")"
  fi
  info "$(t sni_ok "$h2_tag")"
  if ((cf_hit)); then
    confirm "$(t use_anyway)" n || return 2
  fi
  return 0
}

# Socket inspection. $1 = t|u, $2 = port, $3 = ERE of process names to exclude.
port_users_except() {
  local proto=$1 port=$2 excl=${3:-} out
  out=$(ss -H -"$proto"lnp "sport = :$port" 2>/dev/null)
  [[ -n $excl ]] && out=$(grep -Ev "$excl" <<<"$out")
  printf '%s' "$out"
}

check_port80() {
  local out
  out=$(port_users_except t 80 '"hysteria"')
  [[ -n $out ]] && { err "$(t port_busy 80 tcp)"; echo "$out"; die "$(t port80_required)"; }
}

ensure_local_port() {
  local p=${HY_LOCAL_PORT:-18443} out
  for ((; p <= 18550; p++)); do
    out=$(port_users_except t "$p" '"hysteria"')
    if [[ -z $out ]]; then
      HY_LOCAL_PORT=$p
      return 0
    fi
  done
  HY_LOCAL_PORT=18443
}

# ---------------------------------------------------------------------------
# Input collection
# ---------------------------------------------------------------------------
collect_domain() {
  local d=$OPT_DOMAIN
  while :; do
    [[ -z $d ]] && ask d "$(t ask_domain)" "$HY_DOMAIN"
    d=${d,,}; d=${d%.}
    if ! valid_domain "$d"; then
      err "$(t bad_domain)"; [[ -n $OPT_DOMAIN ]] && exit 1; d=""; continue
    fi
    if check_domain_dns "$d"; then HY_DOMAIN=$d; return 0; fi
    [[ -n $OPT_DOMAIN ]] && exit 1
    d=""
  done
}

collect_email() {
  local e
  if [[ -n $OPT_EMAIL_SET ]]; then
    e=$OPT_EMAIL
  elif ((ASSUME_YES)); then
    e=$HY_EMAIL
  else
    while :; do
      ask e "$(t ask_email)" "$HY_EMAIL"
      { [[ -z $e ]] || valid_email "$e"; } && break
      err "$(t bad_email)"
    done
  fi
  [[ -n $e ]] && ! valid_email "$e" && die "$(t bad_email)"
  HY_EMAIL=$e
}

collect_hy_masq() {
  local u=$OPT_MASQ rc
  while :; do
    [[ -z $u ]] && ask u "$(t ask_masq)" "$HY_MASQ_URL"
    u=$(normalize_url "$u")
    if ! valid_url "$u"; then
      err "$(t bad_url)"; [[ -n $OPT_MASQ ]] && exit 1; u=""; continue
    fi
    check_masquerade "$u" "$HY_DOMAIN"; rc=$?
    if ((rc == 0)) || { ((rc == 1)) && confirm "$(t use_anyway)" n; }; then
      HY_MASQ_URL=$u; return 0
    fi
    [[ -n $OPT_MASQ ]] && exit 1
    u=""
  done
}

collect_password() {
  local p
  if [[ -n $OPT_PASSWORD ]]; then
    p=$OPT_PASSWORD
  elif ((ASSUME_YES)); then
    p=${HY_PASSWORD:-$(gen_password)}
  else
    while :; do
      if [[ $1 == keep && -n $HY_PASSWORD ]]; then
        read -rp "$(t ask_password_keep): " p || die "$(t no_input)"
        p=${p:-$HY_PASSWORD}
      else
        read -rp "$(t ask_password): " p || die "$(t no_input)"
        p=${p:-$(gen_password)}
      fi
      valid_password "$p" && break
      err "$(t bad_password)"
    done
  fi
  valid_password "$p" || die "$(t bad_password)"
  HY_PASSWORD=$p
}

collect_uuid() {
  local u
  if [[ -n $OPT_UUID ]]; then
    u=${OPT_UUID,,}
  elif ((ASSUME_YES)); then
    u=${VL_UUID:-$(gen_uuid)}
  else
    while :; do
      if [[ $1 == keep && -n $VL_UUID ]]; then
        read -rp "$(t ask_uuid_keep): " u || die "$(t no_input)"
        u=${u:-$VL_UUID}
      else
        read -rp "$(t ask_uuid): " u || die "$(t no_input)"
        u=${u:-$(gen_uuid)}
      fi
      u=${u,,}
      valid_uuid "$u" && break
      err "$(t bad_uuid)"
    done
  fi
  valid_uuid "$u" || die "$(t bad_uuid)"
  VL_UUID=$u
}

collect_fp() {
  local f=${OPT_FP,,} c i def=1 cur=${VL_FP:-chrome}
  if [[ -n $f ]]; then
    valid_fp "$f" || die "$(t bad_fp "$OPT_FP" "${ALLOWED_FPS[*]}")"
    VL_FP=$f; return 0
  fi
  if ((ASSUME_YES)); then
    valid_fp "$cur" || cur=chrome
    VL_FP=$cur; return 0
  fi
  title "$(t fp_title)"
  for i in "${!ALLOWED_FPS[@]}"; do
    f=${ALLOWED_FPS[i]}
    [[ $f == "$cur" ]] && def=$((i + 1))
    local tag=""
    if [[ $f == chrome && $f == "$cur" ]]; then tag=" ($(t port_default), $(t current))"
    elif [[ $f == chrome ]]; then tag=" ($(t port_default))"
    elif [[ $f == "$cur" ]]; then tag=" ($(t current))"
    fi
    printf '  %d. %s%s\n' "$((i + 1))" "$f" "$tag"
  done
  while :; do
    ask c "$(t fp_choose "${#ALLOWED_FPS[@]}")" "$def"
    c=${c//[[:space:]]/}
    if [[ $c =~ ^[1-9][0-9]*$ ]] && ((c >= 1 && c <= ${#ALLOWED_FPS[@]})); then
      VL_FP=${ALLOWED_FPS[c - 1]}; return 0
    elif valid_fp "${c,,}"; then
      VL_FP=${c,,}; return 0
    fi
    err "$(t invalid_choice)"
  done
}

collect_sni() {
  local s=$OPT_SNI rc
  while :; do
    [[ -z $s ]] && ask s "$(t ask_sni)" "$VL_SNI"
    s=$(url_host "$s"); s=${s%.}
    if ! valid_domain "$s"; then
      err "$(t bad_domain)"; [[ -n $OPT_SNI ]] && exit 1; s=""; continue
    fi
    check_reality_sni "$s"; rc=$?
    if ((rc == 0)) || { ((rc == 1)) && confirm "$(t use_anyway)" n; }; then
      VL_SNI=$s; return 0
    fi
    [[ -n $OPT_SNI ]] && exit 1
    s=""
  done
}

# collect_vl_masq <hy_available: yes|no>
collect_vl_masq() {
  local hy_avail=$1 c def=1
  if [[ $hy_avail != yes ]]; then
    VL_MASQ_MODE=external
    collect_sni
    return 0
  fi
  if [[ -n $OPT_VL_MASQ ]]; then
    case ${OPT_VL_MASQ,,} in
      hy2) VL_MASQ_MODE=hy2; ensure_local_port; return 0 ;;
      external) VL_MASQ_MODE=external; collect_sni; return 0 ;;
      *) die "$(t unknown_arg "--vless-masq $OPT_VL_MASQ")" ;;
    esac
  fi
  if [[ -n $OPT_SNI ]]; then
    VL_MASQ_MODE=external
    collect_sni
    return 0
  fi
  if ((ASSUME_YES)); then
    VL_MASQ_MODE=hy2
    ensure_local_port
    return 0
  fi
  title "$(t vl_masq_title)"
  echo "  1. $(t vl_masq_hy2 "$HY_DOMAIN")"
  echo "  2. $(t vl_masq_ext)"
  [[ $VL_MASQ_MODE == external && -n $VL_SNI ]] && def=2
  while :; do
    ask c "$(t vl_masq_choose)" "$def"
    case ${c//[[:space:]]/} in
      1) VL_MASQ_MODE=hy2; ensure_local_port; return 0 ;;
      2) VL_MASQ_MODE=external; collect_sni; return 0 ;;
      *) err "$(t invalid_choice)" ;;
    esac
  done
}

collect_vl_addr() {
  if [[ -n $OPT_ADDR ]]; then
    local h=${OPT_ADDR//[\[\]]/}
    valid_host "$h" || die "$(t bad_addr)"
    VL_ADDR_MODE=custom
    VL_CUSTOM_ADDR=$h
    return 0
  fi
  if [[ $VL_MASQ_MODE == hy2 ]]; then
    VL_ADDR_MODE=auto
    return 0
  fi
  detect_ips
  if [[ -z $PUB_IP4 && -z $PUB_IP6 ]]; then
    ((ASSUME_YES)) && die "$(t no_pub_ip)"
    local custom
    while :; do
      ask custom "$(t ask_custom_addr)" "$VL_CUSTOM_ADDR"
      custom=${custom//[\[\]]/}
      valid_host "$custom" && { VL_ADDR_MODE=custom; VL_CUSTOM_ADDR=$custom; return 0; }
      err "$(t bad_addr)"
    done
  fi
  VL_ADDR_MODE=${VL_ADDR_MODE:-auto}
}

# render_port_menu CURRENT_PORT TITLE_KEY INTRO_KEY -> prints menu and returns default index via DEF_IDX
DEF_IDX=1
render_port_choices() {
  local cur=$1 mode=$2 title_k=$3 intro_k=$4 i p tag
  local -a tags
  DEF_IDX=1
  title "$(t "$title_k")"
  printf '%s\n' "$(t "$intro_k")"
  for i in "${!ALLOWED_PORTS[@]}"; do
    p=${ALLOWED_PORTS[i]}
    [[ $p == "$cur" ]] && DEF_IDX=$((i + 1))
    tags=()
    [[ $p == 443 ]] && tags+=("$(t port_default)")
    [[ $mode == modify && $p == "$cur" ]] && tags+=("$(t current)")
    tag=""
    if ((${#tags[@]} == 2)); then tag=" (${tags[0]}, ${tags[1]})"
    elif ((${#tags[@]} == 1)); then tag=" (${tags[0]})"
    fi
    printf '  %d. %s%s\n' "$((i + 1))" "$p" "$tag"
  done
}

pick_allowed_port() {
  local c=$1
  c=${c//[[:space:]]/}
  if [[ $c =~ ^[1-9][0-9]*$ ]] && ((c >= 1 && c <= ${#ALLOWED_PORTS[@]})); then
    printf '%s' "${ALLOWED_PORTS[c - 1]}"
    return 0
  elif valid_port "$c"; then
    printf '%s' "$c"
    return 0
  fi
  return 1
}

# Collect shared port when installing Hysteria2 + VLESS together
collect_shared_port() {
  local p out c
  if [[ -n $OPT_PORT ]] || ((ASSUME_YES)); then
    p=${OPT_PORT:-443}
    valid_port "$p" || die "$(t bad_port "${ALLOWED_PORTS[*]}")"
    out=$(port_users_except u "$p" '"hysteria"')
    [[ -n $out ]] && { err "$(t port_busy "$p" udp)"; echo "$out"; die "$(t udp_port_required "$p")"; }
    out=$(port_users_except t "$p" '"hysteria"|"sing-box"')
    [[ -n $out ]] && { err "$(t port_busy "$p" tcp)"; echo "$out"; die "$(t tcp_port_required "$p")"; }
    HY_PORT=$p VL_PORT=$p HY_TCP_MASQ=yes
    return 0
  fi
  render_port_choices "$HY_PORT" install port_title_both port_intro_both
  while :; do
    ask c "$(t port_choose "${#ALLOWED_PORTS[@]}")" "$DEF_IDX"
    if ! p=$(pick_allowed_port "$c"); then
      err "$(t bad_port "${ALLOWED_PORTS[*]}")"; continue
    fi
    out=$(port_users_except u "$p" '"hysteria"')
    if [[ -n $out ]]; then err "$(t port_busy "$p" udp)"; echo "$out"; warn "$(t port_retry)"; continue; fi
    out=$(port_users_except t "$p" '"hysteria"|"sing-box"')
    if [[ -n $out ]]; then err "$(t port_busy "$p" tcp)"; echo "$out"; warn "$(t port_retry)"; continue; fi
    HY_PORT=$p VL_PORT=$p HY_TCP_MASQ=yes
    return 0
  done
}

# Collect Hysteria2 port (install | modify)
collect_hy_port() {
  local mode=${1:-install} opt_p=${OPT_HY_PORT:-$OPT_PORT} p out c
  if [[ -n $opt_p ]] || ((ASSUME_YES)); then
    p=${opt_p:-$HY_PORT}
    valid_port "$p" || die "$(t bad_port "${ALLOWED_PORTS[*]}")"
    out=$(port_users_except u "$p" '"hysteria"')
    [[ -n $out ]] && { err "$(t port_busy "$p" udp)"; echo "$out"; die "$(t udp_port_required "$p")"; }
    if [[ $VL_ENABLED == yes && $VL_PORT == "$p" ]]; then
      ensure_local_port
    elif [[ $mode == install || $HY_TCP_MASQ == yes ]]; then
      out=$(port_users_except t "$p" '"hysteria"')
      if [[ -n $out ]]; then
        warn "$(t port_busy "$p" tcp)"; echo "$out"; warn "$(t tcp_port_busy "$p")"
        if confirm "$(t tcp_port_continue "$p")" n; then HY_TCP_MASQ=no; else die "$(t aborted)"; fi
      elif [[ $mode == install ]]; then
        HY_TCP_MASQ=yes
      fi
    fi
    HY_PORT=$p
    return 0
  fi

  render_port_choices "$HY_PORT" "$mode" port_title_hy port_intro_hy
  while :; do
    ask c "$(t port_choose "${#ALLOWED_PORTS[@]}")" "$DEF_IDX"
    if ! p=$(pick_allowed_port "$c"); then
      err "$(t bad_port "${ALLOWED_PORTS[*]}")"; continue
    fi
    [[ $mode == modify && $p == "$HY_PORT" ]] && return 0
    out=$(port_users_except u "$p" '"hysteria"')
    if [[ -n $out ]]; then err "$(t port_busy "$p" udp)"; echo "$out"; warn "$(t port_retry)"; continue; fi
    if [[ $VL_ENABLED == yes && $VL_PORT == "$p" ]]; then
      ensure_local_port
    elif [[ $mode == install || $HY_TCP_MASQ == yes ]]; then
      out=$(port_users_except t "$p" '"hysteria"')
      if [[ -n $out ]]; then
        warn "$(t port_busy "$p" tcp)"; echo "$out"; warn "$(t tcp_port_busy "$p")"
        if confirm "$(t tcp_port_continue "$p")" n; then
          HY_TCP_MASQ=no
        else
          warn "$(t port_retry)"; continue
        fi
      elif [[ $mode == install ]]; then
        HY_TCP_MASQ=yes
      fi
    fi
    HY_PORT=$p
    return 0
  done
}

# Collect VLESS TCP port (install | modify). If HY_ENABLED == yes and port == HY_PORT,
# hysteria's public TCP listener is excluded from conflict check since nodectl shifts it to loopback.
collect_vl_port() {
  local mode=${1:-install} opt_p=${OPT_VL_PORT:-$OPT_PORT} p out c excl
  if [[ -n $opt_p ]] || ((ASSUME_YES)); then
    p=${opt_p:-$VL_PORT}
    valid_port "$p" || die "$(t bad_port "${ALLOWED_PORTS[*]}")"
    excl='"sing-box"'
    [[ $HY_ENABLED == yes && $p == "$HY_PORT" ]] && excl='"sing-box"|"hysteria"'
    out=$(port_users_except t "$p" "$excl")
    [[ -n $out ]] && { err "$(t port_busy "$p" tcp)"; echo "$out"; die "$(t tcp_port_required "$p")"; }
    [[ $HY_ENABLED == yes && $p == "$HY_PORT" ]] && ensure_local_port
    VL_PORT=$p
    return 0
  fi

  render_port_choices "$VL_PORT" "$mode" port_title_vl port_intro_vl
  while :; do
    ask c "$(t port_choose "${#ALLOWED_PORTS[@]}")" "$DEF_IDX"
    if ! p=$(pick_allowed_port "$c"); then
      err "$(t bad_port "${ALLOWED_PORTS[*]}")"; continue
    fi
    [[ $mode == modify && $p == "$VL_PORT" ]] && return 0
    excl='"sing-box"'
    [[ $HY_ENABLED == yes && $p == "$HY_PORT" ]] && excl='"sing-box"|"hysteria"'
    out=$(port_users_except t "$p" "$excl")
    if [[ -n $out ]]; then err "$(t port_busy "$p" tcp)"; echo "$out"; warn "$(t port_retry)"; continue; fi
    [[ $HY_ENABLED == yes && $p == "$HY_PORT" ]] && ensure_local_port
    VL_PORT=$p
    return 0
  done
}

collect_hy_name() {
  local n opt=${OPT_HY_NAME:-$OPT_NAME} def=${HY_NAME:-hy2-$HY_DOMAIN}
  if [[ -n $opt ]]; then n=$opt
  elif ((ASSUME_YES)); then n=$def
  else ask n "$(t ask_hy_name)" "$def"; fi
  HY_NAME=${n:-$def}
}

collect_vl_name() {
  local addr n opt=${OPT_VL_NAME:-} def
  [[ -z $opt && $1 == single ]] && opt=$OPT_NAME
  addr=$(vl_effective_addr)
  def=${VL_NAME:-vless-${addr:-node}}
  if [[ -n $opt ]]; then n=$opt
  elif ((ASSUME_YES)); then n=$def
  else ask n "$(t ask_vl_name)" "$def"; fi
  VL_NAME=${n:-$def}
}

ask_bw() {
  local __var=$1 __v
  while :; do
    ask __v "$2" "${3:-}"
    __v=$(parse_bw "$__v") && break
    err "$(t bad_bw)"
  done
  printf -v "$__var" '%s' "$__v"
}

print_bw_directions() {
  local k
  for k in bw_dir1 bw_dir2 bw_dir3 bw_dir4 bw_dir5 bw_dir6; do
    if [[ $k == bw_dir1 ]]; then echo -e "\033[33m$(t "$k")\033[0m"; else printf '%s\n' "$(t "$k")"; fi
  done
}

collect_bandwidth() {
  local mode=${HY_BW_MODE:-client} up=$HY_BW_UP down=$HY_BW_DOWN c def
  if [[ -n $OPT_BW_MODE$OPT_UP$OPT_DOWN ]]; then
    up=0 down=0
    if [[ -n $OPT_UP ]]; then up=$(parse_bw "$OPT_UP") || die "$(t bad_bw)"; fi
    if [[ -n $OPT_DOWN ]]; then down=$(parse_bw "$OPT_DOWN") || die "$(t bad_bw)"; fi
    case ${OPT_BW_MODE,,} in
      client | limit | bbr) mode=${OPT_BW_MODE,,} ;;
      '') if ((up == 0 && down == 0)); then mode=bbr; else mode=limit; fi ;;
      *) die "$(t bad_bw_mode "$OPT_BW_MODE")" ;;
    esac
  elif ((!ASSUME_YES)); then
    title "$(t bw_title)"
    printf '%s\n' "$(t bw_intro1)"
    printf '%s\n' "$(t bw_intro2)"
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
      if [[ $HY_BW_MODE == limit ]]; then
        ask_bw up "$(t ask_bw_up)" "$HY_BW_UP"
        ask_bw down "$(t ask_bw_down)" "$HY_BW_DOWN"
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
  HY_BW_MODE=$mode HY_BW_UP=$up HY_BW_DOWN=$down
}

print_install_summary() {
  local mode=$1 hy_listen lhttps
  title "$(t summary_title)"
  case $mode in
    both)
      printf '  %-16s: %s\n' "$(t sum_mode)" "Hysteria2 + VLESS (REALITY)"
      ;;
    hy2)
      printf '  %-16s: %s\n' "$(t sum_mode)" "Hysteria2"
      ;;
    vless)
      printf '  %-16s: %s\n' "$(t sum_mode)" "VLESS (XTLS-Vision + REALITY)"
      ;;
  esac
  if [[ $mode == both || $mode == hy2 ]]; then
    lhttps=$(hy_effective_listen_https)
    hy_listen="UDP $HY_PORT"
    if [[ $lhttps == :* ]]; then hy_listen+=" + TCP $HY_PORT (HTTPS)"
    elif [[ -n $lhttps ]]; then hy_listen+=" + $lhttps (loopback HTTPS)"
    fi
    printf '  %-16s: %s\n' \
      "$(t sum_domain)" "$HY_DOMAIN" \
      "$(t sum_email)" "${HY_EMAIL:-$(t none)}" \
      "$(t sum_hy_listen)" "$hy_listen" \
      "$(t sum_hy_masq)" "$HY_MASQ_URL" \
      "$(t sum_hy_pass)" "$HY_PASSWORD" \
      "$(t sum_hy_bw)" "$(bw_label)" \
      "$(t sum_hy_name)" "$HY_NAME"
  fi
  if [[ $mode == both || $mode == vless ]]; then
    printf '  %-16s: %s\n' \
      "$(t sum_vl_listen)" "TCP $VL_PORT" \
      "$(t sum_vl_masq)" "$(vl_masq_label)" \
      "$(t sum_vl_uuid)" "$VL_UUID" \
      "$(t sum_vl_fp)" "$VL_FP" \
      "$(t sum_vl_addr)" "$(uri_host "$(vl_effective_addr)")" \
      "$(t sum_vl_name)" "$VL_NAME"
  fi
  echo
}

# ---------------------------------------------------------------------------
# Cores, configuration & service orchestration
# ---------------------------------------------------------------------------
run_hy_installer() {
  local tmp rc
  tmp=$(mktemp) || return 1
  if ! curl -fsSL --retry 3 --max-time 60 "$HY_INSTALLER_URL" -o "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  bash "$tmp" "$@"; rc=$?
  rm -f "$tmp"
  return $rc
}

install_hy_core() {
  info "$(t installing_hy)"
  run_hy_installer || die "$(t hy_core_failed)"
  [[ -x $HY_BIN ]] || die "$(t hy_core_failed)"
}

install_sb_repo() {
  mkdir -p /etc/apt/keyrings
  curl -fsSL --retry 3 --max-time 30 "$SB_GPG_URL" -o "$SB_APT_KEY" || return 1
  chmod a+r "$SB_APT_KEY"
  cat >"$SB_APT_SRC" <<'EOF'
Types: deb
URIs: https://deb.sagernet.org/
Suites: *
Components: *
Enabled: yes
Signed-By: /etc/apt/keyrings/sagernet.asc
EOF
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq sing-box >/dev/null
}

run_sb_installer() {
  local tmp rc
  tmp=$(mktemp) || return 1
  if ! curl -fsSL --retry 3 --max-time 60 "$SB_INSTALLER_URL" -o "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  sh "$tmp"; rc=$?
  rm -f "$tmp"
  return $rc
}

install_sb_core() {
  [[ -n $(sb_bin) ]] && return 0
  info "$(t installing_sb)"
  if ! install_sb_repo; then
    run_sb_installer || die "$(t sb_core_failed)"
  fi
  [[ -n $(sb_bin) ]] || die "$(t sb_core_failed)"
}

gen_reality_keypair() {
  local sb out priv pub
  sb=$(sb_bin)
  [[ -n $sb ]] || return 1
  out=$("$sb" generate reality-keypair 2>/dev/null) || return 1
  priv=$(awk -F'[:[:space:]"]+' '/PrivateKey/{print $2; exit}' <<<"$out")
  pub=$(awk -F'[:[:space:]"]+' '/PublicKey/{print $2; exit}' <<<"$out")
  [[ -n $priv && -n $pub ]] || return 1
  VL_PRIVATE_KEY=$priv
  VL_PUBLIC_KEY=$pub
  [[ -n $VL_SHORT_ID ]] || VL_SHORT_ID=$(gen_short_id)
}

prepare_hy_dirs() {
  mkdir -p "$HY_DIR" "$HY_ACME_DIR" "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  if id hysteria >/dev/null 2>&1; then chown -R hysteria:hysteria "$HY_DATA"; fi
}

prepare_sb_dirs() {
  mkdir -p "$SB_DIR" "$SB_DATA" "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  if id sing-box >/dev/null 2>&1; then chown -R sing-box:sing-box "$SB_DATA"; fi
}

sync_sb_systemd_dropin() {
  if [[ $VL_ENABLED == yes && $HY_ENABLED == yes && $VL_MASQ_MODE == hy2 ]]; then
    mkdir -p "$SB_DROPIN_DIR"
    cat >"$SB_DROPIN_FILE" <<EOF
[Unit]
After=$HY_SERVICE
EOF
  else
    rm -f "$SB_DROPIN_FILE"
    rmdir "$SB_DROPIN_DIR" 2>/dev/null || true
  fi
}

write_hy_config() {
  local tmp lhttps
  lhttps=$(hy_effective_listen_https)
  tmp=$(mktemp) || die "mktemp failed"
  {
    echo "# Generated by nodectl.sh v$SCRIPT_VERSION on $(date '+%F %T')"
    echo "# Manual edits will be overwritten when configuration is modified via nodectl."
    echo
    echo "listen: :$HY_PORT"
    echo
    echo "acme:"
    echo "  domains:"
    echo "    - $HY_DOMAIN"
    [[ -n $HY_EMAIL ]] && echo "  email: $(yaml_str "$HY_EMAIL")"
    echo "  ca: letsencrypt"
    echo "  dir: $HY_ACME_DIR"
    echo "  type: http"
    echo
    echo "auth:"
    echo "  type: password"
    echo "  password: $(yaml_str "$HY_PASSWORD")"
    echo
    echo "masquerade:"
    echo "  type: proxy"
    echo "  proxy:"
    echo "    url: $(yaml_str "$HY_MASQ_URL")"
    echo "    rewriteHost: true"
    [[ -n $lhttps ]] && echo "  listenHTTPS: $(yaml_str "$lhttps")"
    case $HY_BW_MODE in
      limit)
        echo
        echo "bandwidth:"
        ((HY_BW_UP > 0)) && echo "  up: ${HY_BW_UP} mbps"
        ((HY_BW_DOWN > 0)) && echo "  down: ${HY_BW_DOWN} mbps"
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

write_sb_config() {
  local tmp sb sni hs_host hs_port
  sb=$(sb_bin)
  sni=$(vl_effective_sni)
  read -r hs_host hs_port <<<"$(vl_effective_handshake)"
  tmp=$(mktemp) || die "mktemp failed"
  cat >"$tmp" <<EOF
{
  "log": {
    "level": "info",
    "timestamp": true
  },
  "inbounds": [
    {
      "type": "vless",
      "tag": "vless-in",
      "listen": "::",
      "listen_port": $VL_PORT,
      "users": [
        {
          "uuid": $(json_str "$VL_UUID"),
          "flow": "xtls-rprx-vision"
        }
      ],
      "tls": {
        "enabled": true,
        "server_name": $(json_str "$sni"),
        "reality": {
          "enabled": true,
          "handshake": {
            "server": $(json_str "$hs_host"),
            "server_port": $hs_port
          },
          "private_key": $(json_str "$VL_PRIVATE_KEY"),
          "short_id": [
            $(json_str "$VL_SHORT_ID")
          ]
        }
      }
    }
  ],
  "outbounds": [
    {
      "type": "direct",
      "tag": "direct"
    }
  ]
}
EOF
  if [[ -n $sb ]]; then
    local chk_err
    if ! chk_err=$("$sb" check -c "$tmp" 2>&1); then
      rm -f "$tmp"
      err "$(t sb_check_fail)"
      echo "$chk_err" >&2
      return 1
    fi
  fi
  install -m 640 -o root -g "$(sb_group)" "$tmp" "$SB_CONF"
  rm -f "$tmp"
}

tune_hy_sysctl() {
  cat >"$HY_SYSCTL_FILE" <<'EOF'
# Added by nodectl.sh: larger UDP buffers for QUIC (recommended by Hysteria)
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
EOF
  if sysctl -p "$HY_SYSCTL_FILE" >/dev/null 2>&1; then info "$(t sysctl_done)"; else warn "$(t sysctl_fail)"; fi
}

# ---- Kernel TCP BBR -------------------------------------------------------
bbr_cc()      { cat "$PROC_NET/ipv4/tcp_congestion_control" 2>/dev/null || echo "-"; }
bbr_qdisc()   { cat "$PROC_NET/core/default_qdisc" 2>/dev/null || echo "-"; }
bbr_managed() { [[ -f $BBR_FILE ]]; }
bbr_supported() {
  grep -qw bbr "$PROC_NET/ipv4/tcp_available_congestion_control" 2>/dev/null && return 0
  modprobe tcp_bbr >/dev/null 2>&1
  grep -qw bbr "$PROC_NET/ipv4/tcp_available_congestion_control" 2>/dev/null
}
bbr_prev() { sed -n "s/^# previous_$1=\([A-Za-z0-9_]*\)$/\1/p" "$BBR_FILE" 2>/dev/null | head -n 1; }

migrate_legacy_bbr() {
  if [[ -f $LEGACY_BBR_FILE && ! -f $BBR_FILE ]]; then
    local cc qdisc
    cc=$(sed -n 's/^# previous_cc=\([A-Za-z0-9_]*\)$/\1/p' "$LEGACY_BBR_FILE" 2>/dev/null | head -n 1)
    qdisc=$(sed -n 's/^# previous_qdisc=\([A-Za-z0-9_]*\)$/\1/p' "$LEGACY_BBR_FILE" 2>/dev/null | head -n 1)
    {
      echo "# Added by nodectl.sh: kernel TCP BBR. Remove via 'nodectl bbr off'."
      echo "# previous_cc=${cc:-cubic}"
      echo "# previous_qdisc=${qdisc:-fq_codel}"
      echo "net.core.default_qdisc = fq"
      echo "net.ipv4.tcp_congestion_control = bbr"
    } >"$BBR_FILE"
    rm -f "$LEGACY_BBR_FILE"
  fi
  if [[ -f $LEGACY_BBR_MODLOAD && ! -f $BBR_MODLOAD ]]; then
    mv -f "$LEGACY_BBR_MODLOAD" "$BBR_MODLOAD"
  fi
}

bbr_status() {
  title "$(t bbr_title)"
  printf '%s\n' "$(t bbr_cur "$(bbr_cc)" "$(bbr_qdisc)")"
  if [[ $(bbr_cc) == bbr ]]; then
    if bbr_managed; then info "$(t bbr_by_us "$BBR_FILE")"; else info "$(t bbr_by_other)"; fi
  fi
  printf '%s\n' "$(t bbr_scope)"
}

bbr_enable() {
  local cc qdisc
  cc=$(bbr_cc) qdisc=$(bbr_qdisc)
  if [[ $cc == bbr ]]; then bbr_status; return 0; fi
  bbr_supported || { err "$(t bbr_unsupported)"; return 1; }
  printf '%s\n' "$(t bbr_scope)"
  confirm "$(t bbr_confirm_on)" y || { info "$(t aborted)"; return 0; }
  {
    echo "# Added by nodectl.sh: kernel TCP BBR. Remove via 'nodectl bbr off'."
    echo "# previous_cc=$cc"
    echo "# previous_qdisc=$qdisc"
    echo "net.core.default_qdisc = fq"
    echo "net.ipv4.tcp_congestion_control = bbr"
  } >"$BBR_FILE"
  echo tcp_bbr >"$BBR_MODLOAD"
  if sysctl -p "$BBR_FILE" >/dev/null 2>&1 && [[ $(bbr_cc) == bbr ]]; then
    info "$(t bbr_on_ok)"
  else
    rm -f "$BBR_FILE" "$BBR_MODLOAD"
    sysctl -w "net.ipv4.tcp_congestion_control=$cc" "net.core.default_qdisc=$qdisc" >/dev/null 2>&1
    err "$(t bbr_on_fail)"
    return 1
  fi
}

bbr_disable() {
  local cc qdisc
  bbr_managed || { info "$(t bbr_not_ours)"; return 0; }
  cc=$(bbr_prev cc) qdisc=$(bbr_prev qdisc)
  [[ -z $cc || $cc == bbr ]] && cc=cubic
  [[ -z $qdisc ]] && qdisc=fq_codel
  if [[ ${1:-} != --yes ]] && ! confirm "$(t bbr_confirm_off "$cc")" n; then info "$(t aborted)"; return 0; fi
  rm -f "$BBR_FILE" "$BBR_MODLOAD"
  sysctl -w "net.ipv4.tcp_congestion_control=$cc" "net.core.default_qdisc=$qdisc" >/dev/null 2>&1
  sysctl --system >/dev/null 2>&1
  info "$(t bbr_off_ok "$(bbr_cc)")"
}

bbr_toggle() {
  if [[ $(bbr_cc) == bbr ]]; then
    if bbr_managed; then bbr_status; echo; bbr_disable; else bbr_status; fi
  else
    bbr_status; echo; bbr_enable
  fi
}

# ---- Firewall hints (never modify ufw automatically) ----------------------
ufw_active() { command -v ufw >/dev/null && ufw status 2>/dev/null | grep -q '^Status: active'; }

required_ports_desc() {
  local -a items=()
  if [[ $HY_ENABLED == yes ]]; then
    items+=("UDP $HY_PORT" "TCP 80")
    [[ $(hy_effective_listen_https) == :* ]] && items+=("TCP $HY_PORT")
  fi
  if [[ $VL_ENABLED == yes ]]; then
    items+=("TCP $VL_PORT")
  fi
  local out="" p
  for p in "${items[@]}"; do
    [[ -n $out ]] && out+=", "
    out+=$p
  done
  printf '%s' "$out"
}

ufw_allow_hint() {
  local -a cmds=()
  if [[ $HY_ENABLED == yes ]]; then
    cmds+=("ufw allow 80/tcp" "ufw allow $HY_PORT/udp")
    [[ $(hy_effective_listen_https) == :* ]] && cmds+=("ufw allow $HY_PORT/tcp")
  fi
  if [[ $VL_ENABLED == yes ]]; then
    cmds+=("ufw allow $VL_PORT/tcp")
  fi
  local out="" c
  for c in "${cmds[@]}"; do
    [[ -n $out ]] && out+=" && "
    out+=$c
  done
  printf '%s' "$out"
}

warn_firewall() {
  local ports
  ports=$(required_ports_desc)
  [[ -z $ports ]] && return 0
  if ufw_active; then
    warn "$(t fw_ufw_manual "$ports" "$(ufw_allow_hint)")"
  fi
  warn "$(t fw_cloud "$ports")"
}

# ---- Service startup & verification ---------------------------------------
restart_and_verify_hy() {
  local since state logs i
  since=$(date '+%Y-%m-%d %H:%M:%S')
  systemctl daemon-reload
  systemctl enable "$HY_SERVICE" >/dev/null 2>&1
  systemctl restart "$HY_SERVICE"
  printf '\033[32m[INFO]\033[0m %s' "$(t starting_hy)"
  for ((i = 0; i < 90; i++)); do
    sleep 2
    printf '.'
    logs=$(journalctl -u "$HY_SERVICE" --since "$since" --no-pager -o cat 2>/dev/null)
    state=$(systemctl is-active "$HY_SERVICE" 2>/dev/null)
    if grep -q 'server up and running' <<<"$logs"; then
      echo
      info "$(t hy_start_ok)"
      return 0
    fi
    if grep -q 'FATAL' <<<"$logs" || [[ $state == failed || $state == inactive ]]; then
      echo
      err "$(t hy_start_fail)"
      tail -n 30 <<<"$logs"
      warn "$(t hy_fail_hints)"
      return 1
    fi
  done
  echo
  err "$(t hy_start_timeout)"
  tail -n 30 <<<"$logs"
  warn "$(t hy_fail_hints)"
  return 1
}

restart_and_verify_sb() {
  local since state logs i
  since=$(date '+%Y-%m-%d %H:%M:%S')
  sync_sb_systemd_dropin
  systemctl daemon-reload
  systemctl enable "$SB_SERVICE" >/dev/null 2>&1
  info "$(t starting_sb)"
  systemctl restart "$SB_SERVICE"
  for ((i = 0; i < 15; i++)); do
    sleep 1
    logs=$(journalctl -u "$SB_SERVICE" --since "$since" --no-pager -o cat 2>/dev/null)
    state=$(systemctl is-active "$SB_SERVICE" 2>/dev/null)
    if [[ $state == active ]] && [[ -n $(ss -H -tln "sport = :$VL_PORT" 2>/dev/null) ]]; then
      info "$(t sb_start_ok)"
      return 0
    fi
    if grep -qi 'FATAL' <<<"$logs" || [[ $state == failed || $state == inactive ]]; then
      err "$(t sb_start_fail)"
      tail -n 30 <<<"$logs"
      return 1
    fi
  done
  err "$(t sb_start_fail)"
  tail -n 30 <<<"$logs"
  return 1
}

# ---- Atomic backups & coordinated apply_changes ---------------------------
backup_configs() {
  LAST_BACKUP_TS=$(date +%Y%m%d-%H%M%S)
  mkdir -p "$BACKUP_DIR"
  chmod 700 "$BACKUP_DIR"
  [[ -f $STATE_FILE ]] && cp -a "$STATE_FILE" "$BACKUP_DIR/state.env.$LAST_BACKUP_TS"
  [[ -f $HY_CONF ]] && cp -a "$HY_CONF" "$BACKUP_DIR/hy-config.yaml.$LAST_BACKUP_TS"
  [[ -f $SB_CONF ]] && cp -a "$SB_CONF" "$BACKUP_DIR/sb-config.json.$LAST_BACKUP_TS"
  local f ts
  # shellcheck disable=SC2012
  while read -r f; do
    [[ -n $f ]] || continue
    ts=${f##*.state.env.}
    ts=${f##*state.env.}
    rm -f "$BACKUP_DIR/state.env.$ts" "$BACKUP_DIR/hy-config.yaml.$ts" "$BACKUP_DIR/sb-config.json.$ts"
  done < <(ls -1t "$BACKUP_DIR"/state.env.* 2>/dev/null | tail -n +11)
}

restore_backup() {
  local ts=$1
  [[ -f "$BACKUP_DIR/state.env.$ts" ]] && install -m 600 "$BACKUP_DIR/state.env.$ts" "$STATE_FILE"
  [[ -f "$BACKUP_DIR/hy-config.yaml.$ts" ]] && install -m 640 -o root -g "$(hy_group)" "$BACKUP_DIR/hy-config.yaml.$ts" "$HY_CONF"
  [[ -f "$BACKUP_DIR/sb-config.json.$ts" ]] && install -m 640 -o root -g "$(sb_group)" "$BACKUP_DIR/sb-config.json.$ts" "$SB_CONF"
  load_state
  sync_sb_systemd_dropin
  systemctl daemon-reload
  if [[ $(hy_effective_listen_https) == :* ]]; then
    [[ $VL_ENABLED == yes ]] && systemctl restart "$SB_SERVICE" >/dev/null 2>&1
    [[ $HY_ENABLED == yes ]] && restart_and_verify_hy >/dev/null 2>&1
  else
    [[ $HY_ENABLED == yes ]] && restart_and_verify_hy >/dev/null 2>&1
    [[ $VL_ENABLED == yes ]] && systemctl restart "$SB_SERVICE" >/dev/null 2>&1
  fi
}

# apply_changes <hy|vl|both> [--firewall]
# Automatically orders service restarts when public TCP ports hand off between HY2 and VLESS.
apply_changes() {
  local scope=${1:-both} fw_hint=0 ok=1
  [[ ${2:-} == --firewall ]] && fw_hint=1
  backup_configs
  if [[ $HY_ENABLED == yes ]]; then write_hy_config; fi
  if [[ $VL_ENABLED == yes ]]; then
    if ! write_sb_config; then
      restore_backup "$LAST_BACKUP_TS"
      warn "$(t backup_restored)"
      return 1
    fi
  fi
  save_state

  if [[ $scope == both ]]; then
    if [[ $(hy_effective_listen_https) == :* ]]; then
      [[ $VL_ENABLED == yes ]] && { restart_and_verify_sb || ok=0; }
      ((ok)) && [[ $HY_ENABLED == yes ]] && { restart_and_verify_hy || ok=0; }
    else
      [[ $HY_ENABLED == yes ]] && { restart_and_verify_hy || ok=0; }
      ((ok)) && [[ $VL_ENABLED == yes ]] && { restart_and_verify_sb || ok=0; }
    fi
  elif [[ $scope == hy ]]; then
    restart_and_verify_hy || ok=0
  elif [[ $scope == vl ]]; then
    restart_and_verify_sb || ok=0
  fi

  if ((ok)); then
    ((fw_hint)) && warn_firewall
    show_share
    return 0
  fi
  restore_backup "$LAST_BACKUP_TS"
  warn "$(t backup_restored)"
  return 1
}

# ---------------------------------------------------------------------------
# Versioning, shortcut & seamless migration from hy2.sh
# ---------------------------------------------------------------------------
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

detect_installed_version() {
  if [[ -f $STATE_FILE ]]; then
    [[ -n $INSTALLED_VERSION ]] && { echo "$INSTALLED_VERSION"; return 0; }
    local v
    v=$(sed -n 's/^INSTALLED_VERSION=\([0-9.]*\)$/\1/p' "$STATE_FILE" 2>/dev/null | tr -d "\"'" | head -n 1)
    echo "${v:-unknown}"
    return 0
  fi
  if [[ -f $LEGACY_HY_STATE ]]; then
    if [[ -n $INSTALLED_VERSION ]]; then echo "$INSTALLED_VERSION"; return 0; fi
    local v
    v=$(sed -n '1s/^# Generated by hy2.sh v\([0-9.]*\) .*/\1/p' "$HY_CONF" 2>/dev/null)
    if [[ -n $v ]] && grep -q '^BW_MODE=' "$LEGACY_HY_STATE"; then echo "$v"; else echo "${v:-unknown}"; fi
    return 0
  fi
  return 1
}

# none | partial | legacy | newer | current
version_state() {
  local v
  if [[ ! -f $STATE_FILE && ! -f $LEGACY_HY_STATE ]]; then
    if [[ -x $HY_BIN || -d $HY_DIR || -f $SB_CONF ]]; then echo partial; else echo none; fi
    return
  fi
  if ! hy_core_present && ! sb_core_present; then
    echo partial
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

script_file_version() { sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' "$1" 2>/dev/null | head -n 1; }

fetch_script() {
  local v
  curl -fsSL --max-time "${2:-20}" "$SCRIPT_URL" -o "$1" 2>/dev/null || { err "$(t su_fetch_fail "$SCRIPT_URL")"; return 1; }
  v=$(script_file_version "$1")
  if [[ -z $v ]] || ! grep -q '^# nodectl\.sh -' "$1" || ! bash -n "$1" 2>/dev/null; then
    err "$(t su_invalid)"; return 1
  fi
  echo "$v"
}

install_shortcut() {
  local src="" tmp
  ((FROM_PIPE)) || src=$(readlink -f "$0" 2>/dev/null)
  [[ $src == "$SHORTCUT" ]] && return 0
  tmp=$(mktemp "$SHORTCUT.XXXXXX") || { warn "$(t shortcut_skip)"; return 1; }
  if [[ -f $src ]] && grep -q '^# nodectl\.sh -' "$src"; then
    cp "$src" "$tmp"
  elif ! fetch_script "$tmp" >/dev/null; then
    rm -f "$tmp"; warn "$(t shortcut_skip)"; return 1
  fi
  chmod 755 "$tmp" && mv -f "$tmp" "$SHORTCUT" && info "$(t shortcut_ok "$SHORTCUT")"
}

sync_shortcut() {
  local v
  v=$(script_file_version "$SHORTCUT")
  [[ -n $v ]] && ! ver_lt "$v" "$SCRIPT_VERSION" && return 0
  install_shortcut
}

remove_legacy_hy2_shortcut() {
  if [[ -e $LEGACY_HY2_SHORTCUT || -L $LEGACY_HY2_SHORTCUT ]]; then
    rm -f "$LEGACY_HY2_SHORTCUT"
    info "$(t legacy_hy2_removed)"
  fi
}

# Adopt an installation from older nodectl OR migrate seamlessly from hy2.sh (>= 1.3.1).
# Existing Hysteria2 config & running service remain untouched (zero downtime).
adopt_installation() {
  local vs from from_hy2=0
  vs=$(version_state)
  if [[ $vs == legacy ]]; then
    # Even for legacy (<1.3.1), if invoked via upgrade path clean up old hy2 shortcut once
    if [[ -f $LEGACY_HY_STATE && -e $LEGACY_HY2_SHORTCUT ]]; then
      sync_shortcut
      remove_legacy_hy2_shortcut
    fi
    return 0
  fi
  [[ $vs == current ]] || return 0

  [[ -f $LEGACY_HY_STATE && ! -f $STATE_FILE ]] && from_hy2=1
  from=$(detect_installed_version)

  if ((!from_hy2)) && [[ $from == "$SCRIPT_VERSION" ]]; then
    sync_shortcut
    [[ -e $LEGACY_HY2_SHORTCUT ]] && remove_legacy_hy2_shortcut
    # If self_update handed over NODECTL_UPGRADED_FROM, display changelog once
    if [[ -n ${NODECTL_UPGRADED_FROM:-} ]] && ((!UPGRADED_NOTICE_SHOWN)); then
      UPGRADED_NOTICE_SHOWN=1
      show_changelog "$NODECTL_UPGRADED_FROM"
      [[ $CMD == menu ]] && pause
    fi
    return 0
  fi

  migrate_legacy_bbr
  save_state
  [[ -f $LEGACY_HY_STATE ]] && rm -f "$LEGACY_HY_STATE"
  sync_shortcut
  remove_legacy_hy2_shortcut

  MIGRATED_FROM=$from
  UPGRADED_NOTICE_SHOWN=1
  if ((from_hy2)); then
    info "$(t ver_migrated "$from" "$SCRIPT_VERSION")"
  else
    info "$(t ver_adopted "$from" "$SCRIPT_VERSION")"
  fi
  show_changelog "$from"
  [[ $CMD == menu ]] && pause
}

check_remote_version() {
  [[ -n ${NODECTL_NO_UPDATE_CHECK:-}${HY2_NO_UPDATE_CHECK:-} ]] && return 0
  REMOTE_VERSION=$(curl -fsSL --max-time 3 "$SCRIPT_URL" 2>/dev/null |
    sed -n 's/^SCRIPT_VERSION="\([0-9.]*\)"$/\1/p' | head -n 1)
}

update_available() { [[ -n $REMOTE_VERSION ]] && ver_lt "$SCRIPT_VERSION" "$REMOTE_VERSION"; }

self_update() {
  local tmp v
  info "$(t su_checking)"
  tmp=$(mktemp "$SHORTCUT.XXXXXX") || return 1
  if ! v=$(fetch_script "$tmp"); then rm -f "$tmp"; return 1; fi
  if ! ver_lt "$SCRIPT_VERSION" "$v"; then
    info "$(t su_latest "$SCRIPT_VERSION")"; rm -f "$tmp"; sync_shortcut; return 0
  fi
  if [[ ${1:-} != --yes ]] && ! confirm "$(t su_confirm "$SCRIPT_VERSION" "$v")" y; then
    rm -f "$tmp"; info "$(t aborted)"; return 0
  fi
  if ! { chmod 755 "$tmp" && mv -f "$tmp" "$SHORTCUT"; }; then
    rm -f "$tmp"; return 1
  fi
  remove_legacy_hy2_shortcut
  info "$(t su_done "$v")"
  if [[ $CMD == menu ]]; then
    NODECTL_NO_UPDATE_CHECK=1 NODECTL_UPGRADED_FROM="$SCRIPT_VERSION" exec bash "$SHORTCUT" --lang "$UI_LANG"
  fi
  NODECTL_NO_UPDATE_CHECK=1 bash "$SHORTCUT" --lang "$UI_LANG" changelog
  exit 0
}

require_manageable() {
  case $(version_state) in
    legacy) legacy_notice; return 1 ;;
    newer) err "$(t ver_newer "$(detect_installed_version)" "curl -fsSL $SCRIPT_URL | sudo bash")"; return 1 ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# Install / Update / Uninstall / Info actions
# ---------------------------------------------------------------------------
do_install_both() {
  require_manageable || return 1
  check_os
  load_state
  if hy_installed && ! confirm "$(t already_installed_hy)" n; then info "$(t aborted)"; return 0; fi
  if vl_installed && ! confirm "$(t already_installed_vl)" n; then info "$(t aborted)"; return 0; fi

  install_deps
  check_port80
  collect_domain
  if [[ -n $OPT_HY_PORT || -n $OPT_VL_PORT ]]; then
    HY_ENABLED=yes VL_ENABLED=yes
    collect_hy_port install
    collect_vl_port install
  else
    collect_shared_port
  fi
  collect_email
  collect_hy_masq
  collect_password keep
  collect_hy_name
  collect_bandwidth

  HY_ENABLED=yes
  VL_ENABLED=yes
  if [[ -n $OPT_VL_MASQ || -n $OPT_SNI ]]; then
    collect_vl_masq yes
  else
    VL_MASQ_MODE=hy2
    ensure_local_port
  fi
  collect_uuid keep
  collect_fp
  collect_vl_addr
  collect_vl_name both

  print_install_summary both
  confirm "$(t proceed)" y || { load_state; info "$(t aborted)"; return 0; }

  install_hy_core
  install_sb_core
  if [[ -z $VL_PRIVATE_KEY || -z $VL_PUBLIC_KEY ]]; then
    gen_reality_keypair || die "$(t sb_core_failed)"
  fi
  [[ -n $VL_SHORT_ID ]] || VL_SHORT_ID=$(gen_short_id)

  prepare_hy_dirs
  prepare_sb_dirs
  tune_hy_sysctl
  info "$(t writing_config)"
  write_hy_config
  write_sb_config || return 1
  warn_firewall
  save_state
  install_shortcut

  local ok=1
  if [[ $(hy_effective_listen_https) == :* ]]; then
    restart_and_verify_sb || ok=0
    ((ok)) && { restart_and_verify_hy || ok=0; }
  else
    restart_and_verify_hy || ok=0
    ((ok)) && { restart_and_verify_sb || ok=0; }
  fi
  if ((ok)); then
    show_share
    info "$(t install_done)"
    return 0
  fi
  return 1
}

do_install_hy() {
  require_manageable || return 1
  check_os
  load_state
  local prev_vl=$VL_ENABLED adopt_vl=0
  if hy_installed && ! confirm "$(t already_installed_hy)" n; then info "$(t aborted)"; return 0; fi

  install_deps
  check_port80
  collect_domain
  collect_hy_port install
  collect_email
  collect_hy_masq
  collect_password keep
  collect_hy_name
  collect_bandwidth

  HY_ENABLED=yes
  if [[ $prev_vl == yes ]] && vl_installed; then
    if [[ $VL_MASQ_MODE != hy2 ]]; then
      if [[ ${OPT_VL_MASQ,,} == hy2 ]]; then
        adopt_vl=1
      elif ((!ASSUME_YES)) && confirm "$(t vl_adopt_hy2_ask "$HY_DOMAIN")" y; then
        adopt_vl=1
      fi
      if ((adopt_vl)); then
        VL_MASQ_MODE=hy2
        ensure_local_port
      fi
    else
      ensure_local_port
    fi
  fi

  print_install_summary hy2
  confirm "$(t proceed)" y || { load_state; info "$(t aborted)"; return 0; }

  [[ $prev_vl == yes ]] && backup_configs
  install_hy_core
  prepare_hy_dirs
  tune_hy_sysctl
  info "$(t writing_config)"
  write_hy_config
  if [[ $prev_vl == yes ]] && vl_installed; then
    write_sb_config || { restore_backup "$LAST_BACKUP_TS"; warn "$(t backup_restored)"; return 1; }
  fi
  warn_firewall
  save_state
  install_shortcut

  local ok=1
  if [[ $prev_vl == yes ]] && vl_installed; then
    if [[ $(hy_effective_listen_https) == :* ]]; then
      restart_and_verify_sb || ok=0
      ((ok)) && { restart_and_verify_hy || ok=0; }
    else
      restart_and_verify_hy || ok=0
      ((ok)) && { restart_and_verify_sb || ok=0; }
    fi
    if ((!ok)); then
      restore_backup "$LAST_BACKUP_TS"
      warn "$(t backup_restored)"
      return 1
    fi
  else
    restart_and_verify_hy || return 1
  fi
  show_share
  info "$(t install_done)"
}

do_install_vl() {
  require_manageable || return 1
  check_os
  load_state
  local prev_hy=$HY_ENABLED
  if vl_installed && ! confirm "$(t already_installed_vl)" n; then info "$(t aborted)"; return 0; fi

  install_deps
  collect_vl_port install
  if [[ $prev_hy == yes ]] && hy_installed; then
    collect_vl_masq yes
  else
    collect_vl_masq no
  fi
  collect_uuid keep
  collect_fp
  collect_vl_addr
  VL_ENABLED=yes
  collect_vl_name single

  print_install_summary vless
  confirm "$(t proceed)" y || { load_state; info "$(t aborted)"; return 0; }

  [[ $prev_hy == yes ]] && backup_configs
  install_sb_core
  if [[ -z $VL_PRIVATE_KEY || -z $VL_PUBLIC_KEY ]]; then
    gen_reality_keypair || die "$(t sb_core_failed)"
  fi
  [[ -n $VL_SHORT_ID ]] || VL_SHORT_ID=$(gen_short_id)
  prepare_sb_dirs

  info "$(t writing_config)"
  if [[ $prev_hy == yes ]] && hy_installed; then
    write_hy_config
  fi
  if ! write_sb_config; then
    [[ $prev_hy == yes ]] && { restore_backup "$LAST_BACKUP_TS"; warn "$(t backup_restored)"; }
    return 1
  fi
  warn_firewall
  save_state
  install_shortcut

  local ok=1
  if [[ $prev_hy == yes ]] && hy_installed; then
    if [[ $(hy_effective_listen_https) == :* ]]; then
      restart_and_verify_sb || ok=0
      ((ok)) && { restart_and_verify_hy || ok=0; }
    else
      restart_and_verify_hy || ok=0
      ((ok)) && { restart_and_verify_sb || ok=0; }
    fi
    if ((!ok)); then
      restore_backup "$LAST_BACKUP_TS"
      warn "$(t backup_restored)"
      return 1
    fi
    if [[ $(hy_effective_listen_https) == 127.0.0.1:* ]]; then
      info "$(t tcpmasq_loopback "$HY_LOCAL_PORT" "$VL_PORT")"
    fi
  else
    restart_and_verify_sb || return 1
  fi
  show_share
  info "$(t install_done)"
}

do_install_dispatch() {
  require_manageable || return 1
  local mode=${TARGET,,} c
  if [[ -z $mode ]]; then
    if ((ASSUME_YES)); then
      if [[ -n $OPT_DOMAIN && -n $OPT_MASQ ]]; then
        if [[ -n $OPT_UUID$OPT_FP$OPT_VL_PORT$OPT_VL_MASQ$OPT_SNI ]]; then mode=both; else mode=hy2; fi
      elif [[ -n $OPT_SNI ]]; then
        mode=vless
      else
        mode=both
      fi
    else
      title "$(t install_mode_title)"
      echo "  1. $(t im_both)"
      echo "  2. $(t im_hy2)"
      echo "  3. $(t im_vless)"
      while :; do
        ask c "$(t choose) [1-3]" "1"
        case ${c//[[:space:]]/} in
          1) mode=both; break ;;
          2) mode=hy2; break ;;
          3) mode=vless; break ;;
          *) err "$(t invalid_choice)" ;;
        esac
      done
    fi
  fi
  case $mode in
    both | all) do_install_both ;;
    hy2 | hysteria | hysteria2) do_install_hy ;;
    vless | reality) do_install_vl ;;
    *) die "$(t unknown_arg "$mode")" ;;
  esac
}

do_update_hy() {
  need_hy_installed || return 1
  require_manageable || return 1
  local old new
  old=$(hy_version)
  info "$(t updating_hy)"
  run_hy_installer || { err "$(t hy_core_failed)"; return 1; }
  new=$(hy_version)
  info "$(t update_done "Hysteria2" "${old:--}" "${new:--}")"
  prepare_hy_dirs
  restart_and_verify_hy
}

do_update_sb() {
  need_vl_installed || return 1
  require_manageable || return 1
  local old new
  old=$(sb_version)
  info "$(t updating_sb)"
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -s sing-box >/dev/null 2>&1; then
    { apt-get update -qq && apt-get install --only-upgrade -y -qq sing-box >/dev/null; } || { err "$(t sb_core_failed)"; return 1; }
  else
    run_sb_installer || { err "$(t sb_core_failed)"; return 1; }
  fi
  new=$(sb_version)
  info "$(t update_done "sing-box" "${old:--}" "${new:--}")"
  prepare_sb_dirs
  restart_and_verify_sb
}

do_update_all() {
  need_any_installed || return 1
  require_manageable || return 1
  local rc=0
  if hy_installed; then do_update_hy || rc=1; fi
  if vl_installed; then do_update_sb || rc=1; fi
  return $rc
}

remove_hy_files() {
  systemctl disable --now "$HY_SERVICE" >/dev/null 2>&1
  run_hy_installer --remove >/dev/null 2>&1 || warn "$(t remove_warn)"
  rm -rf "$HY_DIR" "$HY_DATA"
  rm -f "$HY_BIN" /etc/systemd/system/hysteria-server.service /etc/systemd/system/hysteria-server@.service
  rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server.service
  rm -f /etc/systemd/system/multi-user.target.wants/hysteria-server@*.service
  userdel hysteria >/dev/null 2>&1 || true
  rm -f "$HY_SYSCTL_FILE"
}

remove_sb_files() {
  systemctl disable --now "$SB_SERVICE" >/dev/null 2>&1
  rm -f "$SB_DROPIN_FILE"
  rmdir "$SB_DROPIN_DIR" 2>/dev/null || true
  export DEBIAN_FRONTEND=noninteractive
  if dpkg -s sing-box >/dev/null 2>&1; then
    apt-get purge -y -qq sing-box >/dev/null 2>&1 || true
  fi
  rm -f "$SB_APT_SRC" "$SB_APT_KEY"
  rm -rf "$SB_DIR" "$SB_DATA"
  rm -f /usr/local/bin/sing-box /etc/systemd/system/sing-box.service
  rm -f /etc/systemd/system/multi-user.target.wants/sing-box.service
}

finalize_full_cleanup() {
  if bbr_managed && ((!ASSUME_YES)) && confirm "$(t bbr_keep)" n; then bbr_disable --yes; fi
  rm -rf "$STATE_DIR"
  systemctl daemon-reload
  info "$(t uninstall_all_done)"
  rm -f "$SHORTCUT" "$LEGACY_HY2_SHORTCUT"
  exit 0
}

do_uninstall_hy() {
  load_state
  if [[ ! -x $HY_BIN && ! -d $HY_DIR ]]; then err "$(t hy_not_installed)"; return 1; fi
  confirm "$(t uninstall_hy_confirm)" n || { info "$(t aborted)"; return 0; }

  # If VLESS remains and is reusing HY2's local masquerade, migrate VLESS to external SNI first
  if vl_installed && [[ $VL_MASQ_MODE == hy2 ]]; then
    warn "$(t hy_uninst_vl_dep)"
    collect_sni
    VL_MASQ_MODE=external
    collect_vl_addr
    HY_ENABLED=no
    sync_sb_systemd_dropin
    write_sb_config || { HY_ENABLED=yes; VL_MASQ_MODE=hy2; return 1; }
    restart_and_verify_sb || { HY_ENABLED=yes; VL_MASQ_MODE=hy2; return 1; }
  fi

  local old_ports="UDP $HY_PORT, TCP 80"
  [[ $HY_TCP_MASQ == yes ]] && old_ports+=", TCP $HY_PORT"
  remove_hy_files
  if ufw_active; then warn "$(t fw_ufw_uninstall "$old_ports")"; fi

  HY_ENABLED=no
  HY_DOMAIN="" HY_EMAIL="" HY_PASSWORD="" HY_MASQ_URL="" HY_NAME=""
  sync_sb_systemd_dropin
  systemctl daemon-reload

  if vl_installed; then
    save_state
    info "$(t uninstall_hy_done)"
    show_share
    return 0
  fi
  finalize_full_cleanup
}

do_uninstall_vl() {
  load_state
  if [[ -z $(sb_bin) && ! -d $SB_DIR ]]; then err "$(t vl_not_installed)"; return 1; fi
  confirm "$(t uninstall_vl_confirm)" n || { info "$(t aborted)"; return 0; }

  local old_port=$VL_PORT
  remove_sb_files
  if ufw_active; then warn "$(t fw_ufw_uninstall "TCP $old_port")"; fi

  VL_ENABLED=no
  VL_UUID="" VL_PRIVATE_KEY="" VL_PUBLIC_KEY="" VL_SHORT_ID="" VL_SNI="" VL_NAME=""
  systemctl daemon-reload

  if hy_installed; then
    # If HY2 wanted TCP_MASQ=yes and port is now free, restore HY2's public TCP masquerade listener
    if [[ $HY_TCP_MASQ == yes && -z $(port_users_except t "$HY_PORT" '"hysteria"') ]]; then
      write_hy_config
      restart_and_verify_hy >/dev/null 2>&1 || true
    fi
    save_state
    info "$(t uninstall_vl_done)"
    show_share
    return 0
  fi
  finalize_full_cleanup
}

do_uninstall_all() {
  load_state
  if [[ ! -x $HY_BIN && ! -d $HY_DIR && -z $(sb_bin) && ! -d $SB_DIR ]]; then
    err "$(t not_installed)"
    return 1
  fi
  confirm "$(t uninstall_all_confirm)" n || { info "$(t aborted)"; return 0; }
  local ports
  ports=$(required_ports_desc)
  [[ -x $HY_BIN || -d $HY_DIR ]] && remove_hy_files
  [[ -n $(sb_bin) || -d $SB_DIR ]] && remove_sb_files
  if [[ -n $ports ]] && ufw_active; then warn "$(t fw_ufw_uninstall "$ports")"; fi
  HY_ENABLED=no VL_ENABLED=no
  finalize_full_cleanup
}

do_uninstall_dispatch() {
  case ${TARGET,,} in
    '' | all | both) do_uninstall_all ;;
    hy2 | hysteria | hysteria2) do_uninstall_hy ;;
    vless | reality) do_uninstall_vl ;;
    *) die "$(t unknown_arg "$TARGET")" ;;
  esac
}

# Only node share links are printed (no client configs or QR codes).
show_share() {
  need_any_installed || return 1
  local filter=${1:-all}
  title "$(t share_title)"
  if [[ ($filter == all || $filter == hy2) ]] && hy_installed; then
    echo "hysteria2://$(urlencode "$HY_PASSWORD")@$HY_DOMAIN:$HY_PORT/?sni=$HY_DOMAIN#$(urlencode "$HY_NAME")"
  fi
  if [[ ($filter == all || $filter == vless) ]] && vl_installed; then
    local addr sni
    addr=$(uri_host "$(vl_effective_addr)")
    sni=$(vl_effective_sni)
    echo "vless://$VL_UUID@$addr:$VL_PORT?encryption=none&flow=xtls-rprx-vision&security=reality&sni=$sni&fp=$VL_FP&pbk=$(urlencode "$VL_PUBLIC_KEY")&sid=$VL_SHORT_ID&type=tcp#$(urlencode "$VL_NAME")"
  fi
}

show_status() {
  need_any_installed || return 1
  if hy_installed; then
    title "Hysteria2"
    systemctl status "$HY_SERVICE" --no-pager -l 2>/dev/null | head -n 10
  fi
  if vl_installed; then
    title "VLESS (sing-box)"
    systemctl status "$SB_SERVICE" --no-pager -l 2>/dev/null | head -n 10
  fi
  title "$(t listening)"
  if hy_installed; then
    ss -H -ulnp "sport = :$HY_PORT" 2>/dev/null
    local lhttps
    lhttps=$(hy_effective_listen_https)
    if [[ $lhttps == :* ]]; then
      ss -H -tlnp "sport = :$HY_PORT" 2>/dev/null
    elif [[ $lhttps == 127.0.0.1:* ]]; then
      ss -H -tlnp "sport = :$HY_LOCAL_PORT" 2>/dev/null
    fi
  fi
  if vl_installed; then
    ss -H -tlnp "sport = :$VL_PORT" 2>/dev/null
  fi
  echo
  printf '%s\n' "$(t bbr_cur "$(bbr_cc)" "$(bbr_qdisc)")"
}

show_hy_logs() {
  need_hy_installed || return 1
  info "$(t logs_hint)"
  trap ':' INT
  journalctl -u "$HY_SERVICE" -n 50 -f --no-pager
  trap - INT
}

show_vl_logs() {
  need_vl_installed || return 1
  info "$(t logs_hint)"
  trap ':' INT
  journalctl -u "$SB_SERVICE" -n 50 -f --no-pager
  trap - INT
}

find_cert() { find "$HY_ACME_DIR" -type f -name "$HY_DOMAIN.crt" 2>/dev/null | head -n 1; }

show_cert_info() {
  need_hy_installed || return 1
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
  need_hy_installed || return 1
  confirm "$(t reissue_confirm)" n || return 0
  systemctl stop "$HY_SERVICE"
  find "$HY_ACME_DIR" -mindepth 3 -maxdepth 3 -type d -path '*/certificates/*' -name "$HY_DOMAIN" \
    -exec rm -rf {} + 2>/dev/null
  restart_and_verify_hy
}

show_keys_info() {
  need_vl_installed || return 1
  title "$(t keys_title)"
  printf '  %-18s: %s\n' \
    "$(t lbl_pubkey)" "$VL_PUBLIC_KEY" \
    "$(t lbl_shortid)" "$VL_SHORT_ID"
}

reset_reality_keys() {
  need_vl_installed || return 1
  confirm "$(t reset_keys_confirm)" n || return 0
  local old_priv=$VL_PRIVATE_KEY old_pub=$VL_PUBLIC_KEY old_sid=$VL_SHORT_ID
  VL_SHORT_ID=""
  if ! gen_reality_keypair; then
    VL_PRIVATE_KEY=$old_priv VL_PUBLIC_KEY=$old_pub VL_SHORT_ID=$old_sid
    err "$(t sb_core_failed)"
    return 1
  fi
  apply_changes vl
}

# ---------------------------------------------------------------------------
# Configuration modification handlers
# ---------------------------------------------------------------------------
modify_hy_password() { collect_password new; apply_changes hy; }

modify_hy_port() {
  local old_port=$HY_PORT old_tcp=$HY_TCP_MASQ scope=hy
  collect_hy_port modify
  if [[ $HY_PORT == "$old_port" && $HY_TCP_MASQ == "$old_tcp" ]]; then
    info "$(t no_change)"; return 0
  fi
  vl_installed && scope=both
  if apply_changes "$scope" --firewall; then
    if [[ $(hy_effective_listen_https) == 127.0.0.1:* ]]; then
      info "$(t tcpmasq_loopback "$HY_LOCAL_PORT" "$VL_PORT")"
    elif [[ $HY_TCP_MASQ != "$old_tcp" ]]; then
      info "$(t tcpmasq_now "$(on_off "$HY_TCP_MASQ")")"
    fi
    return 0
  fi
  return 1
}

modify_hy_masq() {
  local old=$HY_MASQ_URL
  collect_hy_masq
  if [[ $HY_MASQ_URL == "$old" ]]; then info "$(t no_change)"; else apply_changes hy; fi
}

modify_hy_domain() {
  local old=$HY_DOMAIN scope=hy
  collect_domain
  if [[ $HY_DOMAIN == "$old" ]]; then info "$(t no_change)"; return 0; fi
  [[ $(url_host "$HY_MASQ_URL") == "$HY_DOMAIN" ]] && collect_hy_masq
  [[ $VL_ENABLED == yes && $VL_MASQ_MODE == hy2 ]] && scope=both
  apply_changes "$scope"
}

modify_hy_name() {
  local old=$HY_NAME
  ask HY_NAME "$(t ask_hy_name)" "$HY_NAME"
  HY_NAME=${HY_NAME:-$old}
  save_state; info "$(t saved)"; show_share
}

toggle_hy_tcp_masq() {
  if [[ $VL_ENABLED == yes && $VL_PORT == "$HY_PORT" ]]; then
    info "$(t tcpmasq_loopback "$HY_LOCAL_PORT" "$VL_PORT")"
    return 0
  fi
  local users scope=hy
  [[ $VL_ENABLED == yes && $VL_MASQ_MODE == hy2 ]] && scope=both
  if [[ $HY_TCP_MASQ == yes ]]; then
    HY_TCP_MASQ=no
    [[ $VL_ENABLED == yes && $VL_MASQ_MODE == hy2 ]] && ensure_local_port
    apply_changes "$scope" && info "$(t tcpmasq_now "$(on_off "$HY_TCP_MASQ")")"
  else
    users=$(port_users_except t "$HY_PORT" '"hysteria"')
    if [[ -n $users ]]; then err "$(t port_busy "$HY_PORT" tcp)"; echo "$users"; return 1; fi
    HY_TCP_MASQ=yes
    apply_changes "$scope" --firewall && info "$(t tcpmasq_now "$(on_off "$HY_TCP_MASQ")")"
  fi
}

modify_hy_bw() {
  local old="$HY_BW_MODE $HY_BW_UP $HY_BW_DOWN"
  collect_bandwidth
  if [[ "$HY_BW_MODE $HY_BW_UP $HY_BW_DOWN" == "$old" ]]; then info "$(t no_change)"; else apply_changes hy; fi
}

modify_vl_uuid() { collect_uuid new; apply_changes vl; }

modify_vl_port() {
  local old_port=$VL_PORT scope=vl
  collect_vl_port modify
  if [[ $VL_PORT == "$old_port" ]]; then info "$(t no_change)"; return 0; fi
  hy_installed && scope=both
  apply_changes "$scope" --firewall
}

modify_vl_masq() {
  local old_mode=$VL_MASQ_MODE old_sni=$VL_SNI scope=vl
  if hy_installed; then
    collect_vl_masq yes
    scope=both
  else
    collect_sni
  fi
  if [[ $VL_MASQ_MODE == "$old_mode" && $VL_SNI == "$old_sni" ]]; then
    info "$(t no_change)"; return 0
  fi
  collect_vl_addr
  apply_changes "$scope"
}

modify_vl_fp() {
  local old=$VL_FP
  collect_fp
  if [[ $VL_FP == "$old" ]]; then info "$(t no_change)"; return 0; fi
  save_state; info "$(t saved)"; show_share
}

modify_vl_addr() {
  if [[ $VL_MASQ_MODE == hy2 && $HY_ENABLED == yes ]]; then
    info "$(t addr_hy2_note "$HY_DOMAIN")"
    return 0
  fi
  detect_ips
  local -a modes=() labels=()
  local c def=1 i cur_desc
  cur_desc=$(vl_effective_addr)
  if [[ -n $PUB_IP4 ]]; then
    modes+=(ip4); labels+=("$(t addr_ip4 "$PUB_IP4")")
  fi
  if [[ -n $PUB_IP6 ]]; then
    modes+=(ip6); labels+=("$(t addr_ip6 "$PUB_IP6")")
  fi
  modes+=(custom); labels+=("$(t addr_custom)")

  title "$(t addr_title)"
  for i in "${!modes[@]}"; do
    [[ ${modes[i]} == "$VL_ADDR_MODE" ]] && def=$((i + 1))
    printf '  %d. %s\n' "$((i + 1))" "${labels[i]}"
  done
  while :; do
    ask c "$(t choose) [1-${#modes[@]}]" "$def"
    c=${c//[[:space:]]/}
    if [[ $c =~ ^[1-9][0-9]*$ ]] && ((c >= 1 && c <= ${#modes[@]})); then
      VL_ADDR_MODE=${modes[c - 1]}
      break
    fi
    err "$(t invalid_choice)"
  done
  if [[ $VL_ADDR_MODE == custom ]]; then
    local custom
    while :; do
      ask custom "$(t ask_custom_addr)" "${VL_CUSTOM_ADDR:-$cur_desc}"
      custom=${custom//[\[\]]/}
      if valid_host "$custom"; then VL_CUSTOM_ADDR=$custom; break; fi
      err "$(t bad_addr)"
    done
  fi
  save_state; info "$(t saved)"; show_share
}

modify_vl_name() {
  local old=$VL_NAME
  ask VL_NAME "$(t ask_vl_name)" "$VL_NAME"
  VL_NAME=${VL_NAME:-$old}
  save_state; info "$(t saved)"; show_share
}

hy_service_stop() {
  if vl_installed && [[ $VL_MASQ_MODE == hy2 ]]; then
    confirm "$(t hy_stop_vl_warn "$HY_LOCAL_PORT")" n || return 0
  fi
  systemctl stop "$HY_SERVICE" && info "$(t stopped_ok)"
}

vl_service_stop() { systemctl stop "$SB_SERVICE" && info "$(t stopped_ok)"; }

# ---------------------------------------------------------------------------
# Menus (strictly adheres to docs/menu-standard.md)
# ---------------------------------------------------------------------------
MENU_KIND=() MENU_FN=() MENU_TXT=() MENU_MAP=() MENU_MSG=""

menu_begin()   { MENU_KIND=(); MENU_FN=(); MENU_TXT=(); }
menu_section() { MENU_KIND+=(sec); MENU_FN+=(""); MENU_TXT+=("$1"); }
menu_item()    { MENU_KIND+=("$1"); MENU_FN+=("$2"); MENU_TXT+=("$3"); }

toggle_lang() { if [[ $UI_LANG == zh ]]; then UI_LANG=en; else UI_LANG=zh; fi; }

read_choice() {
  local __c
  read -rp "$(t choose): " __c || return 1
  __c=${__c//[[:space:]]/}
  printf -v "$1" '%s' "${__c,,}"
}

proto_status_line() {
  local name=$1 enabled=$2 svc=$3 ver=$4 extra=$5 st
  if [[ $enabled == yes ]]; then
    if systemctl is-active --quiet "$svc"; then
      st="\033[32m● $(t st_running)\033[0m"
    else
      st="\033[31m● $(t st_stopped)\033[0m"
    fi
    printf '   %-10s: %b (%s)   %s\n' "$name" "$st" "${ver:--}" "$extra"
  else
    st="\033[33m● $(t st_notinst)\033[0m"
    printf '   %-10s: %b\n' "$name" "$st"
  fi
}

print_header() {
  local vs hy_extra="" vl_extra=""
  vs=$(version_state)
  echo "======================================================"
  echo "   $(t m_title)  v$SCRIPT_VERSION"
  case $vs in
    current | legacy | newer)
      [[ $HY_ENABLED == yes ]] && hy_extra="UDP $HY_PORT   $HY_DOMAIN"
      if [[ $VL_ENABLED == yes ]]; then
        vl_extra="TCP $VL_PORT   $(vl_masq_label)"
      fi
      proto_status_line "Hysteria2" "$HY_ENABLED" "$HY_SERVICE" "$([[ $HY_ENABLED == yes ]] && hy_version)" "$hy_extra"
      proto_status_line "VLESS" "$VL_ENABLED" "$SB_SERVICE" "$([[ $VL_ENABLED == yes ]] && sb_version)" "$vl_extra"
      printf '   %-10s: %s (%s)\n' "TCP BBR" "$(bbr_cc)" "$(bbr_qdisc)"
      ;;
    partial)
      echo -e "   \033[33m● $(t st_partial)\033[0m"
      ;;
    none)
      echo -e "   \033[33m● $(t st_notinst)\033[0m"
      ;;
  esac
  if update_available; then echo -e "   \033[33m$(t ver_new_avail "$REMOTE_VERSION")\033[0m"; fi
  echo "======================================================"
  [[ $vs == legacy ]] && legacy_notice
  [[ $vs == newer ]] && err "$(t ver_newer "$(detect_installed_version)" "curl -fsSL $SCRIPT_URL | sudo bash")"
}

menu_render() {
  local i n=0
  MENU_MAP=()
  clear
  print_header
  [[ -n ${1:-} ]] && echo -e " \033[36m$1\033[0m"
  for i in "${!MENU_KIND[@]}"; do
    case ${MENU_KIND[i]} in
      sec) echo " ${MENU_TXT[i]}" ;;
      danger) n=$((n + 1)); MENU_MAP[n]=$i; printf '  %2d. \033[31m%s\033[0m\n' "$n" "${MENU_TXT[i]}" ;;
      *) n=$((n + 1)); MENU_MAP[n]=$i; printf '  %2d. %s\n' "$n" "${MENU_TXT[i]}" ;;
    esac
  done
  echo "------------------------------------------------------"
  echo "   L. $(t m_lang)"
  if [[ -n ${1:-} ]]; then echo "   0. $(t back)"; else echo "   0. $(t m_exit)"; fi
  echo "======================================================"
  if [[ -n $MENU_MSG ]]; then warn "$MENU_MSG"; MENU_MSG=""; fi
}

menu_loop() {
  local builder=$1 heading=${2:-} c idx
  while :; do
    "$builder" || return 0
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

# --- Submenus ---------------------------------------------------------------
build_logs_menu() {
  menu_begin
  hy_installed && menu_item act show_hy_logs "$(t ml_hy)"
  vl_installed && menu_item act show_vl_logs "$(t ml_vl)"
}
menu_logs() { need_any_installed || return 1; menu_loop build_logs_menu m_logs_h; }

build_update_menu() {
  menu_begin
  menu_item act do_update_all "$(t mu_all)"
  hy_installed && menu_item act do_update_hy "$(t m_update_hy)"
  vl_installed && menu_item act do_update_sb "$(t m_update_sb)"
}
menu_updates() { need_any_installed || return 1; require_manageable || return 1; menu_loop build_update_menu m_update_h; }

build_cert() {
  menu_begin
  menu_item act show_cert_info "$(t mc_info)"
  menu_item danger reissue_cert "$(t mc_reissue)"
}
menu_cert() { need_hy_installed || return 1; require_manageable || return 1; menu_loop build_cert m_cert_h; }

build_keys() {
  menu_begin
  menu_item act show_keys_info "$(t mk_info)"
  menu_item danger reset_reality_keys "$(t mk_reset)"
}
menu_keys() { need_vl_installed || return 1; require_manageable || return 1; menu_loop build_keys m_keys_h; }

build_hy_service() {
  menu_begin
  if systemctl is-active --quiet "$HY_SERVICE"; then
    menu_item act restart_and_verify_hy "$(t ms_restart)"
    menu_item act hy_service_stop "$(t ms_stop)"
  else
    menu_item act restart_and_verify_hy "$(t ms_start)"
  fi
}
menu_hy_service() { need_hy_installed || return 1; require_manageable || return 1; menu_loop build_hy_service m_hy_service_h; }

build_vl_service() {
  menu_begin
  if systemctl is-active --quiet "$SB_SERVICE"; then
    menu_item act restart_and_verify_sb "$(t ms_restart)"
    menu_item act vl_service_stop "$(t ms_stop)"
  else
    menu_item act restart_and_verify_sb "$(t ms_start)"
  fi
}
menu_vl_service() { need_vl_installed || return 1; require_manageable || return 1; menu_loop build_vl_service m_vl_service_h; }

build_hy_mgr() {
  hy_installed || return 1
  local tcp_lbl
  if [[ $VL_ENABLED == yes && $VL_PORT == "$HY_PORT" ]]; then
    tcp_lbl="127.0.0.1:$HY_LOCAL_PORT"
  else
    tcp_lbl=$(on_off "$HY_TCP_MASQ")
  fi
  menu_begin
  menu_section "$(t m_sec_proto)"
  menu_item act modify_hy_pass_wrap "$(t mm_hy_pass)"
  menu_item act modify_hy_port "$(t mm_hy_port)   ($(t current): $HY_PORT)"
  menu_item act modify_hy_masq "$(t mm_hy_masq)   ($(t current): $HY_MASQ_URL)"
  menu_item act modify_hy_domain "$(t mm_hy_domain)   ($(t current): $HY_DOMAIN)"
  menu_item act modify_hy_name "$(t mm_hy_name)   ($(t current): $HY_NAME)"
  menu_item act toggle_hy_tcp_masq "$(t mm_hy_tcpmasq "$HY_PORT")   ($(t current): $tcp_lbl)"
  menu_item act modify_hy_bw "$(t mm_hy_bw)   ($(t current): $(bw_label))"
  menu_item sub menu_cert "$(t m_cert)"
  menu_item sub menu_hy_service "$(t m_service)"
  menu_section "$(t m_sec_maint)"
  menu_item danger do_install_hy "$(t m_reinstall_hy)"
  menu_item danger do_uninstall_hy "$(t m_uninstall_hy)"
}
modify_hy_pass_wrap() { modify_hy_password; }
menu_hy_mgr() { need_hy_installed || return 1; require_manageable || return 1; menu_loop build_hy_mgr m_hy_mgr_h; }

build_vl_mgr() {
  vl_installed || return 1
  menu_begin
  menu_section "$(t m_sec_proto)"
  menu_item act modify_vl_uuid "$(t mm_vl_uuid)"
  menu_item act modify_vl_port "$(t mm_vl_port)   ($(t current): $VL_PORT)"
  menu_item act modify_vl_masq "$(t mm_vl_masq)   ($(t current): $(vl_masq_label))"
  menu_item act modify_vl_fp "$(t mm_vl_fp)   ($(t current): $VL_FP)"
  if [[ $VL_MASQ_MODE != hy2 || $HY_ENABLED != yes ]]; then
    menu_item act modify_vl_addr "$(t mm_vl_addr)   ($(t current): $(uri_host "$(vl_effective_addr)"))"
  fi
  menu_item act modify_vl_name "$(t mm_vl_name)   ($(t current): $VL_NAME)"
  menu_item sub menu_keys "$(t m_keys)"
  menu_item sub menu_vl_service "$(t m_service)"
  menu_section "$(t m_sec_maint)"
  menu_item danger do_install_vl "$(t m_reinstall_vl)"
  menu_item danger do_uninstall_vl "$(t m_uninstall_vl)"
}
menu_vl_mgr() { need_vl_installed || return 1; require_manageable || return 1; menu_loop build_vl_mgr m_vl_mgr_h; }

# --- Main menu --------------------------------------------------------------
build_main() {
  menu_begin
  case $(version_state) in
    current)
      menu_section "$(t m_sec_common)"
      menu_item act show_share "$(t m_share)"
      menu_item act show_status "$(t m_status)"
      if hy_installed && vl_installed; then
        menu_item sub menu_logs "$(t m_logs_sub)"
      elif hy_installed; then
        menu_item act show_hy_logs "$(t m_logs)"
      else
        menu_item act show_vl_logs "$(t m_logs)"
      fi

      menu_section "$(t m_sec_proto)"
      if hy_installed; then
        menu_item sub menu_hy_mgr "$(t m_hy_mgr)"
      else
        menu_item act do_install_hy "$(t m_inst_hy_co)"
      fi
      if vl_installed; then
        menu_item sub menu_vl_mgr "$(t m_vl_mgr)"
      else
        menu_item act do_install_vl "$(t m_inst_vl_co)"
      fi
      menu_item act bbr_toggle "$(t m_bbr "$(bbr_cc)")"

      menu_section "$(t m_sec_maint)"
      menu_item act self_update "$(t m_selfupdate)"
      menu_item act show_changelog "$(t m_changelog)"
      if hy_installed && vl_installed; then
        menu_item sub menu_updates "$(t m_update_sub)"
        menu_item danger do_uninstall_all "$(t m_uninstall_all)"
      elif hy_installed; then
        menu_item act do_update_hy "$(t m_update_hy)"
        menu_item danger do_uninstall_hy "$(t m_uninstall_hy)"
      else
        menu_item act do_update_sb "$(t m_update_sb)"
        menu_item danger do_uninstall_vl "$(t m_uninstall_vl)"
      fi
      ;;
    legacy)
      menu_item act show_share "$(t m_share)"
      menu_item danger do_uninstall_all "$(t m_uninstall_all)"
      ;;
    newer)
      menu_item act show_share "$(t m_share)"
      menu_item act self_update "$(t m_selfupdate)"
      ;;
    partial)
      menu_item act do_install_both "$(t m_inst_both)"
      menu_item act do_install_hy "$(t m_inst_hy)"
      menu_item act do_install_vl "$(t m_inst_vl)"
      menu_item act self_update "$(t m_selfupdate)"
      menu_item danger do_uninstall_all "$(t m_uninstall_all)"
      ;;
    none)
      menu_item act do_install_both "$(t m_inst_both)"
      menu_item act do_install_hy "$(t m_inst_hy)"
      menu_item act do_install_vl "$(t m_inst_vl)"
      menu_item act self_update "$(t m_selfupdate)"
      ;;
  esac
}

main_menu() {
  ((FROM_PIPE)) || check_remote_version
  if update_available && [[ -t 0 ]] && confirm "$(t su_prompt "$REMOTE_VERSION" "$SCRIPT_VERSION")" y; then
    self_update --yes
  fi
  menu_loop build_main
}

# ---------------------------------------------------------------------------
# CLI usage & argument parser
# ---------------------------------------------------------------------------
usage() {
  cat <<EOF
nodectl.sh v$SCRIPT_VERSION - Hysteria2 & VLESS-REALITY unified node manager

Usage: nodectl [command] [target] [options]

Commands:
  menu                      Interactive menu (default)
  install [both|hy2|vless]  Install Hysteria2 + VLESS, or a single protocol
  link [all|hy2|vless]      Show node share link(s)
  status                    Show service status and listening sockets
  update [all|hy2|vless]    Update protocol core(s)
  self-update               Update this management script (keeps node configs)
  changelog                 Show version changelog
  bbr [on|off|status]       Kernel TCP BBR (accelerates VLESS TCP & outbound TCP)
  uninstall [all|hy2|vless] Remove protocol(s) and configurations

Common Options:
  --lang en|zh              UI language (default: en, or env NODECTL_LANG)
  --port PORT               Listen port (shared in 'both', or for single protocol)
                            Allowed HTTPS ports: ${ALLOWED_PORTS[*]} (default: 443)
  -y, --yes                 Answer yes to all confirmations
  -h, --help                Show this help

Hysteria2 Options:
  --domain DOMAIN           Domain bound to this server (also used by VLESS in hy2 mode)
  --hy2-port PORT           Explicit Hysteria2 port when different from --vless-port
  --masq URL                Hysteria2 masquerade site URL (e.g. https://www.example.com)
  --email EMAIL             Email for Let's Encrypt (optional)
  --password PASS           Hysteria2 password (default: random)
  --name / --hy2-name NAME  Hysteria2 node name shown in clients
  --bw-mode MODE            Bandwidth mode: client (default) | limit | bbr
  --up MBPS                 Server UPLOAD limit = client DOWNLOAD limit (0 = no limit)
  --down MBPS               Server DOWNLOAD limit = client UPLOAD limit (0 = no limit)

VLESS-REALITY Options:
  --vless-port PORT         Explicit VLESS TCP port
  --vless-masq hy2|external Reuse local Hysteria2 masquerade (default when HY2 enabled)
                            or use an external TLS 1.3 domain
  --sni DOMAIN              External REALITY target domain (e.g. www.apple.com)
  --uuid UUID               VLESS UUID (default: random)
  --fp FP                   Client uTLS fingerprint: ${ALLOWED_FPS[*]} (default: chrome)
  --addr HOST               Custom client endpoint host/IP (external mode)
  --vless-name NAME         VLESS node name shown in clients
EOF
}

parse_args() {
  while (($#)); do
    case $1 in
      menu | status | self-update | changelog)
        CMD=$1
        ;;
      install | link | update | uninstall)
        CMD=$1
        if [[ ${2:-} =~ ^(both|all|hy2|hysteria|hysteria2|vless|reality)$ ]]; then
          TARGET=$2; shift
        fi
        ;;
      bbr)
        CMD=bbr
        if [[ ${2:-} == on || ${2:-} == off || ${2:-} == status ]]; then BBR_ACTION=$2; shift; fi
        ;;
      --lang | --domain | --port | --hy2-port | --vless-port | --masq | --email | \
      --password | --name | --hy2-name | --vless-name | --up | --down | --bw-mode | \
      --sni | --vless-masq | --uuid | --fp | --addr)
        [[ $# -ge 2 ]] || die "$(t missing_val "$1")"
        case $1 in
          --lang) UI_LANG=$2; LANG_SET=1 ;;
          --domain) OPT_DOMAIN=$2 ;;
          --port) OPT_PORT=$2 ;;
          --hy2-port) OPT_HY_PORT=$2 ;;
          --vless-port) OPT_VL_PORT=$2 ;;
          --masq) OPT_MASQ=$2 ;;
          --email) OPT_EMAIL=$2; OPT_EMAIL_SET=1 ;;
          --password) OPT_PASSWORD=$2 ;;
          --name) OPT_NAME=$2 ;;
          --hy2-name) OPT_HY_NAME=$2 ;;
          --vless-name) OPT_VL_NAME=$2 ;;
          --up) OPT_UP=$2 ;;
          --down) OPT_DOWN=$2 ;;
          --bw-mode) OPT_BW_MODE=$2 ;;
          --sni) OPT_SNI=$2 ;;
          --vless-masq) OPT_VL_MASQ=$2 ;;
          --uuid) OPT_UUID=$2 ;;
          --fp) OPT_FP=$2 ;;
          --addr) OPT_ADDR=$2 ;;
        esac
        shift
        ;;
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
    changelog) show_changelog "$MIGRATED_FROM" ;;
    install) do_install_dispatch ;;
    link)
      case ${TARGET,,} in
        hy2 | hysteria | hysteria2) show_share hy2 ;;
        vless | reality) show_share vless ;;
        *) show_share all ;;
      esac
      ;;
    status) show_status ;;
    update)
      case ${TARGET,,} in
        hy2 | hysteria | hysteria2) do_update_hy ;;
        vless | reality) do_update_sb ;;
        *) do_update_all ;;
      esac
      ;;
    uninstall) do_uninstall_dispatch ;;
    bbr)
      require_manageable || exit 1
      case $BBR_ACTION in
        on) bbr_enable ;;
        off) if ((ASSUME_YES)); then bbr_disable --yes; else bbr_disable; fi ;;
        *) bbr_status ;;
      esac
      ;;
  esac
}

if [[ -z ${BASH_SOURCE[0]:-} && ! -t 0 ]] && { : </dev/tty; } 2>/dev/null; then
  main "$@" </dev/tty
else
  main "$@"
fi
