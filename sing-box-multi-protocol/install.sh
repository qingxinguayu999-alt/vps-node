#!/bin/sh
set -eu

readonly MANAGER_URL="https://raw.githubusercontent.com/qingxinguayu999-alt/vps-node/main/sing-box-multi-protocol/sing-box-node-manager.sh"
readonly MANAGER_SHA256="39e928445946f5a7241a13478daa59b62c6d5236f4aa01996eae1c7ddacfba80"
readonly MANAGER_PATH="/usr/local/sbin/sing-box-node"
readonly UNINSTALL_SHORTCUT_PATH="/usr/local/bin/sc"

[ "$(id -u)" -eq 0 ] || { printf '错误：请使用 root 运行。\n' >&2; exit 1; }
[ "$(uname -m)" = "x86_64" ] || { printf '错误：目前仅支持 Linux amd64。\n' >&2; exit 1; }
if ! command -v bash >/dev/null 2>&1 || ! command -v install >/dev/null 2>&1; then
  if command -v apk >/dev/null 2>&1; then
    apk add --no-cache bash coreutils ca-certificates curl
  elif command -v apt-get >/dev/null 2>&1; then
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y bash coreutils ca-certificates curl
  else
    printf '错误：需要 bash 和 install，且未找到 apk 或 apt-get。\n' >&2
    exit 1
  fi
fi
command -v curl >/dev/null 2>&1 || { printf '错误：系统没有 curl。\n' >&2; exit 1; }
command -v sha256sum >/dev/null 2>&1 || { printf '错误：系统没有 sha256sum。\n' >&2; exit 1; }

temporary_file="$(mktemp /tmp/sing-box-node-manager.XXXXXX)"
trap 'rm -f -- "$temporary_file"' EXIT

printf '下载 sing-box 中文多协议管理脚本……\n'
curl -fL --retry 5 --retry-delay 3 --connect-timeout 20 "$MANAGER_URL" -o "$temporary_file"
printf '%s  %s\n' "$MANAGER_SHA256" "$temporary_file" | sha256sum -c - >/dev/null
bash -n "$temporary_file"
bash "$temporary_file" --check-environment

install -d -m 0755 /usr/local/sbin /usr/local/bin
install -m 0755 "$temporary_file" "$MANAGER_PATH"
"$MANAGER_PATH" --install-shortcuts

printf '\n管理脚本已安装；请打开菜单配置节点：\n\n  jiaoben\n\n'
if [ -L "$UNINSTALL_SHORTCUT_PATH" ] && [ "$(readlink -f "$UNINSTALL_SHORTCUT_PATH")" = "$MANAGER_PATH" ]; then
  printf '彻底卸载请输入：sc（需要再次输入 DELETE 确认）\n\n'
else
  printf '系统的 sc 命令已被占用；彻底卸载请运行：sing-box-node uninstall\n\n'
fi

