#!/usr/bin/env python3
"""Local safety checks. Never run the installer or edit the host's SSH settings.

Use a real OpenSSH parser for configuration checks; isolate the generated control
program in a temporary directory and substitute service/ownership operations.
This is not a live Ubuntu/systemd integration test.
"""
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / 'scripts/setup-ssh.sh'
TEXT = SCRIPT.read_text()


def section(marker):
    return TEXT.split("<<'" + marker + "'\n", 1)[1].split('\n' + marker + '\n', 1)[0]


def run(args, **kwargs):
    return subprocess.run(args, text=True, capture_output=True, **kwargs)


class Configuration(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.config = self.root / 'sshd_config'
        (self.root / 'block').write_text(section('BLOCK') + '\n')
        self.sshd = shutil.which('sshd') or '/usr/sbin/sshd'
        self.key = self.root / 'host_key'
        result = run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)])
        self.assertEqual(result.returncode, 0, result.stderr)

    def audit(self):
        return run(['python3', '-c', section('PY_AUDIT'), str(self.config)])

    def candidate(self):
        return run(['python3', '-c', section('PY_CANDIDATE'), str(self.root), str(self.config)])

    def test_first_block_overrides_cloud_init_and_checks_context(self):
        cloud = self.root / '50-cloud-init.conf'
        cloud.write_text('PasswordAuthentication yes\nPermitRootLogin yes\n')
        self.config.write_text(f'Include "{cloud}"\nPubkeyAuthentication no\n')
        self.assertEqual(self.audit().returncode, 0)
        self.assertEqual(self.candidate().returncode, 0)
        candidate = self.root / 'candidate'
        syntax = run([self.sshd, '-t', '-f', str(candidate), '-h', str(self.key)])
        self.assertEqual(syntax.returncode, 0, syntax.stderr)
        function = TEXT.split('verify_effective() {', 1)[1].split('\n}\n', 1)[0]
        # Supply only a host key to the real parser; use production verification body.
        code = ('set -euo pipefail\n'
                'sshd() { "$REAL_SSHD" -h "$HOST_KEY" "$@"; }\n'
                'client_ip=192.0.2.10; server_ip=192.0.2.20; server_port=22\n'
                'verify_effective() {' + function + '\n}\nverify_effective "$CANDIDATE"\n')
        result = run(['bash', '-c', code], env={**os.environ, 'REAL_SSHD': self.sshd,
                     'HOST_KEY': str(self.key), 'CANDIDATE': str(candidate)})
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_nested_match_is_rejected_without_changing_original(self):
        child = self.root / 'child.conf'
        child.write_text('mAtCh=User root\n PasswordAuthentication yes\n')
        parent = self.root / 'parent.conf'
        parent.write_text(f'Include {child}\n')
        original = f'Include {parent}\n'
        self.config.write_text(original)
        self.assertNotEqual(self.audit().returncode, 0)
        self.assertEqual(self.config.read_text(), original)

    def test_include_cycle_rejected(self):
        self.config.write_text(f'Include {self.config}\n')
        self.assertNotEqual(self.audit().returncode, 0)

    def test_ambiguous_include_syntax_rejected(self):
        self.config.write_text('Include /etc/ssh/special\\ name.conf\n')
        self.assertNotEqual(self.audit().returncode, 0)

    def test_default_empty_sshd_options_allowed_but_overrides_rejected(self):
        proc = self.root / 'proc/123'
        proc.mkdir(parents=True)
        cmdline = proc / 'cmdline'
        cmdline.write_bytes(b'sshd: /usr/sbin/sshd -D [listener] 0 of 10-100 startups\0')
        defaults = self.root / 'defaults'
        code = section('PY_PREFLIGHT').replace('/proc/{pid}/cmdline', str(self.root) + '/proc/{pid}/cmdline')
        code = code.replace('/etc/default/ssh', str(defaults))
        for value in ('SSHD_OPTS=\n', 'SSHD_OPTS="" # default\n', "SSHD_OPTS=''\n"):
            defaults.write_text(value)
            result = run(['python3', '-c', code, '123'])
            self.assertEqual(result.returncode, 0, result.stderr)
        defaults.write_text('SSHD_OPTS="-oPasswordAuthentication=yes"\n')
        self.assertNotEqual(run(['python3', '-c', code, '123']).returncode, 0)
        defaults.write_text('SSHD_OPTS=\n')
        cmdline.write_bytes(b'/usr/sbin/sshd\0-D\0-oPasswordAuthentication=yes\0')
        self.assertNotEqual(run(['python3', '-c', code, '123']).returncode, 0)

    def test_idempotent_candidate_and_damaged_marker_rejected(self):
        self.config.write_text('PasswordAuthentication yes\n')
        self.assertEqual(self.candidate().returncode, 0)
        first = (self.root / 'candidate').read_text()
        self.config.write_text(first)
        self.assertEqual(self.candidate().returncode, 0)
        self.assertEqual(first, (self.root / 'candidate').read_text())
        self.config.write_text(first.replace('PasswordAuthentication no', 'PasswordAuthentication yes', 1))
        self.assertNotEqual(self.candidate().returncode, 0)

    def test_invalid_original_config_rejected_by_real_sshd(self):
        self.config.write_text('NotAnSSHOption yes\n')
        result = run([self.sshd, '-t', '-f', str(self.config), '-h', str(self.key)])
        self.assertNotEqual(result.returncode, 0)

    def test_unrestricted_key_dedup_retains_restricted_key(self):
        pubkey = re.search(r"^PUBKEY='(.*)'$", TEXT, re.M).group(1)
        keytype, data, _ = pubkey.split()
        keyfile = self.root / 'authorized_keys'
        pattern = '$1 == type && $2 == data { found=1 } END { exit !found }'
        for content, expected in [(pubkey + '\n', 0),
                                  (keytype + ' ' + data + ' another-comment\n', 0),
                                  ('from="192.0.2.1" ' + pubkey + '\n', 1)]:
            keyfile.write_text(content)
            result = run(['awk', '-v', f'type={keytype}', '-v', f'data={data}', pattern, str(keyfile)])
            self.assertEqual(result.returncode, expected)


class Recovery(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.base = self.root / 'state'
        self.state = self.base / 'transaction-test'
        self.etc = self.root / 'etc-ssh'
        self.ssh = self.root / 'root-ssh'
        for p in (self.state, self.etc, self.ssh):
            p.mkdir(parents=True)
        self.config = self.etc / 'sshd_config'
        self.auth = self.ssh / 'authorized_keys'
        self.config.write_text('changed config\n')
        self.auth.write_text('changed key\n')
        (self.state / 'sshd_config.original').write_text('original config\n')
        (self.state / 'authorized_keys.original').write_text('original key\n')
        (self.state / 'authorized_keys.original').chmod(0o640)
        (self.state / 'ssh-dir-mode').write_text('750\n')
        (self.state / 'ssh-dir-group').write_text(str(os.getgid()) + '\n')
        (self.state / 'unit').write_text('utilities-ssh-test\n')
        (self.state / 'original-connection').write_text('192.0.2.1 100 192.0.2.2 22\n')
        (self.base / 'pending').write_text(str(self.state) + '\n')
        hashes = run(['shasum', '-a', '256', str(self.config), str(self.auth)])
        self.assertEqual(hashes.returncode, 0)
        (self.state / 'applied.sha256').write_text(hashes.stdout)
        control = section('CONTROL').replace('[[ $EUID -eq 0 ]]', '[[ 0 -eq 0 ]]')
        for original, substitute in [('/var/lib/utilities-ssh', self.base),
                                     ('/etc/ssh', self.etc), ('/root/.ssh', self.ssh),
                                     ('/run/lock/utilities-ssh.lock', self.root / 'lock')]:
            control = control.replace(original, str(substitute))
        self.control = self.state / 'control.sh'
        self.control.write_text('STATE=' + repr(str(self.state)) + '\n' + control)
        shim = self.root / 'shims.sh'
        shim.write_text('''flock() { :; }
chown() { :; }
sshd() { :; }
sha256sum() { shasum -a 256 "$@"; }
systemctl() {
    printf '%s\\n' "$*" >> "$EVENTS"
    if [[ $1 == reload && ${FAIL_RELOAD:-0} == 1 ]]; then return 1; fi
}
''')
        self.env = {**os.environ, 'BASH_ENV': str(shim), 'EVENTS': str(self.root / 'events')}

    def control_run(self, action, **env):
        return run(['bash', str(self.control), action], env={**self.env, **env})

    def test_rollback_restores_bytes_permissions_and_is_idempotent(self):
        result = self.control_run('rollback')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.config.read_text(), 'original config\n')
        self.assertEqual(self.auth.read_text(), 'original key\n')
        self.assertEqual(self.auth.stat().st_mode & 0o777, 0o640)
        self.assertEqual(self.ssh.stat().st_mode & 0o777, 0o750)
        self.assertFalse((self.base / 'pending').exists())
        self.assertEqual(self.control_run('rollback').returncode, 0)

    def test_rollback_removes_only_new_files_and_directory(self):
        for name in ('authorized_keys.original', 'ssh-dir-mode', 'ssh-dir-group'):
            (self.state / name).unlink()
        result = self.control_run('rollback')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(self.ssh.exists())

    def test_reload_failure_keeps_pending_for_retry(self):
        result = self.control_run('rollback', FAIL_RELOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.base / 'pending').exists())
        self.assertEqual(self.control_run('rollback').returncode, 0)

    def test_confirm_requires_new_connection_and_cancels_rollback(self):
        old = (self.state / 'original-connection').read_text().strip()
        self.assertNotEqual(self.control_run('confirm', SSH_CONNECTION=old).returncode, 0)
        self.assertNotEqual(self.control_run('confirm', SSH_CONNECTION='').returncode, 0)
        result = self.control_run('confirm', SSH_CONNECTION='192.0.2.1 101 192.0.2.2 22')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.state / 'confirmed').exists())
        self.assertEqual(self.control_run('rollback').returncode, 0)
        self.assertEqual(self.config.read_text(), 'changed config\n')

    def test_confirm_rejects_configuration_changed_after_apply(self):
        self.config.write_text('externally edited\n')
        result = self.control_run('confirm', SSH_CONNECTION='192.0.2.1 101 192.0.2.2 22')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue((self.base / 'pending').exists())


if __name__ == '__main__':
    unittest.main(verbosity=2)
