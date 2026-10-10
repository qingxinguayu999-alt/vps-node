#!/usr/bin/env python3
"""无 root、无网络、无系统变更的管理器回滚及更新校验测试。"""
import hashlib
import pathlib
import subprocess
import tempfile
import unittest
import json
import base64
import threading
from urllib.request import urlopen, Request
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from unittest.mock import patch

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'vps-node.sh'
SOURCE = SCRIPT.read_text()
CODE = SOURCE.split("<<'PY'\n", 1)[1].rsplit('\nPY', 1)[0]

def manager():
    namespace = {'__name__': 'test_manager'}
    exec(compile(CODE, 'manager.py', 'exec'), namespace)
    return namespace

class ManagerTests(unittest.TestCase):
    def test_existing_and_first_install_rollback(self):
        for existing in (True, False):
            with self.subTest(existing=existing), tempfile.TemporaryDirectory() as d:
                g = manager(); root = pathlib.Path(d); g['ROOT'] = root
                if existing:
                    (root/'config.json').write_text('{"old":true}')
                    (root/'nodes.json').write_text('[]')
                calls = []
                def fail_status(*args, **kwargs):
                    calls.append(args)
                    if args[:3] == ('systemctl','is-active','--quiet'):
                        raise subprocess.CalledProcessError(1,args)
                g['run'] = fail_status
                with patch('time.sleep'), self.assertRaises(RuntimeError): g['apply']([])
                if existing:
                    self.assertEqual((root/'config.json').read_text(),'{"old":true}')
                    self.assertEqual((root/'nodes.json').read_text(),'[]')
                    self.assertEqual(calls.count(('systemctl','restart','vps-node')),2)
                else:
                    self.assertFalse((root/'config.json').exists())
                    self.assertIn(('systemctl','stop','vps-node'),calls)

    def test_reject_invalid_updates_before_write(self):
        g = manager()
        data = SOURCE.replace("VERSION = '" + g['VERSION'] + "'", "VERSION = '99.0.0'").encode()
        with self.assertRaises(ValueError): g['install_script'](data,'0'*64,'99.0.0')
        with self.assertRaises(ValueError): g['install_script'](data,hashlib.sha256(data).hexdigest(),'99.1.0')
        with self.assertRaises(ValueError): g['validate_manifest'](dict(version='1.2.0',script_url='http://example.com/a',sha256='a'*64))

    def test_ipv6_argo_and_legacy_ipv4(self):
        g = manager()
        node=dict(protocol='vmess',id='test',port=18080,uuid='00000000-0000-4000-8000-000000000000',path='/ws',argo=True)
        self.assertEqual(g['config']([node])['inbounds'][0]['listen'],'127.0.0.1')
        node['ip_version']='6'
        self.assertEqual(g['config']([node])['inbounds'][0]['listen'],'::1')
        self.assertEqual(g['origin'](node),'http://[::1]:18080')
        self.assertNotIn('tls',g['config']([node])['inbounds'][0])

    def test_selfsigned_hy2_cert_and_uri(self):
        for address in ('8.8.8.8','2606:4700:4700::1111'):
            with self.subTest(address=address), tempfile.TemporaryDirectory() as d:
                g=manager(); g['ROOT']=pathlib.Path(d)
                cert,key,pin=g['selfsigned_certificate'](address)
                self.assertEqual(len(pin),64)
                result=subprocess.run(['openssl','x509','-in',cert,'-noout','-checkip',address],check=True,text=True,capture_output=True)
                self.assertIn('does match certificate',result.stdout)
                node=dict(id='hy2',name='HY2',protocol='hysteria2',host=address,port=20443,argo=False,password='a:@/b',cert=cert,key=key,cert_mode='selfsigned',cert_pin=pin)
                link=g['links']([node])[0][1]; parsed=urlsplit(link)
                self.assertEqual(parsed.hostname,address)
                q=parse_qs(parsed.query)
                self.assertEqual(q['insecure'],['1']); self.assertEqual(q['pinSHA256'],[pin])
                node['cert_mode']='custom'; node['host']='hy2.example.com'
                q=parse_qs(urlsplit(g['links']([node])[0][1]).query)
                self.assertNotIn('insecure',q); self.assertNotIn('pinSHA256',q)

    def test_hy2_defaults_and_preserves_selfsigned_certificate(self):
        with tempfile.TemporaryDirectory() as d:
            g=manager(); g['ROOT']=pathlib.Path(d); g['public_ip']=lambda family:'8.8.8.8'
            prompts=[]
            def defaults(text,default=''): prompts.append(default); return default
            g['ask']=defaults
            new=g['hy2_settings']('4')
            self.assertEqual(prompts[0],'1'); self.assertEqual(new['host'],'8.8.8.8')
            old=dict(new)
            existing=g['hy2_settings']('4',old)
            self.assertEqual(existing['cert'],old['cert']); self.assertEqual(existing['cert_pin'],old['cert_pin'])

    def test_hy2_custom_mode_and_legacy_node(self):
        g=manager(); prompts=[]
        old=dict(host='hy2.example.com',cert='/tmp/cert',key='/tmp/key')
        def defaults(text,default=''): prompts.append(default); return default
        g['ask']=defaults
        custom=g['hy2_settings']('4',old)
        self.assertEqual(prompts[0],'2')
        self.assertEqual(custom['cert_mode'],'custom'); self.assertEqual(custom['cert'],old['cert'])
        self.assertNotIn('cert_pin',custom)

    def fixtures(self,g):
        cert,key,pin=g['selfsigned_certificate']('8.8.8.8')
        return [dict(id='id-'+p,name='same-name',protocol=p,host='ws.example.com' if p in ('vless','vmess') else '8.8.8.8',port=20000+i,uuid='00000000-0000-4000-8000-000000000000',password='SECRET_PASSWORD',path='/ws-'+p,argo=p in ('vless','vmess'),ip_version='4',cert=cert,key=key,cert_mode='custom' if p in ('vless','vmess') else 'selfsigned',cert_pin=pin) for i,p in enumerate(g['PROTOCOLS'])]

    def test_four_protocol_client_exports(self):
        with tempfile.TemporaryDirectory() as d:
            g=manager();g['ROOT']=pathlib.Path(d); nodes=self.fixtures(g)
            self.assertEqual(set(g['PROTOCOLS']),{'vless','vmess','tuic','hysteria2'})
            lines=base64.b64decode(g['subscription_body'](nodes,'base64')).decode().splitlines()
            self.assertEqual(len(lines),4)
            tuic_q=parse_qs(urlsplit(lines[2]).query)
            self.assertEqual(tuic_q['allow_insecure'],['1'])
            clash=json.loads(g['subscription_body'](nodes,'clash'))
            self.assertEqual(len(clash['proxies']),4)
            self.assertEqual(len({p['name'] for p in clash['proxies']}),4)
            self.assertEqual(clash['proxies'][0]['port'],443)
            self.assertEqual(clash['proxies'][2]['uuid'],nodes[2]['uuid'])
            self.assertEqual(clash['proxies'][2]['fingerprint'],nodes[2]['cert_pin'])
            sb=json.loads(g['subscription_body'](nodes,'singbox'))
            proxy=next(o for o in sb['outbounds'] if o['type']=='tuic')
            self.assertIn('certificate',proxy['tls']); self.assertNotIn('insecure',proxy['tls'])
            self.assertNotIn('PRIVATE KEY',json.dumps(sb))
            legacy=dict(nodes[0],protocol='trojan')
            self.assertEqual(len(json.loads(g['subscription_body'](nodes+[legacy],'clash'))['proxies']),4)

    def test_subscription_http_auth_formats_rotation_and_live_nodes(self):
        with tempfile.TemporaryDirectory() as d:
            g=manager();root=pathlib.Path(d);g['ROOT']=root;nodes=self.fixtures(g)
            token='x'*24
            (root/'subscription.json').write_text(json.dumps(dict(token=token,host='sub.example.com',port=0)))
            (root/'nodes.json').write_text(json.dumps(nodes))
            server=g['ThreadingHTTPServer'](('127.0.0.1',0),g['SubscriptionHandler'])
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            base='http://127.0.0.1:'+str(server.server_port)
            try:
                with self.assertRaises(HTTPError) as err:urlopen(base+'/s/wrong')
                self.assertEqual(err.exception.code,404)
                with urlopen(Request(base+'/s/'+token,headers={'User-Agent':'clash.meta'})) as response:
                    self.assertEqual(len(json.load(response)['proxies']),4)
                    self.assertIn('no-store',response.headers['Cache-Control'])
                with urlopen(base+'/s/'+token+'?format=base64') as response:
                    self.assertEqual(len(base64.b64decode(response.read()).decode().splitlines()),4)
                with self.assertRaises(HTTPError) as err:urlopen(base+'/s/'+token+'?format=invalid')
                self.assertEqual(err.exception.code,400)
                (root/'nodes.json').write_text(json.dumps(nodes[:2]))
                with urlopen(base+'/s/'+token+'?format=clash') as response:self.assertEqual(len(json.load(response)['proxies']),2)
                (root/'subscription.json').write_text(json.dumps(dict(token='y'*24,host='sub.example.com',port=0)))
                with self.assertRaises(HTTPError) as err:urlopen(base+'/s/'+token)
                self.assertEqual(err.exception.code,404)
                with urlopen(base+'/s/'+'y'*24) as response:self.assertEqual(response.status,200)
            finally:server.shutdown();server.server_close();thread.join()

    def test_four_in_one_applies_all_four_once(self):
        g=manager(); captured=[]
        def ask(text,default=''):
            if '监听地址' in text:return '4'
            if '都走 Argo' in text:return 'y'
            if '公开域名' in text:return ('vless' if 'VLESS' in text else 'vmess')+'.example.com'
            if '现在配置' in text:return 'n'
            return default
        g['ask']=ask;g['load']=lambda:[];g['port_free']=lambda *a:None
        g['quic_settings']=lambda *a,**k:dict(host='8.8.8.8',cert='/cert',key='/key',cert_mode='selfsigned',cert_pin='a'*64)
        g['apply']=lambda nodes:captured.append(nodes)
        with patch('shutil.which',return_value='/usr/bin/sing-box'):g['four_in_one']()
        self.assertEqual(len(captured),1);self.assertEqual([n['protocol'] for n in captured[0]],g['PROTOCOLS'])
        self.assertEqual(len({n['port'] for n in captured[0]}),4)

if __name__ == '__main__': unittest.main()
