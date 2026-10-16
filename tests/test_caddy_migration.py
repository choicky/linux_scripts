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
    def exercise(self, fail=False, noop=False, plan=False, manual=False, prepare_fail=False, install_fail=False):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp); fs = d/'fs'; scripts = d/'scripts'; scripts.mkdir()
            for p in ['etc/caddy','etc/sing-box','etc/systemd/system/caddy.service.d','usr/bin','usr/lib/systemd/system','home/tls/certificates','var/lib/caddy/.local/share/caddy/certificates','var/lib/sing-box','run/lock','tmp']:
                (fs/p).mkdir(parents=True, exist_ok=True)
            old = str(fs/'home/tls'); new = str(fs/'var/lib/caddy/.local/share/caddy')
            (Path(old)/'certificates/a.crt').write_text('SOURCE CERT')
            (Path(new)/'certificates/a.crt').write_text('PREVIOUS DESTINATION CERT')
            source = new if noop else old
            c = fs/'etc/caddy/caddy.jsonc'; s = fs/'etc/sing-box/config.json'
            c.write_text(json.dumps({'storage':{'module':'file_system','root':source}}))
            s.write_text(json.dumps({'inbounds':[{'tls':{'certificate_path':source+'/certificates/a.crt'}}]}))
            before = c.read_bytes(), s.read_bytes()
            fragment=fs/'usr/lib/systemd/system/caddy.service'; fragment.write_text('[Service]\nUser=www-data\n')
            for name in ['caddy.custom','caddy.default','sing-box']:
                p=fs/'usr/bin'/name;p.write_text('#!/bin/sh\nif [ "$1" = version ]; then echo v2.11.7; fi\nexit 0\n');p.chmod(0o755)
            (fs/'usr/bin/caddy').symlink_to(fs/'usr/bin/caddy.custom')
            helper=(ROOT/'caddy/migration-config.py').read_text().replace("OLD = '/home/tls'",f'OLD = {old!r}').replace("NEW = '/var/lib/caddy/.local/share/caddy'",f'NEW = {new!r}')
            (scripts/'migration-config.py').write_text(helper)
            installed=d/'installed'
            if manual:
                (fs/'usr/local/bin').mkdir(parents=True,exist_ok=True)
                (fs/'usr/local/bin/caddy').write_bytes((fs/'usr/bin/caddy.custom').read_bytes())
                (fs/'usr/local/bin/caddy').chmod(0o755)
                (fs/'usr/bin/caddy').unlink()
            installer=f'''#!/bin/bash
printf '%s\\n' "INSTALLER $*" >> '{d}/calls'
if [[ "$1" == --prepare-only ]]; then
  [[ "{str(prepare_fail).lower()}" == false ]] || exit 8
  mkdir -m 700 "$2"
  exit 0
fi
[[ "{str(install_fail).lower()}" == false ]] || exit 7
ln -sfn '{fs}/usr/bin/caddy.custom' '{fs}/usr/bin/caddy'
touch '{installed}'
'''
            (scripts/'install-caddy-debian.sh').write_text(installer)
            src=(ROOT/'caddy/migrate-caddy-debian.sh').read_text()
            # All absolute production paths are remapped into this temp tree.
            src=re.sub(r'/(?:usr/local/|usr/lib/|usr/bin/|var/lib/|etc/|home/|root/|run/|lib/systemd/|tmp/)',lambda m:str(fs)+m[0],src)
            src=src.replace('. '+str(fs)+'/etc/os-release','ID=debian; VERSION_ID=13')
            src=src.replace("[[ $EUID == 0 ]] || die 'Run as root.'", ':')
            # Mock commands in a separate PATH; no live systemctl/APT calls.
            bins=d/'bin';bins.mkdir();calls=d/'calls'
            systemctl=f'''#!/bin/bash
printf '%s\\n' "$*" >> '{calls}'
if [[ "$1" == show ]]; then
 case "$*" in
 *User*|*Group*) echo www-data;;
 *ExecStart*) if [[ "$2" == caddy ]]; then if [[ '{str(manual).lower()}' == true && ! -f '{installed}' ]]; then echo 'ExecStart={{ path={fs}/usr/local/bin/caddy ; argv[]={fs}/usr/local/bin/caddy run --config {c} --adapter jsonc ; }}'; else echo 'ExecStart={{ path={fs}/usr/bin/caddy ; argv[]={fs}/usr/bin/caddy run --config {c} --adapter jsonc ; }}'; fi; else echo 'ExecStart={{ path={fs}/usr/bin/sing-box ; argv[]={fs}/usr/bin/sing-box -c {s} run ; }}'; fi;;
 *FragmentPath*) echo '{fragment}';;
 *DropInPaths*) echo '{fs}/etc/systemd/system/caddy.service.d/override.conf';;
 esac
fi
exit 0
'''
            runuser='#!/bin/bash\nwhile [[ "$1" != -- ]]; do shift; done\nshift\n'
            if fail:runuser+='if [[ "$*" == *"check -c"* ]]; then exit 9; fi\n'
            runuser+='"$@"\n'
            install='#!/bin/bash\na=(); while (( $# )); do case "$1" in -o|-g) shift 2;; *) a+=("$1"); shift;; esac; done\nexec /usr/bin/install "${a[@]}"\n'
            cmds={'install':install,'systemctl':systemctl,'runuser':runuser,'getent':'#!/bin/sh\nexit 0\n','chown':'#!/bin/sh\nexit 0\n','sleep':'#!/bin/sh\nexit 0\n','dpkg-query':'#!/bin/sh\necho "install ok installed"\n','dpkg-divert':f'#!/bin/sh\nif [ "$1" = --truename ]; then echo {fs}/usr/bin/caddy.default; else echo "local diversion to {fs}/usr/bin/caddy.default"; fi\n'}
            for name,text in cmds.items():
                p=bins/name;p.write_text(text);p.chmod(0o755)
            script=scripts/'migrate-caddy-debian.sh';script.write_text(src)
            env=dict(os.environ,PATH=str(bins)+':'+os.environ['PATH'])
            r=subprocess.run(['bash',str(script)]+([] if plan else ['--apply']),env=env,text=True,capture_output=True)
            self.assertEqual(r.returncode, 8 if prepare_fail else 7 if install_fail else 9 if fail else 0, r.stdout+r.stderr)
            logs=calls.read_text()
            if fail or plan or noop or prepare_fail or install_fail:
                self.assertEqual((c.read_bytes(),s.read_bytes()),before)
            else:
                self.assertIn(new,c.read_text());self.assertIn(new,s.read_text())
                self.assertEqual((Path(new)/'certificates/a.crt').read_text(),'SOURCE CERT')
            if fail or install_fail:
                self.assertEqual((Path(new)/'certificates/a.crt').read_text(),'PREVIOUS DESTINATION CERT')
                self.assertIn('restart caddy',logs);self.assertIn('restart sing-box',logs)
            if plan or noop or prepare_fail:self.assertNotIn('stop ',logs);self.assertNotIn('restart ',logs)
            if manual and not plan:
                self.assertIn('INSTALLER --prepare-only',logs)
                if not prepare_fail:
                    self.assertLess(logs.index('INSTALLER --prepare-only'), logs.index('stop caddy'))
                    self.assertIn('INSTALLER --prepared-dir',logs)
            self.assertEqual((Path(old)/'certificates/a.crt').read_text(),'SOURCE CERT')

    def test_manual_install_success_resources_precede_stop(self):self.exercise(manual=True)
    def test_unavailable_release_keeps_running_service(self):self.exercise(manual=True,prepare_fail=True)
    def test_failed_installer_restores_old_runtime(self):self.exercise(manual=True,install_fail=True)
    def test_storage_only_success(self):self.exercise()
    def test_failed_validation_restores_configs_storage_and_services(self):self.exercise(fail=True)
    def test_plan_does_not_stop_services(self):self.exercise(plan=True)
    def test_standardized_rerun_does_not_restart(self):self.exercise(noop=True)


if __name__ == '__main__':unittest.main()
