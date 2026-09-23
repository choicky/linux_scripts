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
- `sing-box/migrate-caddy-cert-paths.sh` — migrate sing-box certificate/key paths from legacy Caddy storage to the standard Caddy storage.
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

### 3. Migrate sing-box certificate paths

Run:

```bash
bash sing-box/migrate-caddy-cert-paths.sh
```

This helper only rewrites `certificate_path` and `key_path` entries from:

```text
/home/tls/...
```

to:

```text
/var/lib/caddy/.local/share/caddy/...
```

Before editing, it verifies that every corresponding certificate/key already exists in the new Caddy storage. It creates a timestamped backup of `/etc/sing-box/config.json`, validates the modified configuration as `www-data`, and restores the backup if validation fails. It does not remove `/home/tls`.

### 4. Install/standardize sing-box when needed

For servers that do not yet use the official Stable APT package, run:

```bash
bash sing-box/install-sing-box-debian.sh
```

The installer uses the official SagerNet APT repository and installs `sing-box`, never `sing-box-beta`. It retains the vendor systemd unit and uses a drop-in to run as `www-data:www-data` with only `/etc/sing-box/config.json`. See the installation and recovery options above.

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

Do not rerun `caddy/migrate-caddy-debian.sh` after the old `/usr/local/bin/caddy + /home/tls` layout has already been migrated.
