# 上传解压部署包

包内包含：部署和维护脚本、配置模板、构建好的博客、x86_64/aarch64 固定版本的 Xray/Hysteria2 资产、固定 commit 的 acme.sh 源码、文档、校验清单和构建信息。不含 Git 历史、Node.js 依赖、服务器私钥或任何凭据。

## 新服务器

先把域名的 A/AAAA 记录直接指向服务器（不经 CDN 代理），并在云安全组或系统防火墙放行 TCP 80/443、UDP 443 和 SSH。证书通过 HTTP-01 签发，公网 TCP 80 必须可达。

上传并在服务器上执行：

```bash
# 本机上传（把地址换成实际服务器）
scp dual-proxy-bundle-YYYYMMDD.tar.gz root@SERVER_IP:/root/

# 以下在服务器执行
cd /root
tar -xzf dual-proxy-bundle-YYYYMMDD.tar.gz
cd dual-proxy
sudo bash deploy.sh --domain YOUR_DOMAIN
```

自动化安装：

```bash
sudo bash deploy.sh --domain YOUR_DOMAIN --non-interactive
```

运行前会自动校验包内全部文件，也可以只做校验：`bash deploy.sh --verify-only`。包外的 `.sha256` 用于在上传前后校验整个压缩包，校验文件应从可信渠道获取。

安装失败不会自动回滚。排除问题后重新运行同一命令即可继续。

**这不是完全离线的安装介质。** 核心二进制和 ACME 源码已经带齐，但 apt 仓库、DNS 和 Let's Encrypt 必须可达。服务器不需要 Node.js，也不需要访问 GitHub。

## 已部署的实例

只更新博客：

```bash
sudo bash deploy.sh --update-site
```

该模式校验包后，调用服务器上已安装的 `manage.sh site-update` 原子替换站点内容，不保留旧版本，也不替换服务脚本。

## 博客

博客在独立副本中按 lockfile 安装依赖、以 UTC 构建，包内直接提供静态产物。原站点的 URL 和 SEO canonical 配置保持不变；若要改用其他主域名，需要调整构建配置后重新打包。图片、字体等外链仍依赖对应的外部服务。

博客源码 commit、构建时区、Node 版本、依赖锁文件哈希和资产哈希见 BUILD-MANIFEST.json。
