"""Isolated mocked lifecycle checks for caddy/normalize-caddy-services.sh.

The script under test is rewritten on the fly to redirect its absolute paths
into a temporary fake filesystem; systemctl, runuser, stat, chown, install,
dpkg-query and getent are mocked via the PATH. Ownership is simulated through
an owner table because unprivileged tests cannot chown to www-data. Modes are
real filesystem modes. Nothing here touches a live systemd instance, APT
repository or service; these are mocked regression tests, not Debian/Ubuntu
integration tests.
"""
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "caddy" / "normalize-caddy-services.sh"

ABS_PATHS = [
    "/etc/caddy/caddy.jsonc",
    "/etc/systemd/system/caddy.service.d",
    "/etc/systemd/system/sing-box.service.d",
    "/etc/systemd/system/sing-box.service",
    "/run/systemd/system/sing-box.service.d",
    "/usr/lib/systemd/system",
    "/etc/caddy",
    "/etc/sing-box/config.json",
    "/etc/sing-box",
    "/var/lib/caddy",
    "/var/lib/sing-box",
    "/var/log/caddy",
    "/var/log/sing-box",
    "/usr/bin/caddy",
    "/usr/bin/sing-box",
    "/run/",
]
ABS_PATHS.sort(key=len, reverse=True)
PATH_RE = re.compile("|".join(re.escape(p) for p in ABS_PATHS))


class NormalizeTests(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.base = Path(self._tmp.name)
        self.fs = self.base / "fs"
        self.bins = self.base / "bin"
        self.state = self.base / "state"
        self.calls = self.base / "calls"
        self.table = self.base / "owners.tsv"
        self.table.write_text("")
        for d in (self.fs, self.bins, self.state):
            d.mkdir(parents=True, exist_ok=True)
        self.calls.write_text("")
        F = str(self.fs)
        self.F = F

        # Default fixture: a fully compliant standard deployment with both
        # services running. Individual tests mutate the pieces they need.
        self.caddy_dropin_dir = self.fs / "etc/systemd/system/caddy.service.d"
        self.singbox_dropin_dir = self.fs / "etc/systemd/system/sing-box.service.d"
        self.singbox_run_dir = self.fs / "run/systemd/system/sing-box.service.d"
        self.caddy_etc = self.fs / "etc/caddy"
        self.singbox_etc = self.fs / "etc/sing-box"
        self.caddy_state = self.fs / "var/lib/caddy"
        self.caddy_log = self.fs / "var/log/caddy"
        self.singbox_state = self.fs / "var/lib/sing-box"
        for d, mode in [
            (self.caddy_dropin_dir, 0o755), (self.singbox_dropin_dir, 0o755),
            (self.singbox_run_dir, 0o755), (self.caddy_etc, 0o750),
            (self.singbox_etc, 0o755), (self.caddy_state, 0o700),
            (self.caddy_log, 0o750), (self.singbox_state, 0o755),
            (self.fs / "usr/lib/systemd/system", 0o755),
            (self.fs / "run", 0o755),
        ]:
            d.mkdir(parents=True, exist_ok=True)
            os.chmod(d, mode)

        self.caddy_cfg = self.caddy_etc / "caddy.jsonc"
        self.caddy_cfg.write_text('{"apps":{"http":{}}}\n')
        os.chmod(self.caddy_cfg, 0o640)
        self.singbox_cfg = self.singbox_etc / "config.json"
        self.singbox_cfg.write_text('{"log":{"level":"info"},"inbounds":[]}\n')
        os.chmod(self.singbox_cfg, 0o644)

        owners = {
            self.caddy_dropin_dir: "root:root",
            self.singbox_dropin_dir: "root:root",
            self.singbox_run_dir: "root:root",
            self.caddy_etc: "root:www-data",
            self.caddy_cfg: "root:www-data",
            self.singbox_etc: "root:www-data",
            self.singbox_cfg: "root:www-data",
            self.caddy_state: "www-data:www-data",
            self.caddy_log: "www-data:www-data",
            self.singbox_state: "www-data:www-data",
        }
        self._owners(owners)

        (self.fs / "usr/lib/systemd/system/caddy.service").write_text(
            "[Service]\nUser=caddy\nGroup=caddy\n"
            "ExecStart=/usr/bin/caddy run --config /etc/caddy/Caddyfile\n"
        )
        # Vendor paths use the fake filesystem so the -C dir-mode guard can
        # resolve the config directory inside the isolated fixture.
        (self.fs / "usr/lib/systemd/system/sing-box.service").write_text(
            "[Service]\n"
            f"ExecStart={F}/usr/bin/sing-box -D {F}/var/lib/sing-box -C {F}/etc/sing-box run\n"
        )

        # Default fixture: both services running and enabled.
        (self.state / "caddy.active").touch()
        (self.state / "sing-box.active").touch()
        (self.state / "caddy.enabled").touch()
        (self.state / "sing-box.enabled").touch()

        self.desired_caddy = (
            "[Service]\nUser=www-data\nGroup=www-data\n"
            f"Environment=HOME={F}/var/lib/caddy\nExecStart=\n"
            f"ExecStart={F}/usr/bin/caddy run --environ --config {F}/etc/caddy/caddy.jsonc --adapter jsonc\n"
            f"ExecReload=\n"
            f"ExecReload={F}/usr/bin/caddy reload --config {F}/etc/caddy/caddy.jsonc --adapter jsonc --force\n"
        )
        self.desired_singbox = (
            "[Service]\nUser=www-data\nGroup=www-data\nStateDirectoryMode=0755\n"
            "ExecStart=\n"
            f"ExecStart={F}/usr/bin/sing-box -D {F}/var/lib/sing-box -c {F}/etc/sing-box/config.json run\n"
        )
        (self.caddy_dropin_dir / "override.conf").write_text(self.desired_caddy)
        os.chmod(self.caddy_dropin_dir / "override.conf", 0o644)
        self._owners({self.caddy_dropin_dir / "override.conf": "root:root"})
        (self.singbox_dropin_dir / "override.conf").write_text(self.desired_singbox)
        os.chmod(self.singbox_dropin_dir / "override.conf", 0o644)
        self._owners({self.singbox_dropin_dir / "override.conf": "root:root"})

        self._write_binaries()
        self._write_fakes()

    def tearDown(self):
        self._tmp.cleanup()

    # ---------------- fixture helpers ----------------

    def _owners(self, mapping):
        lines = {}
        if self.table.exists():
            for line in self.table.read_text().splitlines():
                if not line.strip():
                    continue
                k, _, v = line.partition("\t")
                lines[k] = v
        for path, owner in mapping.items():
            lines[str(path)] = owner
        self.table.write_text("".join(f"{k}\t{v}\n" for k, v in lines.items()))

    def _write_binaries(self):
        (self.fs / "usr/bin").mkdir(parents=True, exist_ok=True)
        (self.fs / "usr/bin/caddy").write_text(
            f"""#!/bin/bash
case "$*" in
  *validate*) [ -f '{self.state}/caddy_validate_fail' ] && exit 1; exit 0;;
  version) echo 'v2.11.7'; exit 0;;
esac
exit 0
"""
        )
        (self.fs / "usr/bin/sing-box").write_text(
            f"""#!/bin/bash
case "$*" in
  *check*) [ -f '{self.state}/singbox_check_fail' ] && exit 9; exit 0;;
  version) echo 'sing-box version 1.10.0'; exit 0;;
esac
exit 0
"""
        )
        for b in ((self.fs / "usr/bin/caddy"), (self.fs / "usr/bin/sing-box")):
            b.chmod(0o755)

    def _write_fakes(self):
        F = str(self.fs)
        STATE = str(self.state)
        CALLS = str(self.calls)
        TABLE = str(self.table)

        self._fake("stat", r"""#!/usr/bin/env python3
import os, sys
args = sys.argv[1:]
if args[:2] == ["-c", "%U:%G %a"] and len(args) == 3:
    p = args[2]
    if not os.path.exists(p):
        sys.exit(1)
    table = {}
    tp = os.environ["OWNER_TABLE"]
    if os.path.exists(tp):
        for line in open(tp):
            k, _, v = line.rstrip("\n").partition("\t")
            if k:
                table[k] = v
    owner = table.get(p)
    if owner is None:
        # An unprivileged test cannot really chown; a file atomically
        # replaced via temp-file+mv keeps the temp file's owner, so fall
        # back to the nearest ancestor recorded in the owner table.
        cur = os.path.dirname(p)
        while cur and cur != "/":
            if cur in table:
                owner = table[cur]
                break
            cur = os.path.dirname(cur)
    if owner is None:
        st = os.stat(p)
        owner = f"{st.st_uid}:{st.st_gid}"
    print(f"{owner} {oct(os.stat(p).st_mode & 0o777)[2:]}")
    sys.exit(0)
os.execv("/usr/bin/stat", ["stat"] + args)
""")

        self._fake("chown", r"""#!/usr/bin/env python3
import os, sys
args = [a for a in sys.argv[1:] if a not in ("-R", "-h", "--from=user:group")]
if not args:
    sys.exit(0)
owner = args[0]
paths = args[1:]
lines = {}
order = []
tp = os.environ["OWNER_TABLE"]
if os.path.exists(tp):
    for line in open(tp):
        k, _, v = line.rstrip("\n").partition("\t")
        if k:
            lines[k] = v
            order.append(k)
for p in paths:
    keys = [p]
    if "-R" in sys.argv[1:] and os.path.isdir(p):
        for root, dirs, files in os.walk(p):
            keys.append(root)
            keys.extend(os.path.join(root, f) for f in files)
    for k in keys:
        if k not in lines:
            order.append(k)
        lines[k] = owner
with open(tp, "w") as fh:
    for k in order:
        fh.write(f"{k}\t{lines[k]}\n")
sys.exit(0)
""")

        self._fake("install", r"""#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
mode = None
owner = None
group = None
isdir = False
positional = []
i = 0
while i < len(args):
    a = args[i]
    if a == "-d":
        isdir = True
    elif a == "-m":
        mode = args[i + 1]; i += 1
    elif a == "-o":
        owner = args[i + 1]; i += 1
    elif a == "-g":
        group = args[i + 1]; i += 1
    else:
        positional.append(a)
    i += 1
cmd = ["/usr/bin/install"]
if isdir:
    cmd.append("-d")
if mode:
    cmd += ["-m", mode]
cmd += positional
subprocess.run(cmd, check=True)
target = positional[-1]
if owner or group:
    lines = {}
    order = []
    tp = os.environ["OWNER_TABLE"]
    if os.path.exists(tp):
        for line in open(tp):
            k, _, v = line.rstrip("\n").partition("\t")
            if k:
                lines[k] = v
                order.append(k)
    if target not in lines:
        order.append(target)
    lines[target] = f"{owner or 'root'}:{group or 'root'}"
    with open(tp, "w") as fh:
        for k in order:
            fh.write(f"{k}\t{lines[k]}\n")
sys.exit(0)
""")

        self._fake("systemctl", r"""#!/bin/bash
printf 'systemctl %s\n' "$*" >> '@CALLS@'
FS='@FS@'
STATE='@STATE@'
svc=''
quiet=false
for a in "$@"; do
  case "$a" in
    caddy|sing-box) svc="$a" ;;
    --quiet) quiet=true ;;
  esac
done

dropin_files() {
  # vendor unit first, then etc drop-ins then run drop-ins, sorted by name
  printf '%s\n' "$FS/usr/lib/systemd/system/$svc.service"
  find "$FS/etc/systemd/system/$svc.service.d" "$FS/run/systemd/system/$svc.service.d" \
    -maxdepth 1 -type f -name '*.conf' 2>/dev/null | sort
}

effective() {
  local user='' group='' exec='' line val
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in
        User=*) user="${line#User=}" ;;
        Group=*) group="${line#Group=}" ;;
        ExecStart=) exec='' ;;
        ExecStart=*) val="${line#ExecStart=}"
          if [ -z "$exec" ]; then exec="$val"; else exec="$exec ; $val"; fi ;;
      esac
    done < "$f"
  done < <(dropin_files)
  case "$1" in
    User) echo "$user" ;;
    Group) echo "$group" ;;
    ExecStart)
      bin="${exec%% *}"
      echo "{ path=$bin ; argv[]=$exec ; ignore_errors=no ; }" ;;
    LoadState)
      if [ -f "$STATE/$svc.masked" ]; then echo masked; else echo loaded; fi ;;
  esac
}

case "$1" in
  show)
    prop=''
    prev=''
    for a in "$@"; do
      [ "$prev" = "-p" ] && prop="$a"
      prev="$a"
    done
    # handle "-p User -p Group": print only the first requested property
    case "$*" in
      *LoadState*) effective LoadState ;;
      *ExecStart*) effective ExecStart ;;
      *Group*) effective Group ;;
      *User*) effective User ;;
      *) echo "" ;;
    esac
    ;;
  is-active)
    if [ -f "$STATE/$svc.active" ]; then
      if [ "$quiet" = false ]; then echo active; fi
      exit 0
    fi
    if [ "$quiet" = false ]; then echo inactive; fi
    exit 3
    ;;
  is-enabled)
    if [ -f "$STATE/$svc.enabled" ]; then
      if [ "$quiet" = false ]; then echo enabled; fi
      exit 0
    fi
    if [ "$quiet" = false ]; then echo disabled; fi
    exit 1
    ;;
  stop) rm -f "$STATE/$svc.active" ;;
  start|restart)
    if [ -f "$STATE/$svc.start_fail" ]; then rm -f "$STATE/$svc.active"; exit 1; fi
    touch "$STATE/$svc.active"
    ;;
  enable) touch "$STATE/$svc.enabled" ;;
  disable) rm -f "$STATE/$svc.enabled" ;;
  mask) touch "$STATE/$svc.masked" ;;
  unmask) rm -f "$STATE/$svc.masked" ;;
  daemon-reload) : ;;
esac
exit 0
""".replace("@CALLS@", CALLS).replace("@FS@", F).replace("@STATE@", STATE))

        self._fake("runuser", """#!/bin/bash
shift 2
[ "$1" == "--" ] && shift
exec "$@"
""")
        self._fake("dpkg-query", f"""#!/bin/bash
case "$*" in
  *'${{Status}}'*) if [ -f '{STATE}/singbox_installed' ]; then printf 'install ok installed\\n'; exit 0; fi; exit 1;;
  *) exit 0;;
esac
""")
        self.state.joinpath("singbox_installed").touch()
        self._fake("getent", """#!/bin/bash
case "$1" in
  passwd) [ "$2" == "www-data" ] && echo 'www-data:x:33:33:www-data:/var/www:/usr/sbin/nologin' || exit 2;;
  group) [ "$2" == "www-data" ] && echo 'www-data:x:33:' || exit 2;;
  *) exit 1;;
esac
""")

    def _fake(self, name, body):
        p = self.bins / name
        p.write_text(body)
        p.chmod(0o755)

    def _run(self, args=()):
        text = SCRIPT.read_text()
        text = PATH_RE.sub(lambda m: self.F + m.group(0), text)
        text = text.replace(
            '[[ ${EUID} -eq 0 ]] || die "Run this script as root."',
            "true # root check bypassed by the isolated test harness",
        )
        local = self.base / "normalize.sh"
        local.write_text(text)
        env = dict(
            os.environ,
            PATH=f"{self.bins}:/usr/bin:/bin",
            OWNER_TABLE=str(self.table),
        )
        return subprocess.run(
            ["bash", str(local), *args], env=env, capture_output=True, text=True
        )

    def _calls(self):
        return self.calls.read_text()

    # ---------------- mode selection ----------------

    def test_mode_required(self):
        r = self._run([])
        self.assertEqual(r.returncode, 1)
        self.assertIn("service selection mode is required", r.stdout + r.stderr)

    def test_exactly_one_mode(self):
        r = self._run(["--caddy", "--sing-box"])
        self.assertEqual(r.returncode, 1)
        self.assertIn("exactly one mode", r.stdout + r.stderr)

    def test_unknown_option(self):
        self.assertEqual(self._run(["--all"]).returncode, 1)

    # ---------------- compliant state: no changes ----------------

    def test_compliant_both_changes_nothing(self):
        r = self._run(["--both"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self._calls()
        for verb in ("stop", "start", "restart", "daemon-reload", "mask", "unmask", "enable", "disable"):
            self.assertNotIn(f"systemctl {verb} ", calls, calls)
        self.assertIn("caddy: compliant (no changes)", r.stdout)
        self.assertIn("sing-box: compliant (no changes)", r.stdout)
        self.assertEqual((self.caddy_dropin_dir / "override.conf").read_text(), self.desired_caddy)
        self.assertEqual((self.singbox_dropin_dir / "override.conf").read_text(), self.desired_singbox)

    def test_compliant_run_is_idempotent(self):
        first = self._run(["--both"])
        second = self._run(["--both"])
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertIn("compliant (no changes)", second.stdout)

    def test_config_content_untouched_when_compliant(self):
        before_cfg = self.singbox_cfg.read_text()
        before_caddy = self.caddy_cfg.read_text()
        r = self._run(["--both"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.singbox_cfg.read_text(), before_cfg)
        self.assertEqual(self.caddy_cfg.read_text(), before_caddy)

    # ---------------- caddy drift ----------------

    def test_caddy_missing_dropin_writes_exact_unit(self):
        (self.caddy_dropin_dir / "override.conf").unlink()
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.caddy_dropin_dir / "override.conf").read_text(), self.desired_caddy)
        calls = self._calls()
        self.assertIn("systemctl daemon-reload", calls)
        self.assertIn("systemctl restart caddy", calls)  # service was active
        self.assertNotIn("sing-box", calls)

    def test_caddy_legacy_root_unit_converges_identity(self):
        (self.caddy_dropin_dir / "override.conf").write_text(
            "[Service]\nUser=root\nGroup=root\n"
        )
        os.chmod(self.caddy_dropin_dir / "override.conf", 0o600)
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.caddy_dropin_dir / "override.conf").read_text(), self.desired_caddy)
        self.assertIn("systemctl restart caddy", self._calls())

    def test_caddy_inactive_drift_never_starts_service(self):
        (self.state / "caddy.active").unlink()
        (self.caddy_dropin_dir / "override.conf").unlink()
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self._calls()
        self.assertIn("systemctl daemon-reload", calls)
        self.assertNotIn("systemctl restart caddy", calls)
        self.assertNotIn("systemctl start caddy", calls)
        self.assertIn("stopped/disabled state preserved", r.stdout)

    def test_caddy_permission_drift_applies_restrictive_modes(self):
        os.chmod(self.caddy_state, 0o755)
        os.chmod(self.caddy_cfg, 0o644)
        self.state.joinpath("caddy.active").unlink()
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(self.caddy_state.stat().st_mode & 0o777, 0o700)
        self.assertEqual(self.caddy_cfg.stat().st_mode & 0o777, 0o640)
        self.assertNotIn("systemctl restart caddy", self._calls())

    def test_caddy_validation_failure_changes_nothing(self):
        (self.caddy_dropin_dir / "override.conf").unlink()
        self.state.joinpath("caddy_validate_fail").touch()
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 1)
        self.assertFalse((self.caddy_dropin_dir / "override.conf").exists())
        calls = self._calls()
        self.assertNotIn("daemon-reload", calls)
        self.assertNotIn("restart", calls)

    def test_caddy_unrelated_dropins_preserved(self):
        other = self.caddy_dropin_dir / "20-extra.conf"
        other.write_text("[Service]\nLimitNOFILE=65536\n")
        os.chmod(other, 0o644)
        (self.caddy_dropin_dir / "override.conf").unlink()
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual(other.read_text(), "[Service]\nLimitNOFILE=65536\n")

    # ---------------- sing-box drift ----------------

    def _legacy_singbox_layout(self):
        for f in self.singbox_dropin_dir.glob("*.conf"):
            f.unlink()
        legacy = self.singbox_dropin_dir / "override.conf"
        legacy.write_text("[Service]\nUser=www-data\nGroup=www-data\nStateDirectoryMode=0750\n")
        os.chmod(legacy, 0o644)
        stale = self.singbox_dropin_dir / "zzzz-single-file.conf"
        stale.write_text("[Service]\nExecStart=\n")
        os.chmod(stale, 0o644)
        resolved = self.singbox_run_dir / "20-resolved.conf"
        resolved.write_text("[Service]\nEnvironment=LANG=C\n")
        os.chmod(resolved, 0o644)
        os.chmod(self.singbox_state, 0o750)
        os.chmod(self.singbox_etc, 0o750)
        os.chmod(self.singbox_cfg, 0o640)

    def test_singbox_legacy_layout_converges_to_installer_convention(self):
        self._legacy_singbox_layout()
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        conf = self.singbox_dropin_dir / "override.conf"
        self.assertEqual(conf.read_text(), self.desired_singbox)
        self.assertIn("-c ", conf.read_text())
        self.assertNotIn(" -C ", conf.read_text())
        self.assertFalse((self.singbox_dropin_dir / "zzzz-single-file.conf").exists())
        self.assertFalse((self.singbox_run_dir / "20-resolved.conf").exists())
        self.assertEqual(self.singbox_state.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.singbox_etc.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.singbox_cfg.stat().st_mode & 0o777, 0o644)
        self.assertIn("systemctl restart sing-box", self._calls())

    def test_singbox_reconciled_run_is_idempotent(self):
        self._legacy_singbox_layout()
        first = self._run(["--sing-box"])
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        restarts = self._calls().count("systemctl restart sing-box")
        self.assertEqual(restarts, 1)
        second = self._run(["--sing-box"])
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertEqual(self._calls().count("systemctl restart sing-box"), restarts)
        self.assertIn("sing-box: compliant (no changes)", second.stdout)

    def test_singbox_permission_drift_alone_does_not_restart(self):
        os.chmod(self.singbox_state, 0o750)
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        calls = self._calls()
        self.assertIn("systemctl daemon-reload", calls)
        self.assertNotIn("systemctl restart sing-box", calls)
        self.assertEqual(self.singbox_state.stat().st_mode & 0o777, 0o755)

    def test_singbox_inactive_drift_not_started(self):
        (self.state / "sing-box.active").unlink()
        self._legacy_singbox_layout()
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertNotIn("systemctl start sing-box", self._calls())
        self.assertNotIn("systemctl restart sing-box", self._calls())

    def test_singbox_directory_mode_with_extra_inputs_refuses(self):
        # The vendor unit still uses "-C" dir mode; the managed drop-in
        # overrides it with "-c", so remove the drop-in first to expose the
        # legacy invocation to the extras guard.
        (self.singbox_dropin_dir / "override.conf").unlink()
        extra = self.singbox_etc / "extra.json"
        extra.write_text("{}")
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertIn("silently omitted", r.stderr)
        self.assertFalse((self.singbox_dropin_dir / "override.conf").exists())
        self.assertNotIn("daemon-reload", self._calls())
        extra.unlink()
        r2 = self._run(["--sing-box"])
        self.assertEqual(r2.returncode, 0, r2.stdout + r2.stderr)
        self.assertEqual((self.singbox_dropin_dir / "override.conf").read_text(), self.desired_singbox)

    def test_singbox_local_unit_shadowing_refused(self):
        unit = self.fs / "etc/systemd/system/sing-box.service"
        unit.write_text("[Service]\nExecStart=/usr/bin/sing-box run\n")
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 1)
        self.assertIn("shadows the package-owned unit", r.stderr)
        self.assertNotIn("daemon-reload", self._calls())

    def test_singbox_masked_refused(self):
        self.state.joinpath("sing-box.masked").touch()
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 1)
        self.assertIn("masked", r.stderr)

    def test_singbox_active_missing_config_refused(self):
        self.singbox_cfg.unlink()
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 1)
        self.assertIn("is missing", r.stderr)
        self.assertEqual((self.singbox_dropin_dir / "override.conf").read_text(), self.desired_singbox)

    def test_singbox_validation_failure_restores_dropins(self):
        self._legacy_singbox_layout()
        before = (self.singbox_dropin_dir / "override.conf").read_text()
        self.state.joinpath("singbox_check_fail").touch()
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 1)
        # validation runs before any file change, so the pre-existing layout
        # must be untouched and no restart may have happened
        self.assertEqual((self.singbox_dropin_dir / "override.conf").read_text(), before)
        self.assertTrue((self.singbox_dropin_dir / "zzzz-single-file.conf").exists())
        self.assertNotIn("systemctl restart sing-box", self._calls())

    def test_singbox_not_installed_skips(self):
        (self.state / "singbox_installed").unlink()
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("nothing to normalize", r.stdout)
        self.assertNotIn("sing-box: ", r.stdout)

    def test_both_modes_reconcile_each_service(self):
        (self.caddy_dropin_dir / "override.conf").unlink()
        self._legacy_singbox_layout()
        r = self._run(["--both"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.caddy_dropin_dir / "override.conf").read_text(), self.desired_caddy)
        self.assertEqual((self.singbox_dropin_dir / "override.conf").read_text(), self.desired_singbox)
        self.assertIn("caddy: reconciled", r.stdout)
        self.assertIn("sing-box: reconciled", r.stdout)
        calls = self._calls()
        self.assertIn("systemctl restart caddy", calls)
        self.assertIn("systemctl restart sing-box", calls)

    def test_caddy_only_mode_leaves_singbox_drift_untouched(self):
        self._legacy_singbox_layout()
        (self.caddy_dropin_dir / "override.conf").unlink()
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("zzzz-single-file.conf", " ".join(p.name for p in self.singbox_dropin_dir.iterdir()))
        self.assertNotIn("systemctl restart sing-box", self._calls())

    def test_singbox_only_mode_leaves_caddy_untouched(self):
        (self.caddy_dropin_dir / "override.conf").unlink()
        os.chmod(self.caddy_state, 0o755)
        r = self._run(["--sing-box"])
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertFalse((self.caddy_dropin_dir / "override.conf").exists())
        self.assertNotIn("systemctl restart caddy", self._calls())

    def test_missing_caddy_binary_refuses_caddy_mode(self):
        (self.fs / "usr/bin/caddy").unlink()
        r = self._run(["--caddy"])
        self.assertEqual(r.returncode, 1)
        self.assertIn("run caddy/install-caddy-debian.sh", r.stderr)


if __name__ == "__main__":
    unittest.main()
