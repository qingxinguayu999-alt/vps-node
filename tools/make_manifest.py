#!/usr/bin/env python3
"""每次修改 vps-node.sh 后运行，生成用于安装和更新的版本清单。"""
import hashlib
import json
import pathlib
import re

root = pathlib.Path(__file__).resolve().parent.parent
data = (root / 'vps-node.sh').read_bytes()
version = re.search(r"^VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'$", data.decode(), re.M).group(1)
source = re.search(r"^DEFAULT_UPDATE_SOURCE = '([^']+)'$", data.decode(), re.M).group(1)
digest = hashlib.sha256(data).hexdigest()
manifest = dict(version=version, script_url=source.rsplit('/', 1)[0] + '/vps-node.sh', sha256=digest)
(root / 'update.json').write_text(json.dumps(manifest, indent=2) + '\n')
(root / 'SHA256SUMS').write_text(digest + '  vps-node.sh\n')
print('Generated update.json and SHA256SUMS for ' + version)
