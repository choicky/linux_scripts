"""Mock lifecycle checks; never call live APT/systemd or install binaries."""
from pathlib import Path
import subprocess,tempfile,unittest

SCRIPT=Path(__file__).resolve().parents[1]/'caddy/install-caddy-debian.sh'
if not SCRIPT.exists():SCRIPT=Path(__file__).with_name('install-caddy-debian.sh')
SOURCE=SCRIPT.read_text().rsplit('main "$@"',1)[0]

class CaddyInstallTests(unittest.TestCase):
    def run_case(self,body,expected=0,error=None):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            src=SOURCE.replace('readonly CONFIG="/etc/caddy/caddy.jsonc"',f'readonly CONFIG="{root}/config.jsonc"').replace('/usr/bin/caddy version','true')
            code=src+f'''
systemctl() {{ echo "$*" >> '{root}/calls'; return 0; }}
runuser() {{ return 1; }}
'''+body.replace('__TEMP__',tmp)
            r=subprocess.run(['bash'],input=code,text=True,capture_output=True)
            self.assertEqual(r.returncode,expected,r.stdout+r.stderr)
            if error:self.assertIn(error,r.stderr)
            return (root/'calls').read_text() if (root/'calls').exists() else ''
    def test_prepare_only_never_installs_or_stops(self):
        calls=self.run_case('''preflight(){ :; }
install_caddy(){ :; }
download_custom_caddy(){ :; }
save_prepared(){ :; }
install_caddy_package(){ exit 77; }
main --prepare-only __TEMP__/prepared''')
        self.assertEqual(calls, '')
    def test_bad_prepared_checksum_rejected_before_execution(self):
        calls=self.run_case('''mkdir -m 700 __TEMP__/bundle
printf '2.11.7\\n' > __TEMP__/bundle/package-version
printf 'amd64\\n' > __TEMP__/bundle/architecture
printf '#!/bin/sh\\nexit 88\\n' > __TEMP__/bundle/caddy-linux-amd64
chmod 755 __TEMP__/bundle/caddy-linux-amd64
printf '%064d  caddy-linux-amd64\\n' 0 > __TEMP__/bundle/SHA256SUMS
stat(){ case "$*" in *%u*) echo 0;; *%a*) echo 700;; *) command stat "$@";; esac; }
ARCH=amd64; PREPARED_DIR=__TEMP__/bundle
load_prepared''',1,error='Prepared checksum failed.')
        self.assertEqual(calls, '')
    def test_missing_config_validation_succeeds(self):
        self.assertEqual(self.run_case('validate_installation'), '')
    def test_missing_config_exposes_stopped_unit(self):
        calls=self.run_case('start_caddy')
        self.assertIn('unmask caddy',calls);self.assertIn('stop caddy',calls);self.assertIn('disable caddy',calls)
        self.assertNotIn('restart caddy',calls);self.assertNotIn('\nenable caddy',calls)
    def test_no_start_with_existing_config(self):
        calls=self.run_case('touch "$CONFIG"; NO_START=true; validate_installation; start_caddy')
        self.assertIn('unmask caddy',calls);self.assertNotIn('restart caddy',calls)
    def test_validated_config_can_start(self):
        calls=self.run_case('touch "$CONFIG"; start_caddy')
        self.assertIn('enable caddy',calls);self.assertIn('restart caddy',calls)
    def test_failed_partial_install_stays_masked(self):
        calls=self.run_case('SERVICE_TOUCHED=true; false',1)
        self.assertIn('mask caddy',calls);self.assertNotIn('unmask caddy',calls)
    def test_failure_preserves_existing_mask(self):
        calls=self.run_case('SERVICE_TOUCHED=true; RUNTIME_READY=true; WAS_MASKED=true; false',1)
        self.assertIn('mask caddy',calls);self.assertNotIn('unmask caddy',calls)
    def test_failed_validation_after_setup_unmasks_only_our_mask(self):
        calls=self.run_case('touch "$CONFIG"; SERVICE_TOUCHED=true; RUNTIME_READY=true; validate_installation',1)
        self.assertIn('stop caddy',calls);self.assertIn('unmask caddy',calls);self.assertNotIn('restart caddy',calls)

if __name__=='__main__':unittest.main()

