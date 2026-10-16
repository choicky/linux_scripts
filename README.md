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
- `caddy/migrate-caddy-debian.sh` — reconcile manual/standard installations, certificate storage and sing-box paths.
- `caddy/convert-services-to-www-data.sh` — one-time compatibility helper for servers migrated with the earlier runtime-user layout.
- `sing-box/install-sing-box-debian.sh` — install the official Stable `sing-box` APT package (not `sing-box-beta`) and run it as `www-data:www-data`.
- `sing-box/migrate-caddy-cert-paths.sh` — migrate sing-box certificate/key paths from legacy Caddy storage to the standard Caddy storage.
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

## One-time migration of an old server

The migration reconciles existing manual and already standardized Caddy layouts.
It supports Debian 12/13, JSONC at `/etc/caddy/caddy.jsonc`, an active Caddy,
and Caddy/sing-box already running as `www-data:www-data`. Unexpected layouts,
service identities, external drop-ins, storage symlinks or config directories
stop during preflight for review. Use the compatibility conversion below first
when the runtime identities differ; do not apply it blindly to every server.

```bash
cd /root/linux_scripts
git pull --ff-only
# Plan: does not stop services or install packages.
bash caddy/migrate-caddy-debian.sh
# Execute the reviewed plan:
bash caddy/migrate-caddy-debian.sh --apply
# Optional: refuse a binary migration, allow storage-only on a standard layout:
bash caddy/migrate-caddy-debian.sh --storage-only --apply
```

- Already standard installation, storage and paths: validate and skip restarting.
- Standard installation with legacy storage: copy storage and adapt both configs.
- Manual installation: prepare and verify the matching custom core and pre-download
  the APT package before stopping services, then install the standard layout.
- Plan prints a diff of changed path fields only, avoiding credential disclosure.
  Legacy `/home/tls` references are scanned in Caddy/sing-box configs, systemd units,
  nginx/haproxy configs and cron.d at plan time and after apply. Remaining references
  block both plan and apply with exit code 4 (BLOCKED). Already-standardized
  runs return 3 (SKIPPED); a completed plan/apply returns 0. The Windows wrapper
  streams SSH output directly so sudo prompts and download progress stay visible.
  Preflight excludes only the local legacy unit that will be removed and the
  override.conf that will be replaced; other retained drop-ins remain scanned.
  The post-apply scan has no such exclusions.
  Backup filenames with .bak/.old/.before-/.migration- are excluded;
  names such as caddy.jsonc.orig and config.json~ are intentionally still reported.
  Review these files before moving backups outside scanned directories;
  inspect custom consumers outside
  these directories separately. Comments containing old paths can also trigger review.
- Only Caddy `storage.root` and sing-box `certificate_path`/`key_path` are edited;
  comments and unrelated values remain. Both candidate configs are validated as
  `www-data` before replacement. Only affected active services are restarted.
- Backups live under `/root/caddy-migration-backup`. `/home/tls` is retained.
  An existing destination tree is retained separately rather than merged.
- Failure attempts to restore configs, storage, binaries and effective services;
  APT packages/repositories/diversions are **not** rolled back. Inspect any reported
  restoration failure before retrying. Test actual websites/proxy nodes before
  removing old storage or backups.

### Windows batch entry

`caddy/Invoke-CaddyMigration.ps1` downloads one immutable repository revision and
uploads the same scripts to each SSH alias. Targets must be supplied explicitly using local SSH aliases; keep your fleet list locally. Each host can prompt for its sudo password; failed hosts do not stop the
remaining hosts. Use a commit containing these scripts, not a moving branch name.

```powershell
.\Invoke-CaddyMigration.ps1 -Revision <40-character-commit> -Targets kr3
.\Invoke-CaddyMigration.ps1 -Revision <40-character-commit> -Targets kr3 -Apply
# After checking KR3, explicitly choose the next hosts:
.\Invoke-CaddyMigration.ps1 -Revision <40-character-commit> -Targets hk,sg -Apply
```

The separate `sing-box/migrate-caddy-cert-paths.sh` remains useful for path-only
repairs after storage has already been migrated. The coordinated Caddy migrator
now handles this adaptation itself; there is no additional helper step required.

### 1. Install/standardize sing-box when needed

For servers that do not yet use the official Stable APT package, run:

```bash
bash sing-box/install-sing-box-debian.sh
```

The installer uses the official SagerNet APT repository and installs `sing-box`, never `sing-box-beta`. It retains the vendor systemd unit and uses a drop-in to run as `www-data:www-data` with only `/etc/sing-box/config.json`. See the installation and recovery options above.

If the server already has the correct official Stable package and service, do not reinstall it merely for the certificate-path migration.

### 2. Compatibility conversion for previously migrated servers

Servers that were migrated with an earlier version of these scripts may still run Caddy and/or sing-box as another service account. For those servers only:

```bash
bash caddy/convert-services-to-www-data.sh
```

This changes both services to `www-data:www-data`, fixes Caddy/sing-box state and log ownership, validates both configurations as `www-data`, and restarts the services.

A server migrated from scratch with the current scripts normally does not need this compatibility step if both services already show the expected runtime identities.

### 3. Final verification

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
- timestamped `/etc/sing-box/config.json.before-caddy-storage-migration-*` backups

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

The reconciler can be rerun: an already standardized layout is validated and skipped.

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
- Certificate-path migration validates a staged candidate before atomically
  replacing sing-box configuration. It does not restart sing-box automatically.

Validation: `bash tests/test_caddy_update.sh`; `bash -n caddy/*.sh` (run each file
individually). These checks do not replace installation/upgrade testing on Debian.
