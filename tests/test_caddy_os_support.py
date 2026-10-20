"""Distribution-support checks for the Caddy APT workflow.

These are mocked regression tests: they never call live APT or systemd, never
install a package or replace a binary, and never touch a service. The single
exception is the host test, which only runs the read-only "--check-os" probe.

Run them on a real Debian/Ubuntu host to additionally validate detection
against a genuine /etc/os-release:

    python3 tests/test_caddy_os_support.py
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = ROOT / "caddy" / "install-caddy-apt.sh"
LEGACY_ENTRY = ROOT / "caddy" / "install-caddy-debian.sh"
UPDATER = ROOT / "caddy" / "update-caddy-debian.sh"

# (os-release content, expected label or None when it must be rejected,
#  substring expected in the rejection message)
ACCEPT_CASES = [
    ("Debian 12", 'ID=debian\nNAME="Debian GNU/Linux"\nVERSION_ID="12"\nVERSION_CODENAME=bookworm\n', "Debian 12"),
    ("Debian 13", 'ID=debian\nNAME="Debian GNU/Linux"\nVERSION_ID="13"\nVERSION_CODENAME=trixie\n', "Debian 13"),
    ("Ubuntu 24.04", 'ID=ubuntu\nNAME="Ubuntu"\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\nID_LIKE=debian\n', "Ubuntu 24.04 LTS"),
    ("Ubuntu 26.04", 'ID=ubuntu\nNAME="Ubuntu"\nVERSION_ID="26.04"\nVERSION_CODENAME=resolute\nID_LIKE=debian\n', "Ubuntu 26.04 LTS"),
    # Unquoted assignments occur in hand-edited and minimal images.
    ("Ubuntu 26.04 unquoted", "ID=ubuntu\nVERSION_ID=26.04\n", "Ubuntu 26.04 LTS"),
]

REJECT_CASES = [
    ("Debian 11", 'ID=debian\nVERSION_ID="11"\n', "Debian '11' is not supported"),
    ("Debian 14", 'ID=debian\nVERSION_ID="14"\n', "Debian '14' is not supported"),
    ("Debian sid", 'ID=debian\nVERSION_ID="14"\nVERSION_CODENAME=sid\n', "Debian '14' is not supported"),
    ("Ubuntu 22.04", 'ID=ubuntu\nVERSION_ID="22.04"\nID_LIKE=debian\n', "Ubuntu '22.04' is not supported"),
    ("Ubuntu 25.10", 'ID=ubuntu\nVERSION_ID="25.10"\nID_LIKE=debian\n', "Ubuntu '25.10' is not supported"),
    # ID_LIKE must not be enough: apt-based derivatives stay rejected.
    ("Linux Mint", 'ID=linuxmint\nID_LIKE="ubuntu debian"\nVERSION_ID="22.1"\n', "Distribution 'linuxmint' is not supported"),
    ("Pop!_OS", 'ID=pop\nID_LIKE="ubuntu debian"\nVERSION_ID="22.04"\n', "Distribution 'pop' is not supported"),
    ("Debian Testing unnamed", 'ID=debian\n', "Debian 'unknown' is not supported"),
    ("Ubuntu no VERSION_ID", 'ID=ubuntu\n', "Ubuntu 'unknown' is not supported"),
]

MALFORMED_CASES = [
    ("no ID field", 'NAME="Something"\nVERSION_ID="12"\n', "has no ID field"),
    ("empty file", "", "non-empty regular file"),
    ("only comments", '# nothing here\n', "has no ID field"),
]

SCRIPT_DIR_LINE = 'readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"'

CLOUDSMITH = "https://dl.cloudsmith.io/public/caddy/stable/deb/deb stable/main amd64 Packages"
UBUNTU = "http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages"


def policy(candidate, *entry_lines, installed="(none)"):
    """Assemble realistic `apt-cache policy caddy` stdout.

    Each entry is a (version-table body) string exactly as apt prints it, so a
    change in the parser has to keep working against the real layout.
    """
    return (
        "caddy:\n"
        f"  Installed: {installed}\n"
        f"  Candidate: {candidate}\n"
        "  Version table:\n"
        + "".join(entry_lines)
    )


# (name, policy output, accepted?, needles expected in the failure text)
# The order of version-table entries is significant: an origin belongs to the
# version entry printed directly above it and to no other version.
CANDIDATE_CASES = [
    (
        "official cloudsmith candidate",
        policy("2.11.7", "     2.11.7 500\n", f"        500 {CLOUDSMITH}\n",
               "     2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n"),
        True, (),
    ),
    (
        "candidate from cloudsmith after an older universe version",
        policy("2.11.7", "     2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n",
               "     2.11.7 500\n", f"        500 {CLOUDSMITH}\n"),
        True, (),
    ),
    (
        "universe-only candidate",
        policy("2.6.2-14ubuntu1", "     2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n"),
        False, ("comes from 'http://archive.ubuntu.com/ubuntu", "not the official Caddy repository"),
    ),
    (
        # The regression: a non-candidate version listed first carries the
        # Cloudsmith origin while the actual candidate belongs to universe.
        "older cloudsmith version listed before a universe candidate",
        policy("2.6.2-14ubuntu1", installed="2.11.7",
               *["     2.11.7 500\n", f"        500 {CLOUDSMITH}\n",
                 " *** 2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n",
                 "    100 /var/lib/dpkg/status\n"]),
        False, ("comes from 'http://archive.ubuntu.com/ubuntu", "not the official Caddy repository"),
    ),
    (
        "installed candidate marked with *** alongside the dpkg status entry",
        policy("2.11.7", installed="2.11.7",
               *[" *** 2.11.7 500\n", f"        500 {CLOUDSMITH}\n",
                 "    100 /var/lib/dpkg/status\n",
                 "     2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n"]),
        True, (),
    ),
    (
        # The dpkg status database must never be read as the candidate origin.
        "status database only after the candidate entry",
        policy("2.11.7", installed="2.11.7",
               *[" *** 2.11.7 500\n", "    100 /var/lib/dpkg/status\n"]),
        False, ("no repository origin",),
    ),
    (
        "same version published by universe and cloudsmith",
        policy("2.11.7", "     2.11.7 500\n", f"        500 {UBUNTU}\n", f"        500 {CLOUDSMITH}\n"),
        True, (),
    ),
    (
        "repository-update warning does not supply an origin",
        "W: Failed to fetch https://dl.cloudsmith.io/public/caddy/stable/deb/binary-amd64/Packages  404 Not Found\n"
        "W: Some index files failed to download.\n"
        + policy("2.6.2-14ubuntu1", "     2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n"),
        False, ("comes from 'http://archive.ubuntu.com/ubuntu", "not the official Caddy repository"),
    ),
    (
        "candidate version with no origin line at all",
        policy("2.11.7", "     2.11.7 500\n"),
        False, ("no repository origin",),
    ),
    (
        # Some apt builds mark the pinned or held entry with "::" instead of
        # "***"; the version, not the marker, must carry the origin.
        "candidate marked with the double-colon variant",
        policy("2.11.7", installed="2.6.2-14ubuntu1",
               *["     2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n",
                 "  :: 2.11.7 500\n", f"        500 {CLOUDSMITH}\n"]),
        True, (),
    ),
    (
        "malformed version entry without a priority",
        policy("2.11.7", "     2.11.7\n", f"        500 {CLOUDSMITH}\n"),
        False, ("no repository origin",),
    ),
    (
        "empty version table",
        policy("2.11.7"),
        False, ("no repository origin",),
    ),
]



def script_source(path):
    """The script body without its final invocation line.

    Sourcing a script from a here-string leaves BASH_SOURCE unset, so the
    SCRIPT_DIR probe is pinned to the real directory instead.
    """
    text = path.read_text(encoding="utf-8").rsplit('main "$@"', 1)[0]
    assert SCRIPT_DIR_LINE in text, f"{path.name} no longer derives SCRIPT_DIR from BASH_SOURCE"
    return text.replace(SCRIPT_DIR_LINE, f'readonly SCRIPT_DIR="{quote(path.parent)}"')


def strip_comments(text):
    """Drop full-line comments so policy code, not prose, is compared."""
    return "".join(
        f"{line}\n" for line in text.splitlines() if not line.lstrip().startswith("#")
    )


def run_bash(body):
    result = subprocess.run(["bash"], input=body, text=True, capture_output=True)
    return result.returncode, result.stdout, result.stderr


def quote(path):
    return Path(path).as_posix()


def os_release_body(script, fixture_path, extra=""):
    """Source `script` with OS_RELEASE redirected at a fixture."""
    marker = 'readonly OS_RELEASE="/etc/os-release"'
    src = script_source(script)
    assert marker in src, f"{script.name} no longer declares readonly {marker}"
    src = src.replace(marker, f'readonly OS_RELEASE="{fixture_path}"')
    return src + extra + "\nrequire_supported_os\nprintf 'LABEL=%s\\n' \"$DISTRO_LABEL\"\n"


def os_release_fields(path):
    fields = {}
    for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
        match = re.match(r'^([A-Z_]+)=(?:"([^"]*)"|\'([^\']*)\'|([^ ]*))', line)
        if match:
            fields[match.group(1)] = next(g for g in match.groups()[1:] if g is not None)
    return fields


class DistributionMatrixTests(unittest.TestCase):
    """The installer and the updater must accept and reject the same hosts."""

    def check_script(self, script, content):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(quote(tmp)) / "os-release"
            fixture.write_text(content, encoding="utf-8")
            return run_bash(os_release_body(script, quote(fixture)))

    def _matrix(self, script):
        for name, content, label in ACCEPT_CASES:
            with self.subTest(script=script.name, case=name):
                rc, out, err = self.check_script(script, content)
                self.assertEqual(rc, 0, err)
                self.assertEqual(out.strip(), f"LABEL={label}")

        for name, content, reason in REJECT_CASES:
            with self.subTest(script=script.name, case=name):
                rc, out, err = self.check_script(script, content)
                self.assertEqual(rc, 1)
                self.assertIn(reason, err)
                self.assertIn("Supported: Debian 12, Debian 13, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS", err)
                self.assertNotIn("LABEL=", out)

        for name, content, reason in MALFORMED_CASES:
            with self.subTest(script=script.name, case=name):
                rc, out, err = self.check_script(script, content)
                self.assertEqual(rc, 1, f"{out}\n{err}")
                self.assertIn(reason, err)

    def test_installer_matrix(self):
        self._matrix(INSTALLER)

    def test_updater_matrix(self):
        self._matrix(UPDATER)

    def test_missing_os_release_is_rejected_safely(self):
        for script in (INSTALLER, UPDATER):
            with self.subTest(script=script.name):
                with tempfile.TemporaryDirectory() as tmp:
                    absent = Path(quote(tmp)) / "os-release"
                    rc, out, err = run_bash(os_release_body(script, quote(absent)))
                    self.assertEqual(rc, 1)
                    self.assertIn("Cannot read a non-empty regular file", err)

    def test_directory_at_os_release_path_is_rejected_safely(self):
        for script in (INSTALLER, UPDATER):
            with self.subTest(script=script.name):
                with tempfile.TemporaryDirectory() as tmp:
                    directory = Path(quote(tmp)) / "os-release"
                    directory.mkdir()
                    rc, out, err = run_bash(os_release_body(script, quote(directory)))
                    self.assertEqual(rc, 1)
                    self.assertIn("Cannot read a non-empty regular file", err)


class SharedPolicyTests(unittest.TestCase):
    """Installer and updater must not drift apart; the entry points must agree."""

    @staticmethod
    def function_body(text, name):
        match = re.search(rf"^{re.escape(name)}\(\)\{{.*?^\}}\n", text, re.M | re.S)
        assert match, f"{name}() is missing"
        return match.group(0)

    def test_os_policy_is_identical_in_installer_and_updater(self):
        self.assertEqual(
            strip_comments(self.function_body(script_source(INSTALLER), "require_supported_os")),
            strip_comments(self.function_body(script_source(UPDATER), "require_supported_os")),
        )

    def test_supported_distributions_constant_matches_everywhere(self):
        for script in (INSTALLER, UPDATER):
            with self.subTest(script=script.name):
                match = re.search(
                    r'readonly SUPPORTED_DISTRIBUTIONS="([^"]+)"', script.read_text(encoding="utf-8")
                )
                self.assertIsNotNone(match)
                self.assertEqual(
                    match.group(1), "Debian 12, Debian 13, Ubuntu 24.04 LTS, Ubuntu 26.04 LTS"
                )

    def test_repo_origin_policy_is_identical_in_installer_and_updater(self):
        # The two scripts may word their "no candidate" failure differently, but
        # the origin assertion itself must not diverge.
        def normalised(script):
            body = self.function_body(script_source(script), "caddy_repo_candidate")
            body = re.sub(r'die "No Caddy[^"]*"', 'die "NO_CANDIDATE"', body)
            return strip_comments(body)

        self.assertEqual(normalised(INSTALLER), normalised(UPDATER))

    def test_no_distribution_specific_branches_outside_os_detection(self):
        # Shared APT logic must not fork on ID/VERSION_ID outside detection.
        for script in (INSTALLER, UPDATER):
            with self.subTest(script=script.name):
                body = self.function_body(script.read_text(encoding="utf-8"), "require_supported_os")
                outside = script.read_text(encoding="utf-8").replace(body, "")
                self.assertNotIn('${ID', outside)
                self.assertNotIn('${VERSION_ID', outside)

    def test_legacy_entry_point_is_a_forwarding_wrapper(self):
        text = LEGACY_ENTRY.read_text(encoding="utf-8")
        self.assertIn("install-caddy-apt.sh", text)
        self.assertIn("exec bash", text)
        # No second implementation may live in the wrapper.
        for marker in ("apt-get", "dpkg-divert", "preflight(", "require_supported_os("):
            self.assertNotIn(marker, text)
        self.assertLessEqual(len([line for line in text.splitlines() if line.strip()]), 8)

    def test_legacy_entry_point_forwards_options_to_the_canonical_installer(self):
        for args, expected in ((["--help"], "Usage:"), (["--bogus"], "Unknown option: --bogus")):
            for entry in (INSTALLER, LEGACY_ENTRY):
                with self.subTest(entry=entry.name, args=args):
                    result = subprocess.run(
                        ["bash", str(entry), *args], text=True, capture_output=True
                    )
                    forwarded = result.stdout + result.stderr
                    self.assertIn(expected, forwarded)
                    if args == ["--bogus"]:
                        self.assertEqual(result.returncode, 1)
                        # The canonical installer must report the rejection, not
                        # the wrapper failing to find it.
                        self.assertIn("install-caddy-apt.sh", forwarded)

    def test_migration_delegates_distribution_support_to_the_installer(self):
        text = (ROOT / "caddy" / "migrate-caddy-deployment.sh").read_text(encoding="utf-8")
        self.assertIn('readonly INSTALLER="${SCRIPT_DIR}/install-caddy-apt.sh"', text)
        self.assertIn('"$INSTALLER" --check-os', text)
        self.assertNotIn("require_supported_os", text)

    def test_no_caddy_script_references_the_removed_debian_installer(self):
        for name in ("install-caddy-apt.sh", "update-caddy-debian.sh",
                     "migrate-caddy-deployment.sh", "normalize-caddy-services.sh"):
            with self.subTest(script=name):
                text = (ROOT / "caddy" / name).read_text(encoding="utf-8")
                self.assertNotIn("install-caddy-debian.sh", text)


class RepositoryCandidateTests(unittest.TestCase):
    """Ubuntu ships its own caddy build, so the candidate origin is checked."""

    def run_candidate(self, policy, script=INSTALLER):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(quote(tmp)) / "policy"
            fixture.write_text(policy, encoding="utf-8")
            src = script_source(script)
            body = (
                src
                + f"""
apt-cache(){{ cat "{quote(fixture)}"; }}
caddy_repo_candidate
"""
            )
            return run_bash(body)

    def test_cloudsmith_candidate_is_accepted(self):
        policy = (
            "caddy:\n"
            "  Installed: (none)\n"
            "  Candidate: 2.11.7\n"
            "  Version table:\n"
            "     2.11.7 500\n"
            "        500 https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version/main amd64 Packages\n"
            "     2.6.2-14 500\n"
            "        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages\n"
        )
        rc, out, err = self.run_candidate(policy)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), "2.11.7")

    def test_distro_build_only_candidate_is_rejected(self):
        policy = (
            "caddy:\n"
            "  Installed: (none)\n"
            "  Candidate: 2.6.2-14\n"
            "  Version table:\n"
            "     2.6.2-14 500\n"
            "        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages\n"
        )
        rc, out, err = self.run_candidate(policy)
        self.assertEqual(rc, 1)
        self.assertIn("comes from 'http://archive.ubuntu.com/ubuntu", err)
        self.assertIn("not the official Caddy repository", err)
        self.assertIn("caddy-stable source probably failed to load", err)

    def test_installed_cloudsmith_candidate_is_recognised_desite_the_asterisks(self):
        policy = (
            "caddy:\n"
            "  Installed: 2.11.7\n"
            "  Candidate: 2.11.7\n"
            "  Version table:\n"
            " *** 2.11.7 500\n"
            "        500 https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version/main amd64 Packages\n"
        )
        rc, out, err = self.run_candidate(policy)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), "2.11.7")

    def test_origin_is_bound_to_the_candidates_own_version_entry(self):
        # Every fixture is run through the installer and the updater, which must
        # reach the same decision from the same policy output.
        for name, text, accept, needles in CANDIDATE_CASES:
            for script in (INSTALLER, UPDATER):
                with self.subTest(case=name, script=script.name):
                    rc, out, err = self.run_candidate(text, script=script)
                    if accept:
                        self.assertEqual(rc, 0, err)
                        self.assertEqual(out.strip(), text.split("Candidate: ")[1].split("\n")[0])
                    else:
                        self.assertEqual(rc, 1, err)
                        for needle in needles:
                            self.assertIn(needle, err)

    def test_rejection_names_the_candidates_origin_not_the_first_line(self):
        # A wrong attribution must not be masked by a generic message: the
        # reported origin has to be the one that publishes the candidate.
        wrong = policy("2.6.2-14ubuntu1", installed="2.11.7",
                       *["     2.11.7 500\n", f"        500 {CLOUDSMITH}\n",
                         " *** 2.6.2-14ubuntu1 500\n", f"        500 {UBUNTU}\n"])
        rc, out, err = self.run_candidate(wrong)
        self.assertEqual(rc, 1)
        self.assertIn("comes from 'http://archive.ubuntu.com/ubuntu", err)
        self.assertNotIn("comes from 'https://dl.cloudsmith.io", err)

    def test_no_candidate_at_all_is_rejected(self):
        for script in (INSTALLER, UPDATER):
            with self.subTest(script=script.name):
                rc, out, err = self.run_candidate(
                    "caddy:\n  Installed: (none)\n  Candidate: (none)\n  Version table:\n",
                    script=script,
                )
                self.assertEqual(rc, 1)
                self.assertIn("No Caddy", err)
                self.assertIn("candidate", err)

    def test_candidate_version_is_not_contaminated_by_other_output(self):
        # APT chatter on stdout must not become the version string.
        policy = (
            "W: Some index file failed to download.\n"
            "caddy:\n"
            "  Installed: (none)\n"
            "  Candidate: 2.11.7\n"
            "  Version table:\n"
            "     2.11.7 500\n"
            "        500 https://dl.cloudsmith.io/public/caddy/stable/deb/debian any-version/main amd64 Packages\n"
        )
        rc, out, err = self.run_candidate(policy)
        self.assertEqual(rc, 0, err)
        self.assertEqual(out.strip(), "2.11.7")

    def test_updater_applies_the_same_origin_guard(self):
        policy = (
            "caddy:\n"
            "  Installed: 2.11.7\n"
            "  Candidate: 2.6.2-14\n"
            "  Version table:\n"
            "     2.6.2-14 500\n"
            "        500 http://archive.ubuntu.com/ubuntu resolute/universe amd64 Packages\n"
        )
        rc, out, err = self.run_candidate(policy, script=UPDATER)
        self.assertEqual(rc, 1)
        self.assertIn("not the official Caddy repository", err)


class DependencySelectionTests(unittest.TestCase):
    """The APT dependency set must be installable on Debian and Ubuntu alike."""

    def prepare(self):
        src = script_source(INSTALLER)
        return src + """
CALLS='__TMP__/calls'
apt-get(){ printf 'apt-get %s\\n' "$*" >> "$CALLS"; }
curl(){ printf 'curl %s\\n' "$2" >> "$CALLS"; }
gpg(){ cat >/dev/null; }
chmod(){ :; }
caddy_repo_candidate(){ echo 2.11.7; }
install_caddy
printf 'PKG=%s\\nCADDY=%s\\n' "$PACKAGE_VERSION" "$CADDY_VERSION"
"""

    def collect(self):
        with tempfile.TemporaryDirectory() as tmp:
            body = self.prepare().replace("__TMP__", quote(tmp))
            rc, out, err = run_bash(body)
            calls = (Path(quote(tmp)) / "calls")
            return rc, out, err, (calls.read_text(encoding="utf-8") if calls.exists() else "")

    def test_only_main_pocket_packages_are_required(self):
        rc, out, err, calls = self.collect()
        self.assertEqual(rc, 0, err)
        self.assertIn("apt-get install -y ca-certificates curl gpg\n", calls)
        # debian-keyring/debian-archive-keyring/apt-transport-https are
        # universe-only on Ubuntu and are not consulted for a signed-by keyring.
        for unwanted in ("debian-keyring", "debian-archive-keyring", "apt-transport-https"):
            self.assertNotIn(unwanted, calls)

    def test_repository_metadata_is_resolved_before_the_service_is_touched(self):
        rc, out, err, calls = self.collect()
        self.assertEqual(rc, 0, err)
        lines = [line for line in calls.splitlines() if line.startswith("apt-get")]
        self.assertEqual(lines[0], "apt-get update")
        self.assertEqual(lines[-1], "apt-get update")
        self.assertNotIn("systemctl", calls)
        self.assertIn("Preparing the official Caddy APT repository", out)
        self.assertTrue(out.strip().endswith("PKG=2.11.7\nCADDY=v2.11.7"), out)

    def test_installer_never_holds_or_pins_the_package(self):
        text = INSTALLER.read_text(encoding="utf-8")
        code = "\n".join(line for line in text.splitlines() if not line.lstrip().startswith("#"))
        for unwanted in ("apt-mark", "apt_preferences", "etc/apt/preferences"):
            self.assertNotIn(unwanted, code)


class PreflightTests(unittest.TestCase):
    """Architecture and host checks, with dpkg/systemctl mocked."""

    def run_preflight(self, content, arch="amd64"):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = Path(quote(tmp)) / "os-release"
            fixture.write_text(content, encoding="utf-8")
            src = script_source(INSTALLER).replace(
                'readonly OS_RELEASE="/etc/os-release"', f'readonly OS_RELEASE="{quote(fixture)}"'
            ).replace(
                '[[ ${EUID} -eq 0 ]] || die "Run this script as root."',
                "true # root check bypassed by the isolated test harness",
            )
            body = src + f"""
getent(){{ return 0; }}
systemctl(){{ echo inactive; }}
dpkg(){{ echo "{arch}"; }}
preflight
printf 'ARCH=%s LABEL=%s\\n' "$ARCH" "$DISTRO_LABEL"
"""
            return run_bash(body)

    def test_amd64_and_arm64_are_both_supported_on_ubuntu(self):
        for arch in ("amd64", "arm64"):
            with self.subTest(arch=arch):
                rc, out, err = self.run_preflight('ID=ubuntu\nVERSION_ID="26.04"\n', arch)
                self.assertEqual(rc, 0, err)
                self.assertIn(f"ARCH={arch} LABEL=Ubuntu 26.04 LTS", out)
                self.assertIn(f"Environment: Ubuntu 26.04 LTS, architecture: {arch}", out)

    def test_unknown_architecture_is_rejected(self):
        rc, out, err = self.run_preflight('ID=ubuntu\nVERSION_ID="26.04"\n', "armhf")
        self.assertEqual(rc, 1)
        self.assertIn("Unsupported architecture: armhf", err)

    def test_distribution_is_checked_before_architecture(self):
        rc, out, err = self.run_preflight('ID=fedora\nVERSION_ID="43"\n', "sparc64")
        self.assertEqual(rc, 1)
        self.assertIn("Distribution 'fedora' is not supported", err)


@unittest.skipUnless(
    sys.platform.startswith("linux") and os.path.exists("/etc/os-release"),
    "needs a real Linux /etc/os-release",
)
class HostDistributionTests(unittest.TestCase):
    """On a supported or unsupported real host, detection must agree with it.

    Read-only: --check-os performs no APT, systemd or filesystem changes.
    """

    def test_host_matches_the_matrix(self):
        fields = os_release_fields("/etc/os-release")
        pair = (fields.get("ID"), fields.get("VERSION_ID"))
        expected_label = {
            ("debian", "12"): "Debian 12",
            ("debian", "13"): "Debian 13",
            ("ubuntu", "24.04"): "Ubuntu 24.04 LTS",
            ("ubuntu", "26.04"): "Ubuntu 26.04 LTS",
        }.get(pair)
        for entry in (INSTALLER, LEGACY_ENTRY):
            with self.subTest(entry=entry.name, host=str(pair)):
                result = subprocess.run(
                    ["bash", str(entry), "--check-os"], text=True, capture_output=True
                )
                if expected_label is not None:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), expected_label)
                else:
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("not supported", result.stderr)


if __name__ == "__main__":
    unittest.main()
