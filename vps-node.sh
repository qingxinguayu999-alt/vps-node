#!/usr/bin/env bash
set -euo pipefail
if ! command -v python3 >/dev/null; then
  [ "$(id -u)" -eq 0 ] || { echo '请使用 sudo bash vps-node.sh'; exit 1; }
  apt-get update
  apt-get install -y python3
fi
export VPS_NODE_SCRIPT="$(realpath "$0")"
exec python3 - "$@" <<'PY'
import base64, copy, fcntl, getpass, ipaddress, json, os, pathlib, re
import secrets, shutil, socket, subprocess, sys, tempfile, time, uuid, hashlib
from urllib.request import urlopen
from urllib.parse import quote, urlencode

ROOT = pathlib.Path('/etc/vps-node')
VERSION = '1.3.0'
DEFAULT_UPDATE_SOURCE = 'https://raw.githubusercontent.com/qingxinguayu999-alt/vps-node/main/update.json'
SERVICE = 'vps-node'
PROTOCOLS = ['vless', 'vmess', 'tuic', 'hysteria2', 'trojan', 'shadowsocks']

def run(*args, capture=False, check=True):
    return subprocess.run(args, check=check, text=True,
                          stdout=subprocess.PIPE if capture else None,
                          stderr=subprocess.PIPE if capture else None)

def write(path, data, mode=0o600):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent)
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, 'w') as f:
            f.write(data)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)

def ask(text, default=''):
    with open('/dev/tty', 'r+') as tty:
        tty.write(text + (f' [{default}]' if default else '') + ': ')
        tty.flush()
        value = tty.readline()
        if not value: raise EOFError('终端输入结束')
        return value.strip() or default

def host(value):
    value = value.strip().strip('[]')
    try: ipaddress.ip_address(value); return value
    except ValueError: pass
    value = value.encode('idna').decode()
    if len(value) > 253 or not all(re.fullmatch(r'[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?', p) for p in value.split('.')):
        raise ValueError('域名/IP 格式不正确，请勿输入 https:// 或路径')
    return value.lower()

def load():
    return json.loads((ROOT/'nodes.json').read_text()) if (ROOT/'nodes.json').exists() else []

def config(nodes):
    ins = []
    for n in nodes:
        p = n['protocol']
        item = dict(type=p, tag=n['id'], listen=listen_addr(n), listen_port=n['port'])
        if p in ('vless', 'vmess'): item['users'] = [{'uuid': n['uuid']}]
        elif p == 'tuic':
            item.update(users=[{'uuid': n['uuid'], 'password': n['password']}], congestion_control='bbr', zero_rtt_handshake=False)
        elif p in ('hysteria2', 'trojan'): item['users'] = [{'password': n['password']}]
        else: item.update(method='aes-128-gcm', password=n['password'])
        if p in ('vless', 'vmess'): item['transport'] = {'type': 'ws', 'path': n['path']}
        if p != 'shadowsocks' and not n['argo']:
            item['tls'] = dict(enabled=True, certificate_path=n['cert'], key_path=n['key'])
            if p in ('tuic', 'hysteria2'): item['tls']['alpn'] = ['h3']
        ins.append(item)
    return {'log': {'level': 'info', 'timestamp': True}, 'inbounds': ins, 'outbounds': [{'type': 'direct', 'tag': 'direct'}]}

def links(nodes):
    out = []
    for n in nodes:
        p = n['protocol']; h = n['host']; authority = f'[{h}]' if ':' in h else h
        port = 443 if n['argo'] else n['port']; label = quote(n['name'], safe='')
        q = {'sni': h}
        if p in ('vless', 'vmess'):
            q.update(security='tls', type='ws', host=h, path=n['path'])
        if p == 'vless':
            q['encryption'] = 'none'
            link = f'vless://{n["uuid"]}@{authority}:{port}?{urlencode(q)}#{label}'
        elif p == 'vmess':
            v = dict(v='2', ps=n['name'], add=h, port=str(port), id=n['uuid'], aid='0', scy='auto', net='ws', type='none', host=h, path=n['path'], tls='tls', sni=h)
            link = 'vmess://' + base64.b64encode(json.dumps(v, ensure_ascii=False).encode()).decode()
        elif p == 'tuic':
            q.update(congestion_control='bbr', udp_relay_mode='native', alpn='h3')
            link = f'tuic://{n["uuid"]}:{quote(n["password"],safe="")}@{authority}:{port}?{urlencode(q)}#{label}'
        elif p in ('hysteria2', 'trojan'):
            if p == 'hysteria2':
                q['alpn'] = 'h3'
                if n.get('cert_mode') == 'selfsigned':
                    q['insecure'] = '1'
                    q['pinSHA256'] = n['cert_pin']
            link = f'{p}://{quote(n["password"],safe="")}@{authority}:{port}?{urlencode(q)}#{label}'
        else:
            auth = base64.urlsafe_b64encode(('aes-128-gcm:' + n['password']).encode()).decode().rstrip('=')
            link = f'ss://{auth}@{authority}:{port}#{label}'
        out.append((n['id'], link))
    return out

def apply(nodes):
    cfg = ROOT/'config.json'
    candidate = ROOT/'candidate.json'
    write(candidate, json.dumps(config(nodes), indent=2))
    run('sing-box', 'check', '-c', str(candidate))
    old_cfg = cfg.read_text() if cfg.exists() else None
    old_nodes = (ROOT/'nodes.json').read_text() if (ROOT/'nodes.json').exists() else None
    if old_cfg: write(ROOT/'config.previous.json', old_cfg)
    if old_nodes: write(ROOT/'nodes.previous.json', old_nodes)
    try:
        os.replace(candidate, cfg)
        run('systemctl', 'restart', SERVICE)
        time.sleep(2)
        run('systemctl', 'is-active', '--quiet', SERVICE)
        write(ROOT/'nodes.json', json.dumps(nodes, ensure_ascii=False, indent=2))
    except Exception:
        if old_cfg:
            write(cfg, old_cfg)
            run('systemctl', 'restart', SERVICE, check=False)
        else:
            run('systemctl', 'stop', SERVICE, check=False)
            cfg.unlink(missing_ok=True)
        if old_nodes: write(ROOT/'nodes.json', old_nodes)
        raise RuntimeError('配置启动失败，已恢复原配置；用菜单查看日志')
    export(nodes)

def export(nodes):
    rows = links(nodes)
    write(ROOT/'links.txt', '\n'.join(x[1] for x in rows) + '\n')
    qr = ROOT/'qr'; qr.mkdir(exist_ok=True, mode=0o700)
    for f in qr.glob('*.png'): f.unlink()
    if shutil.which('qrencode'):
        for tag, link in rows:
            run('qrencode', '-o', str(qr/(tag+'.png')), '-s', '6', link)
            os.chmod(qr/(tag+'.png'), 0o600)

def install():
    run('apt-get', 'update')
    run('apt-get', 'install', '-y', 'curl', 'ca-certificates', 'openssl', 'qrencode', 'certbot', 'iproute2', 'kmod')
    if not shutil.which('sing-box'):
        pathlib.Path('/etc/apt/keyrings').mkdir(exist_ok=True)
        run('curl', '-fSL', '--retry', '3', 'https://sing-box.app/gpg.key', '-o', '/etc/apt/keyrings/sagernet.asc')
        os.chmod('/etc/apt/keyrings/sagernet.asc', 0o644)
        write('/etc/apt/sources.list.d/sagernet.sources', 'Types: deb\nURIs: https://deb.sagernet.org/\nSuites: *\nComponents: *\nEnabled: yes\nSigned-By: /etc/apt/keyrings/sagernet.asc\n', 0o644)
        run('apt-get', 'update')
        run('apt-get', 'install', '-y', 'sing-box')
    binary = shutil.which('sing-box')
    write('/etc/systemd/system/vps-node.service', f'''[Unit]
Description=VPS Node Manager (sing-box)
After=network-online.target
Wants=network-online.target
[Service]
ExecStart={binary} run -c /etc/vps-node/config.json
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
ReadWritePaths=/etc/vps-node
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
''', 0o644)
    write('/etc/letsencrypt/renewal-hooks/deploy/vps-node-restart', '#!/bin/sh\nif systemctl is-active --quiet vps-node; then systemctl restart vps-node; fi\n', 0o755)
    run('systemctl', 'daemon-reload')
    run('systemctl', 'enable', SERVICE)
    source = os.environ.get('VPS_NODE_SCRIPT', '')
    if source and pathlib.Path(source).is_file():
        write('/usr/local/bin/vps-node', pathlib.Path(source).read_text(), 0o755)
    for shortcut in ('jb', 'k', 'sc'):
        path = pathlib.Path('/usr/local/bin')/shortcut
        wrapper = '#!/bin/sh\n# vps-node shortcut\nexec /usr/local/bin/vps-node '+shortcut+' "$@"\n'
        if path.exists() and 'vps-node shortcut' not in path.read_text(errors='replace'):
            print(f'{shortcut} 已被其他程序占用；请使用 sudo vps-node {shortcut}')
        else: write(path, wrapper, 0o755)
    if not (ROOT/'update-source.txt').exists(): write(ROOT/'update-source.txt',DEFAULT_UPDATE_SOURCE+'\n')
    print('安装完成。后续运行 sudo vps-node；添加首个节点后启动服务。')

def certificate(h):
    choice = ask('证书：1 Let’s Encrypt HTTP-01  2 导入现有 PEM', '1')
    if choice == '1':
        try: ipaddress.ip_address(h)
        except ValueError: pass
        else: raise ValueError('此脚本的自动证书申请请使用域名')
        print('域名 A/AAAA 必须正确指向本机；80/TCP 必须可达且空闲。直连域名应关闭 CDN 代理。')
        email = ask('ACME 邮箱')
        if not re.fullmatch(r'[^\s@]+@[^\s@]+\.[^\s@]+', email): raise ValueError('邮箱格式不正确')
        if ask('同意 Let’s Encrypt 服务条款？输入 YES') != 'YES': raise ValueError('未同意服务条款')
        run('certbot', 'certonly', '--standalone', '--non-interactive', '--agree-tos', '-m', email, '-d', h, '--cert-name', h)
        run('systemctl', 'enable', '--now', 'certbot.timer')
        cert = f'/etc/letsencrypt/live/{h}/fullchain.pem'; key = f'/etc/letsencrypt/live/{h}/privkey.pem'
    elif choice == '2':
        cert = str(pathlib.Path(ask('fullchain.pem 绝对路径')).resolve())
        key = str(pathlib.Path(ask('privkey.pem 绝对路径')).resolve())
        if not pathlib.Path(cert).is_file() or not pathlib.Path(key).is_file(): raise ValueError('证书或私钥不存在')
    else: raise ValueError('无效选择')
    run('openssl', 'x509', '-in', cert, '-noout', '-checkend', '86400')
    try: ipaddress.ip_address(h); check_flag = '-checkip'
    except ValueError: check_flag = '-checkhost'
    match = run('openssl', 'x509', '-in', cert, '-noout', check_flag, h, capture=True).stdout
    if 'does match certificate' not in match: raise ValueError('证书不覆盖节点域名/IP')
    pub_cert = run('openssl', 'x509', '-in', cert, '-pubkey', '-noout', capture=True).stdout
    pub_key = run('openssl', 'pkey', '-in', key, '-pubout', capture=True).stdout
    if pub_cert.strip() != pub_key.strip(): raise ValueError('证书和私钥不匹配')
    # 导入证书复制进专用目录，避免 systemd 的 ProtectHome 阻断读取。
    if choice == '2':
        dst = ROOT/'certs'/secrets.token_hex(8); dst.mkdir(parents=True, mode=0o700)
        write(dst/'fullchain.pem', pathlib.Path(cert).read_text())
        write(dst/'privkey.pem', pathlib.Path(key).read_text())
        cert, key = str(dst/'fullchain.pem'), str(dst/'privkey.pem')
    return cert, key

def public_ip(ip_version):
    url = 'https://api6.ipify.org' if ip_version == '6' else 'https://api.ipify.org'
    try:
        result = run('curl', '-'+ip_version, '-fsS', '--connect-timeout', '5', '--max-time', '8', url, capture=True)
        address = ipaddress.ip_address(result.stdout.strip())
        if str(address.version) == ip_version and address.is_global: return str(address)
    except (ValueError,OSError,subprocess.CalledProcessError): pass
    return ''

def cert_fingerprint(cert):
    pem = pathlib.Path(cert).read_text()
    return hashlib.sha256(__import__('ssl').PEM_cert_to_DER_cert(pem)).hexdigest()

def selfsigned_certificate(address):
    ip = ipaddress.ip_address(address)
    directory = ROOT/'certs'/secrets.token_hex(8)
    directory.mkdir(parents=True, mode=0o700)
    cert, key = directory/'fullchain.pem', directory/'privkey.pem'
    try:
        run('openssl','req','-x509','-newkey','rsa:2048','-sha256','-nodes','-days','3650',
            '-keyout',str(key),'-out',str(cert),'-subj','/CN=vps-node-hy2',
            '-addext','subjectAltName=IP:'+str(ip),capture=True)
        os.chmod(cert,0o600); os.chmod(key,0o600)
        return str(cert),str(key),cert_fingerprint(cert)
    except Exception:
        shutil.rmtree(directory)
        raise

def hy2_settings(ip_version, previous=None):
    old = previous or {}
    default = '1' if not previous or old.get('cert_mode') == 'selfsigned' else '2'
    mode = ask('HY2 模式：1 无域名 + 自动自签证书 / 2 自定义域名及证书',default)
    if mode == '1':
        default_ip = old.get('host','') if old.get('cert_mode') == 'selfsigned' else ''
        try:
            if str(ipaddress.ip_address(default_ip).version) != ip_version: default_ip = ''
        except ValueError: default_ip = ''
        if not default_ip: default_ip = public_ip(ip_version)
        address = ipaddress.ip_address(ask('VPS 公网 IP（自动识别成功可直接回车）',default_ip))
        if str(address.version) != ip_version or not address.is_global:
            raise ValueError('请填写所选地址族的可用公网 IP；NAT VPS 需自行设置 UDP 端口映射')
        address = str(address)
        reusable = old.get('cert_mode') == 'selfsigned' and old.get('host') == address and pathlib.Path(old.get('cert','')).is_file() and pathlib.Path(old.get('key','')).is_file()
        if reusable:
            reusable = run('openssl','x509','-in',old['cert'],'-noout','-checkend','86400',capture=True,check=False).returncode == 0
        if reusable: cert,key,pin = old['cert'],old['key'],cert_fingerprint(old['cert'])
        else: cert,key,pin = selfsigned_certificate(address)
        print('自签模式：分享链接使用 insecure=1 并附 pinSHA256 固定证书指纹；请确认客户端支持并保留指纹。')
        return dict(host=address,cert_mode='selfsigned',cert=cert,key=key,cert_pin=pin)
    if mode == '2':
        default_host = old.get('host','') if old.get('cert_mode') != 'selfsigned' else ''
        h = host(ask('HY2 节点域名',default_host))
        try: ipaddress.ip_address(h)
        except ValueError: pass
        else: raise ValueError('自定义域名模式请填写域名；公网 IP 请选自签模式')
        if old.get('cert_mode') != 'selfsigned' and old.get('host') == h and old.get('cert') and ask('保留现有证书？y/n','y').lower() == 'y':
            cert,key = old['cert'],old['key']
        else: cert,key = certificate(h)
        return dict(host=h,cert_mode='custom',cert=cert,key=key)
    raise ValueError('请输入 1 或 2')

def choose(nodes):
    if not nodes: raise ValueError('暂无节点')
    for i, n in enumerate(nodes, 1): print(f'{i}. {n["name"]}  {n["protocol"]}  {n["host"]}:{n["port"]}  IPv{n.get("ip_version","4")}  Argo={n["argo"]}')
    index = int(ask('选择节点编号')) - 1
    if not 0 <= index < len(nodes): raise ValueError('编号超出范围')
    return index

def listen_addr(n):
    return ('::1' if n.get('ip_version', '4') == '6' else '127.0.0.1') if n['argo'] else ('::' if n.get('ip_version', '4') == '6' else '0.0.0.0')

def ip_choice(default='4'):
    value = ask('监听地址：4 IPv4 / 6 IPv6', default)
    if value not in ('4', '6'): raise ValueError('请输入 4 或 6')
    return value

def origin(n):
    address = '[::1]' if n.get('ip_version','4') == '6' else '127.0.0.1'
    return f'http://{address}:{n["port"]}'

def port_free(port, udp, loopback, ip_version='4'):
    ipv6 = ip_version == '6'
    with socket.socket(socket.AF_INET6 if ipv6 else socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as s:
        if ipv6: s.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        s.bind((('::1' if loopback else '::') if ipv6 else ('127.0.0.1' if loopback else '0.0.0.0'), port))

def add():
    if not shutil.which('sing-box') or not pathlib.Path('/etc/systemd/system/vps-node.service').exists(): raise ValueError('请先选择安装核心')
    nodes = load()
    for i, p in enumerate(PROTOCOLS, 1): print(f'{i}. {p}')
    i = int(ask('选择协议')) - 1
    if not 0 <= i < len(PROTOCOLS): raise ValueError('无效协议')
    p = PROTOCOLS[i]
    argo = p in ('vless', 'vmess') and ask('通过 Argo 固定隧道？y/n', 'y' if p == 'vmess' else 'n').lower() == 'y'
    ip_version = ip_choice()
    hy2 = hy2_settings(ip_version) if p == 'hysteria2' else {}
    h = hy2['host'] if hy2 else host(ask('节点域名（SS 可填 IP；Argo 填隧道公开域名）'))
    port = int(ask('本机监听端口', str(18080 + len(nodes)) if argo else str(20000 + len(nodes))))
    if not 1 <= port <= 65535: raise ValueError('端口必须是 1–65535')
    if any(n['port'] == port for n in nodes): raise ValueError('脚本中的节点已占用此端口')
    port_free(port, p in ('tuic', 'hysteria2'), argo, ip_version)
    if p == 'shadowsocks': port_free(port, True, False, ip_version)
    n = dict(id=uuid.uuid4().hex, name=ask('节点名称', p), protocol=p, host=h, port=port, uuid=str(uuid.uuid4()), password=secrets.token_urlsafe(24), path='/'+secrets.token_hex(12), argo=argo, ip_version=ip_version)
    n.update(hy2)
    if p not in ('shadowsocks','hysteria2') and not argo: n['cert'], n['key'] = certificate(h)
    apply(nodes + [n])
    print('节点已添加。请在云安全组/本机防火墙放行：', f'{port}/'+('UDP' if p in ('tuic','hysteria2') else 'TCP+UDP' if p == 'shadowsocks' else 'TCP'))
    if argo: print(f'Cloudflare 隧道 Public hostname 设置 {h} → HTTP 服务 {origin(n)}；再用菜单安装隧道。路径：{n["path"]}')
    print(links([n])[0][1])

def edit():
    nodes = load(); i = choose(nodes); n = copy.deepcopy(nodes[i])
    n['name'] = ask('节点名称', n['name'])
    n['ip_version'] = ip_choice(n.get('ip_version','4'))
    if n['protocol'] == 'hysteria2':
        n.update(hy2_settings(n['ip_version'],nodes[i]))
        if n.get('cert_mode') != 'selfsigned': n.pop('cert_pin',None)
    else: n['host'] = host(ask('节点域名/IP', n['host']))
    if n['protocol'] in ('vless','vmess'):
        n['argo'] = ask('通过 Argo 固定隧道？y/n','y' if n['argo'] else 'n').lower() == 'y'
    if n['protocol'] not in ('shadowsocks','hysteria2') and not n['argo']: n['cert'], n['key'] = certificate(n['host'])
    port = int(ask('监听端口', str(n['port'])))
    if not 1 <= port <= 65535 or any(j != i and x['port'] == port for j,x in enumerate(nodes)): raise ValueError('端口无效或重复')
    # 同端口换监听地址时旧服务仍占用端口，交由重启检查与回滚处理。
    if port != n['port']:
        port_free(port, n['protocol'] in ('tuic','hysteria2'), n['argo'], n['ip_version'])
        if n['protocol'] == 'shadowsocks': port_free(port, True, False, n['ip_version'])
    n['port'] = port
    if n['protocol'] in ('vless','vmess'):
        n['path'] = ask('WebSocket 路径', n['path'])
        if not n['path'].startswith('/'): raise ValueError('路径必须以 / 开始')
    if ask('重新生成 UUID/密码？y/n', 'n') == 'y':
        n.update(uuid=str(uuid.uuid4()), password=secrets.token_urlsafe(24))
    nodes[i] = n; apply(nodes)
    print('修改完成。请更新客户端链接、放行新端口；Argo 节点还需同步 Cloudflare 服务端口。')
    if n['argo']: print('Cloudflare HTTP 服务地址：'+origin(n))

def bbr():
    run('modprobe', 'tcp_bbr', check=False)
    available = run('sysctl', '-n', 'net.ipv4.tcp_available_congestion_control', capture=True).stdout.split()
    if 'bbr' not in available: raise ValueError('当前内核/容器不支持 BBR；请更换支持的内核，此脚本不自动重装内核')
    old_cc = run('sysctl','-n','net.ipv4.tcp_congestion_control',capture=True).stdout.strip()
    old_q = run('sysctl','-n','net.core.default_qdisc',capture=True).stdout.strip()
    path = pathlib.Path('/etc/sysctl.d/99-vps-node-bbr.conf')
    old_file = path.read_text() if path.exists() else None
    try:
        run('sysctl', '-w', 'net.core.default_qdisc=fq', 'net.ipv4.tcp_congestion_control=bbr')
        write(path, 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n', 0o644)
    except Exception:
        run('sysctl','-w',f'net.core.default_qdisc={old_q}',f'net.ipv4.tcp_congestion_control={old_cc}',check=False)
        if old_file is not None: write(path,old_file,0o644)
        else: path.unlink(missing_ok=True)
        raise
    print('已开启系统 TCP BBR；不等同于 UDP/QUIC 加速。已有网卡队列可能需要重启服务器才能采用 fq。')

def tunnel():
    if not shutil.which('cloudflared'):
        arch = run('dpkg','--print-architecture',capture=True).stdout.strip()
        if arch not in ('amd64','arm64','armhf','i386'): raise ValueError('不支持此 cloudflared 架构')
        with tempfile.TemporaryDirectory() as d:
            deb = str(pathlib.Path(d)/'cloudflared.deb')
            run('curl','-fSL','--retry','3',f'https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-{arch}.deb','-o',deb)
            run('apt-get','install','-y',deb)
    token = getpass.getpass('固定隧道 Token（隐藏输入）: ')
    if not re.fullmatch(r'[A-Za-z0-9_+/=-]+',token): raise ValueError('Token 格式不正确')
    write(ROOT/'tunnel.env', 'TUNNEL_TOKEN='+token+'\n')
    binary = shutil.which('cloudflared')
    write('/etc/systemd/system/vps-node-argo.service',f'''[Unit]
Description=VPS Node Cloudflare Tunnel
After=network-online.target vps-node.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/vps-node/tunnel.env
ExecStart={binary} tunnel --no-autoupdate run
Restart=on-failure
RestartSec=5
UMask=0077
NoNewPrivileges=true
[Install]
WantedBy=multi-user.target
''',0o644)
    run('systemctl','daemon-reload')
    run('systemctl','enable','vps-node-argo')
    run('systemctl','restart','vps-node-argo')
    time.sleep(2)
    run('systemctl','is-active','--quiet','vps-node-argo')
    print('隧道进程已启动。请用日志确认与 Cloudflare 建立连接；本脚本不代替控制台创建隧道/DNS 路由。')

def show():
    nodes = load(); export(nodes)
    for tag, link in links(nodes):
        print('\n'+link)
        if shutil.which('qrencode'): run('qrencode','-t','ANSIUTF8',link)
    print('导出位置：/etc/vps-node/links.txt 与 /etc/vps-node/qr/*.png；包含节点凭据，请妥善保管。')

def remove():
    nodes = load(); i = choose(nodes)
    if ask('输入 DELETE 确认删除此节点') == 'DELETE': nodes.pop(i); apply(nodes)

def fetch_https(url, limit):
    if not isinstance(url,str) or not url.startswith('https://'): raise ValueError('更新地址必须使用 HTTPS')
    with urlopen(url, timeout=30) as response:
        if not response.geturl().startswith('https://'): raise ValueError('更新地址重定向到了非 HTTPS')
        data = response.read(limit+1)
    if len(data)>limit: raise ValueError('更新文件超出大小限制')
    return data

def version_tuple(value):
    if not isinstance(value,str) or not re.fullmatch(r'\d+\.\d+\.\d+',value): raise ValueError('版本号需要 x.y.z 格式')
    return tuple(map(int,value.split('.')))

def update_source():
    url = ask('可信更新清单 HTTPS URL（输入 clear 清除）')
    if url == 'clear':
        (ROOT/'update-source.txt').unlink(missing_ok=True); return
    manifest = json.loads(fetch_https(url, 65536))
    validate_manifest(manifest)
    write(ROOT/'update-source.txt',url+'\n')
    print('已设置更新来源；只使用你信任且控制的发布地址。')

def validate_manifest(m):
    if not isinstance(m,dict): raise ValueError('更新清单必须是 JSON 对象')
    version_tuple(m.get('version'))
    if not isinstance(m.get('sha256'),str) or not re.fullmatch(r'[0-9a-fA-F]{64}',m['sha256']): raise ValueError('缺少有效 SHA256')
    if not isinstance(m.get('script_url'),str) or not m['script_url'].startswith('https://'): raise ValueError('缺少 HTTPS script_url')

def install_script(data, expected_hash=None, expected_version=None):
    if expected_hash and hashlib.sha256(data).hexdigest().lower()!=expected_hash.lower(): raise ValueError('更新脚本 SHA256 不一致')
    text = data.decode('utf-8')
    found = re.search(r"^VERSION = '([0-9]+\.[0-9]+\.[0-9]+)'$",text,re.M)
    if not found: raise ValueError('不是带版本号的 vps-node 脚本')
    new_version=found.group(1)
    if expected_version and new_version!=expected_version: raise ValueError('脚本版本与清单不一致')
    if version_tuple(new_version)<=version_tuple(VERSION): raise ValueError('此脚本版本不高于当前版本')
    # 不执行下载文件的自测；先检查 Bash 和嵌入 Python 的语法。
    if "<<'PY'\n" not in text or not text.endswith('PY\n'): raise ValueError('脚本结构不正确')
    code=text.split("<<'PY'\n",1)[1].rsplit('\nPY',1)[0]
    compile(code,'update.py','exec')
    with tempfile.TemporaryDirectory() as d:
        candidate=pathlib.Path(d)/'update.sh'; candidate.write_text(text)
        run('bash','-n',str(candidate))
    target=pathlib.Path('/usr/local/bin/vps-node')
    if ask(f'更新脚本 {VERSION} → {new_version}？输入 UPDATE')!='UPDATE': return
    if target.exists(): write(ROOT/'vps-node.previous.sh',target.read_text(),0o700)
    write(target,text,0o755)
    print('脚本已更新；请退出后重新运行 sudo vps-node。原上传文件不会被替换。')

def check_updates():
    print('管理脚本版本：'+VERSION)
    if shutil.which('sing-box'):
        run('sing-box','version')
        run('apt-get','update')
        run('apt-cache','policy','sing-box')
        print('上方 Installed / Candidate 可比较核心版本；核心升级需自行执行 sudo apt-get install --only-upgrade sing-box，再检查配置并重启。')
    if shutil.which('cloudflared'):
        run('cloudflared','--version')
        try:
            release=json.loads(fetch_https('https://api.github.com/repos/cloudflare/cloudflared/releases/latest',262144))
            print('cloudflared 官方最新发布：'+str(release.get('tag_name','未知')))
        except (ValueError,OSError) as e: print('cloudflared 最新版本查询失败：'+str(e))
    source=ROOT/'update-source.txt'
    if not source.exists():
        print('尚未设置脚本更新源。本脚本没有公开发布地址；可用菜单 13 配置可信 JSON 更新清单，或菜单 14 从本地新版文件更新。')
        return
    manifest=json.loads(fetch_https(source.read_text().strip(),65536)); validate_manifest(manifest)
    print('更新源脚本版本：'+manifest['version'])
    if version_tuple(manifest['version'])>version_tuple(VERSION):
        install_script(fetch_https(manifest['script_url'],2*1024*1024),manifest['sha256'],manifest['version'])
    else: print('更新源没有更高版本。')

def local_update():
    path=pathlib.Path(ask('本地新版 vps-node.sh 绝对路径'))
    if not path.is_absolute() or not path.is_file(): raise ValueError('请填写存在的绝对文件路径')
    if path.stat().st_size>2*1024*1024: raise ValueError('脚本过大')
    install_script(path.read_bytes())

def uninstall():
    print('sc 将停止并删除本工具的节点/隧道服务、快捷命令与 /etc/vps-node 配置及凭据。保留系统 BBR、软件包、ACME 证书和 Cloudflare 控制台隧道。')
    if ask('输入 UNINSTALL 确认')!='UNINSTALL': return False
    for svc in ('vps-node','vps-node-argo'):
        run('systemctl','disable','--now',svc,check=False)
        pathlib.Path('/etc/systemd/system/'+svc+'.service').unlink(missing_ok=True)
    pathlib.Path('/etc/letsencrypt/renewal-hooks/deploy/vps-node-restart').unlink(missing_ok=True)
    for shortcut in ('jb','k','sc'):
        path=pathlib.Path('/usr/local/bin')/shortcut
        if path.is_file() and 'vps-node shortcut' in path.read_text(errors='replace'): path.unlink()
    pathlib.Path('/usr/local/bin/vps-node').unlink(missing_ok=True)
    run('systemctl','daemon-reload')
    shutil.rmtree(ROOT)
    print('卸载完成。最初上传的 vps-node.sh 文件请自行删除。')
    return True

def colored(text, color):
    return f'\033[{color}m{text}\033[0m' if sys.stdout.isatty() and 'NO_COLOR' not in os.environ else text

def service_state(name):
    result=run('systemctl','is-active',name,capture=True,check=False)
    value=result.stdout.strip() or '未安装'
    return colored(value,'32' if value=='active' else '33')

def menu():
    nodes=load()
    print('\n'+colored('  VPS 多协议节点管理  v'+VERSION,'1;36'))
    print(colored('  Debian / Ubuntu · sing-box · Cloudflare Tunnel','36'))
    print('  节点服务：'+service_state(SERVICE)+'    Argo：'+service_state('vps-node-argo'))
    print(f'  节点数量：{len(nodes)}    IPv4：{sum(n.get("ip_version","4")=="4" for n in nodes)}    IPv6：{sum(n.get("ip_version")=="6" for n in nodes)}')
    print(colored('  安装与服务','1;37'))
    for row in ['  1. 安装 sing-box / 依赖','  8. 查看服务状态','  9. 查看运行日志',' 10. 重启节点服务']:
        print(colored(row,'32'))
    print(colored('  节点配置','1;37'))
    for row in ['  2. 添加节点 / 选择协议','  3. 修改域名 / 证书 / 端口 / IPv4·IPv6','  4. 删除节点','  5. 查看节点链接 / 二维码 [k]']:
        print(colored(row,'32'))
    print(colored('  网络与更新','1;37'))
    for row in ['  6. 开启 TCP BBR','  7. 配置 Argo 固定隧道',' 11. 停止 Argo 隧道',' 12. 检查脚本 / 核心 / 隧道组件更新',' 13. 设置脚本更新源',' 14. 从本地新版文件更新']:
        print(colored(row,'32'))
    print(colored(' sc. 卸载脚本及本工具节点','31'))
    print(colored('  0. 退出脚本','33'))
    print(colored('  快捷命令：sudo jb 打开菜单；sudo k 查看节点；sudo sc 卸载','36'))

def selftest():
    nodes=[]
    for p in PROTOCOLS:
        nodes.append(dict(id=p,name='测试 '+p,protocol=p,host='example.com',port=20443,uuid=str(uuid.uuid4()),password='a:b@/+=',path='/a b',argo=False,cert='/tmp/fullchain.pem',key='/tmp/key.pem'))
    assert len(config(nodes)['inbounds']) == 6
    for n, (_,link) in zip(nodes,links(nodes)):
        assert '\n' not in link and link.startswith(('ss://' if n['protocol']=='shadowsocks' else n['protocol']+'://'))
    for p in ('vless','vmess'):
        n=copy.deepcopy(nodes[PROTOCOLS.index(p)]); n['argo']=True
        inbound=config([n])['inbounds'][0]
        assert inbound['listen']=='127.0.0.1' and 'tls' not in inbound
        n['ip_version']='6'
        assert config([n])['inbounds'][0]['listen']=='::1'
        assert origin(n)=='http://[::1]:20443'
    assert config([dict(nodes[0],ip_version='6')])['inbounds'][0]['listen']=='::'
    assert version_tuple('1.10.0') > version_tuple('1.9.9')
    validate_manifest(dict(version='1.2.0',script_url='https://example.com/vps-node.sh',sha256='a'*64))
    v=json.loads(base64.b64decode(links(nodes)[1][1][8:])); assert v['aid']=='0' and v['tls']=='tls'
    assert host('[2001:db8::1]')=='2001:db8::1'
    assert '@[2001:db8::1]:' in links([dict(nodes[0],host='2001:db8::1')])[0][1]
    for invalid in ['https://example.com','x;touch /tmp/pwn','-bad.example']:
        try: host(invalid)
        except ValueError: pass
        else: raise AssertionError(invalid)
    print('PASS：6 种配置、IPv4/IPv6、Argo 双地址族回环监听、VMess 编码、IPv6 链接、更新版本/清单校验。未进行 VPS 实机安装测试。')

def main():
    if '--self-test' in sys.argv: selftest(); return
    if os.geteuid()!=0: raise RuntimeError('请使用 sudo bash vps-node.sh')
    os_release = pathlib.Path('/etc/os-release').read_text()
    if not re.search(r'^ID=["\']?(debian|ubuntu)["\']?$',os_release,re.M): raise RuntimeError('仅支持 Debian / Ubuntu')
    if not pathlib.Path('/run/systemd/system').exists(): raise RuntimeError('需要 systemd 环境，不支持普通 Docker 容器')
    os.umask(0o077)
    ROOT.mkdir(mode=0o700,exist_ok=True); os.chmod(ROOT,0o700)
    with open(ROOT/'manager.lock','w') as lock:
        try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError: raise RuntimeError('另一个管理程序正在运行')
        if len(sys.argv)>1 and sys.argv[1]=='--install': install(); return
        if len(sys.argv)>1 and sys.argv[1].lower()!='jb':
            command=sys.argv[1].lower()
            if command=='k': show(); return
            if command=='sc': uninstall(); return
            raise ValueError('支持参数：jb / k / sc / --install / --self-test')
        while True:
            menu()
            try:
                choice=ask('选择').lower()
                if choice=='0': return
                if choice=='sc':
                    if uninstall(): return
                    continue
                actions={'1':install,'2':add,'3':edit,'4':remove,'5':show,'k':show,'6':bbr,'7':tunnel,
                         '8':lambda:run('systemctl','--no-pager','status',SERVICE,'vps-node-argo',check=False),
                         '9':lambda:run('journalctl','--no-pager','-n','80','-u',SERVICE,'-u','vps-node-argo'),
                         '10':lambda:run('systemctl','restart',SERVICE),
                         '11':lambda:run('systemctl','disable','--now','vps-node-argo'),
                         '12':check_updates,'13':update_source,'14':local_update}
                if choice not in actions: print('无效选项'); continue
                actions[choice]()
            except EOFError: return
            except (ValueError,RuntimeError,OSError,SyntaxError,subprocess.CalledProcessError) as e: print('操作失败：',e)

if __name__=='__main__':
    try: main()
    except KeyboardInterrupt: print('\n已退出'); sys.exit(130)
    except Exception as e: print('错误：',e,file=sys.stderr); sys.exit(1)
PY
