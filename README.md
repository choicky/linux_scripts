# linux_scripts

Personal Linux server administration and deployment scripts.

- `caddy/` — Caddy installation, migration, upgrade, validation and rollback.
- `sing-box/` and `web/` — planned components.

## Caddy manager — Debian 12/13

`caddy/manage-caddy.sh` uses the official Stable APT repository, vendor service
and `dpkg-divert`/`update-alternatives` layout:

- `/usr/bin/caddy.default`: official APT binary.
- `/usr/bin/caddy.custom`: custom binary, selected at `/usr/bin/caddy`.
- Custom modules: `github.com/mholt/caddy-l4`,
  `github.com/WeidiDeng/caddy-cloudflare-ip`, `github.com/caddyserver/jsonc-adapter`.
- Configuration: `/etc/caddy/caddy.jsonc`, always with `--adapter jsonc`.

Caddy and sing-box share the existing **sing-box:sing-box** account. Caddy keeps
its official service; `/etc/systemd/system/caddy.service.d/override.conf` sets
`User=sing-box`, `Group=sing-box` and JSONC `ExecStart`/`ExecReload`. It also fixes
`HOME=/var/lib/caddy` so switching accounts does not relocate Caddy's default
storage or autosaved configuration to sing-box's home. This is a fixed service
setting, not a new script option. Do not override Caddy's HOME/XDG paths elsewhere.

Caddy storage remains `/var/lib/caddy/.local/share/caddy`. The manager assigns
`/var/lib/caddy` and its contents to `sing-box:sing-box`, including parent
directories required for access. `/etc/caddy` becomes `root:sing-box` mode 0750;
`caddy.jsonc` becomes `root:sing-box` mode 0640. The APT-created caddy account is
left installed, but is no longer the runtime account.

The official sing-box service and `/etc/sing-box` are never edited or restarted.
There are no ACLs, certificate scanners, cron jobs, copy-to-sing-box tasks or
certificate synchronization helpers. Both processes have the same filesystem
identity; they can read the same private keys, including newly created files.

## Usage

Run as root with systemd, coreutils, dpkg/APT, `iproute2` (`ss`) and `util-linux`
(`flock`, `runuser`). Install sing-box's official user/group first; the manager
checks their existence without changing accounts or the sing-box service.
Upgrade also needs `curl`, a current Go toolchain and `xcaddy` in root's PATH.
No Python or ACL tools are required; commands work without an interactive terminal.

```bash
# Prepare /etc/caddy/caddy.jsonc and a binary with the three modules first.
# Set ports to match YOUR configuration.
sudo env CADDY_CUSTOM_BINARY=/path/to/custom-caddy \
  CADDY_REQUIRED_PORTS="tcp:80 tcp:443" bash caddy/manage-caddy.sh install

# Migrate a legacy www-data unit, or switch an existing caddy:caddy deployment.
sudo bash caddy/manage-caddy.sh migrate
sudo bash caddy/manage-caddy.sh upgrade
sudo bash caddy/manage-caddy.sh check
sudo bash caddy/manage-caddy.sh status

# Latest committed snapshot, or an explicit snapshot directory:
sudo bash caddy/manage-caddy.sh rollback
sudo bash caddy/manage-caddy.sh rollback /var/backups/caddy-manager/TIMESTAMP.SUFFIX
```

Migration uses the selected custom binary if present, otherwise
`/usr/local/bin/caddy`; `CADDY_CUSTOM_BINARY` can supply a different binary.
An existing caddy-user deployment must run `migrate` before `upgrade`.
`CADDY_REQUIRED_PORTS` augments the running MainPID's TCP/UDP listeners, e.g.
`tcp:443 udp:443`. Explicit ports are required for an inactive/fresh installation.
Checks verify active state, MainPID, executable and port ownership; they do not
replace application-level HTTP/TLS/upstream tests.

## Migration and certificate paths

Migration copies `/home/tls` once into the standard storage, without overwriting
newer destination files on repeated runs. Literal JSONC roots `/home/tls` and
`/home/tls/` are rewritten to `/var/lib/caddy/.local/share/caddy`. Use that explicit
file-system root or Caddy's default storage; other custom storage paths are outside
this migration's scope. `/home/tls` remains old data for manual review and rollback;
it is not renewed after migration and is not a long-term certificate source.

After verifying Caddy, **manually** update sing-box's `certificate_path` and
`key_path` to the actual issuer/domain files under:

```text
/var/lib/caddy/.local/share/caddy/certificates/<issuer>/<domain>/<domain>.crt
/var/lib/caddy/.local/share/caddy/certificates/<issuer>/<domain>/<domain>.key
```

This script neither scans nor blocks old sing-box paths. Coordinate the sing-box
configuration change and any activation yourself. Keep its previous configuration
for a coordinated manual rollback; the manager rolls back Caddy only.

## Transactions and recovery

The flow remains **preflight → backup → change → validate → restart → health
check → commit**. Upgrade builds the latest Stable release with xcaddy and checks
its version, modules and JSONC before replacing the installed custom binary using
a same-directory temporary file and atomic rename. It never runs `caddy upgrade`.
Validation of the target runs as sing-box with Caddy's fixed HOME.

Root-only snapshots in `/var/backups/caddy-manager` preserve binaries, `/etc/caddy`,
local/runtime units and drop-ins, storage files with ownership/modes, alternatives,
diversion and active/enabled state. Migration stops Caddy and refreshes storage
before changing ownership. A temporary `policy-rc.d` blocks package auto-starts
and is restored on exit. Legacy Caddy units/drop-ins are backed up and replaced
by the official unit plus the small drop-in.

On failure or handled INT/TERM/HUP, rollback restores the old unit (including its
user/group), JSONC, binaries and package-selection state. Saved storage ownership
and permissions are restored; retained new files take the old storage directory's
owner. `/home/tls` is not deleted. The old binary/config is validated as its former
user before starting and checking a previously active service; an inactive service
stays inactive. Rollback does not require the new sing-box account. It never
uninstalls the official Caddy package. An explicit rollback first takes a rescue
snapshot of the current Caddy environment.

Keep backups private: they contain configuration, keys and service metadata.
By default, five committed snapshots are kept (`CADDY_BACKUP_KEEP` changes this).
Failed/restored snapshots are retained. Build timeout is 1800 seconds
(`CADDY_BUILD_TIMEOUT`); health checks retry for about 15 seconds. A lock prevents
concurrent manager runs. Avoid concurrent package/service changes. SIGKILL or
power loss cannot run a shell trap; use the printed backup path for recovery.
A failed recovery reports an error and retains its snapshot for manual repair.

## Verification

```bash
bash -n caddy/manage-caddy.sh
bash -n caddy/tests/transactions.sh
shellcheck caddy/manage-caddy.sh caddy/tests/transactions.sh
bash caddy/tests/transactions.sh
```

Tests use temporary paths and systemd/APT/ownership doubles. They cover legacy
and custom rollback, inactive state, upgrade failures, shared-user setup,
repeated/no-legacy storage setup and migration failures. Windows Git Bash can
run them, but cannot verify actual Linux ownership, APT or systemd integration.
Test those in disposable Debian 12/13 VMs before production use.
