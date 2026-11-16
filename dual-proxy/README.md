# dual-proxy

Linux VPS 上的 VLESS + Reality + XTLS Vision（TCP 443）、Hysteria2（UDP 443）与自有域名静态网站部署及维护脚本。面向单人使用、不承载其他业务的专用 VPS。

## 架构

- TCP 443：Xray Reality；普通 HTTPS 流量转发到 `127.0.0.1:8443` 的 Nginx。
- UDP 443：Hysteria2；普通 HTTP/3 请求通过 `masquerade.file` 服务同一份站点文件。
- 8443：只监听 IPv4 回环地址；未知和缺失 SNI 会被拒绝。
- TCP 80：Nginx 只用于 ACME HTTP-01 验证，其余请求跳转 HTTPS。
- Xray 与 Hysteria2 以 root 运行，由 systemd 沙箱限制，只保留绑定端口的能力。
- 单用户：一个 VLESS UUID、一个 Hysteria2 密码。
- 不管理防火墙。请在系统防火墙或云安全组放行 TCP 80/443、UDP 443 和 SSH。

不生成正式客户端 YAML、订阅或管理面板。

## 系统和版本

支持系统检查：Debian 12/13、Ubuntu 24.04/26.04 LTS、Ubuntu 26.10；架构 x86_64/aarch64。Ubuntu 26.10 为短期支持版本（约 9 个月），到期前需规划迁移。

| 组件 | 固定版本 |
|---|---|
| Xray-core | v26.3.27 |
| Hysteria2 | v2.13.0 |
| Mihomo（测试目标） | v1.19.31 |

版本与官方资产 SHA256 固定在 `lib/common.sh`，不会安装 latest。安装记录位于 `/opt/dual-proxy/manifests/`。

## 安装

准备好域名（A/AAAA 直接指向 VPS，不经 CDN 代理）和博客**静态构建目录**。公网 TCP 80 必须可达。需要 root、Bash ≥ 4、systemd，以及 curl、Python 3、iproute2 等基础工具；其余依赖通过 apt 安装。

```bash
sudo ./install.sh --domain blog.example.com \
  --site /path/to/static-site --non-interactive
```

首次安装会拒绝覆盖已有的 Xray/Hysteria2、systemd 覆盖项，以及被非 Nginx 进程占用的 80 端口。

**安装失败不会自动回滚。** 排除问题后重新运行同一命令即可继续：已完成的步骤会跳过，已生成的凭据和证书保留。放弃安装则执行 `manage.sh uninstall`。

连接参数在安装结束时输出，同时保存到 root 可读的 `/etc/dual-proxy/secrets/client-params.txt`，不写入安装日志。

## 维护

入口：`/opt/dual-proxy/scripts/manage.sh`，所有命令都需要 root。

```bash
manage.sh status
manage.sh check
manage.sh diagnose
manage.sh vless-reset               # 重新生成 VLESS UUID，输出新连接参数
manage.sh hysteria-reset            # 重新生成 Hysteria2 密码，输出新连接参数
manage.sh cert-status
manage.sh cert-renew                # 强制续期，避免反复调用触发 CA 限额
manage.sh site-update --dir /path/to/static-site
manage.sh upgrade                   # 安装 lib/common.sh 中固定的版本并重启
manage.sh uninstall [--purge-site] [--purge-acme] [--yes]
```

修改会先渲染并校验配置，再重启服务；**不做备份，也不自动回滚**。校验或重启失败时命令报错退出，需要按 `diagnose` 的输出手动处理。

升级方式：修改 `lib/common.sh` 中的版本号和 SHA256，把新脚本放到 `/opt/dual-proxy/scripts/`，然后执行 `manage.sh upgrade`。新版本需要单独评估与 Mihomo 的兼容性，见 [COMPATIBILITY.md](COMPATIBILITY.md)。

站点更新会复制到新目录并原子切换符号链接，随后删除旧内容；源目录不会被修改，含符号链接的站点会被拒绝。

## 证书续期

`/etc/cron.d/dual-proxy-cert` 每天运行续期和到期检查，失败时写入 root 可读日志和 syslog。**未配置外部通知。**

新证书先校验域名、有效期和私钥匹配，再原子替换并重载 Nginx；校验不通过时保留当前证书。Hysteria2 每次握手都会读取证书，不需要重启。

## 卸载

```bash
manage.sh uninstall                 # 需输入域名确认
manage.sh uninstall --purge-site --purge-acme
manage.sh uninstall --yes           # 自动化
```

卸载会**永久删除**服务、二进制、配置、凭据和证书，不做备份。默认保留网站目录和 `/opt/dual-proxy/acme`（ACME 账户及证书私钥）；`--purge-acme` 会删除后者，若 acme.sh 由本项目安装，则一并删除 `/root/.acme.sh`。

## 测试

```bash
bash tests/run-static-checks.sh     # 回归部分需要 Linux + Bash ≥ 4
```

`server-*.sh` 为破坏性故障注入和维护测试，**只在明确授权的测试实例上运行**，会短暂停服或模拟文件损坏。Python HTTP/3 测试需要在隔离环境中安装 aioquic。

## 发布包

`scripts/fetch-release-assets.py` 下载固定的核心资产，`scripts/build-release.py` 打包博客构建产物、资产和脚本。使用方法见 [BUNDLE-README.md](BUNDLE-README.md)。

更多信息：[安全说明](SECURITY.md)、[兼容性](COMPATIBILITY.md)、[限制](KNOWN-LIMITATIONS.md)。
