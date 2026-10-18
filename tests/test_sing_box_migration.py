"""Exercise real temporary config/drop-in files with mocked systemctl and core."""
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class MigrationTests(unittest.TestCase):
    def exercise(self, single=False, legacy=True, fail_check=False,
                 fail_restart=False, extra=False, missing=False, prior=False,
                 residual=False, inactive=False, local_unit=False, disabled=False, no_vendor=False, bad_mode=False):
        with tempfile.TemporaryDirectory() as tmp:
            base=Path(tmp); fs=base/'fs'; bins=base/'bin'; bins.mkdir()
            for p in ['etc/sing-box','etc/systemd/system/sing-box.service.d',
                      'var/lib/sing-box','var/lib/caddy/.local/share/caddy/certificates',
                      'run/lock','usr/bin','usr/lib/systemd/system']:
                (fs/p).mkdir(parents=True,exist_ok=True)
            cfg=fs/'etc/sing-box/config.json'
            cert=fs/'var/lib/caddy/.local/share/caddy/certificates/a.crt'
            if not missing:cert.write_text('CERT')
            path=str(fs/'home/tls/certificates/a.crt') if legacy else str(cert)
            cfg.write_text('{"inbounds":[{"tls":{"certificate_path":"'+path+'"}}]'+(',"other":"'+str(fs/'home/tls/other')+'"' if residual else '')+'}')
            cfg.chmod(0o600 if bad_mode else 0o640)
            before=cfg.read_bytes()
            vendor=fs/'usr/lib/systemd/system/sing-box.service'
            if not no_vendor:vendor.write_text('VENDOR UNIT')
            main=fs/'etc/systemd/system/sing-box.service'
            if local_unit:main.write_text('ORIGINAL LOCAL UNIT')
            enabled=base/'enabled'
            if not disabled:enabled.touch()
            drop=fs/'etc/systemd/system/sing-box.service.d/override.conf'
            if prior:drop.write_text('ORIGINAL MANAGED DROPIN')
            obsolete=drop.parent/'zzzz-single-file.conf'
            if local_unit:obsolete.write_text('OLD GENERATED OVERRIDE')
            other=drop.parent/'user.conf';other.write_text('[Service]\nUser=www-data\n')
            if extra:(cfg.parent/'extra.json').write_text('{}')
            active=base/'active'
            if not inactive:active.touch()
            restarted=base/'restart-attempted'
            calls=base/'calls'
            core=fs/'usr/bin/sing-box';core.write_text('#!/bin/sh\nexit '+('9' if fail_check else '0')+'\n');core.chmod(0o755)
            expected=f'{core} -D {fs}/var/lib/sing-box -c {cfg} run'
            directory=f'{core} -D {fs}/var/lib/sing-box -C {cfg.parent} run'
            systemctl=f'''#!/bin/bash
printf '%s\\n' "$*" >> '{calls}'
case "$1" in
show)
 case "$*" in
 *StateDirectoryMode*) if grep -q '^StateDirectoryMode=0755$' '{drop}' 2>/dev/null; then echo 0755; else echo 0755; fi;;
 *FragmentPath*) if [[ -f '{main}' ]]; then echo '{main}'; else echo '{vendor}'; fi;;
 *ExecStart*)
  if [[ '{str(single).lower()}' == true ]] || grep -q 'ExecStart=' '{drop}' 2>/dev/null; then cmd='{expected}'; else cmd='{directory}'; fi
  echo "{{ path={core} ; argv[]=$cmd ; ignore_errors=no ; }}";;
 *) echo www-data;;
 esac;;
is-active) test -f '{active}';;
is-enabled) test -f '{enabled}';;
reenable) touch '{enabled}';;
disable) rm -f '{enabled}';;
stop) rm -f '{active}';;
restart)
 if [[ '{str(fail_restart).lower()}' == true && ! -f '{restarted}' ]]; then touch '{restarted}'; exit 9; fi
 touch '{active}'
 if grep -q '^StateDirectoryMode=0755$' '{drop}' 2>/dev/null; then chmod 755 '{fs}/var/lib/sing-box'; else chmod 755 '{fs}/var/lib/sing-box'; fi;;
cat) echo ORIGINAL_SERVICE;;
esac
'''
            (bins/'systemctl').write_text(systemctl)
            (bins/'runuser').write_text('#!/bin/bash\nshift 3\nexec "$@"\n')
            (bins/'chown').write_text('#!/bin/sh\nexit 0\n')
            (bins/'stat').write_text('#!/bin/bash\ncase "$*" in *"/var/lib/sing-box") echo www-data:www-data:$(/usr/bin/stat -c %a "${@: -1}");; *"/etc/sing-box") echo root:www-data:755;; *) echo root:www-data:$(/usr/bin/stat -c %a "${@: -1}");; esac\n')
            (bins/'dpkg-query').write_text('#!/bin/bash\ncase "$*" in *sing-box-beta*) exit 1;; *-L*) echo "'+str(vendor)+'";; *) printf "install ok installed\\n";; esac\n')
            (bins/'install').write_text('#!/bin/bash\nargs=(); while (( $# )); do case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac; done\nexec /usr/bin/install "${args[@]}"\n')
            (bins/'sleep').write_text('#!/bin/sh\nexit 0\n')
            for p in bins.iterdir():p.chmod(0o755)
            script=(ROOT/'sing-box/migrate-caddy-cert-paths.sh').read_text()
            script=re.sub(r'/(?:etc/|usr/lib/|lib/systemd/|usr/bin/|var/lib/|home/|run/|root/)',lambda m:str(fs)+m[0],script)
            local=base/'migrate.sh';local.write_text(script)
            env=dict(os.environ,PATH=str(bins)+':'+os.environ['PATH'])
            result=subprocess.run(['bash',str(local)],env=env,capture_output=True,text=True)
            failure=fail_check or fail_restart or extra or missing or residual or no_vendor
            self.assertEqual(result.returncode,1 if failure else 0,result.stdout+result.stderr)
            self.assertEqual(other.read_text(),'[Service]\nUser=www-data\n')
            if failure:
                self.assertEqual(cfg.read_bytes(),before)
                self.assertEqual(cfg.stat().st_mode & 0o777,0o600 if bad_mode else 0o640)
                self.assertEqual(drop.exists(),prior)
                if prior:self.assertEqual(drop.read_text(),'ORIGINAL MANAGED DROPIN')
                self.assertEqual(main.exists(),local_unit)
                self.assertEqual(obsolete.exists(),local_unit)
                self.assertEqual(enabled.exists(),not disabled)
            else:
                self.assertIn(str(cert),cfg.read_text())
                self.assertEqual(cfg.stat().st_mode & 0o777,0o640)
                if not single or legacy:self.assertIn(expected,drop.read_text())
                self.assertFalse(main.exists())
                self.assertFalse(obsolete.exists())
                self.assertTrue(enabled.exists())
                self.assertTrue(active.exists())
                self.assertEqual((fs/'var/lib/sing-box').stat().st_mode & 0o777,0o755)
                # Second execution must validate and perform no restart.
                count=calls.read_text().count('restart')
                again=subprocess.run(['bash',str(local)],env=env,capture_output=True,text=True)
                self.assertEqual(again.returncode,0,again.stdout+again.stderr)
                self.assertEqual(calls.read_text().count('restart'),count)
            if fail_check or extra or missing or residual or no_vendor:
                self.assertNotIn('stop',calls.read_text())
                self.assertNotIn('restart',calls.read_text())
            if fail_restart:self.assertTrue(active.exists())

    def test_directory_with_legacy_paths(self):self.exercise()
    def test_directory_with_already_correct_paths(self):self.exercise(legacy=False)
    def test_already_single_file_no_restart(self):self.exercise(single=True,legacy=False)
    def test_single_file_still_migrates_paths(self):self.exercise(single=True)
    def test_invalid_config_changes_nothing(self):self.exercise(fail_check=True)
    def test_restart_failure_restores_config_and_launch(self):self.exercise(fail_restart=True)
    def test_restart_failure_restores_previous_managed_dropin(self):self.exercise(fail_restart=True,prior=True)
    def test_multiple_directory_inputs_are_not_discarded(self):self.exercise(extra=True)
    def test_missing_certificate_blocks_before_restart(self):self.exercise(missing=True)
    def test_unknown_legacy_reference_blocks(self):self.exercise(residual=True)
    def test_inactive_service_started_like_installer(self):self.exercise(inactive=True)
    def test_local_unit_removed_in_favor_of_vendor(self):self.exercise(local_unit=True,legacy=False,single=True)
    def test_config_mode_normalized(self):self.exercise(single=True,legacy=False,bad_mode=True)
    def test_failed_switch_restores_config_mode(self):self.exercise(bad_mode=True,fail_restart=True)
    def test_disabled_service_enabled(self):self.exercise(disabled=True,legacy=False,single=True)
    def test_missing_vendor_does_not_remove_local_unit(self):self.exercise(local_unit=True,no_vendor=True)
    def test_failure_restores_local_unit_obsolete_dropin_and_disabled_state(self):self.exercise(local_unit=True,disabled=True,fail_restart=True)
