# 安全说明

- 配置和密钥只保存在 VPS 上，不上传到第三方 API。
- 脚本以 root 管理系统。Xray/Hysteria2 也以 root 运行，但 systemd 单元将能力限制为 `CAP_NET_BIND_SERVICE`，并启用 `ProtectSystem`、`NoNewPrivileges` 等沙箱选项。配置、密钥和证书均为 root 专用（600/700）。
- 敏感渲染数据经 stdin 传递，UUID 经权限受限的临时文件写入，不出现在命令参数中。不要用 `bash -x` 运行涉及凭据的操作。
- 连接参数是明确的管理员敏感输出，不写入安装日志。自动化时不要把完整安装输出放进公开 CI 日志。
- Xray/Hysteria2 资产按固定版本的官方 SHA256 校验，二进制原子替换。升级没有自动回滚。
- Nginx 仅监听本机 8443，另在公网 80 提供 ACME 验证入口。TLS 检查保留 CA 和域名校验，没有用 insecure 绕过证书问题。
- 本项目不管理防火墙。入站放行由系统防火墙或云安全组负责。
- 出站阻断包括 0.0.0.0/8、回环、链路本地和云元数据地址、CGNAT（含阿里云元数据 100.100.100.200）、多播、保留段、默认私网，以及本机网卡地址和检测到的公网 IPv4（防止经 lo 访问本机服务）。本机地址在渲染配置时采集，IP 变更后需重新渲染（例如执行一次 `vless-reset` 和 `hysteria-reset`）。
- Xray 访问日志关闭（`access: none`），不记录访问目标；错误日志保留。
- 默认不启用公开测速、端口跳跃、Fail2ban、额外混淆或用户行为监控。
- 没有自动备份。卸载会永久删除凭据和证书；如需保留，请在操作前自行备份 `/etc/dual-proxy` 和 `/opt/dual-proxy/acme`，或使用 VPS 快照。
- Reality/Vision/Hysteria2 不保证流量完全不可识别。
