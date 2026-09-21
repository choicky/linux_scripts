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

The installer uses the official SagerNet APT repository and installs `sing-box`, never `sing-box-beta`. It retains the vendor systemd unit and uses a minimal drop-in to run the service as `www-data:www-data`.

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
