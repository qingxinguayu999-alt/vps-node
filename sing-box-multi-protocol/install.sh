#!/usr/bin/env bash
set -Eeuo pipefail

readonly MANAGER_URL="https://raw.githubusercontent.com/qingxinguayu999-alt/vps-node/main/sing-box-multi-protocol/sing-box-node-manager.sh"
readonly MANAGER_SHA256="768b8d0d5d9a63b7b1fcbdf8146f0f76812f03fc98d969fb9f3cc41bd23decd8"
readonly MANAGER_PATH="/usr/local/sbin/sing-box-node"
readonly SHORTCUT_PATH="/usr/local/bin/jiaoben"

[[ "$EUID" -eq 0 ]] || { printf '错误：请使用 root 运行。\n' >&2; exit 1; }
[[ "$(uname -m)" == "x86_64" ]] || { printf '错误：目前仅支持 Linux amd64。\n' >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { printf '错误：系统没有 curl。\n' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { printf '错误：系统没有 sha256sum。\n' >&2; exit 1; }

temporary_file="$(mktemp /tmp/sing-box-node-manager.XXXXXX)"
trap 'rm -f -- "$temporary_file"' EXIT

printf '下载 sing-box 中文多协议管理脚本……\n'
curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 "$MANAGER_URL" -o "$temporary_file"
printf '%s  %s\n' "$MANAGER_SHA256" "$temporary_file" | sha256sum -c - >/dev/null

install -d -m 0755 /usr/local/sbin /usr/local/bin
install -m 0755 "$temporary_file" "$MANAGER_PATH"
ln -sfn "$MANAGER_PATH" "$SHORTCUT_PATH"

printf '\n安装完成。输入下面的命令打开中文菜单：\n\n  jiaoben\n\n'
