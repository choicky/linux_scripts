"""Mocked evidence-migration checks for caddy/migrate-caddy-deployment.sh.

The script under test is rewritten on the fly to redirect absolute paths into
a temporary fake filesystem. The reused installer and the normalization
component are replaced with logging stubs, so these tests exercise the
migration orchestration itself (evidence detection, storage copy/retain,
config rewriting, sing-box reference migration, rollback) without APT,
systemd, packages or service disruption. Ownership changes are simulated by
no-op chown mocks because unprivileged CI cannot chown to www-data.
"""
import glob
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "caddy" / "migrate-caddy-deployment.sh"

PATH_RE = re.compile(r"(?<![\w.])/(?:etc|usr|var|home|run|root|srv|opt|lib)/")


class MigrationTests(unittest.TestCase):
    def exercise(self, root="home", sb="mapped", opts=(), fail=None,
                 caddy_active=True, singbox_active=True, pre_standard=False,
                 sb_local_unit=False, sb_vendor="usr"):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.base = Path(self._tmp.name)
        self.fs = self.base / "fs"
        self.bins = self.base / "bin"
        self.state = self.base / "state"
        self.calls_path = self.base / "calls"
        self.calls_path.write_text("")
        for d in (self.fs, self.bins, self.state):
            d.mkdir(parents=True, exist_ok=True)
        F = str(self.fs)
        self.F = F
        self.standard = f"{F}/var/lib/caddy/.local/share/caddy"

        # ---------------- fake filesystem ----------------
        for rel in (
            "etc/caddy", "etc/systemd/system/caddy.service.d",
            "etc/ssl", "usr/bin", "usr/local/bin", "var/lib", "var/log",
            "run", "root", "home", "srv",
        ):
            self.fs.joinpath(rel).mkdir(parents=True, exist_ok=True)
        self.legacy_root = {
            "home": f"{F}/home/tls", "alt": f"{F}/srv/tls",
            "partial": f"{F}/home/tls", "multiple": f"{F}/home/tls",
            "missing": f"{F}/home/tls",
        }.get(root)
        if root == "implicit":
            self.implicit_home = f"{F}/home/caddyuser"
            self.legacy_root = f"{self.implicit_home}/.local/share/caddy"

        def storage(prefix, complete=True, acme_only=False):
            Path(prefix + "/certificates/example.com").mkdir(parents=True, exist_ok=True)
            Path(prefix + "/certificates/example.com/cert.pem").write_text("CERT")
            Path(prefix + "/certificates/example.com/key.pem").write_text("KEY")
            if complete and not acme_only:
                Path(prefix + "/acme/accounts").mkdir(parents=True, exist_ok=True)
                Path(prefix + "/acme/accounts/list.json").write_text("{}")

        if root in ("home", "alt", "implicit"):
            storage(self.legacy_root)
        elif root == "partial":
            storage(self.legacy_root, complete=False, acme_only=True)
        elif root == "multiple":
            storage(f"{F}/home/tls")
            storage(f"{F}/srv/tls")
        elif root == "missing":
            # config points at /home/tls but only standard storage exists
            storage(self.standard)

        # ---------------- caddy config ----------------
        plain_apps = '"apps": {"http": {"servers": {":443": {}}}}'
        if root == "standard":
            storage(self.standard)
            cfg_body = f'"storage": {{"module": "file_system", "root": "{self.standard}"}}, {plain_apps}'
        elif root == "implicit":
            cfg_body = plain_apps  # no explicit root: implicit default under HOME
        elif root == "multiple":
            cfg_body = (
                f'"storage": {{"module": "file_system", "root": "{F}/home/tls"}}, '
                f'"apps": {{"tls": {{"automation": {{"policy": {{"storage": '
                f'{{"module": "file_system", "root": "{F}/srv/tls"}}}}}}}}}}'
            )
        else:
            cfg_root = {"missing": f"{F}/home/tls",
                        "standard": self.standard}.get(root, self.legacy_root)
            cfg_body = f'"storage": {{"module": "file_system", "root": "{cfg_root}"}}, {plain_apps}'
        self.cfg = self.fs / "etc/caddy/caddy.jsonc"
        self.cfg.write_text("{" + cfg_body + "}\n")
        self.cfg_bytes = self.cfg.read_bytes()

        # ---------------- legacy binary and unit ----------------
        self.old_binary = self.fs / "usr/local/bin/caddy"
        self.old_unit = self.fs / "etc/systemd/system/caddy.service"
        self.has_legacy_files = root != "standard"
        if self.has_legacy_files:
            self.old_binary.write_text("#!/bin/sh\nexit 0\n")
            self.old_binary.chmod(0o755)
            unit = "[Unit]\nDescription=legacy caddy\n[Service]\nExecStart=/usr/local/bin/caddy run\n"
            if root == "implicit":
                unit = unit.replace("[Service]\n", f"[Service]\nEnvironment=HOME={self.implicit_home}\n")
            self.old_unit.write_text(unit)

        # ---------------- sing-box ----------------
        self.sbcfg = self.fs / "etc/sing-box/config.json"
        self.sbcfg_bytes = None
        if sb != "none":
            ext = f"{F}/etc/ssl/external"
            Path(ext + ".pem").write_text("PEM")
            Path(ext + ".key").write_text("KEY")
            tls_objs = []
            if sb in ("mapped", "residual", "missingcert"):
                leaf = "nope" if sb == "missingcert" else "example.com"
                base = self.legacy_root
                tls_objs.append(
                    f'"certificate_path": "{base}/certificates/{leaf}/cert.pem", '
                    f'"key_path": "{base}/certificates/{leaf}/key.pem"'
                )
            if sb != "missing":
                tls_objs.append(
                    f'"certificate_path": "{ext}.pem", "key_path": "{ext}.key"'
                )
            inbounds = ",".join(
                '{"tls": {"enabled": true, %s}}' % o for o in tls_objs
            )
            doc = f'{{"inbounds": [{inbounds}], "log": {{"level": "info"}}'
            if sb == "residual":
                doc += f', "ca_file": "{self.legacy_root}/acme/root-ca.crt"'
            self.sbcfg.parent.mkdir(parents=True, exist_ok=True)
            self.sbcfg.write_text(doc + "}")
            self.sbcfg_bytes = self.sbcfg.read_bytes()
        self.sbdropin = self.fs / "etc/systemd/system/sing-box.service.d"
        self.sbdropin.mkdir(parents=True, exist_ok=True)
        (self.sbdropin / "override.conf").write_text("[Service]\nUser=root\n")

        # optional shadowing local sing-box unit + package unit(s)
        self.sb_local_unit = self.fs / "etc/systemd/system/sing-box.service"
        if sb_local_unit == "masked":
            self.sb_local_unit.write_text("[Service]\nExecStart=/bin/sing-box run\n")
            masked_target = self.fs / "dev-null"
            masked_target.touch()
            self.sb_local_unit.unlink()
            self.sb_local_unit.symlink_to(masked_target)
            self.sb_local_bytes = None
        elif sb_local_unit:
            self.sb_local_unit.write_text(
                "[Unit]\nDescription=local sing-box\n[Service]\n"
                "ExecStart=/usr/bin/sing-box run\n"
            )
            self.sb_local_bytes = self.sb_local_unit.read_bytes()
        else:
            self.sb_local_bytes = None
        if sb_vendor == "usr":
            v = self.fs / "usr/lib/systemd/system/sing-box.service"
            v.parent.mkdir(parents=True, exist_ok=True)
            v.write_text("[Service]\nExecStart=/usr/bin/sing-box run\n")
        elif sb_vendor == "lib":
            v = self.fs / "lib/systemd/system/sing-box.service"
            v.parent.mkdir(parents=True, exist_ok=True)
            v.write_text("[Service]\nExecStart=/usr/bin/sing-box run\n")

        (self.state / "singbox_installed").touch()
        if caddy_active:
            (self.state / "caddy.active").touch()
        if singbox_active:
            (self.state / "sing-box.active").touch()
        (self.state / "caddy.enabled").touch()
        (self.state / "sing-box.enabled").touch()
        if pre_standard:
            storage(self.standard)
        if fail:
            (self.state / fail).touch()

        # ---------------- stub binaries ----------------
        caddy = self.fs / "usr/bin/caddy"
        caddy.write_text(f"""#!/bin/bash
case "$*" in
  *validate*) [ -f '{self.state}/caddy_validate_fail' ] && exit 7; exit 0;;
  version) echo v2.11.7;;
esac
exit 0
""")
        caddy.chmod(0o755)
        singbox = self.fs / "usr/bin/sing-box"
        singbox.write_text(f"""#!/bin/bash
case "$*" in
  *check*) [ -f '{self.state}/singbox_check_fail' ] && exit 9; exit 0;;
  version) echo 'sing-box version 1.10.0';;
esac
exit 0
""")
        singbox.chmod(0o755)

        # ---------------- mocked commands ----------------
        self._bin("systemctl", f"""#!/bin/bash
printf 'systemctl %s\\n' "$*" >> '{self.calls_path}'
STATE='{self.state}'
svc=''
for a in "$@"; do case "$a" in caddy|sing-box) svc="$a";; esac; done
case "$1" in
  stop) rm -f "$STATE/$svc.active";;
  start|restart)
    if [ "$1" = restart ] && [ -f "$STATE/${{svc}}_restart_fail" ]; then exit 9; fi
    touch "$STATE/$svc.active";;
  is-active) [ -f "$STATE/$svc.active" ] && exit 0; exit 3;;
  is-enabled) [ -f "$STATE/$svc.enabled" ] && exit 0; exit 1;;
  enable) touch "$STATE/$svc.enabled";;
  disable) rm -f "$STATE/$svc.enabled";;
  mask) touch "$STATE/$svc.masked";;
  unmask) rm -f "$STATE/$svc.masked";;
esac
exit 0
""")
        self._bin("runuser", """#!/bin/bash
shift 2
[ "$1" = "--" ] && shift
exec "$@"
""")
        self._bin("getent", """#!/bin/bash
case "$1" in
  passwd) [ "$2" = www-data ] || exit 2;;
  group) [ "$2" = www-data ] || exit 2;;
  *) exit 1;;
esac
""")
        self._bin("chown", "#!/bin/sh\nexit 0\n")
        self._bin("journalctl", "#!/bin/sh\nexit 0\n")
        self._bin("dpkg-divert", "#!/bin/sh\nexit 0\n")
        self._bin("install", """#!/bin/bash
args=(); while (( $# )); do case "$1" in -o|-g) shift 2;; *) args+=("$1"); shift;; esac; done
exec /usr/bin/install "${args[@]}"
""")

        # ---------------- collaborator stubs ----------------
        (self.base / "install-caddy-debian.sh").write_text(
            f"#!/bin/bash\nprintf 'installer %s\\n' \"$*\" >> '{self.calls_path}'\nexit 0\n"
        )
        (self.base / "normalize-caddy-services.sh").write_text(
            f"#!/bin/bash\nprintf 'normalize %s\\n' \"$*\" >> '{self.calls_path}'\nexit 0\n"
        )

        # ---------------- run ----------------
        self.local = self._local_script()
        self._run_script(opts)
        backups = glob.glob(f"{F}/root/caddy-migration-backup/*")
        self.backup = Path(backups[0]) if backups else None

    def _local_script(self):
        text = PATH_RE.sub(lambda m: self.F + m.group(0), SCRIPT.read_text())
        text = text.replace(
            '[[ ${EUID} -eq 0 ]] || die "Run this script as root."',
            "true # root check bypassed by the isolated test harness",
        )
        local = self.base / "migrate-caddy-deployment.sh"
        local.write_text(text)
        return local

    def _run_script(self, opts=()):
        env = dict(os.environ, PATH=f"{self.bins}:/usr/bin:/bin")
        self.result = subprocess.run(
            ["bash", str(self.local), *opts], env=env, capture_output=True, text=True
        )

    def _bin(self, name, body):
        p = self.bins / name
        p.write_text(body)
        p.chmod(0o755)

    def calls(self):
        return self.calls_path.read_text()

    def tearDown(self):
        # allow repeated exercise() calls in one test method
        pass

    # ---------------- successful migrations ----------------

    def test_classic_home_tls_migration(self):
        self.exercise()
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # storage copied, legacy root retained
        self.assertTrue(Path(f"{self.standard}/certificates/example.com/cert.pem").exists())
        self.assertTrue(Path(f"{self.standard}/acme/accounts/list.json").exists())
        self.assertTrue(Path(f"{self.F}/home/tls/certificates/example.com/cert.pem").exists())
        # caddy config root rewritten
        cfg = self.cfg.read_text()
        self.assertIn(f'"root": "{self.standard}"', cfg)
        self.assertNotIn("/home/tls", cfg)
        # mapped sing-box refs follow the storage; external refs stay put
        sb = self.sbcfg.read_text()
        self.assertIn(f"{self.standard}/certificates/example.com/cert.pem", sb)
        self.assertIn(f"{self.standard}/certificates/example.com/key.pem", sb)
        self.assertNotIn("/home/tls", sb)
        self.assertIn(f"{self.F}/etc/ssl/external.pem", sb)
        # legacy live paths removed; backups and README retained
        self.assertFalse(self.old_binary.exists())
        self.assertFalse(self.old_unit.exists())
        self.assertTrue((self.backup / "caddy.old").exists())
        self.assertTrue((self.backup / "caddy.service.old").exists())
        self.assertTrue((self.backup / "caddy.jsonc.old").exists())
        self.assertTrue((self.backup / "sing-box-config.old").exists())
        self.assertIn("never deleted", (self.backup / "README.txt").read_text())
        # orchestration: installer --no-start, one normalize --both, one restart
        lines = self.calls().splitlines()
        self.assertEqual(lines.count("installer --no-start"), 1)
        self.assertEqual(lines.count("normalize --both"), 1)
        self.assertLess(lines.index("installer --no-start"), lines.index("normalize --both"))
        self.assertEqual([l for l in lines if l == "systemctl restart caddy"],
                         ["systemctl restart caddy"])
        self.assertGreater([i for i, l in enumerate(lines) if l == "systemctl restart caddy"][-1],
                           lines.index("normalize --both"))
        self.assertEqual([l for l in lines if l == "systemctl restart sing-box"],
                         ["systemctl restart sing-box"])

    def test_alternate_storage_root_is_evidence_based(self):
        self.exercise(root="alt")
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(f'"root": "{self.standard}"', self.cfg.read_text())
        self.assertTrue(Path(f"{self.standard}/certificates/example.com/cert.pem").exists())
        self.assertTrue(Path(f"{self.F}/srv/tls/acme/accounts/list.json").exists())

    def test_implicit_home_root_copied_without_config_rewrite(self):
        self.exercise(root="implicit")
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.cfg.read_bytes(), self.cfg_bytes)  # no sed on config
        self.assertTrue(Path(f"{self.standard}/certificates/example.com/cert.pem").exists())
        self.assertIn("Implicit default storage", r.stdout)
        sb = self.sbcfg.read_text()
        self.assertIn(f"{self.standard}/certificates/example.com/cert.pem", sb)
        self.assertNotIn("caddyuser", sb)

    def test_storage_already_migrated_proceeds_with_remaining_components(self):
        self.exercise(root="missing")
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("assuming storage was migrated", r.stdout)
        self.assertEqual(self.cfg.read_bytes(), self.cfg_bytes)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)
        self.assertEqual(self.calls().count("installer --no-start"), 1)
        self.assertFalse(self.old_unit.exists())

    # ---------------- no-op and refusal paths (nothing changes) ----------------

    def test_already_standard_layout_is_noop(self):
        self.exercise(root="standard")
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("already appears standard", r.stdout)
        self.assertIn("normalize-caddy-services.sh", r.stdout)
        self.assertEqual(self.calls().strip(), "")
        self.assertIsNone(self.backup)

    def test_partial_storage_evidence_stops_before_any_change(self):
        self.exercise(root="partial")
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("resolve the ambiguity", r.stderr)
        self.assertEqual(self.cfg.read_bytes(), self.cfg_bytes)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)
        self.assertTrue(self.old_binary.exists())
        self.assertTrue(self.old_unit.exists())
        self.assertIsNone(self.backup)
        self.assertNotIn("installer", self.calls())
        self.assertTrue((self.state / "caddy.active").exists())

    def test_multiple_legacy_roots_stop(self):
        self.exercise(root="multiple")
        self.assertEqual(self.result.returncode, 1)
        self.assertIn("Multiple legacy FileStorage roots", self.result.stderr)
        self.assertIsNone(self.backup)

    def test_existing_standard_storage_blocks_overwrite(self):
        self.exercise(root="home", pre_standard=True)
        self.assertEqual(self.result.returncode, 1)
        self.assertIn("refusing to overwrite existing standard storage", self.result.stderr)
        self.assertTrue(self.old_binary.exists())
        self.assertIsNone(self.backup)

    def test_residual_reference_outside_cert_fields_stops(self):
        self.exercise(sb="residual")
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("outside certificate_path/key_path", r.stderr)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)
        self.assertEqual(self.cfg.read_bytes(), self.cfg_bytes)
        self.assertTrue(self.old_binary.exists())
        self.assertNotIn("installer", self.calls())

    def test_no_legacy_root_leaves_external_refs_untouched(self):
        # storage already migrated; only external sing-box references remain
        self.exercise(root="missing", sb="external")
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)
        self.assertIn("no references under a legacy storage root", r.stdout)

    # ---------------- applied-then-failed rollback ----------------

    def test_missing_referenced_certificate_stops_and_restores(self):
        self.exercise(sb="missingcert")
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("does not exist: ", r.stderr)
        # pre-migration state restored
        self.assertEqual(self.cfg.read_bytes(), self.cfg_bytes)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)
        self.assertTrue(self.old_binary.exists())
        self.assertTrue(self.old_unit.exists())
        # sing-box was never applied, its config file untouched above
        self.assertIn("systemctl start caddy", self.calls())
        self.assertNotIn("systemctl restart sing-box", self.calls())

    def test_singbox_validation_failure_keeps_live_config_unmodified(self):
        self.exercise(fail="singbox_check_fail")
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("candidate validation failed", r.stderr)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)
        self.assertEqual(self.cfg.read_bytes(), self.cfg_bytes)
        self.assertTrue(self.old_binary.exists())
        self.assertNotIn("systemctl restart sing-box", self.calls())
        self.assertNotIn("normalize --both", self.calls())

    def test_caddy_restart_failure_restores_old_service(self):
        self.exercise(fail="caddy_restart_fail")
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("failed to start", r.stderr)
        self.assertEqual(self.cfg.read_bytes(), self.cfg_bytes)
        self.assertTrue(self.old_binary.exists())
        self.assertTrue(self.old_unit.exists())
        self.assertIn("Old Caddy service restored and started", r.stderr)
        self.assertTrue((self.state / "caddy.active").exists())
        # legacy sing-box config restored because it had been applied
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)

    # ---------------- state preservation and flags ----------------

    def test_inactive_services_are_not_started(self):
        self.exercise(caddy_active=False, singbox_active=False)
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self.calls()
        self.assertNotIn("systemctl start caddy", calls)
        self.assertNotIn("systemctl restart caddy", calls)
        self.assertNotIn("systemctl restart sing-box", calls)
        self.assertIn("leaving it stopped and disabled", r.stdout)
        # config migration still completed
        self.assertIn(f'"root": "{self.standard}"', self.cfg.read_text())

    def test_skip_singbox_leaves_its_config_alone(self):
        self.exercise(opts=["--skip-sing-box"])
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("skipped by --skip-sing-box", r.stdout)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)
        self.assertTrue(Path(f"{self.F}/home/tls/certificates/example.com/cert.pem").exists())
        self.assertIn(f'"root": "{self.standard}"', self.cfg.read_text())
        self.assertNotIn("sing-box-config.old", "\n".join(p.name for p in self.backup.iterdir()))

    def test_unknown_option_rejected(self):
        self.exercise(opts=["--force"])
        self.assertEqual(self.result.returncode, 1)
        self.assertIn("Unknown option", self.result.stderr)
        self.assertIsNone(self.backup)

    def test_rerun_after_success_is_noop(self):
        self.exercise()
        self.assertEqual(self.result.returncode, 0, self.result.stdout + self.result.stderr)
        calls_before = self.calls()
        # second execution against the already-migrated state: no legacy
        # evidence remains, so the script must stop without touching anything
        self._run_script()
        self.assertEqual(self.result.returncode, 0, self.result.stdout + self.result.stderr)
        self.assertIn("already appears standard", self.result.stdout)
        self.assertEqual(self.calls(), calls_before)

    # ---------------- shadowing local sing-box unit (absorbed helper duty) ----------------

    def test_shadowing_local_singbox_unit_forces_proceed_and_is_relocated(self):
        # Caddy is already standard, but a local sing-box unit shadows the
        # package unit; that shadow alone is legacy evidence and must be
        # removed before normalization so the package unit becomes authoritative.
        self.exercise(root="standard", sb="none", sb_local_unit=True, sb_vendor="usr")
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("already appears standard", r.stdout)
        self.assertFalse(self.sb_local_unit.exists())  # shadowing unit removed
        self.assertIn("shadowing local sing-box unit", r.stdout)
        self.assertIn("sing-box.service.local.old", "\n".join(p.name for p in self.backup.iterdir()))
        lines = self.calls().splitlines()
        self.assertEqual(lines.count("normalize --both"), 1)
        # removal (daemon-reload) happens before normalization
        reload_i = max(i for i, l in enumerate(lines) if l == "systemctl daemon-reload")
        self.assertLess(reload_i, lines.index("normalize --both"))

    def test_skip_singbox_leaves_shadowing_local_unit_untouched(self):
        self.exercise(root="home", sb_local_unit=True, sb_vendor="usr",
                      opts=["--skip-sing-box"])
        r = self.result
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        # --skip-sing-box must not remove the shadowing unit nor normalize it
        self.assertTrue(self.sb_local_unit.exists())
        self.assertEqual(self.sb_local_unit.read_bytes(), self.sb_local_bytes)
        self.assertIn("normalize --caddy", self.calls())
        self.assertNotIn("normalize --both", self.calls())

    def test_shadowing_local_unit_without_package_unit_refuses(self):
        self.exercise(root="standard", sb="none", sb_local_unit=True, sb_vendor=False)
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("no package-owned sing-box unit", r.stderr)
        # refusal happens before any mutation
        self.assertTrue(self.sb_local_unit.exists())
        self.assertIsNone(self.backup)
        self.assertNotIn("installer", self.calls())

    def test_masked_local_singbox_unit_refuses(self):
        self.exercise(root="standard", sb="none", sb_local_unit="masked", sb_vendor="usr")
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("symlink (for example masked)", r.stderr)
        self.assertTrue(self.sb_local_unit.is_symlink())
        self.assertIsNone(self.backup)
        self.assertNotIn("installer", self.calls())

    def test_failed_migration_restores_shadowing_local_unit(self):
        # local unit removed during migration; a later caddy restart failure
        # must restore the exact pre-migration shadowing unit
        self.exercise(sb_local_unit=True, sb_vendor="usr", fail="caddy_restart_fail")
        r = self.result
        self.assertEqual(r.returncode, 1)
        self.assertIn("failed to start", r.stderr)
        self.assertTrue(self.sb_local_unit.exists())
        self.assertEqual(self.sb_local_unit.read_bytes(), self.sb_local_bytes)
        self.assertEqual(self.sbcfg.read_bytes(), self.sbcfg_bytes)


if __name__ == "__main__":
    unittest.main()
