"""Isolated regression tests for install-sing-box-debian.sh.

These tests use mocked systemctl, apt-get, dpkg-query, curl, gpg, runuser,
etc. They never touch a real APT repository, systemd instance, or service.
The script is rewritten on the fly to redirect its absolute paths into a
temporary fake filesystem, and external commands are intercepted via mock
binaries placed first in PATH.

These are mocked regression tests, not Debian/Ubuntu integration tests.
"""
import os
import re
import shutil
import subprocess
import tempfile
import unittest
import uuid
from contextlib import contextmanager
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "sing-box" / "install-sing-box-debian.sh"
GIT_BASH = Path(r"C:\Program Files\Git\bin")
BASH = str(GIT_BASH / "bash.exe") if (GIT_BASH / "bash.exe").exists() else "bash"
OFFICIAL_FPR = "2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C"


def bash_path(path):
    """Translate a Windows path to the form MSYS/Git Bash understands."""
    if os.name != "nt":
        return str(path)
    drive, rest = os.path.splitdrive(str(path))
    if drive:
        return "/" + drive[0].lower() + rest.replace("\\", "/")
    return str(path).replace("\\", "/")


@contextmanager
def temporary_directory():
    """A temp dir that also works under restrictive Windows sandbox ACLs."""
    if os.name != "nt":
        with tempfile.TemporaryDirectory() as tmp:
            yield tmp
        return
    root = Path(tempfile.gettempdir()) / f"sing-box-installer-test-{uuid.uuid4().hex}"
    root.mkdir()
    try:
        yield str(root)
    finally:
        shutil.rmtree(root, ignore_errors=True)


class InstallSingBoxTests(unittest.TestCase):
    """Each test builds a fake filesystem and mock binaries, then runs the script."""

    def _run(self, tmpdir, args=None):
        args = list(args or [])
        base = Path(tmpdir)
        fs = base / "fs"
        bins = base / "bin"
        state = base / "state"
        calls = base / "calls"
        for d in (fs, bins, state):
            d.mkdir(parents=True, exist_ok=True)
        (base / "tmp").mkdir(exist_ok=True)
        calls.write_text("")

        for p in [
            "etc/sing-box",
            "etc/apt/keyrings",
            "etc/apt/sources.list.d",
            "etc/ssl/certs",
            "etc/systemd/system/sing-box.service.d",
            "run/systemd/system",
            "var/lib/sing-box",
            "var/log/sing-box",
            "usr/bin",
            "usr/lib/systemd/system",
            "root",
            "etc",
            "var/lib",
            "var/log",
        ]:
            (fs / p).mkdir(parents=True, exist_ok=True)

        os_release = getattr(
            self,
            "_os_release",
            'ID=debian\nVERSION_ID=12\nPRETTY_NAME="Debian GNU/Linux 12 (bookworm)"\n',
        )
        (fs / "etc/os-release").write_text(os_release)
        (fs / "etc/ssl/certs/ca-certificates.crt").write_text("test CA bundle\n")

        vendor_unit = fs / "usr/lib/systemd/system/sing-box.service"
        vendor_unit.write_text(
            "[Unit]\nDescription=sing-box service\n"
            "[Service]\nType=simple\nUser=sing-box\nGroup=sing-box\n"
            "StateDirectory=sing-box\n"
            "ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run\n"
            "[Install]\nWantedBy=multi-user.target\n"
        )
        if getattr(self, "_vendor_unit_missing", False):
            vendor_unit.unlink()

        check_exit = getattr(self, "_check_exit", 0)
        core = fs / "usr/bin/sing-box"
        core.write_text(
            f"""#!/bin/sh
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

        active_flag = state / "active"
        enabled_flag = state / "enabled"
        masked_flag = state / "masked"
        failed_flag = state / "failed"
        load_state_file = state / "load_state"
        load_state_file.write_text("loaded")
        if getattr(self, "_was_active", False):
            active_flag.touch()
        if getattr(self, "_was_enabled", False):
            enabled_flag.touch()
        if getattr(self, "_was_masked", False):
            masked_flag.touch()
            load_state_file.write_text("masked")

        F = bash_path(fs)
        calls_s = bash_path(calls)
        state_s = bash_path(state)
        vendor_s = F + "/usr/lib/systemd/system/sing-box.service"
        local_unit_s = F + "/etc/systemd/system/sing-box.service"
        start_fails = "1" if getattr(self, "_start_fails", False) else "0"
        start_noop = "1" if getattr(self, "_start_returns_zero_but_inactive", False) else "0"
        stop_fails = "1" if getattr(self, "_stop_fails", False) else "0"
        enable_fails = "1" if getattr(self, "_enable_fails", False) else "0"
        restart_fail_once = "1" if getattr(self, "_restart_fail_once", False) else "0"
        state_dir_mode = getattr(self, "_state_dir_mode", "0755")
        fragment_path = getattr(self, "_fragment_path", vendor_s)

        systemctl_mock = r"""#!/bin/bash
printf '%s\n' "$*" >> '@CALLS@'
FAKE='@FS@'
ACTIVE='@STATE@/active'
ENABLED='@STATE@/enabled'
MASKED='@STATE@/masked'
FAILED='@STATE@/failed'
LOAD_STATE='@STATE@/load_state'

effective_values() {
  local user='sing-box' group='sing-box' exec='@FS@/usr/bin/sing-box -D @FS@/var/lib/sing-box -C @FS@/etc/sing-box run'
  local f line val
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        User=*) user="${line#User=}" ;;
        Group=*) group="${line#Group=}" ;;
        ExecStart=) exec='' ;;
        ExecStart=*) val="${line#ExecStart=}"
          if [ -z "$exec" ]; then exec="$val"; else exec="$exec ; $val"; fi ;;
      esac
    done < "$f"
  done < <(find "$FAKE/etc/systemd/system/sing-box.service.d" "$FAKE/run/systemd/system/sing-box.service.d" \
             -maxdepth 1 -type f -name '*.conf' -printf '%f\t%p\n' 2>/dev/null \
           | sort -k1,1 -k2,2 | cut -f2-)
  printf '%s\n%s\n%s\n' "$user" "$group" "$exec"
}

case "$1" in
  show)
    case "$*" in
      *LoadState*) cat "$LOAD_STATE" ;;
      *FragmentPath*) echo '@FRAGMENT@' ;;
      *StateDirectoryMode*) echo '@STATE_DIR_MODE@' ;;
      *ExecStart*)
        mapfile -t vals < <(effective_values)
        line="${vals[2]}"
        bin="${line%% *}"
        echo "{ path=$bin ; argv[]=$line ; ignore_errors=no ; }"
        ;;
      *User*) effective_values | sed -n '1p' ;;
      *Group*) effective_values | sed -n '2p' ;;
    esac
    ;;
  is-active)
    if [ -f "$ACTIVE" ]; then
      [ "$*" = 'is-active sing-box' ] && echo active
      exit 0
    fi
    [ "$*" = 'is-active sing-box' ] && echo inactive
    exit 3
    ;;
  is-enabled)
    if [ -f "$ENABLED" ]; then
      [ "$*" = 'is-enabled sing-box' ] && echo enabled
      exit 0
    fi
    [ "$*" = 'is-enabled sing-box' ] && echo disabled
    exit 1
    ;;
  is-failed)
    if [ -f "$FAILED" ]; then
      [ "$*" = 'is-failed sing-box' ] && echo failed
      exit 0
    fi
    exit 1
    ;;
  stop)
    if [ '@STOP_FAILS@' = '1' ]; then exit 1; fi
    rm -f "$ACTIVE" "$FAILED"
    ;;
  start|restart)
    if [ '@START_FAILS@' = '1' ]; then
      touch "$FAILED"
      exit 1
    fi
    if [ '@START_NOOP@' = '1' ]; then
      exit 0
    fi
    if [ '@RESTART_FAIL_ONCE@' = '1' ] && [ -f '@STATE@/restart_attempted' ]; then
      :
    elif [ '@RESTART_FAIL_ONCE@' = '1' ]; then
      touch '@STATE@/restart_attempted'
      rm -f "$ACTIVE"
      touch "$FAILED"
      exit 1
    fi
    rm -f "$FAILED"
    touch "$ACTIVE"
    ;;
  enable)
    if [ '@ENABLE_FAILS@' = '1' ]; then exit 1; fi
    touch "$ENABLED"
    ;;
  disable) rm -f "$ENABLED" ;;
  mask) touch "$MASKED"; echo masked > "$LOAD_STATE" ;;
  unmask) rm -f "$MASKED"; echo loaded > "$LOAD_STATE" ;;
  daemon-reload) : ;;
esac
"""
        systemctl_mock = (
            systemctl_mock.replace("@CALLS@", calls_s)
            .replace("@FS@", F)
            .replace("@STATE@", state_s)
            .replace("@START_FAILS@", start_fails)
            .replace("@START_NOOP@", start_noop)
            .replace("@STOP_FAILS@", stop_fails)
            .replace("@ENABLE_FAILS@", enable_fails)
            .replace("@RESTART_FAIL_ONCE@", restart_fail_once)
            .replace("@STATE_DIR_MODE@", state_dir_mode)
            .replace("@FRAGMENT@", fragment_path)
        )
        self._write_mock(bins, "systemctl", systemctl_mock)
        self._write_mock(bins, "journalctl", "#!/bin/bash\nexit 0\n")

        self._write_mock(
            bins,
            "runuser",
            '#!/bin/bash\nshift 2\n[ "$1" == "--" ] && shift\nexec "$@"\n',
        )

        apt_fail = "1" if getattr(self, "_apt_fail", False) else "0"
        apt_upgrade = "1" if getattr(self, "_package_upgrade", False) else "0"
        self._write_mock(
            bins,
            "apt-get",
            f"""#!/bin/bash
printf 'apt-get %s\\n' "$*" >> '{calls_s}'
if [ '{apt_upgrade}' = '1' ]; then
  case "$*" in *install*) echo '1.11.0' > '{state_s}/version';; esac
fi
if [ '{apt_fail}' = '1' ]; then
  case "$*" in *install*) exit 100;; esac
fi
exit 0
""",
        )

        self._write_mock(
            bins,
            "dpkg-query",
            f"""#!/bin/bash
case "$*" in
  *sing-box-beta*) exit 1;;
  *'${{Version}}'*) if [ -f '{state_s}/version' ]; then cat '{state_s}/version'; else printf '1.10.0\\n'; fi;;
  *'${{Status}}'*) printf 'install ok installed\\n';;
  *-L*|*--listfiles*) printf '%s\\n' '{vendor_s}';;
  *) exit 0;;
esac
""",
        )

        curl_fail = "1" if getattr(self, "_curl_fail", False) else "0"
        key_content = getattr(self, "_key_content", "VALID_OFFICIAL_KEY\n")
        curl_mock = r"""#!/bin/bash
printf 'curl %s\n' "$*" >> '@CALLS@'
if [ '@CURL_FAIL@' = '1' ]; then exit 22; fi
while [ $# -gt 0 ]; do
  if [ "$1" = '-o' ]; then
    shift
    cat > "$1" <<'__KEY_EOF__'
@KEY_CONTENT@
__KEY_EOF__
    break
  fi
  shift
done
exit 0
"""
        curl_mock = (
            curl_mock.replace("@CALLS@", calls_s)
            .replace("@CURL_FAIL@", curl_fail)
            .replace("@KEY_CONTENT@", key_content.rstrip("\n"))
        )
        self._write_mock(bins, "curl", curl_mock)

        gpg_mock = r"""#!/bin/bash
printf 'gpg %s\n' "$*" >> '@CALLS@'
file=''
for arg in "$@"; do file="$arg"; done
if ! grep -q 'VALID_OFFICIAL_KEY' "$file" 2>/dev/null; then
  echo 'pub:u:2048:1:DEADBEEFDEADBEEF:0:0::::::23::0:'
  echo 'fpr:::::::::DEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF:'
  exit 2
fi
echo 'pub:u:4096:1:6D9152172A2B2F0C:0:0::::::23::0:'
echo 'fpr:::::::::@FPR@:'
if grep -q 'SECOND_KEY' "$file" 2>/dev/null; then
  echo 'pub:u:4096:1:AAAAAAAAAAAAAAAA:0:0::::::23::0:'
  echo 'fpr:::::::::AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA:'
fi
"""
        self._write_mock(bins, "gpg", gpg_mock.replace("@FPR@", OFFICIAL_FPR).replace("@CALLS@", calls_s))

        self._write_mock(
            bins,
            "getent",
            """#!/bin/bash
case "$1" in
  passwd) [ "$2" == "www-data" ] && echo 'www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin' || exit 2;;
  group) [ "$2" == "www-data" ] && echo 'www-data:x:33:' || exit 2;;
  *) exit 1;;
esac
""",
        )
        self._write_mock(bins, "dpkg", "#!/bin/bash\nexit 0\n")
        self._write_mock(
            bins,
            "install",
            """#!/bin/bash
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
""",
        )
        self._write_mock(bins, "chown", "#!/bin/bash\nexit 0\n")
        self._write_mock(bins, "chmod", "#!/bin/bash\nexec /usr/bin/chmod \"$@\"\n")
        self._write_mock(bins, "find", "#!/bin/bash\nexec /usr/bin/find \"$@\"\n")

        script_text = SCRIPT.read_text(encoding="utf-8")
        raw_paths = [
            "/etc/sing-box/config.json",
            "/etc/apt/keyrings/sagernet.asc",
            "/etc/apt/sources.list.d/sagernet.sources",
            "/etc/systemd/system/sing-box.service.d",
            "/run/systemd/system/sing-box.service.d",
            "/etc/systemd/system/sing-box.service",
            "/usr/lib/systemd/system/sing-box.service",
            "/etc/apt/keyrings",
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/sing-box",
            "/var/lib/sing-box",
            "/var/log/sing-box",
            "/usr/bin/sing-box",
        ]
        raw_paths.sort(key=len, reverse=True)
        pattern = re.compile("|".join(re.escape(p) for p in raw_paths))
        script_text = pattern.sub(lambda m: F + m.group(0), script_text)
        script_text = script_text.replace(". /etc/os-release", f". {F}/etc/os-release")
        # Root is required in production; the test filesystem is isolated and
        # the ownership-changing commands are mocked.
        script_text = script_text.replace(
            '[[ ${EUID} -eq 0 ]] || die "Run this script as root."',
            "true # root check bypassed by the isolated test harness",
        )
        local_script = base / "install.sh"
        local_script.write_text(script_text)

        if getattr(self, "_has_config", False):
            cfg_content = getattr(self, "_config_content", '{"log":{"level":"info"},"inbounds":[]}')
            cfg = fs / "etc/sing-box/config.json"
            cfg.write_text(cfg_content)
            cfg.chmod(0o644)

        if getattr(self, "_has_existing_key", False):
            key_content = getattr(self, "_existing_key_content", "VALID_OFFICIAL_KEY\n")
            (fs / "etc/apt/keyrings/sagernet.asc").write_text(key_content)

        if getattr(self, "_has_existing_sources", False):
            (fs / "etc/apt/sources.list.d/sagernet.sources").write_text(self._desired_sources(fs))

        if getattr(self, "_has_correct_dropin", False):
            (fs / "etc/systemd/system/sing-box.service.d/override.conf").write_text(
                self._desired_dropin(fs)
            )

        if getattr(self, "_has_extra_dropins", False):
            dd = fs / "etc/systemd/system/sing-box.service.d"
            (dd / "20-resolved.conf").write_text("[Service]\nUser=root\n")
            (dd / "zzzz-single-file.conf").write_text(
                "[Service]\nExecStart=\nExecStart=/usr/bin/sing-box run\n"
            )

        if getattr(self, "_has_runtime_dropin", False):
            rd = fs / "run/systemd/system/sing-box.service.d"
            rd.mkdir(parents=True, exist_ok=True)
            (rd / "zzzz-runtime.conf").write_text(
                "[Service]\nExecStart=\nExecStart=/usr/bin/sing-box run\n"
            )

        if getattr(self, "_has_wrong_override", False):
            dd = fs / "etc/systemd/system/sing-box.service.d"
            wu = getattr(self, "_wrong_user", "root")
            we = getattr(
                self,
                "_wrong_exec",
                "/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run",
            )
            (dd / "override.conf").write_text(
                f"[Service]\nUser={wu}\nGroup={wu}\nExecStart=\nExecStart={we}\n"
            )

        if getattr(self, "_has_local_unit", False):
            (fs / "etc/systemd/system/sing-box.service").write_text(
                "[Service]\nUser=root\nExecStart=/usr/bin/sing-box run\n"
            )

        if getattr(self, "_has_directory_mode_inputs", False):
            (fs / "etc/sing-box/extra.json").write_text('{"log":{"level":"debug"}}\n')
            (fs / "etc/sing-box/extra.jsonc").write_text('{"log":{"level":"warn"}}\n')

        if getattr(self, "_wrong_dir_perms", False):
            os.chmod(fs / "etc/sing-box", 0o700)
            os.chmod(fs / "var/lib/sing-box", 0o700)

        if getattr(self, "_wrong_file_perms", False):
            cfg = fs / "etc/sing-box/config.json"
            if cfg.exists():
                os.chmod(cfg, 0o600)

        if getattr(self, "_symlink_config", False):
            cfg = fs / "etc/sing-box/config.json"
            if cfg.exists() or cfg.is_symlink():
                cfg.unlink()
            cfg.symlink_to("/dev/null")

        if getattr(self, "_symlink_dropin_dir", False):
            dd = fs / "etc/systemd/system/sing-box.service.d"
            if dd.exists():
                shutil.rmtree(dd)
            dd.symlink_to("/dev/null")

        env = dict(os.environ)
        env["PATH"] = ":".join(
            [bash_path(bins), bash_path(GIT_BASH) if GIT_BASH.exists() else "", "/usr/local/bin", "/usr/bin", "/bin"]
        )
        env["HOME"] = bash_path(base)
        env["TMPDIR"] = bash_path(base / "tmp")

        result = subprocess.run(
            [BASH, bash_path(local_script)]
            + [bash_path(arg) if re.match(r"^[A-Za-z]:[\\/]", arg) else arg for arg in args],
            env=env,
            capture_output=True,
            text=True,
            cwd=str(base),
        )
        return result, base, fs, state, calls

    @staticmethod
    def _write_mock(bins_dir, name, content):
        p = bins_dir / name
        p.write_text(content)
        p.chmod(0o755)

    @staticmethod
    def _desired_dropin(fs):
        f = bash_path(fs)
        return (
            "[Service]\n"
            "User=www-data\n"
            "Group=www-data\n"
            "StateDirectoryMode=0755\n"
            "ExecStart=\n"
            f"ExecStart={f}/usr/bin/sing-box -D {f}/var/lib/sing-box "
            f"-c {f}/etc/sing-box/config.json run\n"
        )

    @staticmethod
    def _desired_sources(fs):
        return (
            "Types: deb\n"
            "URIs: https://deb.sagernet.org/\n"
            "Suites: *\n"
            "Components: *\n"
            "Enabled: yes\n"
            f"Signed-By: {bash_path(fs)}/etc/apt/keyrings/sagernet.asc\n"
        )

    def _succeed(self, result, msg=""):
        self.assertEqual(
            result.returncode,
            0,
            f"Expected success{msg}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}",
        )

    def _fail(self, result, msg=""):
        self.assertNotEqual(
            result.returncode,
            0,
            f"Expected failure{msg}\nSTDOUT:\n{result.stdout}\nSTDERR:\n{result.stderr}",
        )

    @staticmethod
    def _calls(calls):
        return calls.read_text().splitlines() if calls.exists() else []

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
        self.assertEqual(dropin.read_text(), self._desired_dropin(fs))
        content = dropin.read_text()
        self.assertIn("User=www-data", content)
        self.assertIn("Group=www-data", content)
        self.assertIn("-c ", content)
        self.assertNotIn("-C ", content)
        self.assertIn("config.json", content)
        self.assertIn("run", content)

    def _assert_no_extra_dropins(self, fs):
        dd = fs / "etc/systemd/system/sing-box.service.d"
        confs = sorted(p.name for p in dd.glob("*.conf"))
        self.assertEqual(confs, ["override.conf"], f"Expected only override.conf, found: {confs}")
        rd = fs / "run/systemd/system/sing-box.service.d"
        if rd.exists():
            self.assertEqual(sorted(p.name for p in rd.glob("*.conf")), [])

    def _assert_perms_correct(self, fs):
        etc_sb = fs / "etc/sing-box"
        self.assertEqual(os.stat(etc_sb).st_mode & 0o777, 0o755)
        cfg = fs / "etc/sing-box/config.json"
        if cfg.exists():
            self.assertEqual(os.stat(cfg).st_mode & 0o777, 0o644)
        var_lib = fs / "var/lib/sing-box"
        self.assertEqual(os.stat(var_lib).st_mode & 0o777, 0o755)

    def _assert_not_interrupted(self, calls):
        lines = self._calls(calls)
        for verb in ("stop", "start", "restart"):
            self.assertNotIn(
                f"{verb} sing-box",
                lines,
                f"Compliant rerun must not issue 'systemctl {verb}': {lines}",
            )

    # ---- Scenario tests ----

    def test_fresh_debian(self):
        """Scenario 1: Fresh Debian installation."""
        self._has_config = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_enabled(state)
            self._assert_dropin_correct(fs)
            self._assert_perms_correct(fs)
            self.assertIn("curl", "\n".join(self._calls(calls)))
            self.assertIn("gpg", "\n".join(self._calls(calls)))
            self.assertIn("--force-confold", "\n".join(self._calls(calls)))

    def test_fresh_ubuntu(self):
        """Scenario 2: Fresh Ubuntu installation."""
        self._has_config = True
        self._os_release = 'ID=ubuntu\nVERSION_ID=22.04\nPRETTY_NAME="Ubuntu 22.04 LTS"\n'
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_enabled(state)
            self._assert_dropin_correct(fs)

    def test_existing_compliant_is_non_disruptive(self):
        """Scenario 3: Existing compliant installation — no stop/restart/rewrite."""
        self._has_config = True
        self._has_existing_key = True
        self._has_existing_sources = True
        self._has_correct_dropin = True
        self._was_active = True
        self._was_enabled = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_not_interrupted(calls)
            self._assert_dropin_correct(fs)
            self._assert_perms_correct(fs)
            lines = self._calls(calls)
            self.assertFalse(any(line.startswith("curl ") for line in lines), "valid key must be reused")
            self.assertFalse(any(line.startswith("daemon-reload") for line in lines))

    def test_parse_failure_before_service_state_does_not_touch_service(self):
        """A pre-state parse failure must not enable/disable/stop the service."""
        self._has_config = True
        self._was_active = True
        self._was_enabled = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp, args=["--not-an-option"])
            self._fail(result)
            self._assert_active(state)
            self._assert_enabled(state)
            lines = self._calls(calls)
            for verb in ("stop", "start", "restart", "enable", "disable", "mask"):
                self.assertFalse(
                    any(line == f"{verb} sing-box" for line in lines),
                    f"unexpected systemctl {verb}: {lines}",
                )

    def test_local_unit_shadowing_fails_before_changes(self):
        """A local main unit must not be silently overridden by the vendor unit."""
        self._has_config = True
        self._has_local_unit = True
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("shadows the package-owned vendor unit", result.stderr)
            self._assert_active(state)
            self.assertTrue((fs / "etc/systemd/system/sing-box.service").exists())
            lines = self._calls(calls)
            self.assertFalse(any(line.startswith("apt-get ") for line in lines))
            self.assertFalse(any(line.startswith("curl ") for line in lines))
            self.assertNotIn("daemon-reload", lines)
            self._assert_not_interrupted(calls)

    def test_directory_mode_extra_inputs_fail_before_changes(self):
        """Directory-mode inputs must not be silently dropped by switching to -c."""
        self._has_config = True
        self._has_directory_mode_inputs = True
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("additional inputs", result.stderr)
            self._assert_active(state)
            self.assertTrue((fs / "etc/sing-box/extra.json").exists())
            lines = self._calls(calls)
            self.assertFalse(any(line.startswith("apt-get ") for line in lines))
            self.assertFalse(any(line.startswith("curl ") for line in lines))
            self._assert_not_interrupted(calls)

    def test_fixes_dir_permissions(self):
        """Scenario 4: Incorrect directory permissions."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._wrong_dir_perms = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_perms_correct(fs)

    def test_fixes_file_permissions(self):
        """Scenario 5: Incorrect ordinary file permissions."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._wrong_file_perms = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_perms_correct(fs)

    def test_fixes_service_user(self):
        """Scenario 6: Different service user."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._wrong_user = "root"
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_dropin_correct(fs)
            self.assertIn("restart sing-box", self._calls(calls))

    def test_fixes_directory_mode_execstart(self):
        """Scenario 7: -C /etc/sing-box instead of -c."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._wrong_exec = "/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run"
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_dropin_correct(fs)

    def test_removes_extra_dropins(self):
        """Scenario 8: Additional systemd drop-ins, including runtime copies."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._has_extra_dropins = True
        self._has_runtime_dropin = True
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_no_extra_dropins(fs)
            self._assert_dropin_correct(fs)

    def test_unmasks_masked_service(self):
        """Scenario 9: Masked service."""
        self._has_config = True
        self._has_existing_key = True
        self._was_masked = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_enabled(state)

    def test_masked_service_is_unmasked_even_when_install_fails(self):
        """A pre-existing mask is not retained after a failed installation."""
        self._has_config = True
        self._curl_fail = True
        self._was_masked = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)
            self.assertIn("unmask sing-box", self._calls(calls))
            self.assertIn("daemon-reload", self._calls(calls))

    def test_already_latest(self):
        """Scenario 10: Package already latest — safe rerun."""
        self._has_config = True
        self._has_existing_key = True
        self._has_existing_sources = True
        self._has_correct_dropin = True
        self._was_active = True
        self._was_enabled = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_not_interrupted(calls)

    def test_gpg_download_failure_does_not_stop_active_service(self):
        """Scenario 11: GPG download failure must not interrupt a running service."""
        self._has_config = True
        self._curl_fail = True
        self._was_active = True
        self._was_enabled = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_not_interrupted(calls)
            self.assertIn("sing-box.app/gpg.key", result.stderr)
            self.assertIn("/etc/apt/keyrings/sagernet.asc", result.stderr)
            self.assertNotIn("apt-get", "\n".join(self._calls(calls)))

    def test_valid_manual_key(self):
        """Scenario 12: Valid manually supplied key with the official fingerprint."""
        self._has_config = True
        self._was_active = True
        with temporary_directory() as tmp:
            key_file = Path(tmp) / "sagernet.asc"
            key_file.write_text("VALID_OFFICIAL_KEY\n")
            result, base, fs, state, calls = self._run(tmp, args=["--key-file", str(key_file)])
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            keyring = fs / "etc/apt/keyrings/sagernet.asc"
            self.assertEqual(keyring.read_text(), "VALID_OFFICIAL_KEY\n")
            self.assertFalse(any(line.startswith("curl ") for line in self._calls(calls)))

    def test_invalid_manual_key_is_rejected_without_interruption(self):
        """Scenario 13: Non-empty but wrong-fingerprint manual key must fail."""
        self._has_config = True
        self._was_active = True
        with temporary_directory() as tmp:
            key_file = Path(tmp) / "sagernet.asc"
            key_file.write_text("WRONG_KEY\n")
            result, base, fs, state, calls = self._run(tmp, args=["--key-file", str(key_file)])
            self._fail(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_not_interrupted(calls)
            self.assertIn("fingerprint", result.stderr)
            self.assertFalse((fs / "etc/apt/keyrings/sagernet.asc").exists())

    def test_invalid_manual_key_is_not_ignored_when_valid_key_exists(self):
        """An explicitly supplied bad key must fail rather than be silently ignored."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        with temporary_directory() as tmp:
            key_file = Path(tmp) / "sagernet.asc"
            key_file.write_text("WRONG_KEY\n")
            result, base, fs, state, calls = self._run(tmp, args=["--key-file", str(key_file)])
            self._fail(result)
            self._assert_active(state)
            self.assertIn("Local key is not the official", result.stderr)
            self.assertEqual(
                (fs / "etc/apt/keyrings/sagernet.asc").read_text(), "VALID_OFFICIAL_KEY\n"
            )

    def test_failed_apt_upgrade_is_detected_and_service_recovered(self):
        """A non-zero APT exit can still change the package; recovery notices it."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._was_active = True
        self._was_enabled = True
        self._package_upgrade = True
        self._apt_fail = True
        old_dropin = (
            "[Service]\nUser=root\nGroup=root\nExecStart=\n"
            "ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run\n"
        )
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_active(state)
            dropin = fs / "etc/systemd/system/sing-box.service.d/override.conf"
            self.assertEqual(dropin.read_text(), old_dropin)
            # apt changed the package but the running process was never
            # restarted; rollback must not interrupt the still-healthy service.
            self.assertNotIn("restart sing-box", self._calls(calls))

    def test_package_change_restarts_running_service(self):
        """A package upgrade restarts the running service once it is applied."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._was_enabled = True
        self._package_upgrade = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self.assertIn("restart sing-box", self._calls(calls))
            self._assert_active(state)

    def test_package_change_failure_restores_old_dropin(self):
        """A later failure with a changed package still restores unit configuration."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._was_active = True
        self._was_enabled = True
        self._package_upgrade = True
        self._check_exit = 9
        old_dropin = (
            "[Service]\nUser=root\nGroup=root\nExecStart=\n"
            "ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run\n"
        )
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_active(state)
            dropin = fs / "etc/systemd/system/sing-box.service.d/override.conf"
            self.assertEqual(dropin.read_text(), old_dropin)
            self.assertNotIn("restart sing-box", self._calls(calls))

    def test_apt_install_failure_restores_service_and_dropin(self):
        """Scenario 14: APT failure after drop-in replacement restores prior state."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._apt_fail = True
        self._was_active = True
        self._was_enabled = True
        old_dropin = (
            "[Service]\nUser=root\nGroup=root\nExecStart=\n"
            "ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run\n"
        )
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            dropin = fs / "etc/systemd/system/sing-box.service.d/override.conf"
            self.assertEqual(dropin.read_text(), old_dropin)
            self.assertNotIn("restart sing-box", self._calls(calls))

    def test_config_validation_failure_restores_dropin_and_permissions(self):
        """Scenario 15: Config failure restores drop-in content and modes."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._wrong_dir_perms = True
        self._wrong_file_perms = True
        self._check_exit = 9
        self._was_active = True
        old_dropin = (
            "[Service]\nUser=root\nGroup=root\nExecStart=\n"
            "ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run\n"
        )
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            dropin = fs / "etc/systemd/system/sing-box.service.d/override.conf"
            self.assertEqual(dropin.read_text(), old_dropin)
            self.assertEqual(os.stat(fs / "etc/sing-box").st_mode & 0o777, 0o700)
            self.assertEqual(os.stat(fs / "etc/sing-box/config.json").st_mode & 0o777, 0o600)
            self.assertNotIn("restart sing-box", self._calls(calls))

    def test_service_start_failure_is_reported(self):
        """Scenario 16: Start failure must fail and not leave a masked service."""
        self._has_config = True
        self._has_existing_key = True
        self._start_fails = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)
            self._assert_not_active(state)

    def test_state_directory_mode_0750_is_rejected_before_runtime_transition(self):
        """A stale StateDirectoryMode=0750 must fail without restarting."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._state_dir_mode = "0750"
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("StateDirectoryMode is not 0755", result.stderr)
            self._assert_active(state)
            self._assert_not_interrupted(calls)

    def test_missing_package_vendor_unit_is_rejected(self):
        """An incomplete package layout must not be reported as normalized."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._vendor_unit_missing = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("vendor unit is missing", result.stderr)
            self._assert_active(state)
            self._assert_not_interrupted(calls)

    def test_vendor_unit_fragment_mismatch_is_rejected(self):
        """The effective unit must be the package-owned vendor unit."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._fragment_path = "/etc/systemd/system/sing-box.service"
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("not the package-owned vendor unit", result.stderr)
            self._assert_active(state)
            self._assert_not_interrupted(calls)

    def test_restart_failure_after_runtime_transition_restores_old_dropin(self):
        """Recovery restarts only after a restart actually changed runtime state."""
        self._has_config = True
        self._has_existing_key = True
        self._has_wrong_override = True
        self._was_active = True
        self._was_enabled = True
        self._restart_fail_once = True
        old_dropin = (
            "[Service]\nUser=root\nGroup=root\nExecStart=\n"
            "ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -C /etc/sing-box run\n"
        )
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_active(state)
            dropin = fs / "etc/systemd/system/sing-box.service.d/override.conf"
            self.assertEqual(dropin.read_text(), old_dropin)
            lines = self._calls(calls)
            self.assertEqual(
                sum(1 for line in lines if line == "restart sing-box"),
                1,
                f"failed restart stopped the process; rollback should start it: {lines}",
            )
            self.assertIn("start sing-box", lines)

    def test_start_returning_zero_but_inactive_is_reported(self):
        """A zero exit from systemctl start is not sufficient runtime validation."""
        self._has_config = True
        self._has_existing_key = True
        self._start_returns_zero_but_inactive = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("not active", result.stderr)
            self._assert_unmasked(state)

    def test_no_start_fresh(self):
        """Scenario 17a: --no-start on fresh installation."""
        self._has_config = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp, args=["--no-start"])
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_enabled(state)
            self._assert_not_active(state)

    def test_no_start_existing(self):
        """Scenario 17b: --no-start on existing installation."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._was_enabled = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp, args=["--no-start"])
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_enabled(state)
            self._assert_not_active(state)
            self.assertIn("stop sing-box", self._calls(calls))

    def test_no_start_propagates_stop_failure(self):
        """--no-start must not report success if the service remains active."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._was_enabled = True
        self._stop_fails = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp, args=["--no-start"])
            self._fail(result)
            self.assertIn("still active despite --no-start", result.stderr)
            self._assert_active(state)

    def test_enable_failure_is_reported(self):
        """Enablement failure must fail rather than silently leave disabled."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._enable_fails = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("Failed to enable sing-box", result.stderr)
            self._assert_active(state)

    def test_repeated_execution(self):
        """Scenario 18: Repeated installer execution."""
        self._has_config = True
        with temporary_directory() as tmp:
            result1, base, fs, state, calls1 = self._run(tmp)
            self._succeed(result1)
            self._assert_active(state)
            self._assert_unmasked(state)

            self._was_active = True
            self._was_enabled = True
            result2, base, fs, state, calls2 = self._run(tmp)
            self._succeed(result2)
            self._assert_active(state)
            self._assert_unmasked(state)
            self._assert_dropin_correct(fs)
            self._assert_no_extra_dropins(fs)
            self._assert_not_interrupted(calls2)

    def test_preserves_config_and_state(self):
        """Scenario 19: Preserve config content and persistent state."""
        config_content = '{"log":{"level":"warn"},"inbounds":[{"type":"mixed","listen":"::","listen_port":1080}]}'
        self._has_config = True
        self._config_content = config_content
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            cfg = fs / "etc/sing-box/config.json"
            self.assertEqual(cfg.read_text(), config_content)
            self.assertTrue((fs / "var/lib/sing-box").exists())
            (fs / "var/lib/sing-box/cache.db").write_text("state")
            result2, base, fs, state, calls = self._run(tmp)
            self._succeed(result2)
            self.assertEqual((fs / "var/lib/sing-box/cache.db").read_text(), "state")

    def test_symlink_safety(self):
        """Scenario 20a: Config file is a symlink — rejected before changes."""
        self._has_config = True
        self._has_existing_key = True
        self._symlink_config = True
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result, " — symlinked config should be rejected")
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_not_interrupted(calls)

    def test_symlink_dropin_dir_safety(self):
        """Scenario 20b: Drop-in directory is a symlink — rejected before changes."""
        self._has_config = True
        self._has_existing_key = True
        self._symlink_dropin_dir = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result, " — symlinked drop-in dir should be rejected")
            self._assert_unmasked(state)
            self._assert_not_active(state)

    # ---- Additional invariant tests ----

    def test_key_reuse_avoids_download(self):
        """A key with the official fingerprint is reused without downloading."""
        self._has_config = True
        self._has_existing_key = True
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self.assertFalse(any(line.startswith("curl ") for line in self._calls(calls)))
            self.assertIn("gpg", "\n".join(self._calls(calls)))

    def test_header_only_existing_key_is_not_reused(self):
        """An ASCII-armored header alone is not proof of a valid identity."""
        self._has_config = True
        self._has_existing_key = True
        self._existing_key_content = (
            "-----BEGIN PGP PUBLIC KEY BLOCK-----\nfake\n-----END PGP PUBLIC KEY BLOCK-----\n"
        )
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self.assertIn("curl ", "\n".join(self._calls(calls)))
            keyring = fs / "etc/apt/keyrings/sagernet.asc"
            self.assertEqual(keyring.read_text(), "VALID_OFFICIAL_KEY\n")

    def test_downloaded_key_with_wrong_fingerprint_is_rejected(self):
        """Downloaded keys are validated against the official fingerprint."""
        self._has_config = True
        self._has_existing_key = True
        self._existing_key_content = "WRONG_OLD_KEY\n"
        self._key_content = "WRONG_KEY\n"
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_active(state)
            self._assert_not_interrupted(calls)
            self.assertEqual(
                (fs / "etc/apt/keyrings/sagernet.asc").read_text(), "WRONG_OLD_KEY\n"
            )

    def test_multi_key_file_is_rejected(self):
        """A key file containing more than the official primary key is rejected."""
        self._has_config = True
        self._was_active = True
        with temporary_directory() as tmp:
            key_file = Path(tmp) / "sagernet.asc"
            key_file.write_text("VALID_OFFICIAL_KEY\nSECOND_KEY\n")
            result, base, fs, state, calls = self._run(tmp, args=["--key-file", str(key_file)])
            self._fail(result)
            self._assert_active(state)
            self.assertFalse((fs / "etc/apt/keyrings/sagernet.asc").exists())

    def test_no_mask_on_success(self):
        """Service is never masked during normal installation."""
        self._has_config = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            lines = self._calls(calls)
            self.assertFalse(any(line == "mask sing-box" for line in lines))
            self._assert_unmasked(state)

    def test_failure_restores_active_state(self):
        """A previously active service remains active on a non-disruptive failure."""
        self._has_config = True
        self._has_existing_key = True
        self._has_correct_dropin = True
        self._was_active = True
        self._check_exit = 9
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_unmasked(state)
            self._assert_active(state)
            self._assert_not_interrupted(calls)

    def test_missing_config_active_service_is_not_stopped(self):
        """Missing config must fail before touching a running service."""
        self._has_config = False
        self._was_active = True
        self._was_enabled = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self.assertIn("refusing to stop", result.stderr)
            self._assert_active(state)
            self._assert_not_interrupted(calls)
            self.assertFalse(any(line.startswith("curl ") for line in self._calls(calls)))

    def test_missing_config_fresh_install_succeeds_without_start(self):
        """A fresh install without config may complete but must not start."""
        self._has_config = False
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._succeed(result)
            self._assert_unmasked(state)
            self._assert_not_active(state)
            self.assertNotIn("mask sing-box", self._calls(calls))

    def test_failure_before_any_change_does_not_touch_service(self):
        """A key failure before config/package work leaves an active service alone."""
        self._has_config = True
        self._curl_fail = True
        self._was_active = True
        with temporary_directory() as tmp:
            result, base, fs, state, calls = self._run(tmp)
            self._fail(result)
            self._assert_active(state)
            lines = self._calls(calls)
            self.assertFalse(any(line.startswith("apt-get ") for line in lines))
            self.assertNotIn("daemon-reload", lines)


if __name__ == "__main__":
    unittest.main()
