# VPS Node 四合一脚本 v2.2.0

Debian / Ubuntu 中文菜单脚本，仅新建 **VLESS、VMess、TUIC v5、Hysteria2（HY2）** 四种节点。支持一次创建四合一、Argo 固定隧道、BBR、IPv4/IPv6、域名证书、自签证书，以及一个 HTTPS 订阅链接和二维码。

项目：https://github.com/qingxinguayu999-alt/vps-node

## 安装

在自己的 VPS 上执行：

```bash
curl -fsSL https://raw.githubusercontent.com/qingxinguayu999-alt/vps-node/main/install.sh -o install-vps-node.sh
sudo bash install-vps-node.sh
```

没有 curl 时先安装：

```bash
sudo apt-get update && sudo apt-get install -y curl
```

安装器校验脚本版本和 SHA256，检查语法，安装核心及依赖，注册快捷命令。目标系统为带 systemd 的 Debian 12/13、Ubuntu 22.04/24.04；支持常见 amd64/arm64 VPS，需要 root、正常 DNS 和访问上游 APT/GitHub 的网络。普通 Docker 容器不适用，容器中的 BBR 可能受宿主机限制。

也可以上传 vps-node.sh 到服务器后运行 `sudo bash vps-node.sh`，选择菜单 1 安装。

## 快捷命令

| 命令 | 功能 |
| --- | --- |
| `jb` | 打开彩色脚本主菜单 |
| `k` | 查看一个订阅链接和二维码；未配置订阅时显示单节点链接 |
| `sc` | 输入 UNINSTALL 确认后卸载本工具 |

root 直接输入命令，普通用户加 sudo，例如 `sudo jb`。命令冲突时不会覆盖其他程序，可使用 `sudo vps-node jb`、`sudo vps-node k`、`sudo vps-node sc`。

## 四合一创建

1. 输入 jb，选择 **15 四合一创建**。
2. 选择 IPv4 或 IPv6。
3. VLESS/VMess 默认走 Argo，填写两者的公开域名；推荐分别使用 `vless.你的域名` 和 `vmess.你的域名`。也可选择公网 IP＋自签证书直连，或填写域名并申请/导入证书。
4. TUIC/HY2 默认选择 **无域名＋自动自签证书**：回车确认自动识别的公网 IP，也可选域名证书模式。
5. 设置起始端口和名称，脚本一次生成四个节点，校验配置并启动。启动失败恢复此前配置。
6. 选择配置四合一订阅，填写独立订阅域名，例如 `sub.你的域名`。
7. 在 Cloudflare 控制台创建固定 Tunnel，配置下文的公开主机名路由；菜单 7 输入 Tunnel Token。
8. 输入 k，复制一个订阅链接或扫码，将四种节点一起导入客户端。

菜单 2 仍支持单独添加四种协议之一。菜单 3 修改节点的名称、域名、证书、端口、地址族、WS 路径或凭据。可以重复创建多组节点，订阅包含全部受支持节点。

## 协议与证书

| 协议 | 默认四合一模式 | 直连放行 |
| --- | --- | --- |
| VLESS | WebSocket，经 Argo，客户端 TLS/443 | 改用直连时放行 TCP |
| VMess | WebSocket，经 Argo，alterId=0 | 改用直连时放行 TCP |
| TUIC v5 | 公网 IP、UDP/QUIC、自签证书、协议 BBR | UDP |
| HY2 | 公网 IP、UDP/QUIC、自签证书 | UDP |

TUIC/HY2 添加和修改均可选择无域名自签或自定义域名证书。无域名模式无需 DNS 或 80/TCP，HTTPS 查询所选地址族的公网 IP（ipify）；失败时手动填写。NAT VPS 需自己做好 UDP 端口映射。

自签证书包含 IP SAN，有效期约 10 年；IP 不变且证书有效时复用，修改名称或端口不会改变指纹。更换 IP/证书后重新更新客户端订阅。已有域名证书节点不会自动切换到自签。

- HY2 分享 URI：insecure=1，并附 pinSHA256 指纹；客户端需要支持并保留指纹。
- TUIC 分享 URI：使用 allow_insecure / allowInsecure / insecure 参数，客户端导入方式不同。此 URI 不保证所有客户端能固定证书身份；想保留身份校验，可改用正式域名证书，或导入本工具的 sing-box JSON 配置，它内置自签公有证书作为信任材料，不含私钥。
- Clash Meta/Mihomo 配置：自签节点带 skip-cert-verify 和证书 fingerprint，请使用支持这些字段的当前核心。

自动申请使用 Certbot HTTP-01：域名 A/AAAA 正确指向 VPS，80/TCP 需空闲、可从公网访问，按菜单同意 Let's Encrypt 条款。不会停止已有 Web 服务抢占 80。启用 certbot.timer 及续期后节点服务重启钩子。

导入证书填写 fullchain.pem、privkey.pem 的服务器绝对路径，检查期限、域名/IP、公私钥匹配并复制到专用目录；导入证书需自行续期。Cloudflare Origin CA 不是普通客户端默认信任的证书。

直连 TUIC/HY2 使用 CF 管理的域名时设置 **仅 DNS（灰云）**，不能通过普通橙云或本脚本的 Argo 隧道。

## Argo 与 HTTPS 订阅路由

在 Cloudflare 控制台创建远程管理的固定 Tunnel，保存 Token。Public hostname 分别设置：

| 公开域名 | Service 类型 | Service 地址 |
| --- | --- | --- |
| vless.你的域名 | HTTP | 脚本显示的 VLESS 本机地址 |
| vmess.你的域名 | HTTP | 脚本显示的 VMess 本机地址 |
| sub.你的域名 | HTTP | http://127.0.0.1:18999（以实际订阅端口为准） |

Argo 节点选 IPv4 时本机地址类似 `http://127.0.0.1:20000`；选 IPv6 时类似 `http://[::1]:20000`。订阅服务固定监听 IPv4 回环地址，客户端仍通过 Cloudflare HTTPS 访问。

菜单 7 隐藏输入 Token，运行独立 cloudflared 服务。查看菜单 9 日志确认隧道连接。一个 Tunnel 可承载三个主机名。若坚持让 VLESS/VMess 共用域名，需要在 Cloudflare 按两者各自 WS 路径配置不同的 HTTP 服务路由。订阅必须使用独立域名，以免路由冲突。

订阅主机名不要启用需要浏览器登录的 Cloudflare Access 或交互式挑战；不要缓存订阅内容。订阅地址本身带随机 Token，返回 Cache-Control no-store。Token 只保护知道链接的人可访问，不应公开链接或二维码。

**短链接不是免费的第三方缩短服务**：它由你自己的订阅域名和本机服务提供，类似 `https://sub.你的域名/s/随机Token`。只有完成 Cloudflare 路由、Tunnel 在线后才实际可访问。无需将节点密码上传 GitHub或公共转换站。没配置订阅域名时仍可离线导出本地文件及单节点二维码。

## 客户端导入

默认一个订阅地址，根据客户端 User-Agent 自动返回适合的格式。菜单 **18 按客户端导出** 可强制格式，仍使用同一个私有订阅入口，无需第三方转换。

| 客户端 | 推荐导出 | 导入位置 |
| --- | --- | --- |
| v2rayN / v2rayNG | 通用 Base64 | 订阅分组 / 添加订阅地址 |
| Shadowrocket（小火箭） | 通用 Base64 | 添加 Subscribe 类型或支持的订阅扫码入口 |
| NekoBox（nebox） | 通用 Base64 | 分组 / 订阅 URL；也可导入 sing-box JSON 自定义配置 |
| Clash Meta / Mihomo | Clash 配置 | 添加远程配置 URL |
| sing-box | sing-box JSON | 导入完整配置 |

强制格式对应 `?format=base64`、`?format=clash`、`?format=singbox`、`?format=plain`。如果自动识别失效，选择菜单 18 获取相应链接/二维码。

旧版原始 Clash 核心不支持完整四协议，请用 Clash Meta/Mihomo。客户端必须本身支持 VLESS、VMess、TUIC v5、HY2；本项目不保证旧版本兼容，各客户端版本的兼容性需按实际导入结果确认。二维码编码的是订阅 URL，应该在客户端“添加订阅”入口使用，不是四个节点强行合成一种新协议。

## 菜单与更新

- 1 安装核心及依赖；2 单节点添加；3 修改；4 删除；5/k 查看。
- 6 TCP BBR；7 Argo；8 状态；9 日志；10 重启节点；11 停止 Argo。
- 12 检查更新；13 设置更新源；14 导入本地新版脚本。
- 15 四合一；16 HTTPS 订阅设置；17 换订阅 Token（旧链接失效）；18 按客户端导出。
- sc 卸载；0 退出。

菜单 12 查询脚本更新清单、APT 的 sing-box Installed/Candidate 和 cloudflared 最新发布。脚本更新需要输入 UPDATE，之后退出并重新运行 jb；运行中的订阅服务会重启加载新版。核心和 cloudflared 不自动升级。

发布新版时提高脚本 VERSION，然后执行 `python3 tools/make_manifest.py` 生成 update.json 与 SHA256SUMS，一起提交。更换仓库需修改默认更新地址、安装器 base_url 和 README 命令。

升级到 v2.2.0 后，不再新建 Trojan/Shadowsocks，也不把它们加入四协议订阅；旧节点保持服务以免无意中断，若不需要用菜单 4 删除。

## 文件、服务与验证

专用目录 `/etc/vps-node/` 包含配置、凭据、证书和最新回滚副本；不要公开。导出文件：links.txt、subscription.txt、clash.yaml、sing-box-client.json、qr/ 及 subscription-qr.png。Clash 配置采用兼容 YAML 的 JSON 表示。只导出自签公有证书，不导出私钥。

服务分别为 vps-node（节点）、vps-node-argo（隧道）、vps-node-sub（订阅）。本工具不覆盖已有 sing-box 默认配置，但需要避免端口冲突。不自动更改云安全组或 UFW/iptables。IPv6 监听 :: 在一些系统中也接收 IPv4；该选项是监听地址族，不强制代理出站地址族。

BBR 检测内核支持后开启系统 TCP BBR，不替换内核，不等同于 TUIC/HY2 的 QUIC 拥塞控制，也不保证提高网速。

sc 卸载停止并删除本工具三个服务、配置、凭据和快捷命令；保留依赖软件包、系统 BBR、ACME 证书、CF 控制台隧道及原上传脚本。

本地校验：

```bash
bash -n install.sh
bash -n vps-node.sh
bash vps-node.sh --self-test
python3 tests/test_manager.py
sha256sum -c SHA256SUMS
```

已检查回滚、证书生成、订阅内容、HTTP Token 保护、格式切换、动态更新、Token 轮换、真实终端输入及管理锁恢复。实机测试范围见下方“已实测”记录。

MIT 开源许可，第三方核心与依赖遵守各自上游许可。报告问题时提供系统/核心/脚本版本和脱敏日志，不要上传节点链接、二维码、UUID、密码、Token 或私钥。

官方参考：

- https://sing-box.sagernet.org/configuration/
- https://v2.hysteria.network/docs/developers/URI-Scheme/
- https://wiki.metacubex.one/en/config/proxies/tuic/
- https://wiki.metacubex.one/en/config/proxies/hysteria2/
- https://matsuridayo.github.io/nb4a-configuration/

## VLESS/VMess 连接与证书切换

菜单 2 添加、菜单 3 修改 VLESS/VMess 时，可选：

1. **公网 IP＋自签证书直连**：无需自己的域名，自动生成含 IP 的证书；客户端连接 VPS 的 TCP 端口。
2. **域名证书直连**：填写域名，申请 Let’s Encrypt 或导入自己的证书和私钥。
3. **Argo**：填写 Cloudflare 隧道公开域名；客户端使用 Cloudflare HTTPS 证书，源站监听回环地址。VMess 新增时默认此模式。

TUIC/HY2 在菜单 2、3 同样可在自签证书和域名证书之间切换。改动后更新客户端订阅；切换到 Argo 时还需配置 Tunnel 路由，切换到直连时需放行对应端口。

四合一向导选择不走 Argo 后，VLESS/VMess 也可选择自签或域名证书，因此四个节点都可以无需自己的域名使用。**一个 HTTPS 订阅链接仍需要配置订阅域名**；也可直接使用各节点分享链接/二维码。

自签节点导出包含证书信任或指纹参数：sing-box 配置携带公共证书，Clash/Mihomo 配置携带证书指纹，VLESS/VMess 分享链接携带 `pcs`。不同客户端版本对参数支持不同；不识别时使用对应配置格式，或改用受信任的域名证书。已收到使用者四协议通网反馈；不代表所有客户端版本均已验证。

## 历史修复：终端无限刷新

修复 `sudo jb` 在部分终端出现 `File or stream is not seekable` 后无限刷新菜单的问题。终端输入改为分别读写，菜单读取失败时退出并保留错误。升级不重新安装核心或修改已有节点配置。

## 断线恢复与故障排查

SSH 断线后若提示“另一个管理程序正在运行”，新版会显示占锁 PID。确认旧会话已经断开、没有正在执行的安装/修改后运行：

```bash
sudo vps-node --unlock
```

输入 `STOP` 后仅停止经验证的占锁管理进程，保留节点服务。无需安装 fuser，不删除锁文件，不自动强杀进程。收到 SSH 挂断或终止信号时，新版管理程序退出并释放锁。不同 SSH 客户端未必发送挂断信号，仍可使用此恢复入口。

菜单等待输入是正常状态；错误输出应保留便于排查。公网 IP 查询约 8 秒超时，curl 下载及 OpenSSL 操作有超时保护。APT 安装耗时取决于仓库网络与系统包管理锁。

## 已实测

**2026-10-11，使用者反馈：VLESS、VMess、TUIC、Hysteria2 已导入客户端实测，全部通网。** 此反馈来自本项目使用者在真实 VPS 上的操作；客户端名称/版本及各协议连接模式未完整记录。

使用者同时确认 v2.1.1 修复菜单无限刷新后菜单正常，以及旧管理进程停止后恢复使用。v2.2.0 新增的断线恢复入口通过自动化进程锁测试（真实跨进程锁及终止，/proc 元数据模拟）；尚待使用者实机确认。ACME 自动签发续期、Cloudflare Argo、HTTPS 订阅和系统 BBR 未收到明确实测结果。

本记录只覆盖已反馈的范围，不代表所有 Debian/Ubuntu 版本、客户端版本及所有功能都已验证。

## v2.2.0 更新

增加占锁 PID 提示和 `--unlock` 恢复入口；管理程序收到挂断/终止信号时退出；为 curl 与 OpenSSL 操作增加超时保护；安装器增加连接和下载时限；整理故障处理与已实测记录。15 项自动化测试通过。已有用户执行 `sudo jb` → 菜单 12 → 按提示输入 `UPDATE`，然后退出并重新打开。
