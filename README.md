# Debian / Ubuntu VPS 多协议节点脚本 v1.2.0

## 安装与快捷命令

项目仓库：https://github.com/qingxinguayu999-alt/vps-node

在自己的 Debian/Ubuntu VPS 上运行以下命令：

```bash
curl -fsSL https://raw.githubusercontent.com/qingxinguayu999-alt/vps-node/main/install.sh -o install-vps-node.sh
sudo bash install-vps-node.sh
```

安装器下载并校验脚本 SHA256、检查版本和语法、安装核心与依赖，并注册快捷命令。完成后添加节点即可。需要先有 curl；没有时运行 `sudo apt-get update && sudo apt-get install -y curl`。

| 命令 | 功能 |
| --- | --- |
| `jb` | 打开彩色脚本主菜单 |
| `k` | 查看所有节点的链接和二维码 |
| `sc` | 确认后卸载脚本及本工具节点 |
| `vps-node` | 打开主菜单的完整命令 |

root 用户直接输入以上命令；普通用户加 `sudo`，例如 `sudo jb`。如同名命令被占用不会覆盖，可用 `sudo vps-node jb`、`sudo vps-node k`、`sudo vps-node sc`。

离线下载项目文件后，也能在 VPS 上运行：

```bash
sudo bash vps-node.sh
```

先选 **1 安装核心/依赖**，再选 **2 添加节点**。已有旧版：上传新版后选 1 注册新命令，或用菜单 14 更新；配置默认沿用。

设计目标是使用 systemd 的 Debian 12/13、Ubuntu 22.04/24.04，amd64/arm64；脚本检查发行版和 systemd，但本次没有在这些系统的 VPS 上实机验证。需要 root、正常 DNS、访问官方 APT 和 GitHub 的网络。不是 Docker/OpenVZ 专用版本，容器中的 BBR 可能由宿主机决定。

## 已实现

| 协议 | 传输 | 证书 | Argo |
| --- | --- | --- | --- |
| VLESS | WebSocket + TLS | 直连需证书 | 支持固定隧道 |
| VMess | WebSocket + TLS，alterId=0 | 直连需证书 | 支持固定隧道 |
| TUIC v5 | UDP/QUIC，协议 BBR | 需要 | 不支持 |
| Hysteria2 | UDP/QUIC | 需要 | 不支持 |
| Trojan | TCP + TLS | 需要 | 本版不接入 |
| Shadowsocks | aes-128-gcm，TCP/UDP | 不需要 | 不支持 |

可同时添加多个节点。支持修改名称、域名、证书、端口、WebSocket 路径、重新生成 UUID/密码、删除节点、查看服务与日志、重启、导出链接和 PNG/终端二维码。修改会经过 `sing-box check`，启动失败恢复此前配置。

BBR 单独通过菜单开启，不自动替换内核。系统 TCP BBR 不直接控制 TUIC/Hysteria2 的 QUIC 连接。没有实现 VLESS Reality、XHTTP、订阅 HTTP 服务、临时 Argo 隧道或一键系统升级。

## 域名与证书

直连 TLS 节点：域名 A/AAAA 正确指向 VPS，关闭该记录的 CDN 代理；放行相应节点端口。添加和修改节点时可选 IPv4（监听 `0.0.0.0`）或 IPv6（监听 `::`）。IPv6 需要 VPS 配有可用 IPv6、正确 AAAA 记录及 IPv6 防火墙放行；`::` 在某些系统/核心版本下也会接收 IPv4，请勿把它当作严格 IPv6-only 隔离。这是入站监听选择，不强制代理出站流量使用对应地址族。旧配置默认仍为 IPv4。

自动申请采用 Certbot HTTP-01：80/TCP 需空闲并能从公网访问；邮箱和同意 Let's Encrypt 条款由菜单输入。证书申请不停止已有 Web 服务，80 被占用会失败。自动启用 `certbot.timer` 和续期后服务重启钩子。Cloudflare Origin CA 不是通用客户端信任的证书，不适合普通直连节点。

导入证书：填服务器上的 fullchain.pem 和 privkey.pem 路径；会检查有效期、域名/IP 和公私钥匹配，复制到专用目录。应使用客户端信任的完整证书链；导入证书需自行续期并再次导入。不会默认关闭客户端证书验证。

## Argo / Cloudflare Tunnel

1. 在 Cloudflare 控制台创建一个固定的、远程管理的 Tunnel，取得 Token。
2. 添加 VLESS 或 VMess 节点，选择 Argo，填公开节点域名和本机端口。VMess 默认选择 Argo；可改选直连，已有 VMess 节点不自动迁移，可通过修改节点切换到 Argo。
3. 控制台为此 Tunnel 添加 Public hostname，服务设置为 `http://127.0.0.1:本机端口`（选择 IPv6 时为 `http://[::1]:本机端口`）。每个节点用独立公开主机名。
4. 选菜单 7，隐藏输入 Token。脚本安装官方 cloudflared 并启用独立服务。
5. 查看日志，确认 Tunnel 已连接；客户端使用导出的域名、443、TLS、WebSocket 路径。

Token 保存在 root 专用的 `/etc/vps-node/tunnel.env`，不写入进程命令行。本版只有一个固定 Tunnel，可承载多个公开主机名；再次设置 Token 会替换原 Tunnel。停止 Argo 用菜单 11，不会删除 Cloudflare 控制台上的 Tunnel。Argo 本机入站只监听回环地址，客户端到 Cloudflare 使用 TLS。

## 端口、文件和备份

脚本不自动修改 UFW/iptables 或云安全组。直连 VLESS/VMess/Trojan 放行 TCP，TUIC/Hysteria2 放行 UDP，Shadowsocks 放行 TCP+UDP。Argo 本机端口不用公网放行，但服务器需能出站连接 Cloudflare。

配置和凭据位于 `/etc/vps-node/`；链接在 `links.txt`，二维码在 `qr/`。这些文件和二维码都包含可直接使用的访问凭据，不应公开。最新成功修改前的配置保存在 `config.previous.json`、`nodes.previous.json`，包含旧凭据。

使用专用 `vps-node.service`，不覆盖已有 sing-box 默认配置；仍需避免与其他服务端口冲突。安装会增加 SagerNet APT 源、所需软件包和 systemd 单元。cloudflared 下载的是官方 GitHub latest DEB，经 HTTPS 获取，本版没有做独立哈希锁定。核心后续升级前应备份并验证新版本配置。

## 验证范围

```bash
bash -n vps-node.sh
bash vps-node.sh --self-test
```

已验证 Bash/Python 语法、六协议配置与链接生成、Argo 回环监听、VMess 编码、域名校验及配置启动失败回滚逻辑。未在真实 VPS 上验证下载/安装、内核 BBR、ACME 申请、Cloudflare Tunnel 握手、客户端兼容性和实际网速。运行时会使用所安装核心的 `sing-box check` 检查配置。TUIC 分享 URI 可能因客户端不同需要手动填写；二维码只是分享 URI 的编码。

官方参考：

- https://sing-box.sagernet.org/installation/package-manager/
- https://sing-box.sagernet.org/configuration/inbound/
- https://developers.cloudflare.com/tunnel/reference/run-parameters/

## 新增菜单与快捷命令

参考终端截图设计了彩色分组菜单，顶部显示 sing-box/Argo 的真实服务状态、节点总数和 IPv4/IPv6 节点数。设置 `NO_COLOR=1` 可以关闭颜色。

- 菜单中输入 `k`：显示链接和终端二维码。安装后 root 直接输入 `k`，普通用户输入 `sudo k`；也可用 `sudo vps-node k`。
- 输入 `sc` / `sudo sc`：确认卸载后停止并移除本工具服务、配置、凭据与快捷命令；保留依赖软件包、系统 BBR、ACME 证书、Cloudflare 控制台隧道和原上传脚本。可用 `sudo vps-node sc`。
- 快捷命令已被其他程序占用时不会覆盖。打开主菜单：root 输入 `jb`，普通用户输入 `sudo jb`；也可用 `sudo vps-node` 或 `sudo vps-node jb`。
- 从旧版升级到本包：将新版上传到 VPS，运行 `sudo bash vps-node.sh` 后选择 1，安装新版命令与快捷入口；已有节点配置沿用。

## 检查更新

菜单 12 刷新 APT 并显示 sing-box Installed/Candidate，查询已安装 cloudflared 的官方最新版本，并检查管理脚本更新源。它不自动升级核心或 cloudflared。

安装会设置本 GitHub 项目的 `update.json` 为默认更新源。菜单 13 可更改为你控制或信任的 HTTPS JSON 清单地址；格式见 `update.json`。把新版脚本发布到 HTTPS，填写版本号及脚本 SHA256，更新检查会校验哈希、脚本版本和 Bash/Python 语法，确认后更新 `/usr/local/bin/vps-node`。SHA256 校验文件完整性，不替代对发布来源的信任。更新前副本在 `/etc/vps-node/vps-node.previous.sh`，更新后退出并重新打开菜单。

也可通过菜单 14 导入本地新版脚本（版本必须更高）。本地更新不需要更新源。查看脚本哈希：

```bash
sha256sum vps-node.sh
```

更新功能不会凭空检查未发布的未来版本。IPv4/IPv6、更新校验、快捷入口均进行了本地逻辑检查，安装、卸载、网络更新和真实连通性仍需 VPS 验证。

## 常见使用流程

**直连 HY2 / TUIC**：菜单 2 选择协议 → 选择 IPv4/IPv6 → 填自己的域名及端口 → 自动申请或导入证书 → 放行 UDP 端口 → 输入 k 导入节点。使用 Cloudflare DNS 时，节点记录设为仅 DNS（灰云），不能套用普通橙云或本脚本的 Argo。

**VMess + Argo**：Cloudflare 控制台创建固定 Tunnel → 菜单 2 选择 VMess，Argo 默认 y → 填公开域名 → 把脚本显示的本机 HTTP 服务地址配置到 Tunnel 的 Public hostname → 菜单 7 输入 Tunnel Token → 查看日志确认连接 → k 导出。客户端使用域名、443、TLS 和 WebSocket 路径。IPv6 本机服务写作 `http://[::1]:端口`。

**修改节点**：菜单 3 可修改域名、证书、端口、监听地址族、WebSocket 路径和凭据；VLESS/VMess 可切换 Argo/直连。域名路由和 Cloudflare 服务地址需要在控制台同步修改。

## 维护与开源

使用 MIT 许可证，允许他人使用、修改和再分发；外部核心和依赖各自遵循其上游许可证。

发布新版时修改 `VERSION`（必须升高），运行 `python3 tools/make_manifest.py` 同步更新清单和哈希，然后一起提交 `vps-node.sh`、`update.json`、`SHA256SUMS`。更换仓库时还需修改脚本默认更新地址、安装器 base_url 和 README 安装命令。

本地检查：

```bash
bash -n install.sh
bash -n vps-node.sh
bash vps-node.sh --self-test
python3 tests/test_manager.py
sha256sum -c SHA256SUMS
```

报告问题时请提供发行版、脚本/核心版本及脱敏日志。不要上传 UUID、密码、Token、私钥、节点链接或二维码。
