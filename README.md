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
- `caddy/migrate-caddy-debian.sh` — inspect/reconcile an existing Caddy layout and migrate Caddy/sing-box certificate storage together.
- `caddy/Standardize-Caddy.ps1` / `standardize-caddy.bat` — Windows batch entry points for inspection or migration over existing SSH aliases.
- `caddy/convert-services-to-www-data.sh` — one-time compatibility helper for servers migrated with the earlier runtime-user layout.
- `sing-box/install-sing-box-debian.sh` — install the official Stable `sing-box` APT package (not `sing-box-beta`) and run it as `www-data:www-data`.
- `sing-box/migrate-caddy-cert-paths.sh` — migrate sing-box certificate/key paths from legacy Caddy storage to the standard Caddy storage.
- `system/init-debian-server.sh` — two-phase baseline initialization for fresh Debian 12/13 VPS instances; creates/verifies a sudo administrator, optional swap, fail2ban, and SSH hardening while preserving the existing password-authentication policy by default.
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

For a new Debian 12/13 server that does not have the old manual Caddy layout:

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
not a rollback of package/binary changes. The separate sing-box installer's masked
state and recovery behavior are documented below.

Do not use the migration procedure below for a clean server.

### sing-box installation and recovery

The sing-box installer supports Debian 12/13 and installs official Stable
`sing-box` from the SagerNet APT repository. By default it downloads the official
GPG key from `https://sing-box.app/gpg.key`, using IPv4, a 10-second connection
timeout, a 30-second timeout per attempt and at most two retries. The key is
staged in a temporary file and atomically installed as
`/etc/apt/keyrings/sagernet.asc` (root:root, 0644); a failed download leaves any
existing key intact. APT commands use IPv4 for this invocation without changing
the system-wide APT network policy.

For domestic VPS environments or other networks that cannot reach
`sing-box.app`, obtain the official key on a trusted machine and securely copy
it to the server, then run as root:

```bash
bash sing-box/install-sing-box-debian.sh --key-file /root/sagernet.asc
```

`--key-file` requires an existing, non-empty regular file and uses it without
contacting `sing-box.app/gpg.key`. Access to the official APT repository is still
required.

The vendor systemd unit remains unchanged. The installer writes
`/etc/systemd/system/sing-box.service.d/override.conf` with `User=www-data`,
`Group=www-data` and an `ExecStart` reset followed by:

```text
/usr/bin/sing-box -D /var/lib/sing-box -c /etc/sing-box/config.json run
```

The sole production configuration is `/etc/sing-box/config.json`
(`root:www-data`, 0640). Other JSON files in `/etc/sing-box/`, including old,
test and backup configurations, are not automatically loaded by systemd.
Existing state/cache files under `/var/lib/sing-box` are made writable by
`www-data:www-data`.

`--no-start` stops and masks the service but **still checks an existing
config.json as www-data**, including its access to referenced files. An invalid
configuration fails the installation. If config.json is absent, the installer
skips the check and leaves the service stopped and masked, with or without
`--no-start`. Both options may be combined.

Rerunning the installer is supported, including after a key-download failure
that left the service masked. Existing repository/drop-in files are rewritten
in place without appending duplicate entries. After preparing the configuration,
rerun without `--no-start`: only a successful check permits unmasking, enabling
and restarting. Startup verifies active state and the effective User, Group and
single-file ExecStart. A startup or verification failure stops and masks the
service to prevent restart loops, then prints status and recent journal entries.
Earlier installation failures also leave the service stopped and masked; fix
the reported cause and rerun.

## Standardize existing VPS installations

Target: official Caddy Stable APT package; matching custom binary selected using
`dpkg-divert`; vendor service plus a `www-data:www-data` drop-in; configuration
`/etc/caddy/caddy.jsonc`; certificate storage
`/var/lib/caddy/.local/share/caddy`. Existing sing-box keeps its executable,
service and proxy settings; only `certificate_path` / `key_path` references
under `/home/tls/` are rewritten.

Update or clone this repository, then inspect on the server as root:

```bash
cd /root/linux_scripts
git pull --ff-only
bash caddy/migrate-caddy-debian.sh
```

If absent, clone first:

```bash
git clone https://github.com/choicky/linux_scripts.git /root/linux_scripts
```

Default mode does not stop services or install packages. To execute:

```bash
bash caddy/migrate-caddy-debian.sh --apply
```

The script handles these states automatically:

| Current state | Action with `--apply` |
| --- | --- |
| Standard binaries/service, standard storage and sing-box paths | Validate; no restart |
| Standard binaries/service, Caddy and/or sing-box still using `/home/tls` | Reconcile storage and certificate references; no package installation |
| Manual or incomplete package layout, supported executable/service | Prepare package/custom binary first, then install standard layout and reconcile storage |

`--storage-only` additionally requires an already standard installation; it may
be combined with `--apply`. Fresh installations still use the installer.

Preflight requires Debian 12/13, amd64/arm64 for package installation, Python 3,
`flock`, an active Caddy JSONC service running as `www-data:www-data`, and explicit
filesystem storage at `/home/tls` or the target path. Supported Caddy executable
paths are `/usr/local/bin/caddy`, `/usr/bin/caddy`, and `/usr/bin/caddy.custom`.
If sing-box configuration exists, its service must use that single config file
and the `www-data:www-data` identity. Unexpected layouts stop for inspection;
the script does not guess arbitrary paths or convert service accounts.

Migration behavior:

1. Stage comment-preserving JSONC edits; other configuration fields are retained.
2. For manual layouts, download/verify the matching custom core and pre-download
   the exact APT package while production Caddy is still running. Installer
   `--prepare-only DIR` creates the private bundle; `--prepared-dir DIR --no-start`
   rechecks and consumes it with APT `--no-download`. The exact Caddy package is
   reinstalled even when already recorded as installed, so a manually replaced
   `/usr/bin/caddy` cannot be mistaken for the official stock core. These options
   are migration plumbing, not the normal install/upgrade interface.
3. Back up configs, Caddy executable entries, unit and drop-ins under
   `/root/caddy-migration-backup/<timestamp-pid>` before switching.
4. Stop Caddy and existing sing-box during the switch. If copying `/home/tls`,
   retain it unchanged; move any existing target storage to the sibling
   `caddy.before-migration-<timestamp-pid>` before copying the active source.
5. Verify destination certificate/key readability as `www-data`; validate both
   staged configurations as `www-data`; only then replace live configs.
6. Restart Caddy and previously active sing-box, preserve Caddy boot-enable
   state and previously inactive sing-box state, and check service status and
   Caddy identity/entry point. Services are briefly interrupted.
7. On failure after the switch starts, attempt to restore configs, the previous
   destination storage and the old runtime. Package/repository/diversion changes
   are not rolled back; inspect reported restoration failures before retrying.
   A concurrent migration is rejected using a host-local lock.

Do not remove old storage or backups until websites and actual proxy nodes have
been tested. Config validation/service activity does not prove end-to-end health.
Do not restore an old JSONC afterward without preserving the standardized storage
paths, or the next certificate renewal may write to a different directory.

### Windows batch entry

Keep `Standardize-Caddy.ps1` and `standardize-caddy.bat` in the same directory.
The remote host needs `git`; SSH aliases and interactive sudo are reused. Each
host gets a temporary repository checkout, leaving existing checkouts untouched.
The default target list includes HK, SG, JP–JP4, KR–KR3, US–US7, TR and SZ once
each; aliases such as `oraclekr3` / `alisz` are not duplicated.

```powershell
# Inspect all hosts; double-clicking the BAT does the same.
& .\Standardize-Caddy.ps1

# Migrate KR3 first.
& .\Standardize-Caddy.ps1 -Targets @('kr3') -Apply

# Then migrate all hosts; already compliant ones are validated and skipped.
& .\Standardize-Caddy.ps1 -Apply
```

The BAT accepts `-Apply` too. To use one fixed revision across a batch, pass
`-Revision <full-commit-sha>`; otherwise each host checks out current `main` and
prints the resolved commit. A failed/closed SSH connection is reported separately
from a successful run; reconnect and inspect services before retrying.

### Other helpers

- `sing-box/migrate-caddy-cert-paths.sh` remains a standalone path-only helper for
  cases where Caddy storage has already been migrated. It does not restart
  sing-box; normally the integrated migration above handles both components.
- `caddy/convert-services-to-www-data.sh` is only for an older installation using
  other service accounts. It changes **both** identities/permissions, validates
  configs and restarts them; it is not a storage or package migration. It retains
  override/permission backups under `/root/www-data-conversion.*` and attempts
  restoration on failure; newly created empty directories may remain.

Validation: `python3 tests/test_caddy_migration.py` covers JSONC edits, idempotency,
manual-layout preparation ordering, successful storage migration and rollback in
an isolated filesystem with mocked service/package commands. Installer lifecycle
checks remain in `tests/test_caddy_install.py`. No live Debian migration is implied.

## Routine Caddy upgrade

After a server uses the standard Caddy layout, routine Caddy upgrades should use:

```bash
cd /root/linux_scripts
git pull --ff-only
bash caddy/update-caddy-debian.sh
```

The updater deliberately prepares the custom binary **before** changing the APT package. It:

1. refreshes APT metadata and reads the Caddy Stable candidate version;
2. exits without restarting only when both installed stock and custom versions match the candidate;
3. downloads the exactly matching `caddy-linux-amd64` or `caddy-linux-arm64` release and `SHA256SUMS` from `choicky/caddy-custom-build`;
4. verifies SHA256, version, `caddy-l4`, `caddy-cloudflare-ip`, and built-in JSONC support;
5. validates the current JSONC configuration with the new custom binary as `www-data`;
6. only then stops/masks Caddy and upgrades the official APT package;
7. verifies that `/usr/bin/caddy.default` matches the prepared custom version;
8. replaces `/usr/bin/caddy.custom`, validates again, and restarts Caddy;
9. restores the previous custom binary and attempts to restart the previous runtime if a failure occurs after Caddy has been stopped.

If the matching custom GitHub Release does not exist yet, the script stops **before** changing the installed APT package or running service. Build/release that Caddy version first, then rerun the updater.

Do not use `install-caddy-debian.sh` as the normal upgrade command once the standard layout is installed.


Runtime rollback restores the old custom binary and service state, not the APT
package version. After resolving a failure, rerun the updater to reconcile them.
Update regression checks: `bash tests/test_caddy_update.sh`. These isolated checks
do not replace Debian installation/upgrade testing.
