# sing-box 中文多协议节点管理脚本

这是一个面向 **端口映射容器/VPS** 的 sing-box 中文交互管理脚本。一个 sing-box 内核、一个 systemd 服务同时管理四种协议，不会为每种协议重复安装内核。

## 支持的协议

| 协议 | 传输 | 推荐用途 |
|---|---|---|
| VLESS + REALITY + Vision | TCP | 主要 TCP 节点，无需自有证书 |
| VMess AEAD | TCP | 兼容旧客户端，不带 TLS |
| Hysteria2 + Salamander | UDP/QUIC | UDP 网络、弱网和移动网络 |
| TUIC v5 | UDP/QUIC | UDP 网络、低延迟连接 |

当前固定使用官方 sing-box `1.14.2` Linux amd64 glibc 版本，并校验下载文件的 SHA-256。

## 系统要求

- Debian 或 Ubuntu 容器/VPS
- Linux amd64（`x86_64`）
- root 权限
- systemd 正常运行
- 容器能够访问互联网
- 商家后台允许添加 TCP/UDP 端口映射

## 一键安装或更新

在商家自带终端中，以 root 身份粘贴下面一行：

```bash
curl -fsSL https://raw.githubusercontent.com/qingxinguayu999-alt/vps-node/main/sing-box-multi-protocol/install.sh | bash && jiaoben
```

安装完成后，任何时候输入以下命令即可打开中文菜单：

```bash
jiaoben
```

原命令也继续可用：

```bash
sing-box-node
```

彻底卸载可以输入：

```bash
sc
```

为防止误删，必须再输入大写 `DELETE` 才会执行。若系统原本已有同名 `sc` 命令，安装器不会覆盖它，请改用：

```bash
sing-box-node uninstall
```

重复执行安装命令属于更新脚本，不会删除 `/etc/sing-box/node.env` 中已经保存的端口和节点凭据。

## 端口映射示例

下面仅用示例域名 `node.example.net` 和示例端口说明填写方法。首次运行时，脚本不会预填任何用户的公网域名或业务端口，必须填写商家实际分配给自己的信息：

| 协议 | 商家后台公网端口 | 后台协议 | 实例端口 |
|---|---:|---|---:|
| SSH | 30000 | TCP | 22 |
| VLESS Reality | 30001 | TCP | 10001 |
| VMess | 30002 | TCP | 10002 |
| Hysteria2 | 30003 | UDP | 10003 |
| TUIC | 30004 | UDP | 10004 |

公网端口和实例端口不必相同。例如：

```text
公网 30003/UDP → 实例 10003/UDP
```

脚本中对应填写：

```text
Hysteria2 公网端口：30003
Hysteria2 实例监听端口：10003
```

规则：

- `公网端口` 是商家后台公网地址冒号后的端口。
- `实例监听端口` 是商家后台右侧转发到容器的端口。
- VLESS Reality、VMess 使用 TCP。
- Hysteria2、TUIC 使用 UDP。
- 必须先在商家后台添加/修改映射，再运行脚本修改节点。
- 公网端口只能使用商家分配给账号的端口段。
- 公网域名只填写域名本身，例如 `node.example.net`，不要填写 `https://` 或 `:端口`。
- 首次安装所有地址和业务端口均为必填；升级或再次修改时才显示该服务器上次保存的值。

## 中文菜单

运行 `jiaoben` 后可以看到：

```text
1. 安装或修改 VLESS Reality（TCP）
2. 安装或修改 VMess（TCP）
3. 安装或修改 Hysteria2（UDP）
4. 安装或修改 TUIC（UDP）
5. 一次安装或修改 Hysteria2 + TUIC
6. 查看全部节点和分享链接
7. 查看 sing-box 运行状态
8. 查看最近 100 行日志
9. 重新生成协议凭据
0. 退出
```

第一次部署四种协议时，依次选择：

1. 菜单 `1` 配置 VLESS Reality。
2. 菜单 `2` 配置 VMess。
3. 菜单 `5` 同时配置 Hysteria2 和 TUIC。
4. 菜单 `6` 查看四条分享链接。

提示中的 `[默认值]` 正确时直接按回车即可。

## 常用命令

```bash
# 打开中文菜单
jiaoben

# 查看全部分享链接
cat /root/sing-box-link.txt

# 查看服务状态
systemctl status sing-box --no-pager

# 查看最近日志
journalctl -u sing-box -n 100 --no-pager

# 彻底卸载（随后输入 DELETE 确认）
sc
```

## 文件位置

| 文件 | 路径 |
|---|---|
| sing-box 内核 | `/usr/local/bin/sing-box` |
| 中文管理脚本 | `/usr/local/sbin/sing-box-node` |
| 快捷命令 | `/usr/local/bin/jiaoben` |
| 卸载快捷命令 | `/usr/local/bin/sc` |
| sing-box 配置 | `/etc/sing-box/config.json` |
| 管理器状态 | `/etc/sing-box/node.env` |
| TLS 证书 | `/etc/sing-box/server.crt` |
| TLS 私钥 | `/etc/sing-box/server.key` |
| 分享链接 | `/root/sing-box-link.txt` |

## 安全说明

- 分享链接包含 UUID 或密码，只发给可信的使用者。
- Hysteria2 链接包含自签证书指纹；TUIC 使用自签证书兼容模式。
- VMess 节点采用原生 TCP，不带 TLS，主要用于客户端兼容；优先使用 VLESS Reality。
- 重新生成某协议凭据后，该协议旧链接会立即失效。
- `sc` 完整卸载会删除 sing-box 服务、内核、配置、凭据、证书、备份、分享链接、管理脚本和对应 UFW 端口规则；系统共用基础软件及系统日志不会删除。
- 请遵守服务器提供商条款及所在地法律法规。
