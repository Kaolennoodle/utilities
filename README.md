# 实用工具 · utilities

常用服务器脚本集合，每个脚本独立使用，按需一键下载运行。

- **[hy2.sh](#hy2sh)**：Hysteria2 一键安装与管理，提供中/英文菜单、证书和分享链接。

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/hy2.sh -o hy2.sh && bash hy2.sh --lang zh
  ```

- **[ssh-manager.sh](#ssh-managersh)**：交互式管理 SSH 公钥和 sshd 登录配置，支持 Linux/macOS。

  ```bash
  curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/ssh-manager.sh -o ssh-manager.sh && sudo bash ssh-manager.sh
  ```

---

## hy2.sh

[scripts/hy2.sh](scripts/hy2.sh) 为原样收录的 v1.1.0 脚本，面向 Ubuntu 26.04，以 root 运行。提供交互菜单、官方核心安装、内置 ACME 证书申请、伪装站点配置、分享链接/二维码、客户端配置及更新/卸载功能。

- 脚本通过终端读取交互输入；先保存再运行，也便于安装 `hy2` 快捷命令。安装完成后可用 `hy2` 再次打开菜单。
- 去掉 `--lang zh` 会先询问界面语言；`bash hy2.sh --help` 查看全部参数（含非交互安装 `install --domain ... --masq ...`）。

已完成 Bash 语法检查；未在服务器执行安装或验证部署。

## ssh-manager.sh

[scripts/ssh-manager.sh](scripts/ssh-manager.sh) 是一个菜单式 SSH 管理工具，支持 Linux 和 macOS，兼容 bash 3.2+，不依赖额外组件（需要 OpenSSH 的 `ssh-keygen`；从 GitHub 导入公钥时需要 `curl`）。

**运行权限**

- `sudo bash ssh-manager.sh`：可管理所有用户的公钥并修改 sshd 配置，默认目标用户为执行 sudo 的用户。已是 root 时直接 `bash ssh-manager.sh`。
- `bash ssh-manager.sh`（普通用户）：只能管理自己的 `~/.ssh/authorized_keys`。
- 不支持 `curl ... | bash` 管道运行，因为脚本需从终端读取菜单输入，请按上面的命令先下载再运行。

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

- 脚本**没有自动回滚计时**。修改登录方式或端口后，请保留当前会话，另开终端确认能正常登录后再断开；失败时用菜单 15 恢复备份。
- `Match` 块内的同名设置不会被改写，仍可能对匹配的连接生效。
- `AllowUsers`/`DenyUsers`、云防火墙等其他限制不在脚本管理范围内。

已通过 Bash 语法检查和 ShellCheck；未在服务器上实际运行验证。

---

## 说明

- 仓库公开，服务器无需登录 GitHub 即可下载；不包含私钥、访问令牌或服务器地址。
- 上述命令使用 `main` 分支，内容会随仓库更新而变化。长期使用时，建议把 URL 中的 `main` 换成你审查过的完整提交 SHA 以固定版本。
- 新增脚本放在 `scripts/` 目录，并在开头列表添加单行介绍和一键命令，在正文添加详细介绍。
