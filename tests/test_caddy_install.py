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
            src=SOURCE.replace('readonly CONFIG="/etc/caddy/caddy.jsonc"',f'readonly CONFIG="{root}/config.jsonc"').replace('readonly NORMALIZE="${SCRIPT_DIR}/normalize-caddy-services.sh"',f'readonly NORMALIZE="{root}/normalize.sh"').replace('/usr/bin/caddy version','true')
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
    def test_setup_service_delegates_to_normalizer(self):
        body='''cat > "$NORMALIZE" <<'STUB'
#!/bin/bash
echo "normalize $*" >> 'CALLS_FILE'
STUB
chmod +x "$NORMALIZE"
setup_service'''
        calls=self.run_case(body.replace('CALLS_FILE','__TEMP__/calls'))
        self.assertIn('normalize --caddy',calls)
    def test_setup_service_refuses_without_normalizer(self):
        calls=self.run_case('setup_service',1)
        self.assertNotIn('normalize',calls)
    def test_expose_unit_unmasks_before_normalization(self):
        calls=self.run_case('expose_unit')
        self.assertIn('unmask caddy',calls);self.assertIn('daemon-reload',calls)

if __name__=='__main__':unittest.main()
