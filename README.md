# 实用工具 · utilities

常用服务器脚本集合，每个脚本独立使用，按需一键下载运行。

- **[nodectl.sh](#nodectlsh)**：Hysteria2、VLESS-REALITY 与 SS-2022 落地机统一安装管理脚本（原 `hy2.sh` 升级版），支持双协议共用 443 端口与伪装站、一键设置落地机及线路机出站转发、中/英文菜单、自动证书与平滑升级。

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/nodectl.sh | bash -s -- --lang zh
  ```

- **[ssh-manager.sh](#ssh-managersh)**：交互式管理 SSH 公钥和 sshd 登录配置，支持 Linux/macOS。

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/ssh-manager.sh | sudo bash
  ```

---

## nodectl.sh

[scripts/nodectl.sh](scripts/nodectl.sh) 由原 `hy2.sh` 演进升级而来（当前 v2.1.0），面向 Ubuntu 26.04 LTS，以 root 运行。支持部署 **Hysteria2**（官方 `hysteria` 内核）、**VLESS + XTLS-Vision + REALITY**（官方 `sing-box` 内核，原生兼容 Mihomo / Clash.Meta 系客户端）以及 **Shadowsocks-2022 落地机与线路机统一出站转发**，提供交互菜单、自动证书管理、443 端口与伪装站点无冲突复用、纯节点分享链接输出、内核 TCP BBR 开关、内核与脚本更新、配置回滚及卸载功能。

- **运行方式与快捷指令**：管道运行时菜单从当前终端读取输入，参数放在 `bash -s --` 之后。安装后自动写入 `/usr/local/bin/nodectl` 快捷指令，之后直接输入 `nodectl` 即可打开管理菜单。
- **四种部署形态与伪装协同（无需 Nginx）**：
  1. **Hysteria2 + VLESS 同时部署（推荐）**：Hysteria2 监听公网 `UDP 443`（承载 QUIC 代理与 HTTP/3 伪装）并在 `TCP 80` 自动申请/续期 Let's Encrypt 证书，同时将其 HTTPS 伪装监听自动绑定至本机回环 `127.0.0.1:18443`；VLESS (`sing-box`) 前置监听公网 `TCP 443`，合法客户端进入 `VLESS + XTLS-Vision` 隧道，普通浏览器访问或主动探测流量则通过 REALITY 原样透传给 `127.0.0.1:18443`（返回本机域名的真实证书与反代网页，即使反代源位于 Cloudflare 后方也不会产生 CDN 指纹冲突）。
  2. **仅部署 Hysteria2**：监听常见 HTTPS 端口（默认 `443`，UDP 代理 + 公网 TCP 伪装站同步监听）。
  3. **仅部署 VLESS (REALITY)**：免域名、免 80 端口、免证书，自动探测本机公网 IPv4/IPv6，握手回落至外部合规 TLS 1.3 站点（自动校验 TLS 1.3 并对 Cloudflare 等 CDN 目标给出风险提示）。
  4. **将本机设置为落地机（Shadowsocks-2022）**：使用 `sing-box` 部署 `2022-blake3-aes-128-gcm`（16 字节 Base64 密钥，默认随机空闲高位端口 TCP+UDP 监听，自动检测 NTP 时间同步），输出标准 `ss://` 链接供线路机一键接入。
- **线路机统一出站转发（连接远端落地机）**：
  - 在已部署 Hysteria2 和/或 VLESS 的线路机上，可通过菜单「落地机 / 出站设置」或命令 `nodectl outbound set --ss-link 'ss://...'` 直接粘贴落地机生成的 `ss://` 链接（也支持手动填写）。
  - **双协议共享同一落地出口**：VLESS 在 `sing-box` 内部直接通过 `Shadowsocks-2022` 出站转发；Hysteria2 通过本机回环 `127.0.0.1:18080` SOCKS5 桥接接入本机 `sing-box` 出站（仅装 Hysteria2 时也会自动按需拉起本地回环桥接，不占用任何公网端口）。
  - **防 DNS 泄漏**：转发流量保持域名状态直达落地机，由落地机本地完成最终 DNS 解析；客户端仍只需导入原有的单条节点链接，无需配置链式代理。
- **客户端兼容性**：VLESS 服务端采用官方 `sing-box` 内核，避免新版 Xray 强制 `minClientVer` 与后量子 `X25519MLKEM768` 校验导致 Mihomo 系客户端（Clash Verge Rev、FlClash、OpenClash 等）导入 `vless://` 链接静默断流的问题；支持选择客户端 uTLS 指纹（默认 `chrome`）。
- **监听端口**：支持常见 HTTPS 端口（`443` 默认，`8443`、`2053`、`2083`、`2087`、`2096`）。双协议单独卸载任意一方时，另一方的监听与伪装会自动平滑恢复或引导切换。
- **防火墙（ufw）**：脚本不主动修改 ufw 规则；检测到 ufw 已启用时提示需手动放行的端口与命令（同时提醒在云安全组放行）。
- **Hysteria2 带宽 / 拥塞控制**：

  | 模式 | 服务端配置 | 效果 |
  | --- | --- | --- |
  | 由客户端决定（默认，推荐） | 不写带宽相关项 | 客户端填写了带宽的方向使用 Brutal，未填写的方向使用 BBR |
  | 服务器限速 | `bandwidth.up` / `bandwidth.down` | 为**每个客户端**设置上限，只限制使用 Brutal 的客户端，实际取客户端与服务器中较小的值；BBR 客户端不受限 |
  | 强制 BBR | `ignoreClientBandwidth: true` | 忽略客户端带宽设置，全部使用 BBR |

  **服务器与客户端的上传/下载方向相反**：服务器上传 = 客户端下载，服务器下载 = 客户端上传。命令行：`install hy2 ... --bw-mode limit --up 500 --down 50`（单位 Mbps，也可写 `500m`、`1g`；0 表示该方向不限制）。
- **内核 TCP BBR**：菜单「内核 TCP BBR」或 `nodectl bbr on|off|status`。写入 `/etc/sysctl.d/99-nodectl-bbr.conf` 并记录原设置，关闭时恢复。**直接加速 VLESS 节点的 TCP 代理隧道**（强烈建议开启），同时也作用于服务器出站与伪装站 TCP 连接；Hysteria2 走 UDP/QUIC，使用自身的拥塞控制。
- **纯净节点链接**：脚本只输出标准 `hysteria2://` 与 `vless://` 节点分享链接，不生成二维码或额外客户端配置文件。
- **命令行与无人值守安装**：加 `--help` 查看全部子命令与参数（如 `nodectl install both --domain hy.example.com --masq https://www.example.com --yes`、`nodectl link`、`nodectl status`、`nodectl changelog`）。

### 版本与从 `hy2.sh` 平滑升级

- **旧版 `hy2.sh` 自动迁移**：已由 `hy2.sh` **v1.3.1 及以后版本**部署的存量服务器，无论运行上方新的 `nodectl.sh` 一键命令、继续运行旧的 [scripts/hy2.sh](scripts/hy2.sh) 一键命令，还是在现有 `hy2` 菜单中触发自更新，都会**自动平滑升级为 `nodectl`**：
  - 自动迁移节点状态至 `/etc/nodectl/state.env` 并接管原内核 BBR 配置，**不重写现有 Hysteria2 配置、不重启服务，原有节点链接零中断保持不变**；
  - 安装新指令 `nodectl`，自动移除旧的 `/usr/local/bin/hy2` 指令，并展示版本升级日志；
  - 升级后可直接在 `nodectl` 菜单中一键加装 VLESS 节点并与现有 Hysteria2 共用 443 端口及伪装站。
- **自更新与版本保护**：菜单「更新管理脚本」或 `nodectl self-update`。打开菜单时检查一次新版本（超时 3 秒；设置 `NODECTL_NO_UPDATE_CHECK=1` 可关闭）。过旧版本（`< v1.3.1`）仅允许查看链接与卸载；若服务器由更高版本脚本管理，旧脚本拒绝修改以防配置损坏。

已在本地通过 Bash 语法检查、ShellCheck 及旧版迁移/双协议联动场景模拟；未在真实服务器执行安装或验证部署。

## ssh-manager.sh

[scripts/ssh-manager.sh](scripts/ssh-manager.sh) 是一个菜单式 SSH 管理工具，支持 Linux 和 macOS，兼容 bash 3.2+，不依赖额外组件（需要 OpenSSH 的 `ssh-keygen`；从 GitHub 导入公钥时需要 `curl`）。当前 v1.1.0。

**运行权限**

- `curl ... | sudo bash`：可管理所有用户的公钥并修改 sshd 配置，默认目标用户为执行 sudo 的用户。已是 root（或系统未安装 sudo）时去掉 `sudo`。
- `curl ... | bash`（普通用户）：只能管理自己的 `~/.ssh/authorized_keys`。
- 管道运行时菜单从当前终端读取输入，因此需要在交互式终端中执行；没有终端时脚本会报错退出。
- 也可以先下载再运行：`curl -fsSL <URL> -o ssh-manager.sh && sudo bash ssh-manager.sh`。
- 菜单按权限和状态显示：普通用户不显示 sshd 配置和切换用户；没有公钥时不显示查看/删除；没有备份时不显示恢复。删除公钥、恢复备份红色显示并放在最后。

**公钥管理**

- 查看公钥（显示指纹）、粘贴添加（多行）、从文件添加、从 GitHub 导入（`https://github.com/<用户名>.keys`）。
- 添加时校验公钥格式并按密钥内容去重；删除前确认，删除全部公钥时会额外警告。
- 用编辑器手动编辑；切换目标用户（管理其他用户需 root）。
- 自动修正 `.ssh` 目录 700、`authorized_keys` 600 权限及属主。删除或编辑前备份为 `authorized_keys.bak`。

**sshd 配置（需 root）**

- Root 登录（`prohibit-password` / `no` / `yes`）、密码登录（同时设置 `KbdInteractiveAuthentication`）、公钥登录、CA 证书登录（`TrustedUserCAKeys`）、SSH 端口。
- 查看实际生效配置（`sshd -T`）、手动编辑 `sshd_config`、恢复最近一次备份。

**修改方式与保护措施**

- 在 `sshd_config` 顶部维护受管区块 `# >>> ssh-manager >>>` … `# <<< ssh-manager <<<`。sshd 对同一选项取第一次出现的值，因此该区块会覆盖其后的设置及 `sshd_config.d/*.conf`；主文件中（`Match` 块之前）的同名旧配置会被注释为 `# [ssh-manager 已停用]`。
- 每次写入前先用 `sshd -t` 校验，失败不写入；通过后备份为 `sshd_config.bak.<时间戳>`，再写入并重载 SSH 服务（兼容 `ssh`/`sshd` 服务和 `ssh.socket` 套接字激活）。macOS 由 launchd 按连接启动 sshd，新配置对新连接自动生效。
- 关闭密码登录时若目标用户没有公钥、或在密码登录已关闭时关闭公钥登录，会给出警告并要求确认。
- 修改端口前提醒放行防火墙/安全组；使用 `ssh.socket` 时会自动重启套接字以监听新端口。

**注意**

- 脚本**没有自动回滚计时**。修改登录方式或端口后，请保留当前会话，另开终端确认能正常登录后再断开；失败时用菜单中的“恢复 sshd_config 备份”。
- `Match` 块内的同名设置不会被改写，仍可能对匹配的连接生效。
- `AllowUsers`/`DenyUsers`、云防火墙等其他限制不在脚本管理范围内。

已通过 Bash 语法检查和 ShellCheck；未在服务器上实际运行验证。

---

## 说明

- 仓库公开，服务器无需登录 GitHub 即可下载；不包含私钥、访问令牌或服务器地址。
- 上述命令使用 `main` 分支，内容会随仓库更新而变化。长期使用时，建议把 URL 中的 `main` 换成你审查过的完整提交 SHA 以固定版本。
- 新增脚本放在 `scripts/` 目录，并在开头列表添加单行介绍和一键命令，在正文添加详细介绍。
- 交互菜单遵循 [菜单设计标准](docs/menu-standard.md)。
- 交互式脚本需支持 `curl ... | bash`：全部代码写在函数中、最后一行调用 `main`；脚本来自标准输入时（`BASH_SOURCE[0]` 为空）用 `main "$@" </dev/tty` 从终端读取输入；不要依赖 `$0` 定位脚本自身。
