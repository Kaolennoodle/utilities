# 兼容性说明（COMPATIBILITY.md）

## 版本锁定结论（截至 2026-11-13）

| 组件 | 选定版本 | 通道 | 依据 |
|---|---|---|---|
| Xray-core | `v26.3.27` | stable | 最后一个**默认兼容 Mihomo** 的稳定版 |
| Hysteria2 | `app/v2.13.0` | stable | 官方最新稳定版，含 v2.9.2 安全修复 |
| Mihomo（仅测试目标） | `v1.19.31` | stable | VLESS+Reality+Vision 与 Hysteria2 均支持 |

## Xray 与 Mihomo 的两处 REALITY 破坏性变更

### 1. `minClientVer` 默认下限（v26.7.11 ~ v26.9.7）

- Mihomo 在 REALITY 握手中**硬编码**上报客户端版本 `1.8.2`（MetaCubeX/mihomo#2967、#3039）。
- Xray v26.7.11 起，空 `minClientVer` 默认填为 `26.3.27`，导致 Mihomo 被拒。
- v26.9.8 起该默认下限被移除。

### 2. `X25519MLKEM768` 后量子强制（v26.9.8 起，含当前所有稳定版）

- Xray v26.9.8+ 强制要求 REALITY Client Hello 携带后量子密钥共享 `X25519MLKEM768`。
- Mihomo 默认剥离 ML-KEM（`support-x25519mlkem768` 默认 `false`），被静默拒绝。
- **无法在服务端关闭**，只能 Mihomo 客户端侧开启 `reality-opts.support-x25519mlkem768: true`。

### 结论矩阵

| Xray 版本 | 通道 | Mihomo 默认可用 | 备注 |
|---|---|---|---|
| **v26.3.27** | stable | ✅ | 本项目默认基线 |
| v26.6.27 | pre-release | ✅ | 任务书原选，但为预发布版 |
| v26.7.11 ~ v26.9.7 | pre | ⚠️ | 需 `minClientVer:"1.8.2"` |
| v26.9.8+（含 v26.10.x / v26.11.x） | stable | ❌ | 需 Mihomo 客户端开 PQ 开关 |

## 本项目采取的防御措施

1. **默认基线 v26.3.27**：既避开 minClientVer 下限，也避开 PQ 强制，默认兼容 Mihomo。
2. **显式 `minClientVer: "1.8.2"`**：在 `xray-config.json` 中显式写入，防止日后误升级二进制到 v26.7.11~v26.9.7 时因空下限再次破坏 Mihomo。
3. **升级红线**：`manage.sh upgrade` 只安装 `lib/common.sh` 中固定的版本。不要把 Xray 固定版本改到 `>= v26.9.8`，除非所有 Mihomo 客户端都已开启 `support-x25519mlkem768`。

## 服务端配置字段核对

- Reality 字段 `target`（旧名 `dest`，别名兼容）、`serverNames`、`privateKey`、`shortIds`、`minClientVer` —— 均已按官方文档核对。
- Reality 仅支持 `RAW`/`XHTTP`/`gRPC` 传输；本项目用 `RAW`（TCP）+ Vision。
- Hysteria2 `sniGuard: strict`、`masquerade.file`、`tls` 证书热重载 —— 均已按官方文档核对。

## 未默认启用的特性（保持兼容性与范围克制）

- 不启用 XHTTP、VLESS Encryption、后量子密钥交换、端口跳跃、obfs、ECH、mimic。
- 不启用 `limitFallbackUpload/Download`（官方明确「本身即是指纹，不推荐」）。
- 不默认启用 `speedTest`、fail2ban。

## 需要实测确认的项（尚待验证）

- v26.3.27 与 Mihomo v1.19.31 的 VLESS+Reality+Vision 实际互通（当前为版本边界推断）。
- Reality 回退到 127.0.0.1:8443 的 SNI 透传、ALPN、TLS 1.3、未知 SNI 行为。
- Hysteria2 `masquerade.file` 对符号链接 `current` 目录的解析与 404 行为。

## 2026-11-13 实测

Xray v26.3.27 与 Mihomo v1.19.31 通过了真实的 VLESS/Reality/Vision TCP 和 UDP 测试；Hysteria2 v2.13.0 通过了本机测试和 VLESS UDP 诊断传输测试。上表中的其他版本结论来自源码和文档推断。
