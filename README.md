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

- `caddy/install-caddy-debian.sh` — install official Caddy Stable from APT, then use the matching prebuilt custom Caddy binary.
- `caddy/update-caddy-debian.sh` — safely upgrade Caddy only when the matching prebuilt custom binary is already available and verified.
- `caddy/migrate-caddy-debian.sh` — one-time migration from the old manual Caddy layout.
- `caddy/convert-services-to-www-data.sh` — one-time compatibility helper for servers migrated with the earlier runtime-user layout.
- `sing-box/install-sing-box-debian.sh` — install the official Stable `sing-box` APT package (not `sing-box-beta`) and run it as `www-data:www-data`.
- `sing-box/migrate-caddy-cert-paths.sh` — migrate certificate paths and normalize existing sing-box startup to a single config file without reinstalling packages.
- `system/init-debian-server.sh` — two-phase baseline initialization for fresh Debian 12/13 VPS instances; creates/verifies a sudo administrator, optional swap, fail2ban, and SSH hardening while deliberately retaining password authentication.
- `shell/setup-root-colors.sh` — optional root shell colour setup.
- `system/set-hostname.sh` — safely change a Debian 12/13 VPS hostname and matching hosts aliases.

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

## Clean installation

For a new Debian 12/13 or Ubuntu server that does not have the old manual Caddy layout:

```bash
git clone https://github.com/choicky/linux_scripts.git /root/linux_scripts
cd /root/linux_scripts

bash caddy/install-caddy-debian.sh
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
package unit. The installer refuses to make changes while such a unit exists
and points to `sing-box/migrate-caddy-cert-paths.sh`, which validates, backs up
and removes it once the running service is on `www-data:www-data`. This avoids silently reporting an official installation while
a local unit remains authoritative. Likewise, if the existing effective unit
uses directory mode and the directory contains additional `*.json`/`*.jsonc`
inputs, the installer fails before changes rather than silently dropping them
by switching to `-c /etc/sing-box/config.json`; the migration helper already
applies the same rule.

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
| `/etc/sing-box/config.json` | `root:www-data` | `0644` |
| `/var/lib/sing-box/` | `www-data:www-data` | `0755` |
| `/var/log/sing-box/` | `www-data:www-data` | `0755` |
| systemd drop-in files | `root:root` | `0644` |
| executable files under managed directories | directory owner | `0755` |
| `/usr/bin/sing-box` | package-managed | — |

The installer inspects and normalizes these paths on every run, not just
on fresh installation. Directories are set to `0755`; ordinary non-executable
files are set to `0644`, while files that are already executable retain
executable status and are set to `0755`. Persistent data is not deleted and
file contents are not overwritten. Symlinks at managed paths are rejected.
Permission metadata is snapshotted before normalization and restored if
installation fails. The accepted `0644` requirement makes `config.json`
world-readable; deployments that store proxy credentials or private material
in it must rely on stricter host access controls or revisit that requirement.

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
and the migration helper's separate `0750`/`0640` layout remain known
limitations; the migration helper is not repaired in this PR.


## One-time migration of an old server

This procedure is for servers using the legacy layout:

```text
Caddy binary:  /usr/local/bin/caddy
Caddy unit:    /etc/systemd/system/caddy.service
Caddy config:  /etc/caddy/caddy.jsonc
Caddy storage: /home/tls
```

The migration intentionally keeps `/home/tls` and a timestamped backup so rollback remains possible.

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

### 2. Migrate Caddy

```bash
bash caddy/migrate-caddy-debian.sh
```

The script:

1. verifies the expected old layout;
2. backs up the old Caddy binary, unit and configuration under `/root/caddy-migration-backup/<timestamp>`;
3. retains `/home/tls` in place;
4. installs Caddy Stable from the official APT repository;
5. downloads and verifies the matching prebuilt custom Caddy release;
6. registers the stock/custom binaries using dpkg-divert;
7. copies Caddy storage to `/var/lib/caddy/.local/share/caddy`;
8. rewrites only Caddy's FileStorage root;
9. validates and starts Caddy;
10. reports any remaining sing-box references to `/home/tls`.

Do not delete `/home/tls` after this step.

### 3. Normalize existing sing-box configuration and startup

Run:

```bash
bash sing-box/migrate-caddy-cert-paths.sh
```

This helper rewrites `certificate_path` and `key_path` entries from:

```text
/home/tls/...
```

to:

```text
/var/lib/caddy/.local/share/caddy/...
```

The same invocation also converts directory loading (`-C /etc/sing-box`) to:

```text
/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
```

It works even when certificate paths are already correct. It requires the existing service to run as `www-data:www-data`, with a writable `/var/lib/sing-box`; use the identity converter below first if needed. Additional JSON/JSONC files in directory mode are listed and block conversion so effective inputs are not silently discarded. Move confirmed historical JSON inputs outside the directory before retrying.

Before changing live files, it requires the installed Stable package and a package-owned vendor unit, checks certificate/key readability, and validates the candidate as `www-data`. It backs up and removes `/etc/systemd/system/sing-box.service` so the vendor unit is selected. It writes its own `/etc/systemd/system/sing-box.service.d/override.conf` using the migration helper's `StateDirectoryMode=0750` layout and retires the older generated `zzzz-single-file.conf` / `zzzz-caddy-single-file.conf`, retaining unrelated drop-ins. It normalizes config ownership/mode (`root:www-data`, 0640), the config directory (0750), state/log ownership and state-directory permissions according to its own documented helper layout (the APT installer itself uses 0755 directories, 0644 non-executable files, 0755 executable files, `StateDirectoryMode=0755`, and removes all drop-ins). It reenables and starts/restarts the service, including previously disabled/inactive services.

Configuration, the old local unit, drop-ins and permission metadata are backed up under `/root/sing-box-migration-backup/`. A switching/restart failure restores them and attempts to restore the previous enabled/active state. Already-correct enabled/active installations validate and skip changes/restart. It neither installs/upgrades packages nor modifies Caddy or `/home/tls`. Missing vendor units/certificates or conflicting unrelated drop-ins cause failure, rather than a success report for an incomplete layout. This helper still retains unrelated drop-ins and uses its `0750`/`0640` layout; that is a confirmed cross-script normalization gap relative to the APT installer's `0755`/`0644` all-drop-in normalization, recorded here but not repaired in this PR.

### 4. Install/standardize sing-box when needed

For servers that do not yet use the official Stable APT package, run:

```bash
bash sing-box/install-sing-box-debian.sh
```

The installer uses the official SagerNet APT repository and installs `sing-box`, never `sing-box-beta`. It retains the vendor systemd unit and uses a unified drop-in to run as `www-data:www-data` with `-c /etc/sing-box/config.json` (single file, not directory mode). It normalizes filesystem permissions (directories 0755, non-executable files 0644, executable files 0755), removes all existing drop-ins, and does not mask the service. See the installation and recovery options above.

If the server already has the correct official Stable package and service, do not reinstall it merely for the certificate-path migration.

### 5. Compatibility conversion for previously migrated servers

Servers that were migrated with an earlier version of these scripts may still run Caddy and/or sing-box as another service account. For those servers only:

```bash
bash caddy/convert-services-to-www-data.sh
```

This changes both services to `www-data:www-data`, fixes Caddy/sing-box state and log ownership, validates both configurations as `www-data`, and restarts the services.

A server migrated from scratch with the current scripts normally does not need this compatibility step if both services already show the expected runtime identities.

### 6. Final verification

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
2. exits without restarting Caddy when the installed APT version is already current;
3. downloads the exactly matching `caddy-linux-amd64` or `caddy-linux-arm64` release and `SHA256SUMS` from `choicky/caddy-custom-build`;
4. verifies SHA256, version, `caddy-l4`, `caddy-cloudflare-ip`, and built-in JSONC support;
5. validates the current JSONC configuration with the new custom binary as `www-data`;
6. only then stops/masks Caddy and upgrades the official APT package;
7. verifies that `/usr/bin/caddy.default` matches the prepared custom version;
8. replaces `/usr/bin/caddy.custom`, validates again, and restarts Caddy;
9. restores the previous custom binary and attempts to restart the previous runtime if a failure occurs after Caddy has been stopped.

If the matching custom GitHub Release does not exist yet, the script stops **before** changing the installed APT package or running service. Build/release that Caddy version first, then rerun the updater.

Do not use `install-caddy-debian.sh` as the normal upgrade command once the standard layout is installed.

## Backups and old TLS storage

After a migration, keep these rollback materials until the server has been stable and its proxy/web services have been tested:

- `/home/tls`
- `/root/caddy-migration-backup/<timestamp>`
- `/root/sing-box-migration-backup/*` configuration/startup backups (older versions used `/etc/sing-box/config.json.before-caddy-storage-migration-*`)

Do not remove `/home/tls` while any service or configuration still references it.

## Already migrated servers

For servers such as those migrated with an earlier script revision, first update the repository and then run the compatibility conversion only if the effective service users are not already correct:

```bash
cd /root/linux_scripts
git pull --ff-only
systemctl show caddy -p User -p Group
systemctl show sing-box -p User -p Group
```

If required:

```bash
bash caddy/convert-services-to-www-data.sh
```

Do not rerun `caddy/migrate-caddy-debian.sh` after the old `/usr/local/bin/caddy + /home/tls` layout has already been migrated.

### Caddy failure-handling fixes (2026-10-16)

- Install/update verify the matching custom release before stopping Caddy. A missing
  release aborts; no automatic fallback to an older or stock binary is performed.
- Update pre-downloads the exact APT package, validates the custom core as
  `www-data`, and preserves the previous active/enabled state. Runtime rollback
  restores the custom binary and service state, **not the APT package version**;
  rerun the updater after resolving the failure to reconcile package/core versions.
- Legacy migration retains existing service drop-ins for rollback and stops the
  new process before restoring the old unit/configuration.
- Identity conversion retains override/permission backups under
  `/root/www-data-conversion.*`; failed conversion attempts restore them and
  restart previously active services. Newly created empty directories may remain.
- Sing-box normalization validates a candidate before changing live configuration/startup.
  It enables and starts/restarts the normalized service; on failure it restores
  the prior configuration, local unit, drop-ins, permissions and service state.

Validation: `bash tests/test_caddy_update.sh`; `bash -n caddy/*.sh` (run each file
individually). These checks do not replace installation/upgrade testing on Debian.
