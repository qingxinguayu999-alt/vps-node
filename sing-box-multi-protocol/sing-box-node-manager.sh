#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly MANAGER_VERSION="2.2.0"
readonly SB_VERSION="1.14.2"
readonly SB_ARCHIVE="sing-box-${SB_VERSION}-linux-amd64-glibc.tar.gz"
readonly SB_URL="https://github.com/SagerNet/sing-box/releases/download/v${SB_VERSION}/${SB_ARCHIVE}"
readonly SB_SHA256="5c7bc18461827b28d0e5ee7e89d33b276d3ff7c818531104c8e8d26d85b0656e"
readonly SB_BIN="/usr/local/bin/sing-box"
readonly SB_DIR="/etc/sing-box"
readonly SB_CONFIG="${SB_DIR}/config.json"
readonly SB_STATE="${SB_DIR}/node.env"
readonly SB_CERT="${SB_DIR}/server.crt"
readonly SB_CERT_KEY="${SB_DIR}/server.key"
readonly SB_LINK_FILE="/root/sing-box-link.txt"
readonly SB_SERVICE="/etc/systemd/system/sing-box.service"
readonly MANAGER_PATH="/usr/local/sbin/sing-box-node"
readonly JIAOBEN_SHORTCUT="/usr/local/bin/jiaoben"
readonly SC_SHORTCUT="/usr/local/bin/sc"

PUBLIC_HOST=""
VLESS_ENABLED="0"
VLESS_PUBLIC_PORT=""
VLESS_LISTEN_PORT=""
REALITY_SERVER_NAME="www.microsoft.com"
VLESS_UUID=""
REALITY_PRIVATE_KEY=""
REALITY_PUBLIC_KEY=""
REALITY_SHORT_ID=""

VMESS_ENABLED="0"
VMESS_PUBLIC_PORT=""
VMESS_LISTEN_PORT=""
VMESS_UUID=""

HY2_ENABLED="0"
HY2_PUBLIC_PORT=""
HY2_LISTEN_PORT=""
HY2_PASSWORD=""
HY2_OBFS_PASSWORD=""

TUIC_ENABLED="0"
TUIC_PUBLIC_PORT=""
TUIC_LISTEN_PORT=""
TUIC_UUID=""
TUIC_PASSWORD=""

TLS_CERT_NAME=""
CERT_FINGERPRINT=""
CONFIG_BACKUP=""

green='\033[1;32m'
cyan='\033[1;36m'
yellow='\033[1;33m'
red='\033[1;31m'
reset='\033[0m'

info() { printf '\n%b==> %s%b\n' "$cyan" "$*" "$reset"; }
ok() { printf '%b%s%b\n' "$green" "$*" "$reset"; }
warn() { printf '%b注意：%s%b\n' "$yellow" "$*" "$reset"; }
die() { printf '%b错误：%s%b\n' "$red" "$*" "$reset" >&2; exit 1; }

require_environment() {
  [[ "$EUID" -eq 0 ]] || die "请使用 root 运行"
  [[ "$(uname -m)" == "x86_64" ]] || die "此脚本仅支持 Linux amd64"
  [[ -d /run/systemd/system ]] || die "当前容器没有运行 systemd"
}

ensure_shortcuts() {
  local source_path existing_sc resolved_sc
  source_path="$(readlink -f "${BASH_SOURCE[0]}")"
  install -d -m 0755 /usr/local/sbin /usr/local/bin
  if [[ "$source_path" != "$MANAGER_PATH" ]]; then
    install -m 0755 "$source_path" "$MANAGER_PATH"
  fi
  ln -sfn "$MANAGER_PATH" "$JIAOBEN_SHORTCUT"

  if [[ -L "$SC_SHORTCUT" ]]; then
    resolved_sc="$(readlink -f "$SC_SHORTCUT" 2>/dev/null || true)"
    if [[ -n "$resolved_sc" && "$resolved_sc" != "$MANAGER_PATH" ]]; then
      warn "${SC_SHORTCUT} 已指向其他程序，未覆盖；可用 sing-box-node uninstall 卸载。"
      return 0
    fi
  elif [[ -e "$SC_SHORTCUT" ]]; then
    warn "${SC_SHORTCUT} 已存在且不是本脚本，未覆盖；可用 sing-box-node uninstall 卸载。"
    return 0
  else
    existing_sc="$(command -v sc 2>/dev/null || true)"
    if [[ -n "$existing_sc" ]]; then
      warn "系统已有 sc 命令（${existing_sc}），未覆盖；可用 sing-box-node uninstall 卸载。"
      return 0
    fi
  fi
  ln -sfn "$MANAGER_PATH" "$SC_SHORTCUT"
}

remove_ufw_rule() {
  local enabled="$1" port="$2" protocol="$3"
  [[ "$enabled" == "1" ]] || return 0
  validate_port "$port" || return 0
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  ufw --force delete allow "${port}/${protocol}" >/dev/null 2>&1 || true
}

remove_owned_shortcut() {
  local shortcut="$1" resolved=""
  [[ -L "$shortcut" ]] || return 0
  resolved="$(readlink -f "$shortcut" 2>/dev/null || true)"
  if [[ "$resolved" == "$MANAGER_PATH" ]]; then
    rm -f -- "$shortcut"
  fi
  return 0
}

full_uninstall() {
  local confirm
  [[ "$EUID" -eq 0 ]] || die "请使用 root 运行"
  printf '\n%b即将彻底删除 sing-box 多协议节点及管理脚本：%b\n' "$red" "$reset"
  printf -- '- 停止并删除 sing-box 服务和内核\n'
  printf -- '- 删除全部节点配置、凭据、证书、备份和分享链接\n'
  printf -- '- 删除 jiaoben 和 sc 快捷命令\n'
  printf -- '- 删除本脚本开启的已保存协议端口规则\n'
  printf '系统共用的 curl、OpenSSL 等基础软件不会删除。\n\n'
  read -r -p '输入 DELETE 确认彻底删除：' confirm
  [[ "$confirm" == "DELETE" ]] || { printf '已取消卸载。\n'; exit 0; }

  if [[ -f "$SB_STATE" ]]; then
    # 状态文件由本脚本创建，仅 root 可读写；用于清理对应的 UFW 端口规则。
    # shellcheck disable=SC1090
    source "$SB_STATE"
  fi
  remove_ufw_rule "${VLESS_ENABLED:-0}" "${VLESS_LISTEN_PORT:-}" tcp
  remove_ufw_rule "${VMESS_ENABLED:-0}" "${VMESS_LISTEN_PORT:-}" tcp
  remove_ufw_rule "${HY2_ENABLED:-0}" "${HY2_LISTEN_PORT:-}" udp
  remove_ufw_rule "${TUIC_ENABLED:-0}" "${TUIC_LISTEN_PORT:-}" udp

  if command -v systemctl >/dev/null 2>&1; then
    systemctl disable --now sing-box.service >/dev/null 2>&1 || true
  fi
  rm -f -- "$SB_SERVICE" /etc/systemd/system/multi-user.target.wants/sing-box.service
  if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl reset-failed sing-box.service >/dev/null 2>&1 || true
  fi

  [[ "$SB_DIR" == "/etc/sing-box" ]] || die "拒绝删除非预期配置目录：${SB_DIR}"
  rm -rf -- /etc/sing-box
  remove_owned_shortcut "$JIAOBEN_SHORTCUT"
  remove_owned_shortcut "$SC_SHORTCUT"
  rm -f -- "$SB_BIN" "$SB_LINK_FILE" "$MANAGER_PATH"
  find /tmp -maxdepth 1 -type d -name 'sing-box-manager.*' -exec rm -rf -- {} + 2>/dev/null || true
  find /tmp -maxdepth 1 -type f -name 'sing-box-node-manager.*' -delete 2>/dev/null || true
  printf '\n%b卸载完成：sing-box 节点和本管理脚本已删除。%b\n' "$green" "$reset"
  exit 0
}

validate_host() {
  [[ "$1" =~ ^[A-Za-z0-9.-]+$ && "$1" != -* && "$1" != *..* && "$1" != *.-* && "$1" != *-. && "$1" == *.* ]]
}

validate_port() {
  [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 ))
}

validate_flag() {
  [[ "$1" == "0" || "$1" == "1" ]]
}

install_dependencies() {
  local missing=0 command_name
  for command_name in curl tar sha256sum install awk sed openssl base64; do
    command -v "$command_name" >/dev/null 2>&1 || missing=1
  done
  (( missing == 0 )) && return 0
  command -v apt-get >/dev/null 2>&1 || die "缺少基础命令，且系统不是 Debian/Ubuntu"
  apt-get update
  DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl tar coreutils gawk sed openssl
}

ensure_binary() {
  local current_version="" work_dir archive actual_hash extracted
  if [[ -x "$SB_BIN" ]]; then
    current_version="$($SB_BIN version 2>/dev/null | awk 'NR==1 {print $3}')"
  fi
  if [[ "$current_version" == "$SB_VERSION" ]]; then
    ok "已安装 sing-box ${SB_VERSION}，无需重复下载"
    return 0
  fi

  work_dir="$(mktemp -d /tmp/sing-box-manager.XXXXXX)"
  archive="${work_dir}/${SB_ARCHIVE}"
  info "下载 sing-box ${SB_VERSION} 官方稳定版"
  curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 "$SB_URL" -o "$archive"
  actual_hash="$(sha256sum "$archive" | awk '{print $1}')"
  [[ "$actual_hash" == "$SB_SHA256" ]] || { rm -rf -- "$work_dir"; die "安装包 SHA-256 校验失败"; }
  tar -xzf "$archive" -C "$work_dir"
  extracted="${work_dir}/sing-box-${SB_VERSION}-linux-amd64-glibc/sing-box"
  [[ -x "$extracted" ]] || { rm -rf -- "$work_dir"; die "压缩包内未找到 sing-box"; }
  install -m 0755 "$extracted" "$SB_BIN"
  rm -rf -- "$work_dir"
  ok "sing-box ${SB_VERSION} 安装成功，SHA-256 校验通过"
}

parse_query_value() {
  local key="$1" link="$2"
  printf '%s\n' "$link" | sed -n "s/.*[?&]${key}=\([^&]*\).*/\1/p" | head -n 1
}

load_or_migrate_state() {
  local link authority host_port parsed
  if [[ -f "$SB_STATE" ]]; then
    # 状态文件仅 root 可读写，所有值仍会在下方重新校验。
    # shellcheck disable=SC1090
    source "$SB_STATE"
    # 兼容上一版中文管理脚本的变量名，升级时保留原节点凭据。
    if [[ -n "${PUBLIC_PORT:-}" ]]; then
      VLESS_PUBLIC_PORT="$PUBLIC_PORT"
      VLESS_LISTEN_PORT="${LISTEN_PORT:-$PUBLIC_PORT}"
      REALITY_SERVER_NAME="${SERVER_NAME:-$REALITY_SERVER_NAME}"
      VLESS_UUID="${UUID:-$VLESS_UUID}"
      REALITY_PRIVATE_KEY="${PRIVATE_KEY:-$REALITY_PRIVATE_KEY}"
      REALITY_PUBLIC_KEY="${PUBLIC_KEY:-$REALITY_PUBLIC_KEY}"
      REALITY_SHORT_ID="${SHORT_ID:-$REALITY_SHORT_ID}"
      VLESS_ENABLED="1"
      ok "已兼容导入上一版 VLESS Reality 配置"
    fi
  elif [[ -f "$SB_CONFIG" && -f "$SB_LINK_FILE" ]]; then
    VLESS_UUID="$(awk -F'"' '/"uuid"[[:space:]]*:/ {print $4; exit}' "$SB_CONFIG")"
    REALITY_PRIVATE_KEY="$(awk -F'"' '/"private_key"[[:space:]]*:/ {print $4; exit}' "$SB_CONFIG")"
    REALITY_SHORT_ID="$(awk -F'"' '/"short_id"[[:space:]]*:/ {print $4; exit}' "$SB_CONFIG")"
    VLESS_LISTEN_PORT="$(awk '/"listen_port"[[:space:]]*:/ {gsub(/[^0-9]/, ""); print; exit}' "$SB_CONFIG")"
    link="$(sed -n '/^vless:\/\//p' "$SB_LINK_FILE" | head -n 1)"
    REALITY_PUBLIC_KEY="$(parse_query_value pbk "$link")"
    REALITY_SERVER_NAME="$(parse_query_value sni "$link")"
    authority="${link#vless://}"
    authority="${authority#*@}"
    host_port="${authority%%\?*}"
    PUBLIC_HOST="${host_port%:*}"
    VLESS_PUBLIC_PORT="${host_port##*:}"
    VLESS_ENABLED="1"
    ok "已导入当前 VLESS Reality 配置"
  fi

  validate_host "$PUBLIC_HOST" || PUBLIC_HOST=""
  validate_host "$REALITY_SERVER_NAME" || REALITY_SERVER_NAME="www.microsoft.com"
  validate_flag "$VLESS_ENABLED" || VLESS_ENABLED="0"
  validate_flag "$VMESS_ENABLED" || VMESS_ENABLED="0"
  validate_flag "$HY2_ENABLED" || HY2_ENABLED="0"
  validate_flag "$TUIC_ENABLED" || TUIC_ENABLED="0"
  validate_port "$VLESS_PUBLIC_PORT" || VLESS_PUBLIC_PORT=""
  validate_port "$VLESS_LISTEN_PORT" || VLESS_LISTEN_PORT=""
  validate_port "$VMESS_PUBLIC_PORT" || VMESS_PUBLIC_PORT=""
  validate_port "$VMESS_LISTEN_PORT" || VMESS_LISTEN_PORT=""
  validate_port "$HY2_PUBLIC_PORT" || HY2_PUBLIC_PORT=""
  validate_port "$HY2_LISTEN_PORT" || HY2_LISTEN_PORT=""
  validate_port "$TUIC_PUBLIC_PORT" || TUIC_PUBLIC_PORT=""
  validate_port "$TUIC_LISTEN_PORT" || TUIC_LISTEN_PORT=""

  parsed="${VLESS_UUID//-/}"
  [[ "$parsed" =~ ^[0-9a-fA-F]{32}$ ]] || VLESS_UUID=""
  [[ ${#REALITY_PRIVATE_KEY} -eq 43 ]] || REALITY_PRIVATE_KEY=""
  [[ ${#REALITY_PUBLIC_KEY} -eq 43 ]] || REALITY_PUBLIC_KEY=""
  [[ "$REALITY_SHORT_ID" =~ ^[0-9a-fA-F]{16}$ ]] || REALITY_SHORT_ID=""
  parsed="${VMESS_UUID//-/}"
  [[ "$parsed" =~ ^[0-9a-fA-F]{32}$ ]] || VMESS_UUID=""
  [[ "$HY2_PASSWORD" =~ ^[0-9a-fA-F]{32}$ ]] || HY2_PASSWORD=""
  [[ "$HY2_OBFS_PASSWORD" =~ ^[0-9a-fA-F]{32}$ ]] || HY2_OBFS_PASSWORD=""
  parsed="${TUIC_UUID//-/}"
  [[ "$parsed" =~ ^[0-9a-fA-F]{32}$ ]] || TUIC_UUID=""
  [[ "$TUIC_PASSWORD" =~ ^[0-9a-fA-F]{32}$ ]] || TUIC_PASSWORD=""
  validate_host "${TLS_CERT_NAME:-}" || TLS_CERT_NAME=""
}

save_state() {
  install -d -m 0755 "$SB_DIR"
  cat >"$SB_STATE" <<EOF
PUBLIC_HOST='${PUBLIC_HOST}'
VLESS_ENABLED='${VLESS_ENABLED}'
VLESS_PUBLIC_PORT='${VLESS_PUBLIC_PORT}'
VLESS_LISTEN_PORT='${VLESS_LISTEN_PORT}'
REALITY_SERVER_NAME='${REALITY_SERVER_NAME}'
VLESS_UUID='${VLESS_UUID}'
REALITY_PRIVATE_KEY='${REALITY_PRIVATE_KEY}'
REALITY_PUBLIC_KEY='${REALITY_PUBLIC_KEY}'
REALITY_SHORT_ID='${REALITY_SHORT_ID}'
VMESS_ENABLED='${VMESS_ENABLED}'
VMESS_PUBLIC_PORT='${VMESS_PUBLIC_PORT}'
VMESS_LISTEN_PORT='${VMESS_LISTEN_PORT}'
VMESS_UUID='${VMESS_UUID}'
HY2_ENABLED='${HY2_ENABLED}'
HY2_PUBLIC_PORT='${HY2_PUBLIC_PORT}'
HY2_LISTEN_PORT='${HY2_LISTEN_PORT}'
HY2_PASSWORD='${HY2_PASSWORD}'
HY2_OBFS_PASSWORD='${HY2_OBFS_PASSWORD}'
TUIC_ENABLED='${TUIC_ENABLED}'
TUIC_PUBLIC_PORT='${TUIC_PUBLIC_PORT}'
TUIC_LISTEN_PORT='${TUIC_LISTEN_PORT}'
TUIC_UUID='${TUIC_UUID}'
TUIC_PASSWORD='${TUIC_PASSWORD}'
TLS_CERT_NAME='${TLS_CERT_NAME}'
EOF
  chmod 0600 "$SB_STATE"
}

prompt_value() {
  local prompt="$1" default_value="$2" result
  read -r -p "${prompt} [${default_value}]：" result
  printf '%s' "${result:-$default_value}"
}

prompt_required() {
  local prompt="$1" default_value="$2" result
  while true; do
    if [[ -n "$default_value" ]]; then
      read -r -p "${prompt} [${default_value}]：" result
      result="${result:-$default_value}"
    else
      read -r -p "${prompt}（必填）：" result
    fi
    [[ -n "$result" ]] && { printf '%s' "$result"; return 0; }
    warn "此项不能为空" >&2
  done
}

prompt_host() {
  local value
  value="$(prompt_required '公网域名（不要填写端口）' "$PUBLIC_HOST")"
  validate_host "$value" || die "公网域名格式错误"
  PUBLIC_HOST="$value"
}

prompt_port_pair() {
  local protocol="$1" current_public="$2" current_listen="$3" result_public result_listen
  result_public="$(prompt_required "${protocol} 公网端口" "$current_public")"
  [[ -n "$current_listen" ]] || current_listen="$result_public"
  result_listen="$(prompt_required "${protocol} 实例监听端口" "$current_listen")"
  validate_port "$result_public" || die "${protocol} 公网端口格式错误"
  validate_port "$result_listen" || die "${protocol} 实例端口格式错误"
  printf '%s %s' "$result_public" "$result_listen"
}

ensure_reality_credentials() {
  local key_pair
  if [[ -n "$VLESS_UUID" && -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" && -n "$REALITY_SHORT_ID" ]]; then
    return 0
  fi
  VLESS_UUID="$($SB_BIN generate uuid)"
  key_pair="$($SB_BIN generate reality-keypair)"
  REALITY_PRIVATE_KEY="$(printf '%s\n' "$key_pair" | awk '/PrivateKey:/ {print $2; exit}')"
  REALITY_PUBLIC_KEY="$(printf '%s\n' "$key_pair" | awk '/PublicKey:/ {print $2; exit}')"
  REALITY_SHORT_ID="$($SB_BIN generate rand --hex 8)"
  [[ ${#REALITY_PRIVATE_KEY} -eq 43 && ${#REALITY_PUBLIC_KEY} -eq 43 ]] || die "REALITY 密钥生成失败"
}

ensure_hy2_credentials() {
  [[ -n "$HY2_PASSWORD" ]] || HY2_PASSWORD="$($SB_BIN generate rand --hex 16)"
  [[ -n "$HY2_OBFS_PASSWORD" ]] || HY2_OBFS_PASSWORD="$($SB_BIN generate rand --hex 16)"
}

ensure_vmess_credentials() {
  [[ -n "$VMESS_UUID" ]] || VMESS_UUID="$($SB_BIN generate uuid)"
}

ensure_tuic_credentials() {
  [[ -n "$TUIC_UUID" ]] || TUIC_UUID="$($SB_BIN generate uuid)"
  [[ -n "$TUIC_PASSWORD" ]] || TUIC_PASSWORD="$($SB_BIN generate rand --hex 16)"
}

ensure_tls_certificate() {
  local key_pair
  install -d -m 0755 "$SB_DIR"
  if [[ -s "$SB_CERT" && -s "$SB_CERT_KEY" && "$TLS_CERT_NAME" == "$PUBLIC_HOST" ]]; then
    CERT_FINGERPRINT="$(openssl x509 -in "$SB_CERT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
    return 0
  fi

  info "为 Hysteria2/TUIC 生成 10 年自签 TLS 证书"
  key_pair="$($SB_BIN generate tls-keypair "$PUBLIC_HOST" --months 120)"
  printf '%s\n' "$key_pair" | awk '/-----BEGIN PRIVATE KEY-----/,/-----END PRIVATE KEY-----/' >"$SB_CERT_KEY"
  printf '%s\n' "$key_pair" | awk '/-----BEGIN CERTIFICATE-----/,/-----END CERTIFICATE-----/' >"$SB_CERT"
  chmod 0600 "$SB_CERT_KEY" "$SB_CERT"
  openssl x509 -in "$SB_CERT" -noout -subject >/dev/null 2>&1 || die "TLS 证书生成失败"
  TLS_CERT_NAME="$PUBLIC_HOST"
  CERT_FINGERPRINT="$(openssl x509 -in "$SB_CERT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
}

check_port_conflicts() {
  if [[ "$VLESS_ENABLED" == "1" && "$VMESS_ENABLED" == "1" && "$VLESS_LISTEN_PORT" == "$VMESS_LISTEN_PORT" ]]; then
    die "VLESS 和 VMess 都使用 TCP，实例监听端口不能相同"
  fi
  if [[ "$HY2_ENABLED" == "1" && "$TUIC_ENABLED" == "1" && "$HY2_LISTEN_PORT" == "$TUIC_LISTEN_PORT" ]]; then
    die "Hysteria2 和 TUIC 的实例端口不能相同"
  fi
}

write_config_body() {
  local need_comma="0"
  printf '{\n  "log": { "level": "info", "timestamp": true },\n  "inbounds": [\n'

  if [[ "$VLESS_ENABLED" == "1" ]]; then
    cat <<EOF
    {
      "type": "vless",
      "tag": "vless-reality-in",
      "listen": "0.0.0.0",
      "listen_port": ${VLESS_LISTEN_PORT},
      "users": [
        { "name": "owner", "uuid": "${VLESS_UUID}", "flow": "xtls-rprx-vision" }
      ],
      "tls": {
        "enabled": true,
        "server_name": "${REALITY_SERVER_NAME}",
        "reality": {
          "enabled": true,
          "handshake": { "server": "${REALITY_SERVER_NAME}", "server_port": 443 },
          "private_key": "${REALITY_PRIVATE_KEY}",
          "short_id": ["${REALITY_SHORT_ID}"]
        }
      }
    }
EOF
    need_comma="1"
  fi

  if [[ "$VMESS_ENABLED" == "1" ]]; then
    [[ "$need_comma" == "0" ]] || printf ',\n'
    cat <<EOF
    {
      "type": "vmess",
      "tag": "vmess-in",
      "listen": "0.0.0.0",
      "listen_port": ${VMESS_LISTEN_PORT},
      "users": [
        { "name": "owner", "uuid": "${VMESS_UUID}", "alterId": 0 }
      ]
    }
EOF
    need_comma="1"
  fi

  if [[ "$HY2_ENABLED" == "1" ]]; then
    [[ "$need_comma" == "0" ]] || printf ',\n'
    cat <<EOF
    {
      "type": "hysteria2",
      "tag": "hysteria2-in",
      "listen": "0.0.0.0",
      "listen_port": ${HY2_LISTEN_PORT},
      "obfs": { "type": "salamander", "password": "${HY2_OBFS_PASSWORD}" },
      "users": [ { "name": "owner", "password": "${HY2_PASSWORD}" } ],
      "tls": {
        "enabled": true,
        "certificate_path": "${SB_CERT}",
        "key_path": "${SB_CERT_KEY}"
      }
    }
EOF
    need_comma="1"
  fi

  if [[ "$TUIC_ENABLED" == "1" ]]; then
    [[ "$need_comma" == "0" ]] || printf ',\n'
    cat <<EOF
    {
      "type": "tuic",
      "tag": "tuic-in",
      "listen": "0.0.0.0",
      "listen_port": ${TUIC_LISTEN_PORT},
      "users": [
        { "name": "owner", "uuid": "${TUIC_UUID}", "password": "${TUIC_PASSWORD}" }
      ],
      "congestion_control": "cubic",
      "zero_rtt_handshake": false,
      "heartbeat": "10s",
      "tls": {
        "enabled": true,
        "alpn": ["h3"],
        "certificate_path": "${SB_CERT}",
        "key_path": "${SB_CERT_KEY}"
      }
    }
EOF
  fi

  printf '\n  ],\n  "outbounds": [ { "type": "direct", "tag": "direct" } ]\n}\n'
}

install_service_unit() {
  if systemctl cat xray.service >/dev/null 2>&1; then
    systemctl disable --now xray.service >/dev/null 2>&1 || true
  fi
  cat >"$SB_SERVICE" <<'EOF'
[Unit]
Description=sing-box multi-protocol service
Documentation=https://sing-box.sagernet.org/
After=network-online.target nss-lookup.target
Wants=network-online.target

[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/sing-box run -c /etc/sing-box/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=infinity

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "$SB_SERVICE"
  systemctl daemon-reload
  systemctl enable sing-box.service >/dev/null
}

open_firewall_ports() {
  command -v ufw >/dev/null 2>&1 || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  [[ "$VLESS_ENABLED" == "1" ]] && ufw allow "${VLESS_LISTEN_PORT}/tcp" >/dev/null
  [[ "$VMESS_ENABLED" == "1" ]] && ufw allow "${VMESS_LISTEN_PORT}/tcp" >/dev/null
  [[ "$HY2_ENABLED" == "1" ]] && ufw allow "${HY2_LISTEN_PORT}/udp" >/dev/null
  [[ "$TUIC_ENABLED" == "1" ]] && ufw allow "${TUIC_LISTEN_PORT}/udp" >/dev/null
}

write_links() {
  local vless_link="" vmess_link="" vmess_json="" hy2_link="" tuic_link=""
  [[ -n "$CERT_FINGERPRINT" ]] || {
    if [[ -s "$SB_CERT" ]]; then
      CERT_FINGERPRINT="$(openssl x509 -in "$SB_CERT" -noout -fingerprint -sha256 | sed 's/^.*=//')"
    fi
  }
  if [[ "$VLESS_ENABLED" == "1" ]]; then
    vless_link="vless://${VLESS_UUID}@${PUBLIC_HOST}:${VLESS_PUBLIC_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PUBLIC_KEY}&sid=${REALITY_SHORT_ID}&type=tcp&headerType=none#VLESS-Reality-${VLESS_PUBLIC_PORT}"
  fi
  if [[ "$VMESS_ENABLED" == "1" ]]; then
    vmess_json="$(printf '{"v":"2","ps":"VMess-%s","add":"%s","port":"%s","id":"%s","aid":"0","scy":"auto","net":"tcp","type":"none","host":"","path":"","tls":""}' "$VMESS_PUBLIC_PORT" "$PUBLIC_HOST" "$VMESS_PUBLIC_PORT" "$VMESS_UUID")"
    vmess_link="vmess://$(printf '%s' "$vmess_json" | base64 -w 0)"
  fi
  if [[ "$HY2_ENABLED" == "1" ]]; then
    hy2_link="hysteria2://${HY2_PASSWORD}@${PUBLIC_HOST}:${HY2_PUBLIC_PORT}/?sni=${TLS_CERT_NAME}&insecure=1&pinSHA256=${CERT_FINGERPRINT}&obfs=salamander&obfs-password=${HY2_OBFS_PASSWORD}#Hysteria2-${HY2_PUBLIC_PORT}"
  fi
  if [[ "$TUIC_ENABLED" == "1" ]]; then
    tuic_link="tuic://${TUIC_UUID}:${TUIC_PASSWORD}@${PUBLIC_HOST}:${TUIC_PUBLIC_PORT}/?congestion_control=cubic&udp_relay_mode=native&alpn=h3&sni=${TLS_CERT_NAME}&allow_insecure=1#TUIC-${TUIC_PUBLIC_PORT}"
  fi

  cat >"$SB_LINK_FILE" <<EOF
sing-box ${SB_VERSION} 多协议节点
服务器：${PUBLIC_HOST}

VLESS + REALITY + Vision：
${vless_link:-未启用}

VMess AEAD + TCP：
${vmess_link:-未启用}

Hysteria2 + Salamander：
${hy2_link:-未启用}

TUIC v5：
${tuic_link:-未启用}

端口映射：
$([[ "$VLESS_ENABLED" == "1" ]] && printf 'VLESS：%s/TCP -> 实例 %s/TCP\n' "$VLESS_PUBLIC_PORT" "$VLESS_LISTEN_PORT")
$([[ "$VMESS_ENABLED" == "1" ]] && printf 'VMess：%s/TCP -> 实例 %s/TCP\n' "$VMESS_PUBLIC_PORT" "$VMESS_LISTEN_PORT")
$([[ "$HY2_ENABLED" == "1" ]] && printf 'Hysteria2：%s/UDP -> 实例 %s/UDP\n' "$HY2_PUBLIC_PORT" "$HY2_LISTEN_PORT")
$([[ "$TUIC_ENABLED" == "1" ]] && printf 'TUIC：%s/UDP -> 实例 %s/UDP\n' "$TUIC_PUBLIC_PORT" "$TUIC_LISTEN_PORT")
EOF
  chmod 0600 "$SB_LINK_FILE"
}

apply_configuration() {
  local temp_config
  check_port_conflicts
  if [[ "$VLESS_ENABLED" == "1" ]]; then ensure_reality_credentials; fi
  if [[ "$VMESS_ENABLED" == "1" ]]; then ensure_vmess_credentials; fi
  if [[ "$HY2_ENABLED" == "1" ]]; then ensure_hy2_credentials; fi
  if [[ "$TUIC_ENABLED" == "1" ]]; then ensure_tuic_credentials; fi
  if [[ "$HY2_ENABLED" == "1" || "$TUIC_ENABLED" == "1" ]]; then ensure_tls_certificate; fi

  install -d -m 0755 "$SB_DIR"
  temp_config="$(mktemp "${SB_DIR}/config.XXXXXX.json")"
  write_config_body >"$temp_config"
  chmod 0600 "$temp_config"
  info "检查完整的 sing-box 多协议配置"
  if ! "$SB_BIN" check -c "$temp_config"; then
    rm -f -- "$temp_config"
    die "配置检查失败，现有节点未被覆盖"
  fi

  CONFIG_BACKUP=""
  if [[ -f "$SB_CONFIG" ]]; then
    CONFIG_BACKUP="${SB_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a -- "$SB_CONFIG" "$CONFIG_BACKUP"
  fi
  mv -f -- "$temp_config" "$SB_CONFIG"
  install_service_unit
  open_firewall_ports

  if ! systemctl restart sing-box.service || ! systemctl is-active --quiet sing-box.service; then
    if [[ -n "$CONFIG_BACKUP" && -f "$CONFIG_BACKUP" ]]; then
      cp -a -- "$CONFIG_BACKUP" "$SB_CONFIG"
      systemctl restart sing-box.service || true
    fi
    journalctl -u sing-box.service -n 60 --no-pager || true
    die "新配置启动失败，已尝试恢复原配置"
  fi

  save_state
  write_links
  ok "多协议配置已生效"
}

prepare() {
  install_dependencies
  ensure_binary
  load_or_migrate_state
}

configure_vless() {
  local ports
  prepare
  printf '\n请先在商家后台准备一条 TCP 端口映射。\n'
  prompt_host
  ports="$(prompt_port_pair 'VLESS Reality（TCP）' "$VLESS_PUBLIC_PORT" "$VLESS_LISTEN_PORT")"
  read -r VLESS_PUBLIC_PORT VLESS_LISTEN_PORT <<<"$ports"
  REALITY_SERVER_NAME="$(prompt_value 'REALITY 伪装域名/SNI' "$REALITY_SERVER_NAME")"
  validate_host "$REALITY_SERVER_NAME" || die "SNI 域名格式错误"
  VLESS_ENABLED="1"
  apply_configuration
  cat "$SB_LINK_FILE"
}

configure_vmess() {
  local ports
  prepare
  printf '\n请先在商家后台准备一条 TCP 端口映射。\n'
  printf '请按商家后台的 TCP 映射分别填写公网端口和实例端口。\n\n'
  prompt_host
  ports="$(prompt_port_pair 'VMess（TCP）' "$VMESS_PUBLIC_PORT" "$VMESS_LISTEN_PORT")"
  read -r VMESS_PUBLIC_PORT VMESS_LISTEN_PORT <<<"$ports"
  VMESS_ENABLED="1"
  apply_configuration
  cat "$SB_LINK_FILE"
  warn "这个 VMess 节点是原生 TCP，不带 TLS；仅把链接发给可信的人。"
}

configure_hy2() {
  local ports
  prepare
  printf '\n请先在商家后台准备一条 UDP 端口映射。\n'
  prompt_host
  ports="$(prompt_port_pair 'Hysteria2（UDP）' "$HY2_PUBLIC_PORT" "$HY2_LISTEN_PORT")"
  read -r HY2_PUBLIC_PORT HY2_LISTEN_PORT <<<"$ports"
  HY2_ENABLED="1"
  apply_configuration
  cat "$SB_LINK_FILE"
}

configure_tuic() {
  local ports
  prepare
  printf '\n请先在商家后台准备一条 UDP 端口映射。\n'
  prompt_host
  ports="$(prompt_port_pair 'TUIC（UDP）' "$TUIC_PUBLIC_PORT" "$TUIC_LISTEN_PORT")"
  read -r TUIC_PUBLIC_PORT TUIC_LISTEN_PORT <<<"$ports"
  TUIC_ENABLED="1"
  apply_configuration
  cat "$SB_LINK_FILE"
}

configure_udp_pair() {
  local hy2_ports tuic_ports
  prepare
  printf '\n请先在商家后台准备两条不同的 UDP 端口映射。\n'
  printf '请按商家后台的两条 UDP 映射分别填写公网端口和实例端口。\n'
  printf 'Hysteria2 和 TUIC 必须使用两条不同的 UDP 实例端口。\n\n'
  prompt_host
  hy2_ports="$(prompt_port_pair 'Hysteria2（UDP）' "$HY2_PUBLIC_PORT" "$HY2_LISTEN_PORT")"
  read -r HY2_PUBLIC_PORT HY2_LISTEN_PORT <<<"$hy2_ports"
  tuic_ports="$(prompt_port_pair 'TUIC（UDP）' "$TUIC_PUBLIC_PORT" "$TUIC_LISTEN_PORT")"
  read -r TUIC_PUBLIC_PORT TUIC_LISTEN_PORT <<<"$tuic_ports"
  HY2_ENABLED="1"
  TUIC_ENABLED="1"
  apply_configuration
  cat "$SB_LINK_FILE"
  warn "TUIC 分享链接使用自签证书，因此带有 allow_insecure=1；只发给可信的人。"
}

regenerate_credentials() {
  local choice confirm
  prepare
  printf '\n1. VLESS Reality\n2. VMess\n3. Hysteria2\n4. TUIC\n5. 全部协议\n0. 取消\n'
  read -r -p '请选择要重新生成凭据的协议 [0-5]：' choice
  [[ "$choice" =~ ^[0-5]$ ]] || die "选项无效"
  [[ "$choice" != "0" ]] || return 0
  read -r -p '旧链接将立即失效，输入 YES 确认：' confirm
  [[ "$confirm" == "YES" ]] || { printf '已取消。\n'; return 0; }
  case "$choice" in
    1) VLESS_UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID="" ;;
    2) VMESS_UUID="" ;;
    3) HY2_PASSWORD=""; HY2_OBFS_PASSWORD="" ;;
    4) TUIC_UUID=""; TUIC_PASSWORD="" ;;
    5) VLESS_UUID=""; REALITY_PRIVATE_KEY=""; REALITY_PUBLIC_KEY=""; REALITY_SHORT_ID=""; VMESS_UUID=""; HY2_PASSWORD=""; HY2_OBFS_PASSWORD=""; TUIC_UUID=""; TUIC_PASSWORD="" ;;
  esac
  apply_configuration
  cat "$SB_LINK_FILE"
}

show_links() {
  [[ -f "$SB_LINK_FILE" ]] || die "没有找到节点信息，请先安装"
  cat "$SB_LINK_FILE"
}

show_status() {
  systemctl status sing-box.service --no-pager -l || true
}

show_logs() {
  journalctl -u sing-box.service -n 100 --no-pager || true
}

menu() {
  local choice
  while true; do
    printf '\n%b====== sing-box 中文多协议管理 v%s ======%b\n' "$cyan" "$MANAGER_VERSION" "$reset"
    printf '1. 安装或修改 VLESS Reality（TCP）\n'
    printf '2. 安装或修改 VMess（TCP）\n'
    printf '3. 安装或修改 Hysteria2（UDP）\n'
    printf '4. 安装或修改 TUIC（UDP）\n'
    printf '5. 一次安装或修改 Hysteria2 + TUIC\n'
    printf '6. 查看全部节点和分享链接\n'
    printf '7. 查看 sing-box 运行状态\n'
    printf '8. 查看最近 100 行日志\n'
    printf '9. 重新生成协议凭据\n'
    printf '0. 退出\n'
    read -r -p '请选择 [0-9]：' choice
    case "$choice" in
      1) configure_vless ;;
      2) configure_vmess ;;
      3) configure_hy2 ;;
      4) configure_tuic ;;
      5) configure_udp_pair ;;
      6) show_links ;;
      7) show_status ;;
      8) show_logs ;;
      9) regenerate_credentials ;;
      0) exit 0 ;;
      *) printf '请输入 0-9。\n' ;;
    esac
  done
}

if [[ "${1:-}" == "--install-shortcuts" ]]; then
  [[ "$EUID" -eq 0 ]] || die "请使用 root 运行"
  ensure_shortcuts
  exit 0
fi

if [[ "${0##*/}" == "sc" || "${1:-}" == "uninstall" ]]; then
  full_uninstall
fi

require_environment
ensure_shortcuts
menu
