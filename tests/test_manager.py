#!/usr/bin/env python3
"""无 root、无网络、无系统变更的管理器回滚及更新校验测试。"""
import hashlib
import pathlib
import subprocess
import tempfile
import unittest
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

if __name__ == '__main__': unittest.main()
