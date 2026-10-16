"""Run with: python3 -m unittest discover -s sing-box-multi-protocol/tests -v.

Set SB_TEST_ARCHIVE to the verified official 1.14.2 amd64-musl archive to
also run the real binary/configuration integration tests. No host services
are changed. Service calls are recorded inside temporary directories.
"""
import base64
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest


MANAGER = Path(__file__).resolve().parents[1] / 'sing-box-node-manager.sh'
SOURCE = MANAGER.read_text()
ARCHIVE = os.environ.get('SB_TEST_ARCHIVE', '')
MUSL_SHA = '8f6cb4bcf94d2b33c65d52e0d5b142db29a938336f1ff7267f397ac3758fc297'


class CompatibilityTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        # Redirect every owned system path before sourcing the script.
        prefixes = ('/usr/local', '/etc/sing-box', '/etc/systemd', '/etc/init.d',
                    '/run', '/var/log/sing-box', '/root', '/tmp',
                    '/sbin/openrc-run', '/etc/alpine-release')
        source = re.sub('|'.join(map(re.escape, prefixes)),
                        lambda m: str(self.root) + m.group(), SOURCE)
        self.script = self.root / 'manager.sh'
        self.script.write_text(source)
        (self.root / 'tmp').mkdir()
        (self.root / 'etc').mkdir()
        (self.root / 'usr/local/bin').mkdir(parents=True)
        (self.root / 'root').mkdir()
        self.common = f'''source '{self.script}'
CALLS='{self.root / 'calls'}'
systemctl() {{ printf 'systemctl %s\\n' "$*" >>"$CALLS"; }}
rc-service() {{ printf 'rc-service %s\\n' "$*" >>"$CALLS"; }}
rc-update() {{ printf 'rc-update %s\\n' "$*" >>"$CALLS"; }}
journalctl() {{ printf 'journalctl %s\\n' "$*" >>"$CALLS"; }}
'''

    def run_shell(self, code, success=True):
        result = subprocess.run(['bash', '-c', self.common + code],
                                text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0)
        return result

    def calls(self):
        path = self.root / 'calls'
        return path.read_text() if path.exists() else ''

    def openrc_fixture(self):
        (self.root / 'sbin').mkdir(exist_ok=True)
        command = self.root / 'sbin/openrc-run'
        command.write_text('#!/bin/sh\nexit 0\n')
        command.chmod(0o755)
        (self.root / 'run/openrc').mkdir(parents=True, exist_ok=True)
        (self.root / 'run/openrc/softlevel').write_text('default\n')

    def test_systemd_detection_and_commands(self):
        (self.root / 'run/systemd/system').mkdir(parents=True)
        self.run_shell('detect_service_manager; [[ "$SERVICE_MANAGER" == systemd ]]; restart_node_service; node_service_active; show_status; show_logs')
        calls = self.calls()
        self.assertIn('systemctl restart sing-box.service', calls)
        self.assertIn('systemctl is-active --quiet sing-box.service', calls)
        self.assertIn('journalctl -u sing-box.service', calls)
        self.assertNotIn('rc-service', calls)

    def test_openrc_detection_commands_and_logs(self):
        self.openrc_fixture()
        log = self.root / 'var/log/sing-box/sing-box.log'
        log.parent.mkdir(parents=True)
        log.write_text('test node log\n')
        result = self.run_shell('require_environment; [[ "$SERVICE_MANAGER" == openrc ]]; restart_node_service; node_service_active; show_status; show_logs')
        self.assertIn('test node log', result.stdout)
        self.assertIn('rc-service sing-box restart', self.calls())
        self.assertNotIn('systemctl', self.calls())
        self.assertNotIn('journalctl', self.calls())

    def test_openrc_commands_without_boot_are_rejected(self):
        self.openrc_fixture()
        (self.root / 'run/openrc/softlevel').unlink()
        result = self.run_shell('require_environment', success=False)
        self.assertIn('OpenRC 尚未完成启动', result.stderr)
        self.assertEqual(self.calls(), '')

    def test_unsupported_init_is_rejected(self):
        result = self.run_shell('detect_service_manager', success=False)
        self.assertIn('未找到受支持的服务管理器', result.stderr)

    def test_alpine_selects_pinned_musl_release(self):
        (self.root / 'etc/alpine-release').write_text('3.21.8\n')
        self.run_shell(f'select_binary_release; [[ "$SB_ARCHIVE" == *amd64-musl.tar.gz && "$SB_SHA256" == {MUSL_SHA} ]]')

    def test_debian_keeps_glibc_release(self):
        self.run_shell('select_binary_release; [[ "$SB_ARCHIVE" == *amd64-glibc.tar.gz && "$SB_SHA256" == 5c7bc18461827b28d0e5ee7e89d33b276d3ff7c818531104c8e8d26d85b0656e ]]')

    def test_openrc_unit_is_supervised_and_valid_posix_shell(self):
        result = subprocess.run(['bash', '-c', f'source "{MANAGER}"; write_openrc_service'], text=True, capture_output=True, check=True)
        unit = result.stdout
        syntax = subprocess.run(['sh', '-n'], input=unit, text=True, capture_output=True)
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        self.assertIn('supervisor="supervise-daemon"', unit)
        self.assertIn('respawn_delay=5', unit)
        self.assertIn('respawn_max=5', unit)
        self.assertIn('run -c /etc/sing-box/config.json', unit)
        self.assertNotIn('systemctl', unit)
        # A bad config must prevent stopping the old process for restart.
        hooks = subprocess.run(['sh', '-c', unit + '\ncheckconfig() { return 7; }; RC_CMD=restart; stop_pre'], capture_output=True)
        self.assertEqual(hooks.returncode, 7)

    def test_openrc_registration(self):
        self.openrc_fixture()
        self.run_shell('SERVICE_MANAGER=openrc; supervise-daemon() { :; }; install_service_unit')
        unit = self.root / 'etc/init.d/sing-box'
        self.assertTrue(os.access(unit, os.X_OK))
        self.assertIn('rc-update add sing-box default', self.calls())
        self.assertNotIn('systemctl', self.calls())

    def test_openrc_uninstall_uses_its_backend(self):
        self.openrc_fixture()
        unit = self.root / 'etc/init.d/sing-box'
        unit.parent.mkdir(parents=True)
        unit.write_text('# service\n')
        self.run_shell('rm() { printf "rm %s\\n" "$*" >>"$CALLS"; }; find() { :; }; full_uninstall <<<DELETE')
        self.assertIn('rc-service --ifstarted sing-box stop', self.calls())
        self.assertIn('rc-update del sing-box default', self.calls())
        self.assertNotIn('systemctl', self.calls())

    def test_bad_archive_preserves_existing_binary(self):
        (self.root / 'etc/alpine-release').touch()
        binary = self.root / 'usr/local/bin/sing-box'
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_text('#!/bin/sh\nexit 127\n')
        binary.chmod(0o755)
        before = binary.read_bytes()
        self.run_shell('curl() { printf tampered >"${@: -1}"; }; ensure_binary', success=False)
        self.assertEqual(binary.read_bytes(), before)

    def test_vless_only_active_ufw_does_not_abort(self):
        self.run_shell('ufw() { if [[ "$1" == status ]]; then printf "Status: active\\n"; fi; }; VLESS_ENABLED=1; VLESS_LISTEN_PORT=30001; open_firewall_ports; printf reached')

    def installer_fixture(self, valid=True):
        installer = (MANAGER.parent / 'install.sh').read_text()
        destination = self.root / 'usr/local/sbin/sing-box-node'
        installer = installer.replace('/usr/local', str(self.root / 'usr/local'))
        installer = installer.replace('/tmp/', str(self.root / 'tmp') + '/')
        payload = self.root / 'payload.sh'
        payload.write_text('#!/bin/bash\nprintf "%s\\n" "$*" >>"$INSTALL_CALLS"\n')
        checksum = hashlib.sha256(payload.read_bytes()).hexdigest() if valid else '0' * 64
        installer = re.sub(r'MANAGER_SHA256="[0-9a-f]+"', f'MANAGER_SHA256="{checksum}"', installer)
        script = self.root / 'install.sh'
        script.write_text(installer)
        commands = self.root / 'commands'
        commands.mkdir()
        curl = commands / 'curl'
        curl.write_text(f'#!/bin/sh\nwhile [ "$#" -gt 0 ]; do\nif [ "$1" = -o ]; then cp "{payload}" "$2"; exit; fi\nshift\ndone\nexit 1\n')
        curl.chmod(0o755)
        env = dict(os.environ, PATH=str(commands) + ':' + os.environ['PATH'],
                   INSTALL_CALLS=str(self.root / 'install-calls'))
        return script, payload, destination, env

    def test_posix_installer_preflights_then_installs_verified_payload(self):
        script, payload, destination, env = self.installer_fixture()
        result = subprocess.run(['sh', str(script)], env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(destination.read_bytes(), payload.read_bytes())
        self.assertEqual((self.root / 'install-calls').read_text().splitlines(),
                         ['--check-environment', '--install-shortcuts'])

    def test_bad_manager_checksum_preserves_installed_manager(self):
        script, _, destination, env = self.installer_fixture(valid=False)
        destination.parent.mkdir(parents=True)
        destination.write_text('previous manager\n')
        result = subprocess.run(['sh', str(script)], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(destination.read_text(), 'previous manager\n')
        self.assertFalse((self.root / 'install-calls').exists())

    def test_restart_failure_restores_config(self):
        directory = self.root / 'etc/sing-box'
        directory.mkdir(parents=True)
        config = directory / 'config.json'
        config.write_text('old configuration\n')
        binary = self.root / 'usr/local/bin/sing-box'
        binary.parent.mkdir(parents=True, exist_ok=True)
        binary.write_text('#!/bin/sh\nexit 0\n')
        binary.chmod(0o755)
        self.run_shell('''write_config_body() { printf 'new config'; }
install_service_unit() { :; }; open_firewall_ports() { :; }
restart_node_service() { printf restart >>"$CALLS"; return 1; }
show_logs() { :; }; apply_configuration''', success=False)
        self.assertEqual(config.read_text(), 'old configuration\n')
        self.assertEqual(self.calls(), 'restartrestart')
        self.assertFalse((directory / 'node.env').exists())

    @unittest.skipUnless(ARCHIVE, 'set SB_TEST_ARCHIVE for official binary test')
    def test_musl_download_install_and_all_four_real_configs(self):
        archive = Path(ARCHIVE).resolve()
        self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), MUSL_SHA)
        (self.root / 'etc/alpine-release').touch()
        result = self.run_shell(f'''curl() {{ cp '{archive}' "${{@: -1}}"; }}
ensure_binary
PUBLIC_HOST=node.example.net
VLESS_ENABLED=1; VLESS_PUBLIC_PORT=30001; VLESS_LISTEN_PORT=10001
VMESS_ENABLED=1; VMESS_PUBLIC_PORT=30002; VMESS_LISTEN_PORT=10002
HY2_ENABLED=1; HY2_PUBLIC_PORT=30003; HY2_LISTEN_PORT=10003
TUIC_ENABLED=1; TUIC_PUBLIC_PORT=30004; TUIC_LISTEN_PORT=10004
ensure_reality_credentials; ensure_vmess_credentials
ensure_hy2_credentials; ensure_tuic_credentials; ensure_tls_certificate
write_config_body >"$SB_CONFIG"
"$SB_BIN" check -c "$SB_CONFIG"
write_links
''')
        cfg = json.loads((self.root / 'etc/sing-box/config.json').read_text())
        self.assertEqual([x['type'] for x in cfg['inbounds']], ['vless', 'vmess', 'hysteria2', 'tuic'])
        self.assertEqual([x['listen_port'] for x in cfg['inbounds']], [10001, 10002, 10003, 10004])
        links = (self.root / 'root/sing-box-link.txt').read_text()
        self.assertIn('node.example.net:30001?', links)
        self.assertIn('node.example.net:30003/', links)
        self.assertIn('node.example.net:30004/', links)
        vmess = next(x for x in links.splitlines() if x.startswith('vmess://'))
        self.assertEqual(json.loads(base64.b64decode(vmess[8:]))['port'], '30002')
        self.assertIn('SHA-256', result.stdout)


if __name__ == '__main__':
    unittest.main()
