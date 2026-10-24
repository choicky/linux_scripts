# linux_scripts

Personal Linux server administration and deployment scripts.

## Design principles

- Prefer official APT repositories and official systemd services.
- Keep modifications to upstream service/configuration files to a minimum.
- Run Caddy and sing-box as `www-data:www-data`; PHP-FPM keeps the normal root master process and runs pool workers as `www-data:www-data`.
- Use `/var/www/<site>` for website repositories, normally owned by the administrative login user.
- Grant PHP-FPM write access only to application directories that require it.
- Let Caddy manage TLS certificates; sing-box reads certificates directly from Caddy storage.
- Keep one-time migrations separate from routine package updates.

## Components

Caddy lifecycle is three entry points plus one shared component. Install,
update and migration all delegate service/runtime reconciliation to the same
normalizer, so managed systemd drop-ins and permissions are authored in exactly
one place and cannot drift apart.

- `caddy/install-caddy-apt.sh` — install official Caddy Stable from APT on Debian 12/13 or Ubuntu 24.04/26.04 LTS, then use the matching prebuilt custom Caddy binary. Delegates runtime reconciliation to the normalizer. `caddy/install-caddy-debian.sh` remains as a thin compatibility entry point that forwards every argument to it; there is no second implementation.
- `caddy/update-caddy-debian.sh` — safely upgrade Caddy on the same Debian/Ubuntu matrix, only when the matching prebuilt custom binary is already available and verified. Normalizes service state on every path, including when the package is already current.
- `caddy/migrate-caddy-deployment.sh` — one-time, evidence-based migration from a legacy/manual Caddy or sing-box layout to the standard one. It absorbs the former sing-box certificate-path/startup migration, verifies that every effective certificate/key reference is actually readable by `www-data` before any identity change or activation, and removes a shadowing local sing-box unit, then delegates reconciliation to the normalizer.
- `caddy/normalize-caddy-services.sh` — the shared, repeatable runtime reconciler (modes `--caddy`, `--sing-box`, `--both`). It owns the managed drop-ins and permissions, runs both services as `www-data:www-data` so sing-box reads Caddy certificates directly, reconciles (restarts only when a unit change must reach a running service) an already-compliant layout without changes, and on a failed restart rolls the applied changes back and recovers the previously running services.
- `sing-box/install-sing-box-debian.sh` — install the official Stable `sing-box` APT package (not `sing-box-beta`) and run it as `www-data:www-data`.
- `openwrt/zerotier-site-route.sh` — shared R3S/R4S ZeroTier site-to-site route installer; uses two more-specific /25 routes per peer LAN to override a competing Tailscale /24, without modifying Tailscale or sing-box. Requires an existing authorized ZeroTier network. See usage below.
- `openwrt/R4S-momo-to-native-sing-box.md` — R4S/ImmortalWrt migration record from OpenWrt-Momo core_only to native sing-box under procd, including Tailscale state, verification and rollback (separate from Debian scripts).
- `system/init-debian-server.sh` — two-phase baseline initialization for fresh Debian 12/13 VPS instances; creates/verifies a sudo administrator, optional swap, fail2ban, and SSH hardening while deliberately retaining password authentication.
- `shell/setup-root-colors.sh` — optional root shell colour setup.
- `system/set-hostname.sh` — safely change a Debian 12/13 VPS hostname and matching hosts aliases.

## Supported distributions for the Caddy workflow

The Caddy install, update and migration scripts accept exactly these
distributions, read from the `ID` and `VERSION_ID` fields of `/etc/os-release`:

| Distribution | Versions |
|---|---|
| Debian | 12, 13 |
| Ubuntu | 24.04 LTS, 26.04 LTS |

Anything else is rejected before a package, binary, unit or permission is
touched — including apt-based derivatives such as Linux Mint or Pop!_OS, because
`apt-get` existing is not the same as a supported host. A missing, empty or
unparsable `/etc/os-release`, or one without an `ID`, is also rejected rather
than guessed at.

The APT workflow is otherwise shared: both distributions install the same
official Caddy Stable `.deb` from the Caddy Cloudsmith repository (which is
published for codename `any-version`), use the same `dpkg-divert` layout, the
same `www-data:www-data` service identity, and the same custom
`caddy-linux-amd64`/`caddy-linux-arm64` release assets. Ubuntu is not a special
case in the install path.

Two Ubuntu-only conditions are handled explicitly:

- Ubuntu publishes its own `caddy` build in the `universe` pocket (Debian does
  not). If the official Caddy source ever fails to load, APT would silently
  resolve to that distribution build, so the installer and updater assert that
  the candidate version really comes from
  `https://dl.cloudsmith.io/public/caddy/stable/` before stopping anything.
  The origin is taken from the candidate's own version-table entry: a
  repository line belongs to the version printed directly above it, while the
  `Installed` and `Candidate` header lines repeat versions with no origin at
  all, so a version match anywhere in the output would attribute the first
  listed repository to the wrong version. A candidate with no origin line is
  refused rather than guessed.
- The dependency set is limited to `ca-certificates curl gpg`, which live in
  `main` on both distributions. The former `debian-keyring`,
  `debian-archive-keyring` and `apt-transport-https` packages are not consulted
  for a `signed-by` third-party keyring, modern apt speaks HTTPS natively, and
  all three sit in Ubuntu's `universe`, where a disabled pocket would abort the
  run.

`bash caddy/install-caddy-apt.sh --check-os` prints the detected distribution
(or rejects the host) without root privileges and without changing anything; the
migration script uses it as its first check so an unsupported host can never be
left mid-migration.


## System tools

Run the hostname helper as root on Debian 12/13:

```bash
bash system/set-hostname.sh AliSZ
bash system/set-hostname.sh AliHK
bash system/set-hostname.sh OracleKR3
```

Supply exactly one hostname (or `-h`/`--help`). Names must contain 1–63 ASCII
letters, digits or hyphens, with no leading/trailing hyphen. Spaces, dots and
underscores are rejected. Input case is preserved; an identical static hostname
is a no-op.

The script reads `hostnamectl --static` and creates a timestamped
`/etc/hosts.before-hostname-*` backup before changing anything. It replaces only
complete hostname fields equal to the old name, preserving comments, spacing,
unrelated records, owner and permissions. If no field matches, hosts stays
unchanged; no records are added. The script requires a regular, non-symlink
hosts file and uses an atomic replacement before calling
`hostnamectl set-hostname`. On failure or a handled interruption, it attempts
to restore changed hosts/hostname state and reports any recovery failure.

On success it displays the static hostname, `/etc/hostname`, and hosts entries
for localhost and the new name. A VPS reboot is usually unnecessary; reconnect
via SSH to see the updated shell prompt.

## Fresh Debian VPS initialization

Use `system/init-debian-server.sh` on fresh Debian 12/13 instances. Password
authentication is preserved as currently configured by default; direct root SSH is disabled
only by the explicit second phase.

1. Run `prepare` from the existing administrative/root session. For images with
   SSH password login disabled, supply your **public** key file:

   ```bash
   sudo bash system/init-debian-server.sh prepare --user ubuntu --authorized-key /path/to/admin.pub
   ```

   The key is appended without replacing existing keys. The script does not copy
   root keys automatically. Without an explicit key, key-only images stop before
   preparation rather than claim the new login is ready. Existing users must have
   an active password for sudo; set one with `sudo passwd ubuntu` if necessary.
   Optional settings: `--swap-gib 0` skips swap; default is 2 GiB, timezone
   defaults to Asia/Shanghai.

2. In a **new** terminal, test the new user's SSH login and `sudo -v`. Retain the
   original session. Creating a user/key does not prove that AllowUsers,
   AuthenticationMethods, PAM or other existing policies permit login.

3. From a verified SSH session, preserve connection metadata when hardening:

   ```bash
   sudo env SSH_CONNECTION="$SSH_CONNECTION" bash system/init-debian-server.sh harden --user ubuntu
   ```

   Effective settings are checked for both the administrator and root using the
   current source/destination addresses and SSH port. With `UseDNS yes`, also
   supply `--client-host HOST` matching sshd's verified client hostname (or its
   address when no verified reverse name exists). These checks cover this
   connection context, not every possible source address. Test another new login
   before closing the retained sessions. Reload/service failures restore the old
   managed drop-in and attempt to reload it; restoration failures are reported.
   `sshd -T -C` inspects disk configuration, not the running daemon. Reload success
   plus an active service is not an authentication test.

   `harden --password-auth keep` is the default and omits the password directive;
   it checks that effective values are unchanged for root and the administrator.
   To deliberately enable or disable password authentication, pass
   `--password-auth yes` or `--password-auth no`. Verify the intended login method
   in another session before closing existing sessions. `MaxAuthTries 4` can reject
   clients offering many agent keys; select the intended key with `IdentitiesOnly yes`.
   The interactive user-creation step requires a terminal; download/run the script
   rather than piping it into bash.

4. Inspect without modifying settings:

   ```bash
   sudo bash system/init-debian-server.sh status --user ubuntu
   ```

fail2ban uses all effective SSH ports, explicitly selects `nftables-multiport`,
and installs `nftables` rather than depending on optional iptables packages.
It does not enable the nftables service or load/flush `/etc/nftables.conf`.
Configuration is checked before restarting fail2ban; startup polling confirms jail
readiness, not that a ban has been installed in the kernel. Debian 12/13 integration
checks must still verify a controlled ban/unban from a separate test address.
Swap creation failures remove only this run's newly created, inactive swapfile;
an active swapfile is retained, including when writing fstab fails. Run isolated regression checks with
`python3 tests/test_init_debian_server.py`; these do not change live services
and do not replace Debian VPS integration testing.

## Standard runtime layout

Expected final state:

```text
Caddy            www-data:www-data
sing-box         www-data:www-data
PHP-FPM master   root
PHP-FPM workers  www-data:www-data
```

Caddy storage:

```text
/var/lib/caddy/.local/share/caddy
```

Caddy binaries:

```text
/usr/bin/caddy.default   # stock binary from the official APT package
/usr/bin/caddy.custom    # matching prebuilt custom binary
/usr/bin/caddy           # symlink to caddy.custom
```

The custom Caddy binary includes:

- `github.com/mholt/caddy-l4`
- `github.com/WeidiDeng/caddy-cloudflare-ip`

JSONC support is built into current Caddy and does not require a separate adapter module.

The shared normalizer (`caddy/normalize-caddy-services.sh`) is the single
authority for the managed Caddy service state. Its target layout is:

| Path | Owner:Group | Mode |
|---|---|---|
| `/etc/caddy/` | `root:www-data` | `0755` |
| `/etc/caddy/caddy.jsonc` | `root:www-data` | `0640` |
| `/var/lib/caddy/` | `www-data:www-data` | `0755` |
| `/var/lib/caddy/.local/share/caddy/` (TLS storage) | `www-data:www-data` | `0700` |
| `/var/log/caddy/` | `www-data:www-data` | `0755` |
| `/etc/systemd/system/caddy.service.d/` | `root:root` | `0755` |
| `/etc/systemd/system/caddy.service.d/override.conf` | `root:root` | `0644` |

Ordinary users can list filenames in the managed configuration, working and
log directories without sudo, while sensitive *content* stays protected: the
Caddy TLS storage tree keeps its private `0700`, and the `www-data` group plus
`0640`/`0600` file modes keep configuration and key material unreadable to
everyone else. Modes inside a managed tree are capped at these defaults but
existing stricter modes are never relaxed — a `0600` private key or a `0700`
storage subdirectory survives every run. sing-box reads its certificates
directly through the shared `www-data` identity. The managed drop-in sets
`User`/`Group=www-data`, `Environment=HOME=/var/lib/caddy` and a
`--config /etc/caddy/caddy.jsonc --adapter jsonc` `ExecStart`/`ExecReload`; the
vendor/package unit is otherwise left unchanged.

## Clean installation

For a new Debian 12/13 or Ubuntu 24.04/26.04 LTS server that does not have the
old manual Caddy layout:

```bash
git clone https://github.com/choicky/linux_scripts.git /root/linux_scripts
cd /root/linux_scripts

bash caddy/install-caddy-apt.sh
bash sing-box/install-sing-box-debian.sh
```

Place/verify the real Caddy and sing-box configurations before allowing the services to start. Both installers support `--no-start` when configuration needs to be prepared first.

After a successful **Caddy** installation with no JSONC configuration, or with
`--no-start`, its service is **stopped, disabled and unmasked**. The custom binary
and `www-data` drop-in are ready, so configuration deployment can inspect the unit,
validate the candidate and restart it without a manual unmask step. Once the first
configuration is deployed successfully, enable boot startup with
`systemctl enable caddy`. With an existing valid configuration and no
`--no-start`, the installer enables and starts Caddy normally.

The temporary installation mask still prevents the package from starting its stock
Caddyfile. An incomplete binary/unit installation remains stopped and masked on
failure; fix the cause and rerun the installer. Once runtime setup is complete,
failures leave Caddy stopped/disabled and remove only the mask introduced by that
attempt; a pre-existing mask is retained on failure. This is a safe stopped state,
not a rollback of package/binary changes. The sing-box installer does not mask
the service; see the sing-box section below for its lifecycle behavior.

Do not use the migration procedure below for a clean server.

### sing-box installation and recovery

The sing-box installer supports Debian and Ubuntu (APT-based distributions)
and installs official Stable `sing-box` from the SagerNet APT repository. It
uses the official deb822 source format, the GPG key at
`/etc/apt/keyrings/sagernet.asc`, and the repository at
`https://deb.sagernet.org/`.

**GPG key handling.** The installer accepts a key at
`/etc/apt/keyrings/sagernet.asc` only when GnuPG can parse it as a single
primary key whose SHA-1 fingerprint is
`2C317FBD5D886B4E89BAE8DA6D9152172A2B2F0C`. That is the fingerprint of the
SagerNet signing key downloaded from `https://sing-box.app/gpg.key`, and it is
independently corroborated by the issuer fingerprint in the signed
`https://deb.sagernet.org/InRelease` file. Matching an ASCII-armored header is
not sufficient. Files containing extra primary keys are rejected because APT
would trust every key in `Signed-By`.

If no valid key is present, the installer downloads from
`https://sing-box.app/gpg.key` using IPv4, a 10-second connection timeout, a
30-second per-attempt timeout, and at most two retries. The key is staged in a
temporary file, validated against the fingerprint, and atomically installed
(root:root, 0644). A failed download or a key with the wrong fingerprint never
overwrites an existing key. APT commands use IPv4 for this invocation without
changing the system-wide APT network policy. The installer ensures `curl`,
`gpg`, and CA certificates are available without stopping sing-box.

For networks that cannot reach `sing-box.app` (e.g. some mainland China
VPS environments), manually download `https://sing-box.app/gpg.key` on a
trusted machine, copy it to the server as
`/etc/apt/keyrings/sagernet.asc`, then rerun the installer. It will validate
and reuse that key without attempting another download. Alternatively, supply
the key directly:

```bash
bash sing-box/install-sing-box-debian.sh --key-file /root/sagernet.asc
```

`--key-file` requires an existing, non-empty regular file (not a symlink),
validates its fingerprint, and does not contact `sing-box.app/gpg.key` when the
file is valid. Access to the official APT repository is still required.

**Official package layout.** The SagerNet package-owned unit is
`/usr/lib/systemd/system/sing-box.service` (or the equivalent `/lib` path). It
has no maintainer scripts, no `User`/`Group`, no `StateDirectory`, and starts
in directory mode with `-C /etc/sing-box`. The installer therefore owns the
runtime identity and `ExecStart` through its drop-in, creates
`/var/lib/sing-box` itself, and reloads/restarts the service itself after a
package version change. The drop-in explicitly sets
`StateDirectoryMode=0755`; the current vendor unit has no `StateDirectory`, so
the installer also creates and normalizes `/var/lib/sing-box` directly, while
any future vendor `StateDirectory` remains 0755 and a stale `0750` override is
rejected. The package also ships
`/etc/sing-box/config.json` as a dpkg conffile; APT installation uses
`--force-confold` so existing configuration content is preserved. On a clean
install the package supplies its sample configuration, and the installer will
validate and start that sample unless `--no-start` is used; replace it first if
the sample is not the intended production configuration.

A regular local unit at `/etc/systemd/system/sing-box.service` shadows the
package unit. The installer refuses to make changes while such a unit exists.
Its error message directs the operator to `caddy/migrate-caddy-deployment.sh`,
the script that actually handles this: it validates,
backs up and removes the shadowing unit before normalization, so the package
unit stays authoritative instead of an official installation being reported
while a local unit remains in control. Likewise, if the existing effective unit
uses directory mode and the directory contains additional `*.json`/`*.jsonc`
inputs, the installer fails before changes rather than silently dropping them
by switching to `-c /etc/sing-box/config.json`; the migration and normalization
scripts apply the same rule.

**Unified systemd drop-in.** The vendor systemd unit remains unchanged. The
installer removes previous sing-box service drop-ins from both
`/etc/systemd/system/sing-box.service.d` and
`/run/systemd/system/sing-box.service.d` (for example `20-resolved.conf`,
`zzzz-single-file.conf`, etc.) and writes one unified drop-in at
`/etc/systemd/system/sing-box.service.d/override.conf`:

```ini
[Service]
User=www-data
Group=www-data
StateDirectoryMode=0755
ExecStart=
ExecStart=/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
```

The `ExecStart` uses `-c /etc/sing-box/config.json` (single file), not
`-C /etc/sing-box` (directory mode). The drop-in is compared with the desired
content; an already-correct drop-in is not rewritten. After `daemon-reload`,
the installer verifies the *effective* systemd values (`User`, `Group`,
`ExecStart`, `StateDirectoryMode`, `LoadState`) and the live service state
(`active`, not `failed`), so leftover drop-ins or a startup failure cannot be
reported as success.

**Unified filesystem permissions.**

| Path | Owner:Group | Mode |
|---|---|---|
| `/etc/sing-box/` | `root:www-data` | `0755` |
| `/etc/sing-box/config.json` | `root:www-data` | `0640` |
| `/var/lib/sing-box/` | `www-data:www-data` | `0755` |
| `/var/log/sing-box/` | `www-data:www-data` | `0755` |
| systemd drop-in directories | `root:root` | `0755` |
| systemd drop-in files | `root:root` | `0644` |
| executable files under managed directories | directory owner | `0755` |
| `/usr/bin/sing-box` | package-managed | — |

The installer inspects and normalizes these paths on every run, not just
on fresh installation. Managed top-level directories are set to the exact
matrix owner and mode (`0755`); ownership inside each tree follows the
matrix owner, and over-permissive modes are capped — directories to `0755`,
executable files to `0755`, ordinary files to `0644` — while existing
stricter modes are never relaxed (`0600` key material and `0700`
subdirectories survive every run). `config.json` is pinned to exactly
`0640`, not merely capped, because it can hold proxy credentials.
Persistent data is not deleted and file contents are not overwritten.
Symlinks at managed paths are rejected. Permission metadata is snapshotted
before normalization and restored if installation fails. The shared
normalizer implements the identical rules, so a second invocation of either
the installer or the normalizer never reverses the other's permissions.

**Service lifecycle.** The installer does **not** mask the service. A
pre-existing mask is removed before installation proceeds and is not restored
on failure. The running service is not stopped for key, repository, package, or
drop-in preparation. A restart occurs only when the systemd drop-in changed or
the APT package version changed; an already-compliant rerun issues no
`systemctl stop`, `start`, or `restart`. A previously stopped service is
started after validation, and enablement is normalized. The inspected package
control archive has no maintainer scripts, so package installation/upgrade
does not itself stop, restart or enable sing-box.

On failure, the installer restores the previous drop-ins, repository file and
permission metadata, attempts to restore the prior active/enabled state, and
reports the failure. A disk-only drop-in replacement or package upgrade is not
treated as a runtime transition: if the healthy process was never restarted,
rollback does not restart it. Where a start, restart or stop actually changed
runtime state, rollback restores the prior unit files and applies them again;
a failed restart that left the old process running is not restarted. Package
upgrades are not rolled back automatically and no package-version downgrade is
attempted; the installed package remains in place.

`--no-start` validates an existing `config.json` as `www-data`, leaves the
service enabled and unmasked, and stops it. It does not issue a stop for an
already inactive service; when a stop is needed, a non-zero `systemctl stop`
is an installation failure and success is reported only after the service is
confirmed inactive. If `config.json` is absent, the configuration check is
skipped and the service is not started. A missing `config.json` on an
already-active service is rejected before any change, so the installer cannot
stop a running service and then report success.

**Existing-installation normalization.** The installer is safe to rerun.
It inspects and corrects: APT repository configuration, GPG key validity and
fingerprint, package installation state, filesystem ownership and permissions,
existing systemd drop-ins, effective service user/group and `ExecStart`,
masked state, and service enablement/runtime status. It does not reinstall the
package unnecessarily, does not rewrite an already-correct drop-in or source
file, and does not restart the service when the installation is already
compliant. Existing configuration content and persistent state are preserved.

Isolated regression tests: `python3 tests/test_sing_box_install.py` (48 mocked
cases). They use fake `systemctl`, `apt-get`, `dpkg-query`, `curl`, `gpg`, and
`runuser` commands in a temporary fake filesystem. They verify control flow,
rollback boundaries, local-unit/directory-mode guards, effective
`StateDirectoryMode`/vendor-unit values and resulting files, but they are not
Debian/Ubuntu integration tests and do not prove APT repository, package, or
live-systemd behavior. No live Debian/Ubuntu integration test is included in
this PR.

**Follow-up validation.** Owner: repository maintainer. Trigger: before the
next production sing-box deployment and after any change to the APT
repository, package version, or systemd unit. Acceptance criteria: run on
Debian 12 and Ubuntu 22.04/24.04 systems with systemd (fresh install, package
upgrade, compliant rerun, `--no-start`, missing config, masked unit, local-unit
shadowing and directory-mode extra inputs), recording `systemctl show` output,
service state, file modes and installer exit status. Package-version rollback
remains a known limitation. The former cross-script normalization gap (the
deleted sing-box migration helper used its own `0750`/`0640` layout instead of
the installer's `0755`/`0644`) is closed by the consolidation: sing-box
reconciliation now runs through the shared normalizer, and the installer and
normalizer implement the identical permission matrix (`config.json` `0640` in
both), so there is only one layout and repeated invocations converge instead
of oscillating.


## One-time migration of an old server

This procedure is for servers using a legacy layout, for example:

```text
Caddy binary:  /usr/local/bin/caddy
Caddy unit:    /etc/systemd/system/caddy.service
Caddy config:  /etc/caddy/caddy.jsonc
Caddy storage: /home/tls
sing-box:      a local /etc/systemd/system/sing-box.service shadowing the
               package unit, and/or certificate_path/key_path references
               still pointing into the legacy storage root
```

`/home/tls` is the historical example, not a hardcoded assumption: legacy
storage roots are detected from first-hand evidence (a `file_system` storage
`root` in the Caddy config backed by real `acme/` **and** `certificates/`
directories, or an implicit default root derived from a legacy unit's
`Environment=HOME=`). Ambiguous evidence (a partial root, several roots, an
existing standard storage, leftover references outside certificate fields)
stops the migration before any change instead of guessing.

### 1. Update this repository

```bash
cd /root/linux_scripts
git pull --ff-only
```

If the repository is not present yet:

```bash
git clone https://github.com/choicky/linux_scripts.git /root/linux_scripts
cd /root/linux_scripts
```

### 2. Migrate the deployment (Caddy and sing-box)

```bash
bash caddy/migrate-caddy-deployment.sh
```

The script performs the whole one-time migration in order and delegates
package installation and runtime reconciliation instead of duplicating it:

1. detects the legacy layout from evidence and refuses ambiguous states before
   touching anything (a shadowing sing-box local unit is handled only when the
   package-owned unit exists to fall back to);
2. classifies sing-box certificate references into legacy-root-mapped,
   external and residual (residual stops the run);
3. backs up binaries, units, drop-ins, configurations, sing-box state and a
   permission manifest under `/root/caddy-migration-backup/<timestamp>`;
4. stops and removes the legacy Caddy paths so the package unit becomes
   authoritative; the legacy storage root is retained in place, never moved;
5. reruns `caddy/install-caddy-apt.sh --no-start` for the official APT
   package, the matching custom binary, dpkg-divert registration and the
   managed drop-ins;
6. copies the legacy storage into `/var/lib/caddy/.local/share/caddy` and
   rewrites only Caddy's FileStorage `root` (an implicit default root needs no
   rewrite because the managed drop-in sets `HOME=/var/lib/caddy`);
7. rewrites only `certificate_path`/`key_path` fields that follow the verified
   old-root → standard-root mapping, keeps explicit external PEM references in
   place, requires every referenced file to exist and be readable by
   `www-data`, and validates the sing-box candidate as `www-data` before
   applying it;
8. re-verifies **every** effective certificate/key reference in the live
   sing-box configuration with an actual read test as `www-data` — including
   external paths whose location the migration does not change — and stops
   before the runtime identity is changed or any service is activated when
   safe runtime access cannot be established;
9. backs up and removes a shadowing `/etc/systemd/system/sing-box.service` so
   the package unit wins (`--skip-sing-box` leaves sing-box entirely untouched
   and narrows normalization to `--caddy`);
10. calls the shared normalizer once (`normalize-caddy-services.sh --both`) to
    reconcile both services, drop-ins and permissions;
11. validates the migrated Caddy configuration as `www-data`, then activates
    exactly once: a service that was running before is restarted, a
    stopped/disabled service is left stopped/disabled.

If any step fails after changes were applied, the script restores the
pre-migration files, units, drop-ins, permission metadata and prior service
activity. Rollback does not downgrade APT packages and may leave a created
dpkg diversion in place (it is reported). Do not delete the retained legacy
storage root (such as `/home/tls`) after this step; verify and archive it
manually when you decide.

Re-running the script on a finished migration finds no legacy evidence and
exits without changes, pointing to the normalizer for routine reconciliation.

### 3. Install/standardize sing-box when needed

For servers that do not yet use the official Stable APT package, run:

```bash
bash sing-box/install-sing-box-debian.sh
```

The installer uses the official SagerNet APT repository and installs `sing-box`, never `sing-box-beta`. It retains the vendor systemd unit and uses a unified drop-in to run as `www-data:www-data` with `-c /etc/sing-box/config.json` (single file, not directory mode). It normalizes filesystem permissions to the shared matrix (managed directories `0755`, over-permissive inner modes capped to `0755`/`0755`/`0644` but existing stricter modes never relaxed, `config.json` pinned to `0640`), removes all existing drop-ins, and does not mask the service. See the installation and recovery options above.

If the server already has the correct official Stable package and service, do not reinstall it merely for the certificate-path migration; step 2 handled the references and the shared normalizer reconciles the startup layout.

### 4. Reconcile previously migrated servers

Servers migrated with an earlier version of these scripts may still run
Caddy and/or sing-box under another service account or have drifted from the
managed layout. For those servers:

```bash
bash caddy/normalize-caddy-services.sh --both
```

This is the same shared component that install, update and migration call. It
runs both services as `www-data:www-data` (so sing-box reads Caddy storage
certificates directly — no copying, ACLs or sync daemons), fixes Caddy/sing-box
state and log ownership, validates a running service's configuration as
`www-data` before restarting it, and restarts a service only when its unit
definition actually changed. A stopped/disabled service stays
stopped/disabled; a compliant layout produces no changes at all. Use `--caddy`
or `--sing-box` to reconcile a single service. On failure it restores the
drop-ins it applied, replays the permission manifest, and attempts to bring
back every previously running service whose state was disrupted; the rollback
is only reported as successful when that service recovery is verified, and
services that were already stopped or disabled are never started or enabled.
The backup directory it reports under `/run/normalize-caddy-services.*` is
retained.

The normalizer deliberately refuses to work while a local
`/etc/systemd/system/sing-box.service` shadows the package unit (and while a
Caddy package unit is shadowed by a local unit). That backup-and-remove duty
belongs to the one-time migration in step 2.

### 5. Final verification

```bash
echo '=== services ==='
systemctl is-active caddy sing-box

echo
echo '=== identities ==='
systemctl show caddy -p User -p Group
systemctl show sing-box -p User -p Group

echo
echo '=== processes ==='
ps -eo user,group,pid,comm,args | grep -E '[c]addy|[s]ing-box|php-fpm'

echo
echo '=== binaries ==='
ls -l /usr/bin/caddy /usr/bin/caddy.default /usr/bin/caddy.custom
/usr/bin/caddy version

echo
echo '=== old TLS references ==='
grep -Rni '/home/tls' /etc/caddy /etc/sing-box 2>/dev/null || true

echo
echo '=== listeners ==='
ss -lntup | grep -E ':(80|443|8443)\\b'

echo
echo '=== recent warnings/errors ==='
journalctl -u caddy --since '-3 minutes' --no-pager -p warning
journalctl -u sing-box --since '-3 minutes' --no-pager -p warning
```

Expected service identities:

```text
caddy:    User=www-data  Group=www-data
sing-box: User=www-data  Group=www-data
```

Typical listener layout used by these servers is Caddy on TCP 80/443/8443 and sing-box on UDP 443. Caddy may also listen on UDP 8443 for HTTP/3 when configured.

Finally test the actual proxy nodes and web/PHP applications. Service status and configuration validation do not replace an end-to-end test.

## Routine Caddy upgrade

After a server uses the standard Caddy layout, routine Caddy upgrades should use:

```bash
cd /root/linux_scripts
git pull --ff-only
bash caddy/update-caddy-debian.sh
```

The updater deliberately prepares the custom binary **before** changing the APT package. It:

1. refreshes APT metadata and reads the Caddy Stable candidate version;
2. when the installed APT version is already current, still reconciles the managed
   service state via the normalizer and then exits without restarting Caddy (it does
   not short-circuit before normalization);
3. downloads the exactly matching `caddy-linux-amd64` or `caddy-linux-arm64` release and `SHA256SUMS` from `choicky/caddy-custom-build`;
4. verifies SHA256, version, `caddy-l4`, `caddy-cloudflare-ip`, and built-in JSONC support;
5. validates the current JSONC configuration with the new custom binary as `www-data`;
6. only then stops/masks Caddy and upgrades the official APT package;
7. verifies that `/usr/bin/caddy.default` matches the prepared custom version;
8. replaces `/usr/bin/caddy.custom`, reconciles the managed service state with the
   normalizer, validates again, and restarts Caddy once;
9. restores the previous custom binary and attempts to restart the previous runtime if a failure occurs after Caddy has been stopped.

If the matching custom GitHub Release does not exist yet, the script stops **before** changing the installed APT package or running service. Build/release that Caddy version first, then rerun the updater.

**APT protection is deliberately minimum-sufficient.** The preflight requires the
`dpkg-divert` of the stock binary and the `/usr/bin/caddy` symlink to the custom
binary, and normalization re-asserts them. A plain `apt upgrade` therefore moves
the stock package behind the diversion while the verified custom binary stays
selected. The updater intentionally uses **no** `apt-mark hold` and **no** APT
pinning: either would block the stock security updates whose candidate version is
the updater's source of truth for which custom release to fetch.

Do not use `install-caddy-apt.sh` (or its `install-caddy-debian.sh` compatibility
name) as the normal upgrade command once the standard layout is installed.

## Backups and old TLS storage

After a migration, keep these rollback materials until the server has been stable and its proxy/web services have been tested:

- the retained legacy storage root (for example `/home/tls`)
- `/root/caddy-migration-backup/<timestamp>` — this single timestamped directory now
  also holds the sing-box configuration, the old shadowing sing-box local unit,
  drop-ins and the permission manifest that the removed helper used to write to
  `/root/sing-box-migration-backup/*`

Do not remove `/home/tls` while any service or configuration still references it.

## Already migrated servers

For servers such as those migrated with an earlier script revision, first update the repository and then run the shared normalizer only if the effective service identities have drifted:

```bash
cd /root/linux_scripts
git pull --ff-only
systemctl show caddy -p User -p Group
systemctl show sing-box -p User -p Group
```

If required:

```bash
bash caddy/normalize-caddy-services.sh --both
```

Do not rerun `caddy/migrate-caddy-deployment.sh` after the old `/usr/local/bin/caddy + /home/tls` layout has already been migrated; it detects no legacy evidence and exits, and routine reconciliation belongs to the normalizer.

### Failure handling and rollback boundaries

- Install/update verify the matching custom release before stopping Caddy. A missing
  release aborts; no automatic fallback to an older or stock binary is performed.
- Update pre-downloads the exact APT package, validates the custom core as
  `www-data`, and preserves the previous active/enabled state. Runtime rollback
  restores the custom binary and service state, **not the APT package version**;
  rerun the updater after resolving the failure to reconcile package/core versions.
- The one-time migration backs up binaries, units, drop-ins, configurations and a
  permission manifest under `/root/caddy-migration-backup/<timestamp>`, stops the new
  process before restoring the old unit/configuration, and keeps APT packages and any
  created dpkg diversion (reported, not reversed). The legacy storage root is copied,
  never moved, so it remains the manual rollback source.
- The shared normalizer validates a running service's configuration before it
  restarts and, on failure, restores the drop-ins it applied, replays the
  permission manifest and verifies that every previously running service is
  active again — reporting an INCOMPLETE rollback (with the retained backup
  under `/run/normalize-caddy-services.*`) when service recovery fails.
  Stopped/disabled services are never started or enabled by a rollback.

Validation: `python3 tests/test_caddy_normalize.py`, `python3 tests/test_caddy_migration.py`,
`python3 tests/test_caddy_install.py`, `python3 tests/test_caddy_os_support.py`,
`python3 tests/test_sing_box_install.py`,
`python3 tests/test_init_debian_server.py` and `bash tests/test_caddy_update.sh`; also
`bash -n caddy/*.sh` (run each file individually). The permission matrix is exercised
against real filesystem modes inside the mocked fixtures (including mode-`000`
read denial under the mocked runtime identity), but true directory-listing
behaviour for an ordinary non-`www-data` user and end-to-end identity changes
must be validated on a disposable Debian/Ubuntu VM with `systemctl` and APT —
never on a production VPS without explicit authorization. These mocked checks
do not replace installation/upgrade testing on a Debian or Ubuntu host.

`tests/test_caddy_os_support.py` covers the distribution matrix: the four
supported combinations, unsupported Debian/Ubuntu versions, apt-based
derivatives, and missing/empty/`ID`-less `/etc/os-release`, for the installer
and the updater alike. It also asserts that the two scripts share one
distribution policy and one repository-origin policy, that the compatibility
entry point forwards instead of reimplementing, and that the APT candidate is
rejected unless its own version-table entry is published by the official Caddy
repository. The origin fixtures run through both entry points and cover a
`universe`-only candidate, an older Cloudsmith version listed before a
`universe` candidate (which must still be rejected), a Cloudsmith candidate
listed after a `universe` version, the `***` and `::` installed markers, the
`/var/lib/dpkg/status` entry, a candidate with no origin line, a malformed
version entry, an empty table, and APT warning text around the table. On a real
Linux host it additionally runs the read-only `--check-os` probe against the
actual `/etc/os-release`; that self-skips where no such file exists.

**Follow-up validation.** Owner: repository maintainer. Trigger: before the
first Ubuntu Caddy deployment. Acceptance criteria: run
`bash caddy/install-caddy-apt.sh --no-start` on a disposable Ubuntu 24.04 and
26.04 instance, then confirm the Cloudsmith source was preferred over the
`universe` build, `systemctl show caddy -p User -p Group -p ExecStart` reports
the managed `www-data` layout, `/usr/bin/caddy` resolves to `caddy.custom`, and
a second run is a normalizing no-op. Mocked tests prove control flow and
refusals; they do not prove APT resolution or live systemd behaviour on Ubuntu.

## OpenWrt ZeroTier R3S/R4S site routes

Both routers use `openwrt/zerotier-site-route.sh`, with only the role different. ZeroTier network `233ccaac273aa22d` must already be joined and authorized in Central. R3S has LAN `192.168.13.0/24`, gateway `192.168.13.1`, and ZeroTier IP `192.168.192.13`; R4S has LAN `192.168.10.0/24`, gateway `192.168.10.1`, and ZeroTier IP `192.168.192.10`. The installer validates the local LAN address and discovers the ZeroTier device dynamically. It does not install, restart, or rejoin ZeroTier, nor modify Tailscale or sing-box.

Download the script to a local file, inspect it, and run on the appropriate router:

```sh
sh zerotier-site-route.sh install r3s  # R3S only
sh zerotier-site-route.sh install r4s  # R4S only
/usr/sbin/zerotier-site-route check
```

Installation configures two more-specific /25 routes to the other LAN (to take precedence over an overlapping Tailscale /24 route), creates one root cron entry to reconcile those routes every minute, and removes the exact legacy R3S cron entry for `/usr/sbin/zerotier-lan-routes` without deleting the legacy file. The cron job only repairs routes, not firewall rules.

For the already-installed ImmortalWrt `zerotier-fw4` integration, installation sets `fw_allow_input=1`, `fw_allow_forward=1`, and removes `fw_allow_masq` for the matching ZeroTier network. It also creates or reconciles a named IPv4 WAN input firewall rule, `zerotier_site_udp_9993` (`ZeroTier-Site-UDP-9993`), accepting UDP destination port 9993. This is **not** a port-forward/DNAT rule; no UPnP or blanket UDP allowance is added. The installer validates with `fw4 check` before committing, reloads the firewall, invokes `zerotier-fw4 -i` for the discovered interface, and verifies both generated and live inbound/outbound forwarding rules; it never restarts ZeroTier. The upstream generator may skip forwarding generation when an input rule already exists; in that case installation fails rather than falsely reporting success, and the incomplete generated state requires manual inspection. If another rule occupies the managed section name, installation refuses to overwrite it. A firewall reload is not equivalent to regeneration of every stale ZeroTier-generated nft include: `check` still fails if old masquerade rules remain and they must be addressed separately.

`check` validates the routes, ZeroTier NAT state, managed firewall UCI settings, and the generated and live ZeroTier forwarding rules; it does **not** prove end-to-end client reachability. Verify actual LAN clients in both directions, UDP reachability, and recovery after a reboot. The script does not configure ZeroTier Central Managed Routes or external upstream NAT/port mapping. Official ZeroTier guidance says manual port forwarding is normally unnecessary and unrestricted outbound UDP is preferable for peer-to-peer connectivity.

`uninstall` removes the managed routes, cron entry, script/config files, and the named UDP 9993 firewall rule if it still has the expected name. It leaves ZeroTier's input/forward/masquerade UCI settings as configured and does not uninstall ZeroTier. The router's firewall configuration must have a `wan` zone and working fw4 service; this tool is specific to the two named routers, not a generic ZeroTier provisioning system.
