"""Isolated regression tests for install-sing-box-debian.sh.

These tests use mocked systemctl, apt-get, dpk-query, curl, runuser, etc.
They never touch a production machine, real APT, or a real systemd instance.

The script is rewritten on-the-fly to redirect all absolute paths into a
temporary fake filesystem, and all external commands are intercepted via
mock binaries placed first in PATH.

Scenarios covered (task spec section 9):
  1.  Fresh Debian installation                 — test_fresh_debian
  2.  Fresh Ubuntu installation                 — test_fresh_ubuntu
  3.  Existing compliant installation           — test_existing_compliant
  4.  Incorrect directory permissions           — test_fixes_dir_permissions
  5.  Incorrect ordinary file permissions       — test_fixes_file_permissions
  6.  Different service user                    — test_fixes_service_user
  7.  -C instead of -c                          — test_fixes_directory_mode_execstart
  8.  Additional systemd drop-ins               — test_removes_extra_dropins
  9.  Masked service                            — test_unmasks_masked_service
 10.  Package already latest                    — test_already_latest
 11.  GPG key download timeout                  — test_gpg_download_failure
 12.  Valid manually supplied key               — test_valid_manual_key
 13.  Invalid manually supplied key             — test_invalid_manual_key
 14.  APT installation failure                  — test_apt_install_failure
 15.  Configuration validation failure          — test_config_validation_failure
 16.  Service start failure                     — test_service_start_failure
 17.  --no-start on fresh and existing          — test_no_start_fresh / test_no_start_existing
 18.  Repeated installer execution              — test_repeated_execution
 19.  Preserve config content and state         — test_preserves_config_and_state
 20.  Safe handling of symlinks                 — test_symlink_safety / test_symlink_dropin_dir_safety

Additional invariant tests:
  - Key reuse avoids download                   — test_key_reuse_avoids_download
  - Service never masked on success             — test_no_mask_on_success
  - Failure restores active state               — test_failure_restores_active_state
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "sing-box" / "install-sing-box-debian.sh"


class InstallSingBoxTests(unittest.TestCase):
    """Each test builds a fake filesystem and mock binaries, then runs the script."""

    def _run(self, tmpdir, args=None):
        """Execute the installer in an isolated fake environment. Returns (result, env)."""
        args = args or []
        base = Path(tmpdir)
        fs = base / "fs"
        bins = base / "bin"
        state = base / "state"
        calls = base / "calls"
        for d in [fs, bins, state]:
            d.mkdir(parents=True, exist_ok=True)

        # Create base directory structure under fake fs.
        for p in [
            "etc/sing-box",
            "etc/apt/keyrings",
            "etc/apt/sources.list.d",
            "etc/systemd/system/sing-box.service.d",
            "var/lib/sing-box",
            "var/log/sing-box",
            "usr/bin",
            "usr/lib/systemd/system",
            "run",
            "root",
            "etc",
            "var/lib",
            "var/log",
        ]:
            (fs / p).mkdir(parents=True, exist_ok=True)

        # /etc/os-release.
        os_release = getattr(self, "_os_release",
                            'ID=debian\nVERSION_ID=12\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n')
        (fs / "etc/os-release").write_text(os_release)

        # Vendor systemd unit.
        (fs / "usr/lib/systemd/system/sing-box.service").write_text(
            "[Unit]\nDescription=sing-box service\n"
            "[Service]\nType=simple\nUser=sing-box\nGroup=sing-box\n"
            "StateDirectory=sing-box\n"
            "ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run\n"
            "[Install]\nWantedBy=multi-user.target\n"
        )

        # /usr/bin/sing-box mock — handles both direct and runuser invocation.
        check_exit = getattr(self, "_check_exit", 0)
        core = fs / "usr/bin/sing-box"
        core.write_text(
            f"""#!/bin/sh
# Find the subcommand among the arguments.
for arg in "$@"; do
  case "$arg" in
    check) exit {check_exit};;
    version) echo 'sing-box version 1.10.0'; exit 0;;
  esac
done
exit 0
"""
        )
        core.chmod(0o755)

        # State-tracking flags.
        active_flag = state / "active"
        enabled_flag = state / "enabled"
        masked_flag = state / "masked"
        load_state_file = state / "load_state"
        exec_override = state / "exec_override"
        user_override = state / "user_override"

        load_state_file.write_text("loaded")
        if getattr(self, "_was_active", False):
            active_flag.touch()
        if getattr(self, "_was_enabled", False):
            enabled_flag.touch()
        if getattr(self, "_was_masked", False):
            masked_flag.touch()
            load_state_file.write_text("masked")

        # Default effective ExecStart/User from vendor or wrong override.
        wrong_exec = getattr(self, "_wrong_exec", None)
        wrong_user = getattr(self, "_wrong_user", None)
        start_fails = "True" if getattr(self, "_start_fails", False) else "False"

        # The drop-in file path inside the fake filesystem.
        dropin_path = fs / "etc/systemd/system/sing-box.service.d/override.conf"

        # The systemctl mock dynamically reads User/Group/ExecStart from the
        # drop-in file if it exists, otherwise returns the initial (wrong or
        # vendor) values.
        default_exec = wrong_exec or "/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run"
        default_user = wrong_user or "sing-box"

        systemctl_mock = f"""#!/bin/bash
printf '%s\\n' "$*" >> '{calls}'
DROPIN="{dropin_path}"
get_dropin_value() {{
  if [ -f "$DROPIN" ]; then
    grep -E "^$1=" "$DROPIN" | tail -1 | sed "s/^$1=//"
  else
    echo "$2"
  fi
}}
case "$1" in
show)
  case "$*" in
    *LoadState*) cat '{load_state_file}';;
    *ExecStart*)
      exec_line="$(get_dropin_value ExecStart '{default_exec}')"
      bin_path="$(echo "$exec_line" | awk '{{print $1}}')"
      echo "{{ path=$bin_path ; argv[]=$exec_line ; ignore_errors=no ; }}"
      ;;
    *User*) get_dropin_value User '{default_user}';;
    *Group*) get_dropin_value Group '{default_user}';;
  esac;;
is-active) [ -f '{active_flag}' ];;
is-enabled) [ -f '{enabled_flag}' ];;
stop) rm -f '{active_flag}';;
start)
  if [ "{start_fails}" == "True" ]; then exit 1; fi
  touch '{active_flag}';;
restart)
  if [ "{start_fails}" == "True" ]; then exit 1; fi
  touch '{active_flag}';;
enable) touch '{enabled_flag}';;
disable) rm -f '{enabled_flag}';;
mask) touch '{masked_flag}'; echo masked > '{load_state_file}';;
unmask) rm -f '{masked_flag}'; echo loaded > '{load_state_file}';;
daemon-reload) :;;
esac
"""
        self._write_mock(bins, "systemctl", systemctl_mock)

        # runuser — skip -u www-data -- and delegate to the real binary.
        self._write_mock(bins, "runuser",
                         "#!/bin/bash\nshift 2\n[ \"$1\" == \"--\" ] && shift\nexec \"$@\"\n")

        # apt-get mock.
        apt_fail = "True" if getattr(self, "_apt_fail", False) else "False"
        self._write_mock(bins, "apt-get", f"""#!/bin/bash
printf 'apt-get %s\\n' "$*" >> '{calls}'
if [ "{apt_fail}" == "True" ]; then
  case "$*" in *install*) exit 100;; esac
fi
exit 0
""")

        # dpkg-query mock.
        self._write_mock(bins, "dpkg-query", """#!/bin/bash
case "$*" in
  *sing-box-beta*) exit 1;;
  *-f*) printf 'install ok installed\\n';;
  *) exit 0;;
esac
""")

        # curl mock.
        curl_fail = "True" if getattr(self, "_curl_fail", False) else "False"
        key_content = getattr(self, "_key_content",
                              "-----BEGIN PGP PUBLIC KEY BLOCK-----\nfakekey\n-----END PGP PUBLIC KEY BLOCK-----\n")
        # Use a heredoc to avoid quoting issues.
        self._write_mock(bins, "curl", f"""#!/bin/bash
printf 'curl %s\\n' "$*" >> '{calls}'
if [ "{curl_fail}" == "True" ]; then exit 22; fi
while [ $# -gt 0 ]; do
  if [ "$1" == "-o" ]; then
    shift
    cat > "$1" <<'__KEY_EOF__'
{key_content}
__KEY_EOF__
    break
  fi
  shift
done
exit 0
""")

        # gpg mock — always succeeds (key is valid).
        self._write_mock(bins, "gpg", "#!/bin/bash\nexit 0\n")

        # getent mock.
        self._write_mock(bins, "getent", """#!/bin/bash
case "$1" in
  passwd) [ "$2" == "www-data" ] && echo 'www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin' || exit 2;;
  group) [ "$2" == "www-data" ] && echo 'www-data:x:33:' || exit 2;;
  *) exit 1;;
esac
""")

        # dpkg mock.
        self._write_mock(bins, "dpkg", "#!/bin/bash\nexit 0\n")

        # mktemp mock.
        self._write_mock(bins, "mktemp", f"""#!/bin/bash
echo "{fs}/etc/apt/keyrings/.sagernet.asc.$$\"
""")

        # install mock — delegate to real install (works for -d without -o/-g).
        # Strip -o and -g so we don't try real chown as non-root.
        self._write_mock(bins, "install", """#!/bin/bash
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    -d) args+=("-d"); shift;;
    -o) shift 2;;
    -g) shift 2;;
    -m) args+=("-m" "$2"); shift 2;;
    *) args+=("$1"); shift;;
  esac
done
exec /usr/bin/install "${args[@]}"
""")

        # chown mock — no-op (we can't really chown as non-root, and the
        # tests verify mode, not ownership).
        self._write_mock(bins, "chown", "#!/bin/bash\nexit 0\n")

        # chmod mock — delegate to real chmod (works as non-root in tmpdir).
        self._write_mock(bins, "chmod", "#!/bin/bash\nexec /usr/bin/chmod \"$@\"\n")

        # find mock — delegate to real find.
        self._write_mock(bins, "find", "#!/bin/bash\nexec /usr/bin/find \"$@\"\n")

        # cat, grep, command, mv, rm, printf — delegate to real.
        for cmd in ["cat", "grep", "mv", "rm", "printf", "dirname", "touch"]:
            real = f"/usr/bin/{cmd}"
            self._write_mock(bins, cmd, f"#!/bin/bash\nexec {real} \"$@\"\n")

        # command mock — needs special handling.
        self._write_mock(bins, "command", "#!/bin/bash\nexit 0\n")

        # Read and adapt the script — replace ALL absolute paths with fake
        # filesystem paths using a single regex pass to avoid double substitution.
        script_text = SCRIPT.read_text()
        F = str(fs)
        # Build a regex alternation of all paths, longest first.
        raw_paths = [
            "/etc/sing-box/config.json",
            "/etc/apt/keyrings/sagernet.asc",
            "/etc/apt/sources.list.d/sagernet.sources",
            "/etc/systemd/system/sing-box.service.d",
            "/etc/apt/keyrings",
            "/etc/sing-box",
            "/var/lib/sing-box",
            "/var/log/sing-box",
            "/usr/bin/sing-box",
        ]
        # Sort by length descending so longer patterns match first.
        raw_paths.sort(key=len, reverse=True)
        pattern = re.compile("|".join(re.escape(p) for p in raw_paths))
        script_text = pattern.sub(lambda m: F + m.group(0), script_text)
        # Also redirect the os-release sourcing.
        script_text = script_text.replace(". /etc/os-release", f". {F}/etc/os-release")

        local_script = base / "install.sh"
        local_script.write_text(script_text)

        # Write config file if requested.
        if getattr(self, "_has_config", False):
            cfg_content = getattr(self, "_config_content",
                                  '{"log":{"level":"info"},"inbounds":[]}')
            cfg = fs / "etc/sing-box/config.json"
            cfg.write_text(cfg_content)
            cfg.chmod(0o644)

        # Write existing keyring if requested.
        if getattr(self, "_has_existing_key", False):
            key_content = getattr(self, "_existing_key_content",
                                  "-----BEGIN PGP PUBLIC KEY BLOCK-----\nexistingkey\n-----END PGP PUBLIC KEY BLOCK-----\n")
            (fs / "etc/apt/keyrings/sagernet.asc").write_text(key_content)

        # Write existing sources file if requested.
        if getattr(self, "_has_existing_sources", False):
            (fs / "etc/apt/sources.list.d/sagernet.sources").write_text(
                "Types: deb\nURIs: https://deb.sagernet.org/\nSuites: *\n"
                "Components: *\nEnabled: yes\n"
                "Signed-By: /etc/apt/keyrings/sagernet.asc\n"
            )

        # Write extra drop-ins if requested.
        if getattr(self, "_has_extra_dropins", False):
            dd = fs / "etc/systemd/system/sing-box.service.d"
            (dd / "20-resolved.conf").write_text("[Service]\nUser=root\n")
            (dd / "zzzz-single-file.conf").write_text(
                "[Service]\nExecStart=\nExecStart=/usr/bin/sing-box run\n"
            )

        # Write wrong override if requested.
        if getattr(self, "_has_wrong_override", False):
            dd = fs / "etc/systemd/system/sing-box.service.d"
            wu = getattr(self, "_wrong_user", "root")
            we = getattr(self, "_wrong_exec",
                         "/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run")
            (dd / "override.conf").write_text(
                f"[Service]\nUser={wu}\nGroup={wu}\nExecStart=\nExecStart={we}\n"
            )

        # Set wrong permissions if requested.
        if getattr(self, "_wrong_dir_perms", False):
            os.chmod(fs / "etc/sing-box", 0o700)
            os.chmod(fs / "var/lib/sing-box", 0o700)

        if getattr(self, "_wrong_file_perms", False):
            cfg = fs / "etc/sing-box/config.json"
            if cfg.exists():
                os.chmod(cfg, 0o600)

        # Set up symlinks if requested.
        if getattr(self, "_symlink_config", False):
            cfg = fs / "etc/sing-box/config.json"
            if cfg.exists() or cfg.is_symlink():
                cfg.unlink()
            cfg.symlink_to("/dev/null")

        if getattr(self, "_symlink_dropin_dir", False):
            import shutil
            dd = fs / "etc/systemd/system/sing-box.service.d"
            if dd.exists():
                shutil.rmtree(dd)
            dd.symlink_to("/dev/null")

        # Environment.
        env = dict(os.environ)
        env["PATH"] = str(bins) + ":" + env.get("PATH", "/usr/bin:/bin")
        env["EUID"] = "0"
        env["HOME"] = str(base)

        result = subprocess.run(
            ["bash", str(local_script)] + args,
            env=env,
            capture_output=True,
            text=True,
            cwd=str(base),
        )
        return result, base, fs, state, calls

    @staticmethod
    def _write_mock(bins_dir, name, content):
        """Write a mock binary and make it executable."""
        p = bins_dir / name
        p.write_text(content)
        p.chmod(0o755)

    def _succeed(self, result, msg=""):
        self.assertEqual(result.returncode, 0,
                         f"Expected success{msg}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}")

    def _fail(self, result, msg=""):
        self.assertNotEqual(result.returncode, 0,
                            f"Expected failure{msg}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}")

    def _assert_unmasked(self, state):
        self.assertFalse((state / "masked").exists(), "Service should not be masked")

    def _assert_active(self, state):
        self.assertTrue((state / "active").exists(), "Service should be active")

    def _assert_enabled(self, state):
        self.assertTrue((state / "enabled").exists(), "Service should be enabled")

    def _assert_not_active(self, state):
        self.assertFalse((state / "active").exists(), "Service should not be active")

    def _assert_dropin_correct(self, fs):
        dropin = fs / "etc/systemd/system/sing-box.service.d/override.conf"
        self.assertTrue(dropin.exists(), "Drop-in file should exist")
        content = dropin.read_text()
        self.assertIn("User=www-data", content, "Drop-in must set User=www-data")
        self.assertIn("Group=www-data", content, "Drop-in must set Group=www-data")
        # The ExecStart path is substituted to the fake fs in tests, so check
        # for the key structural elements: -c (not -C), run, and config.json.
        self.assertIn("ExecStart=", content)
        self.assertIn("-c ", content, "Drop-in must use -c (single file), not -C (directory)")
        self.assertIn("config.json", content)
        self.assertIn("run", content)
        self.assertNotIn("-C ", content, "Drop-in must not use -C (directory mode)")

    def _assert_no_extra_dropins(self, fs):
        dd = fs / "etc/systemd/system/sing-box.service.d"
        confs = sorted(p.name for p in dd.glob("*.conf"))
        self.assertEqual(confs, ["override.conf"],
                         f"Expected only override.conf, found: {confs}")

    def _assert_perms_correct(self, fs):
        etc_sb = fs / "etc/sing-box"
        self.assertEqual(os.stat(etc_sb).st_mode & 0o777, 0o755,
                         f"/etc/sing-box mode wrong: {oct(os.stat(etc_sb).st_mode & 0o777)}")
        cfg = fs / "etc/sing-box/config.json"
        if cfg.exists():
            self.assertEqual(os.stat(cfg).st_mode & 0o777, 0o644,
                             f"config.json mode wrong: {oct(os.stat(cfg).st_mode & 0o777)}")
        var_lib = fs / "var/lib/sing-box"
        self.assertEqual(os.stat(var_lib).st_mode & 0o777, 0o755,
                         f"/var/lib/sing-box mode wrong: {oct(os.stat(var_lib).st_mode & 0o777)}")

    # ---- Scenario tests ----

    def test_fresh_debian(self):
        """Scenario 1: Fresh Debian installation."""
        self._has_config = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_enabled(state)
            self._assert_dropin_correct(fs)
            self._assert_perms_correct(fs)
            calls_text = calls.read_text() if calls.exists() else ""
            self.assertIn("curl", calls_text, "Should download GPG key on fresh install")

    def test_fresh_ubuntu(self):
        """Scenario 2: Fresh Ubuntu installation."""
        self._has_config = True
        self._os_release = 'ID=ubuntu\nVERSION_ID=22.04\nPRETTY_NAME="Ubuntu 22.04 LTS"\n'
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_enabled(state)
            self._assert_dropin_correct(fs)

    def test_existing_compliant(self):
        """Scenario 3: Existing compliant installation — safe to rerun."""
        self._has_config = True
        self._has_existing_key = True
        self._has_existing_sources = True
        self._was_active = True
        self._was_enabled = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_dropin_correct(fs)
            self._assert_perms_correct(fs)
            # Should not download key again (check for curl command, not package name).
            calls_text = calls.read_text() if calls.exists() else ""
            self.assertFalse(any(l.startswith("curl ") for l in calls_text.splitlines()),
                            "Should not call curl when valid key exists")

    def test_fixes_dir_permissions(self):
        """Scenario 4: Incorrect directory permissions."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        self._wrong_dir_perms = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_perms_correct(fs)

    def test_fixes_file_permissions(self):
        """Scenario 5: Incorrect ordinary file permissions."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        self._wrong_file_perms = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_perms_correct(fs)

    def test_fixes_service_user(self):
        """Scenario 6: Different service user."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        self._has_wrong_override = True
        self._wrong_user = "root"
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_dropin_correct(fs)

    def test_fixes_directory_mode_execstart(self):
        """Scenario 7: -C /etc/sing-box instead of -c."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        self._has_wrong_override = True
        self._wrong_exec = "/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run"
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_dropin_correct(fs)

    def test_removes_extra_dropins(self):
        """Scenario 8: Additional systemd drop-ins."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        self._has_extra_dropins = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_no_extra_dropins(fs)
            self._assert_dropin_correct(fs)

    def test_unmasks_masked_service(self):
        """Scenario 9: Masked service."""
        self._has_config = True
        self._has_existing_key = True
        self._was_masked = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_enabled(state)

    def test_already_latest(self):
        """Scenario 10: Package already latest — safe rerun."""
        self._has_config = True
        self._has_existing_key = True
        self._has_existing_sources = True
        self._was_active = True
        self._was_enabled = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)

    def test_gpg_download_failure(self):
        """Scenario 11: GPG key download timeout or network failure."""
        self._has_config = True
        self._curl_fail = True
        self._was_active = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)
            self.assertIn("sing-box.app/gpg.key", result.stderr,
                          "Should print actionable GPG key message")
            self.assertIn("/etc/apt/keyrings/sagernet.asc", result.stderr)

    def test_valid_manual_key(self):
        """Scenario 12: Valid manually supplied key."""
        self._has_config = True
        self._was_active = True
        with tempfile.TemporaryDirectory() as tmp:
            key_file = Path(tmp) / "sagernet.asc"
            key_file.write_text(
                "-----BEGIN PGP PUBLIC KEY BLOCK-----\nmanualkey\n-----END PGP PUBLIC KEY BLOCK-----\n"
            )
            result, base, fs, state, calls = self._run(tmp, args=["--key-file", str(key_file)])
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            keyring = fs / "etc/apt/keyrings/sagernet.asc"
            self.assertTrue(keyring.exists())
            self.assertIn("manualkey", keyring.read_text())

    def test_invalid_manual_key(self):
        """Scenario 13: Invalid/incomplete manually supplied key (empty file)."""
        self._has_config = True
        with tempfile.TemporaryDirectory() as tmp:
            key_file = Path(tmp) / "sagernet.asc"
            key_file.write_text("")
            result, base, fs, state, calls = self._run(tmp, args=["--key-file", str(key_file)])
            self._fail(result)

    def test_apt_install_failure(self):
        """Scenario 14: APT installation failure."""
        self._has_config = True
        self._apt_fail = True
        self._was_active = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)

    def test_config_validation_failure(self):
        """Scenario 15: Configuration validation failure."""
        self._has_config = True
        self._has_existing_key = True
        self._check_exit = 9
        self._was_active = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)

    def test_service_start_failure(self):
        """Scenario 16: Service start failure."""
        self._has_config = True
        self._has_existing_key = True
        self._start_fails = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)

    def test_no_start_fresh(self):
        """Scenario 17a: --no-start on fresh installation."""
        self._has_config = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp, args=["--no-start"])
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_enabled(state)
            self._assert_not_active(state)

    def test_no_start_existing(self):
        """Scenario 17b: --no-start on existing installation."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        self._was_enabled = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp, args=["--no-start"])
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_enabled(state)
            self._assert_not_active(state)

    def test_repeated_execution(self):
        """Scenario 18: Repeated installer execution."""
        self._has_config = True
        with tempfile.TemporaryDirectory() as tmp:
            # First run.
            result1, base, fs, state, calls = self._run(tmp)
            self._succeed(result1)
            self._assert_active(state)
            self._assert_unmasked(state)
            # Second run — reuse the same filesystem.
            self._was_active = True
            self._was_enabled = True
            self._has_existing_key = True
            self._has_existing_sources = True
            result2, base, fs, state, calls = self._run(tmp)
            self._succeed(result2)
            self._assert_active(state)
            self._assert_unmasked(state)
            self._assert_dropin_correct(fs)
            self._assert_no_extra_dropins(fs)

    def test_preserves_config_and_state(self):
        """Scenario 19: Preserve config content and persistent state."""
        config_content = '{"log":{"level":"warn"},"inbounds":[{"type":"mixed","listen":"::","listen_port":1080}]}'
        self._has_config = True
        self._config_content = config_content
        self._has_existing_key = True
        self._was_active = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            cfg = fs / "etc/sing-box/config.json"
            self.assertEqual(cfg.read_text(), config_content,
                             "Config content must be preserved")
            self.assertTrue((fs / "var/lib/sing-box").exists(),
                            "State directory must be preserved")

    def test_symlink_safety(self):
        """Scenario 20a: Config file is a symlink — should be rejected."""
        self._has_config = True
        self._has_existing_key = True
        self._symlink_config = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result, " — symlinked config should be rejected")
            self._assert_unmasked(state)

    def test_symlink_dropin_dir_safety(self):
        """Scenario 20b: Drop-in directory is a symlink — should be rejected."""
        self._has_config = True
        self._has_existing_key = True
        self._symlink_dropin_dir = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result, " — symlinked drop-in dir should be rejected")
            self._assert_unmasked(state)

    # ---- Additional invariant tests ----

    def test_key_reuse_avoids_download(self):
        """Existing valid GPG key is reused without downloading."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            calls_text = calls.read_text() if calls.exists() else ""
            self.assertFalse(any(l.startswith("curl ") for l in calls_text.splitlines()),
                            "Should not call curl when valid key exists")

    def test_no_mask_on_success(self):
        """Service is never masked during normal installation."""
        self._has_config = True
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            calls_text = calls.read_text() if calls.exists() else ""
            # Check that no line starts with "mask " (excludes "unmask").
            self.assertFalse(any(l.startswith("mask ") for l in calls_text.splitlines()),
                             "Should never mask the service on success")
            self._assert_unmasked(state)

    def test_failure_restores_active_state(self):
        """Previously active service is restored on failure."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        self._check_exit = 9
        with tempfile.TemporaryDirectory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            calls_text = calls.read_text() if calls.exists() else ""
            self.assertIn("start sing-box", calls_text,
                          "Should attempt to restore active state on failure")
            self._assert_unmasked(state)


if __name__ == "__main__":
    unittest.main()
