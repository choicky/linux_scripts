"""Isolated shell regression tests; never modify live SSH/fail2ban settings."""
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / 'system/init-debian-server.sh'
SOURCE = SCRIPT.read_text()
FUNCTIONS = SOURCE[SOURCE.index('ensure_admin_user()'):SOURCE.index('case "$ACTION" in')]

class InitializerTests(unittest.TestCase):
    def run_shell(self, body, expected=0):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            code = FUNCTIONS.replace('/etc/ssh/sshd_config.d', str(root / 'ssh')).replace('/etc/fail2ban/jail.d', str(root / 'jail'))
            prelude = '''set -euo pipefail
die(){ echo "FAILED: $*" >&2; exit 1; }
log(){ :; }; ok(){ :; }; changed(){ :; }; skipped(){ :; }
ADMIN_USER=admin
AUTHORIZED_KEY=""
CLIENT_HOST=""
'''
            result = subprocess.run(['bash'], input=prelude + code + '\n' + body.replace('__TEMP__', str(root)), text=True, capture_output=True)
            self.assertEqual(result.returncode, expected, result.stdout + result.stderr)

    def test_connection_specific_policy(self):
        self.run_shell('''SSH_CONNECTION='192.0.2.1 50000 192.0.2.2 22'
sshd(){
 if [[ "$*" == '-T' ]]; then echo 'usedns no'; return; fi
 printf '%s\\n' "$*" >> '__TEMP__/contexts'
 printf '%s\\n' 'permitrootlogin no' 'passwordauthentication yes' 'kbdinteractiveauthentication no' 'pubkeyauthentication yes' 'maxauthtries 4'
}
check_ssh_hardened admin
check_ssh_hardened root
grep -q 'user=admin,addr=192.0.2.1,host=192.0.2.1,laddr=192.0.2.2,lport=22' '__TEMP__/contexts'
grep -q 'user=root,' '__TEMP__/contexts'
''')

    def test_missing_connection_fails_closed(self):
        self.run_shell('unset SSH_CONNECTION; ssh_config_for admin', 1)

    def test_public_key_validation(self):
        self.run_shell('''ssh-keygen -q -t ed25519 -N '' -f '__TEMP__/key'
AUTHORIZED_KEY='__TEMP__/key.pub'
validate_public_key
AUTHORIZED_KEY='__TEMP__/key'
validate_public_key
''', 1)

    def test_key_only_prepare_requires_key(self):
        self.run_shell('''sshd(){ echo 'passwordauthentication no'; }
apt-get(){ echo 'APT SHOULD NOT RUN'; exit 99; }
prepare
''', 1)

    def test_fail2ban_ports_and_startup_retry(self):
        self.run_shell('''sshd(){ printf 'port 2222\\nport 4588\\n'; }
systemctl(){ return 0; }
sleep(){ :; }
fail2ban-client(){
 if [[ "$1" == ping ]]; then
  local count=0
  [[ ! -f '__TEMP__/count' ]] || count=$(cat '__TEMP__/count')
  count=$((count+1)); echo "$count" > '__TEMP__/count'
  (( count >= 3 )) || return 1
  echo 'Server replied: pong'
 fi
}
configure_fail2ban
grep -qx 'port = 2222,4588' '__TEMP__/jail/sshd.local'
[[ $(cat '__TEMP__/count') == 3 ]]
''')

    def test_reload_failure_restores_previous_dropin(self):
        self.run_shell('''mkdir -p '__TEMP__/ssh'
echo '# old policy' > '__TEMP__/ssh/00-vps-baseline.conf'
verify_admin_user(){ :; }; ssh_config_for(){ :; }; check_ssh_hardened(){ :; }
sshd(){ return 0; }
systemctl(){
 if [[ "$1" == reload ]]; then
  if [[ ! -f '__TEMP__/reload' ]]; then touch '__TEMP__/reload'; return 1; fi
  grep -qx '# old policy' '__TEMP__/ssh/00-vps-baseline.conf' || exit 99
  echo restored > '__TEMP__/restored'
 fi
 return 0
}
# harden intentionally exits 1 after a successful restoration.
set +e
(harden)
rc=$?
set -e
[[ "$rc" == 1 && -f '__TEMP__/restored' ]]
grep -qx '# old policy' '__TEMP__/ssh/00-vps-baseline.conf'
''')

if __name__ == '__main__':
    unittest.main()
