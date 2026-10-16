"""Isolated migration checks: real temp files, mocked service/package commands."""
import importlib.util
import json
import os
import re
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('migration_config', ROOT/'caddy/migration-config.py')
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class ConfigTests(unittest.TestCase):
    def test_scoped_comment_preserving_edits_and_second_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            c = d/'c'; s = d/'s'
            c.write_text('{// keep Caddy comment\n"storage":{"module":"file_system","root":"/home/tls"},"other":{"root":"/home/tls"}}')
            s.write_text('{// keep sing comment\n"inbounds":[{"tls":{"certificate_path":"/home/tls/certificates/a.crt","key_path":"/home/tls/certificates/a.key"}}],"note":"/home/tls/not-a-cert"}')
            plan = config.prepare(c, s, d/'co', d/'so')
            self.assertEqual(plan['sing_changes'], 2)
            self.assertIn('// keep', (d/'co').read_text())
            self.assertIn('// keep', (d/'so').read_text())
            _, value, _ = config.document(d/'co')
            self.assertEqual(value['other']['root'], '/home/tls')
            self.assertIn('/home/tls/not-a-cert', (d/'so').read_text())
            second = config.prepare(d/'co', d/'so', d/'co2', d/'so2')
            self.assertEqual(second['sing_changes'], 0)
            self.assertEqual((d/'co').read_bytes(), (d/'co2').read_bytes())
            self.assertEqual((d/'so').read_bytes(), (d/'so2').read_bytes())

    def test_jsonc_trailing_commas_and_adjacent_comments(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d/'c').write_text('{"storage":{"module":"file_system","root":"/home/tls",},"n":1// c\n,"a":[1,2,],}')
            config.prepare(d/'c', '-', d/'out', d/'unused')
            _, value, _ = config.document(d/'out')
            self.assertEqual(value['n'], 1)
            self.assertEqual(value['a'], [1, 2])

    def test_cli_invalid_json_has_readable_error(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp); (d/'c').write_text('{broken')
            r=subprocess.run(['python3',str(ROOT/'caddy/migration-config.py'),str(d/'c'),'-',str(d/'out'),str(d/'unused')],text=True,capture_output=True)
            self.assertEqual(r.returncode, 2)
            self.assertIn('Configuration preparation failed:', r.stderr)
            self.assertNotIn('Traceback', r.stderr)

    def test_unknown_storage_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp)/'c'
            p.write_text('{"storage":{"module":"file_system","root":"/unexpected"}}')
            with self.assertRaises(ValueError):
                config.prepare(p, '-', p.with_name('out'), p.with_name('unused'))

    def test_traversal_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d/'c').write_text('{"storage":{"module":"file_system","root":"/home/tls"}}')
            (d/'s').write_text('{"key_path":"/home/tls/../private"}')
            with self.assertRaises(ValueError):
                config.prepare(d/'c', d/'s', d/'co', d/'so')


class LifecycleTests(unittest.TestCase):
    def exercise(self, fail=False, noop=False, plan=False, legacy=False, path_only=False, residual=False, install_fail=False, caddy_only=False, local_unit=False, retained_dropin=False):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp); fs = d/'fs'; scripts = d/'scripts'; scripts.mkdir()
            for p in ['etc/caddy','etc/sing-box','etc/systemd/system/caddy.service.d','usr/bin','usr/lib/systemd/system','home/tls/certificates','var/lib/caddy/.local/share/caddy/certificates','var/lib/sing-box','run/lock','tmp']:
                (fs/p).mkdir(parents=True, exist_ok=True)
            old = str(fs/'home/tls'); new = str(fs/'var/lib/caddy/.local/share/caddy')
            (Path(old)/'certificates/a.crt').write_text('SOURCE CERT')
            (Path(new)/'certificates/a.crt').write_text('PREVIOUS DESTINATION CERT')
            source = new if noop or path_only else old
            c = fs/'etc/caddy/caddy.jsonc'; s = fs/'etc/sing-box/config.json'
            c.write_text(json.dumps({'storage':{'module':'file_system','root':source}}))
            s.write_text(json.dumps({'inbounds':[{'tls':{'certificate_path':source+'/certificates/a.crt'}}]}))
            if path_only:
                s.write_text(s.read_text().replace(new,old))
            if caddy_only:
                s.write_text('{"inbounds":[]}')
            if residual == 'main':
                value=json.loads(s.read_text()); value['other']='/home/tls/extra.crt'; s.write_text(json.dumps(value))
            elif residual:
                (fs/'etc/sing-box/other.json').write_text('{"other":"/home/tls/extra.crt"}')
            before = c.read_bytes(), s.read_bytes()
            fragment=fs/('etc/systemd/system/caddy.service' if local_unit else 'usr/lib/systemd/system/caddy.service')
            fragment.write_text('[Service]\nUser=www-data\n' + ('ReadWritePaths=/home/tls\n' if local_unit else ''))
            if retained_dropin:
                (fs/'etc/systemd/system/caddy.service.d/extra.conf').write_text('[Service]\nReadWritePaths=/home/tls\n')
            for name in ['caddy.custom','caddy.default','sing-box']:
                p=fs/'usr/bin'/name;p.write_text('#!/bin/sh\nexit 0\n');p.chmod(0o755)
            (fs/'usr/bin/caddy').symlink_to(fs/'usr/bin/caddy.custom')
            helper=(ROOT/'caddy/migration-config.py').read_text().replace("OLD = '/home/tls'",f'OLD = {old!r}').replace("NEW = '/var/lib/caddy/.local/share/caddy'",f'NEW = {new!r}')
            (scripts/'migration-config.py').write_text(helper)
            scanner=(ROOT/'caddy/scan-legacy-paths.py').read_text()
            scanner=re.sub(r'/(?:usr/lib/|etc/)',lambda m:str(fs)+m[0],scanner)
            (scripts/'scan-legacy-paths.py').write_text(scanner)
            (scripts/'install-caddy-debian.sh').write_text('exit 99\n')
            if legacy:
                (fs/'usr/bin/caddy').unlink()
                (fs/'usr/bin/caddy').write_text('#!/bin/sh\nexit 0\n')
                (fs/'usr/bin/caddy').chmod(0o755)
                installer = f'''#!/bin/bash
if [[ "$1" == --prepare-only ]]; then mkdir -p "$2"; exit 0; fi
printf '[Service]\\nUser=www-data\\n' > '{fs}/usr/lib/systemd/system/caddy.service'
ln -sfn '{fs}/usr/bin/caddy.custom' '{fs}/usr/bin/caddy'
'''
                if install_fail:
                    (fs/'usr/bin/caddy.default').unlink()
                    installer += f"printf '#!/bin/sh\\nexit 0\\n' > '{fs}/usr/bin/caddy.default'\nchmod +x '{fs}/usr/bin/caddy.default'\nsystemctl mask caddy\nexit 8\n"
                (scripts/'install-caddy-debian.sh').write_text(installer)
            src=(ROOT/'caddy/migrate-caddy-debian.sh').read_text()
            # All absolute production paths are remapped into this temp tree.
            src=re.sub(r'/(?:usr/local/|usr/lib/|usr/bin/|var/lib/|etc/|home/|root/|run/|lib/systemd/|tmp/)',lambda m:str(fs)+m[0],src)
            src=src.replace('. '+str(fs)+'/etc/os-release','ID=debian; VERSION_ID=13')
            # Mock commands in a separate PATH; no live systemctl/APT calls.
            bins=d/'bin';bins.mkdir();calls=d/'calls'
            systemctl=f'''#!/bin/bash
printf '%s\\n' "$*" >> '{calls}'
if [[ "$1" == show ]]; then
 case "$*" in
 *User*|*Group*) echo www-data;;
 *ExecStart*) if [[ "$2" == caddy ]]; then echo 'ExecStart={{ path={fs}/usr/bin/caddy ; argv[]={fs}/usr/bin/caddy run --config {c} --adapter jsonc ; }}'; else echo 'ExecStart={{ path={fs}/usr/bin/sing-box ; argv[]={fs}/usr/bin/sing-box -c {s} run ; }}'; fi;;
 *FragmentPath*) if [[ -f '{fragment}' ]]; then echo '{fragment}'; else echo '{fs}/usr/lib/systemd/system/caddy.service'; fi;;
 *DropInPaths*) echo '{fs}/etc/systemd/system/caddy.service.d/override.conf';;
 esac
fi
exit 0
'''
            runuser='#!/bin/bash\nwhile [[ "$1" != -- ]]; do shift; done\nshift\n'
            if fail:runuser+='if [[ "$*" == *"check -c"* ]]; then exit 9; fi\n'
            runuser+='"$@"\n'
            install='#!/bin/bash\na=(); while (( $# )); do case "$1" in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done\nexec /usr/bin/install "${a[@]}"\n'
            cmds={'install':install,'systemctl':systemctl,'runuser':runuser,'getent':'#!/bin/sh\nexit 0\n','chown':'#!/bin/sh\nexit 0\n','sleep':'#!/bin/sh\nexit 0\n','dpkg-query':'#!/bin/sh\necho "install ok installed"\n','dpkg-divert':f'#!/bin/sh\necho "local diversion to {fs}/usr/bin/caddy.default"\n'}
            for name,text in cmds.items():
                p=bins/name;p.write_text(text);p.chmod(0o755)
            script=scripts/'migrate-caddy-debian.sh';script.write_text(src)
            env=dict(os.environ,PATH=str(bins)+':'+os.environ['PATH'])
            r=subprocess.run(['bash',str(script)]+([] if plan else ['--apply']),env=env,text=True,capture_output=True)
            self.assertEqual(r.returncode, 4 if residual or retained_dropin else 8 if install_fail else 9 if fail else 3 if noop else 0, r.stdout+r.stderr)
            logs=calls.read_text()
            if fail or install_fail or residual or retained_dropin or plan or noop:
                self.assertEqual((c.read_bytes(),s.read_bytes()),before)
            else:
                self.assertIn(new,c.read_text())
                if not caddy_only:self.assertIn(new,s.read_text())
                if not path_only:self.assertEqual((Path(new)/'certificates/a.crt').read_text(),'SOURCE CERT')
            if fail:
                if legacy:
                    self.assertFalse((fs/'usr/bin/caddy').is_symlink())
                self.assertEqual((Path(new)/'certificates/a.crt').read_text(),'PREVIOUS DESTINATION CERT')
                self.assertIn('restart caddy',logs);self.assertIn('restart sing-box',logs)
            if plan or noop or residual or retained_dropin:self.assertNotIn('stop ',logs);self.assertNotIn('restart ',logs)
            if path_only:
                self.assertNotIn('stop caddy',logs);self.assertNotIn('restart caddy',logs)
                self.assertIn('restart sing-box',logs)
            if caddy_only:
                self.assertNotIn('stop sing-box',logs);self.assertNotIn('restart sing-box',logs)
            if install_fail or (fail and legacy):
                if local_unit:self.assertTrue((fs/'etc/systemd/system/caddy.service').exists())
                else:self.assertFalse((fs/'etc/systemd/system/caddy.service').exists())
            if install_fail:
                self.assertTrue((fs/'usr/bin/caddy.default').is_file())
                self.assertTrue((fs/'usr/bin/caddy.custom').is_file())
                self.assertFalse((fs/'usr/bin/caddy').is_symlink())
                self.assertIn('restart caddy',logs)
            if residual:
                self.assertIn('config.json:1' if residual == 'main' else 'other.json:1',r.stderr)
            self.assertEqual((Path(old)/'certificates/a.crt').read_text(),'SOURCE CERT')

    def test_legacy_local_unit_is_excluded_then_removed(self):self.exercise(legacy=True,local_unit=True)
    def test_retained_dropin_still_blocks_migration(self):self.exercise(legacy=True,retained_dropin=True)
    def test_plan_with_residual_is_blocked(self):self.exercise(residual=True,plan=True)
    def test_legacy_local_unit_restored_after_installer_failure(self):self.exercise(legacy=True,local_unit=True,install_fail=True)
    def test_path_only_does_not_restart_caddy(self):self.exercise(path_only=True)
    def test_caddy_only_does_not_restart_sing_box(self):self.exercise(caddy_only=True)
    def test_non_certificate_key_in_main_blocks_apply(self):self.exercise(residual='main')
    def test_non_certificate_legacy_reference_blocks_apply(self):self.exercise(residual=True)
    def test_installer_failure_after_mask_preserves_package_core(self):self.exercise(legacy=True,install_fail=True)
    def test_legacy_binary_migration(self):self.exercise(legacy=True)
    def test_legacy_validation_failure_restores_binary(self):self.exercise(legacy=True,fail=True)
    def test_storage_only_success(self):self.exercise()
    def test_failed_validation_restores_configs_storage_and_services(self):self.exercise(fail=True)
    def test_plan_does_not_stop_services(self):self.exercise(plan=True)
    def test_standardized_rerun_does_not_restart(self):self.exercise(noop=True)


if __name__ == '__main__':unittest.main()
