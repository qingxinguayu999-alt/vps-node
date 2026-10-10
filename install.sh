#!/usr/bin/env bash
set -euo pipefail
if [ "$(id -u)" -ne 0 ]; then
  echo '请使用 sudo bash install.sh'
  exit 1
fi
. /etc/os-release
case "$ID" in debian|ubuntu) ;; *) echo '仅支持 Debian / Ubuntu'; exit 1;; esac
[ -d /run/systemd/system ] || { echo '需要 systemd 环境'; exit 1; }
apt-get update
apt-get install -y ca-certificates curl python3
base_url='https://raw.githubusercontent.com/qingxinguayu999-alt/vps-node/main'
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
curl --proto '=https' --proto-redir '=https' -fSL --retry 3 "$base_url/vps-node.sh" -o "$work_dir/vps-node.sh"
curl --proto '=https' --proto-redir '=https' -fSL --retry 3 "$base_url/update.json" -o "$work_dir/update.json"
python3 - "$work_dir" <<'PY'
import hashlib,json,pathlib,re,sys
p=pathlib.Path(sys.argv[1]); manifest=json.loads((p/'update.json').read_text())
data=(p/'vps-node.sh').read_bytes()
if hashlib.sha256(data).hexdigest()!=manifest.get('sha256'):
    sys.exit('下载脚本的 SHA256 与更新清单不一致，请稍后重试')
match=re.search(r"^VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'$",data.decode(),re.M)
if not match or match.group(1)!=manifest.get('version'): sys.exit('下载版本不一致')
PY
bash -n "$work_dir/vps-node.sh"
bash "$work_dir/vps-node.sh" --self-test
bash "$work_dir/vps-node.sh" --install
echo '安装完成：jb 打开菜单；k 查看节点；sc 卸载。普通用户请加 sudo。'
if [ -t 0 ] && [ -t 1 ]; then
  /usr/local/bin/vps-node jb
fi
