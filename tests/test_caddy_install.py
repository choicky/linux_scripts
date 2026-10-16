"""Mock lifecycle checks; never call live APT/systemd or install binaries."""
from pathlib import Path
import subprocess,tempfile,unittest

SCRIPT=Path(__file__).resolve().parents[1]/'caddy/install-caddy-debian.sh'
if not SCRIPT.exists():SCRIPT=Path(__file__).with_name('install-caddy-debian.sh')
SOURCE=SCRIPT.read_text().rsplit('main "$@"',1)[0]

class CaddyInstallTests(unittest.TestCase):
    def run_case(self,body,expected=0):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp)
            src=SOURCE.replace('readonly CONFIG="/etc/caddy/caddy.jsonc"',f'readonly CONFIG="{root}/config.jsonc"').replace('/usr/bin/caddy version','true')
            code=src+f'''
systemctl() {{ echo "$*" >> '{root}/calls'; return 0; }}
runuser() {{ return 1; }}
'''+body.replace('__TEMP__',tmp)
            r=subprocess.run(['bash'],input=code,text=True,capture_output=True)
            self.assertEqual(r.returncode,expected,r.stdout+r.stderr)
            return (root/'calls').read_text() if (root/'calls').exists() else ''
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

    def test_prepare_only_never_installs_or_stops_service(self):
        calls=self.run_case('''
preflight(){ :; }
install_caddy(){ :; }
download_custom_caddy(){ :; }
save_prepared(){ :; }
install_caddy_package(){ systemctl stop caddy; exit 99; }
main --prepare-only /unused
''')
        self.assertEqual(calls, '')
    def test_prepared_install_does_not_redownload(self):
        calls=self.run_case('''
preflight(){ :; }
load_prepared(){ :; }
install_caddy(){ exit 99; }
download_custom_caddy(){ exit 99; }
install_caddy_package(){ :; }
setup_custom_binary(){ :; }
setup_service(){ :; }
prepare_paths(){ :; }
validate_installation(){ :; }
start_caddy(){ :; }
main --prepared-dir /unused --no-start
''')
        self.assertEqual(calls, '')

if __name__=='__main__':unittest.main()
