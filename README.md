# 实用工具 · utilities

常用服务器脚本集合，面向 Ubuntu 26.04。包含 root SSH 公钥初始化、Hysteria2 安装管理工具，以及 dual-proxy 部署项目。

## 仓库

[Kaolennoodle/utilities](https://github.com/Kaolennoodle/utilities) 为公开仓库，服务器无需登录 GitHub 即可下载脚本。仓库只包含公钥，不包含私钥、访问令牌或服务器地址。

## 脚本列表

| 脚本 | 用途 |
| --- | --- |
| [setup-ssh.sh](scripts/setup-ssh.sh) | 安装 root SSH 公钥、禁用密码认证，提供验证及定时回滚 |
| [hy2.sh](scripts/hy2.sh) | Hysteria2 安装和管理，支持中文/英文菜单、证书及分享配置 |
| [dual-proxy/](dual-proxy/) | VLESS+Reality（TCP 443）、Hysteria2（UDP 443）与静态网站部署维护（多文件项目，用法见其 README） |

以下公钥及 SSH 连接测试说明适用于 `setup-ssh.sh`。

## 内置公钥

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDDGGejG7Vqb8azmthZFegM35GOjQlfiQ88LYo4BXPoM eddie-ubuntu26
```

指纹：`SHA256:5CgXfovxVkkmIwFRgAUIA4OeZo7q8bz1XK9tg7TsKSg`。

使用前确认你持有对应私钥。任何人在自己的服务器运行本脚本，都会授权该公钥持有人以 root 登录；复用给别人时应先更换公钥。

## 执行与新连接测试

1. 保留当前 root SSH 窗口，在该窗口运行脚本。需要 Ubuntu 26.04、运行中的标准 `ssh.service`、systemd、Python 3、OpenSSH、flock 和常用系统工具。脚本不会安装组件。
2. 本地文件可直接执行：`bash scripts/setup-ssh.sh`（将脚本上传至目标服务器后执行，不是在个人电脑上执行）。
3. 在服务器当前的 root SSH 会话中整行执行下方命令。命令会直接下载并执行仓库 main 分支上的脚本。

```bash
curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/setup-ssh.sh | bash
```

`main` 会随仓库更新而变化。正式长期使用时，建议将 URL 中的 `main` 换成你审查过的完整提交 SHA，以固定脚本版本。

4. 应用成功后，立即在**自己的电脑**另开终端，使用实际私钥、端口及服务器地址测试：

```bash
ssh -o ControlPath=none -o IdentitiesOnly=yes -o PreferredAuthentications=publickey -o PasswordAuthentication=no -o KbdInteractiveAuthentication=no -i /path/to/private_key -p PORT root@SERVER
```

`ControlPath=none` 防止复用旧 SSH 连接。只输入私钥口令属于正常情况；不能用服务器账号密码完成这次测试。

5. 登录成功后，在**这条新连接中**执行安装脚本输出的具体确认命令。例如下方路径中的 `XXXXXXXX` 必须替换为本次实际值：

```bash
bash /var/lib/utilities-ssh/transaction-XXXXXXXX/control.sh confirm
```

**只有确认成功后才关闭原连接。** 10 分钟从回滚计时器启动时开始计算；未确认会恢复原配置及公钥文件，并重载 SSH。失败时脚本也会立即尝试回滚；定时回滚独立于终端运行。若恢复时重载失败，独立服务每 15 秒重试，保留待处理状态。

需要手动恢复时，在原连接或云厂商控制台运行脚本输出的 `control.sh rollback` 命令。原连接中执行 `confirm` 会被拒绝。

## 配置与保护措施

- 检查原配置语法、实际监听进程与启动选项，备份 `/etc/ssh/sshd_config`、原 `authorized_keys` 及 `.ssh` 的权限和组信息。备份目录仅 root 可访问，且不会复制其他私钥文件。
- 在主配置第一行开始加入受管块，优先于默认 Include 和 cloud-init 配置。OpenSSH 多数选项采用最先读到的值，因此不能依靠 `99-*.conf` 覆盖较早文件。参见 [Ubuntu 26.04 sshd_config 手册](https://manpages.ubuntu.com/manpages/resolute/man5/sshd_config.5.html)。
- 递归审查 Include。任何有效的 `Match` 块（包括 `Match all`）、Include 循环或无法安全解析的配置都会使脚本停止；不会自动改写复杂条件规则。自定义 SSH 配置启动参数、符号链接或多硬链接目标也会拒绝。
- 先验证候选配置，再启用独立的 10 分钟 systemd 回滚计时器，之后才修改公钥和 SSH 配置。使用原子替换写入主配置。
- 同时运行 `sshd -t`、全局 `sshd -T` 及当前连接条件下 root 的 `sshd -T -C`，确认关键设置。兼容 `prohibit-password` 与 `without-password` 两种规范化输出。
- 仅执行 `systemctl reload ssh.service`。不改端口、监听地址、防火墙、系统密码或 PAM 设置。
- 公钥按类型和密钥内容去重。已有带 `from=` 等限制的记录会保留，并另外添加此次明确授权的无限制公钥记录。
- 全部用户使用 `.ssh/authorized_keys`，且 `AuthenticationMethods publickey` 会禁用其他认证方式。其他账号应先准备好这个路径下的可用公钥。
- 使用文件锁防止本工具并发操作；确认时还会检查主配置和公钥文件在应用后没有变化。

配置检查不能证明私钥在你手中，也不能代替实际网络连接测试。已有 AllowUsers、拒绝规则、root 账号状态、云防火墙或其他访问限制仍可能使新连接失败；这时不要确认，让回滚执行或手动恢复。

确认之前不要重启服务器、修改 SSH 配置或公钥文件。此计时器为 systemd 临时单元，**服务器重启后不会继续计时**。回滚会恢复本次操作前的快照，不合并期间其他程序对这些文件的改动。磁盘故障或系统服务不可用也可能阻止恢复，此时保留原会话并使用云控制台处理。

## 验证

```bash
bash -n scripts/setup-ssh.sh
shellcheck scripts/setup-ssh.sh
python3 tests/test_setup_ssh.py
```

已在本地通过 Bash 语法检查、ShellCheck 和 13 项检查：真实 OpenSSH 解析的优先级及最终配置值、嵌套 Match 拒绝、Include 循环及歧义语法拒绝、默认空启动参数和自定义覆盖参数检查、重复运行、受损标记、无效配置、公钥去重，以及隔离环境中的恢复、重试、跨连接确认与文件变化检查。

当前本地验证使用 macOS OpenSSH 10.5；恢复检查模拟了 systemd、文件锁和所有权操作。**尚未在真实 Ubuntu 26.04/systemd 环境完成端到端登录及计时回滚验证，也未运行在你的服务器上。**
## Hysteria2 安装与管理

[hy2.sh](scripts/hy2.sh) 为原样收录的 v1.1.0 脚本，面向 Ubuntu 26.04，以 root 运行。提供交互菜单、官方核心安装、内置 ACME 证书申请、伪装站点配置、分享链接/二维码、客户端配置及更新/卸载功能。

在服务器 root 终端执行，下载后进入中文菜单：

```bash
curl -fsSL https://raw.githubusercontent.com/Kaolennoodle/utilities/main/scripts/hy2.sh -o hy2.sh && bash hy2.sh --lang zh
```

脚本通过终端读取交互输入；先保存再运行，也便于安装 `hy2` 快捷命令。安装完成后可用 `hy2` 再次打开菜单。可通过 `bash hy2.sh --help` 查看参数。

已完成 Bash 语法检查；本次上传未在服务器执行安装或验证部署。
