# 实用工具 · utilities

常用服务器脚本集合，每个脚本独立使用，按需一键下载运行。

- **[hy2.sh](#hy2sh)**：Hysteria2 一键安装与管理，提供中/英文菜单、自动证书和节点链接，支持自动更新。

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/hy2.sh | bash -s -- --lang zh
  ```

- **[ssh-manager.sh](#ssh-managersh)**：交互式管理 SSH 公钥和 sshd 登录配置，支持 Linux/macOS。

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/ssh-manager.sh | sudo bash
  ```

---

## hy2.sh

[scripts/hy2.sh](scripts/hy2.sh) 基于 v1.1.0 修改（当前 v1.4.0），面向 Ubuntu 26.04，以 root 运行。提供交互菜单、官方核心安装、内置 ACME 证书申请、伪装站点配置、节点链接（`hysteria2://`）、内核与脚本更新、卸载功能。

- 管道运行时，菜单从当前终端读取输入；参数放在 `bash -s --` 之后。安装时自动从本仓库 `main` 分支下载脚本作为 `hy2` 快捷命令，之后可用 `hy2` 再次打开菜单。
- 菜单按安装状态显示：未安装时只提供安装；已安装时分为常用、配置、维护三组，卸载等危险操作红色显示并放在最后。
- 带宽 / 拥塞控制有三种模式，安装时选择，之后可在“修改配置”中更改：

  | 模式 | 服务端配置 | 效果 |
  | --- | --- | --- |
  | 由客户端决定（默认，推荐） | 不写带宽相关项 | 客户端填写了带宽的方向使用 Brutal，未填写的方向使用 BBR |
  | 服务器限速 | `bandwidth.up` / `bandwidth.down` | 为**每个客户端**设置上限，只限制使用 Brutal 的客户端，实际取客户端与服务器中较小的值；BBR 客户端不受限 |
  | 强制 BBR | `ignoreClientBandwidth: true` | 忽略客户端带宽设置，全部使用 BBR |

  **服务器与客户端的上传/下载方向相反**：服务器上传 = 客户端下载，服务器下载 = 客户端上传。例如希望客户端下载最多 500 Mbps、上传最多 50 Mbps，应设置服务器上传 500、下载 50。命令行：`install ... --bw-mode limit --up 500 --down 50`（单位 Mbps，也可写 `500m`、`1g`；0 表示该方向不限制）。
- 脚本只输出节点链接，不生成二维码或客户端配置文件。节点链接不含带宽；要使用 Brutal，请在客户端填写**本地网络**的实际上传/下载速度，切勿高于实际带宽。
- 去掉 `--lang zh` 会先询问界面语言；加 `--help` 查看全部参数（含非交互安装 `install --domain ... --masq ... --yes`，无终端环境如 cloud-init 也可用）。
- 也可以先下载再运行：`curl -fsSL <URL> -o hy2.sh && bash hy2.sh --lang zh`。

### 版本与更新

- **更新脚本**：菜单“更新管理脚本”或 `hy2 self-update`。打开菜单时会检查一次新版本（超时 3 秒，失败跳过；设置 `HY2_NO_UPDATE_CHECK=1` 可关闭），有新版本时提示是否更新。下载的脚本须通过版本号与语法检查才会替换 `hy2`，不会降级。
- **覆盖升级**：由 **v1.3.1 及以后**安装的服务器，直接运行新版脚本即可接管（v1.3.1 没有自更新功能，需运行一次上面的一键命令；v1.4.0 起也可用 `hy2 self-update`）：只更新安装记录和 `hy2` 快捷命令，**不改动 Hysteria 配置、不重启服务，节点链接保持不变**。
- **旧版本**：由 v1.3.1 之前的版本安装的服务器无法直接升级。脚本会提示并只允许查看节点链接和卸载；请先完全卸载，再重新安装（如需沿用原密码，先记下节点链接）。
- **更新的版本**：如果服务器由比当前脚本更新的版本管理，脚本拒绝修改，提示运行最新脚本。
- 安装记录（`/etc/hysteria/.hy2-script.env`）保存安装版本；`hy2` 快捷命令缺失、过旧或损坏时会自动修复。
- `MIN_UPGRADE_VERSION`（脚本开头）是可覆盖升级的最低版本。今后修改状态文件或配置格式时，在 `adopt_installation` 中按原版本迁移，保证节点配置不变。

已在本地通过 Bash 语法检查、ShellCheck 及升级场景模拟；未在服务器执行安装或验证部署。

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
