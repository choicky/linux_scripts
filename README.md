# linux_scripts

Personal Linux server administration and deployment scripts.

Planned components:

- `caddy/` — Caddy installation, upgrade, validation, and rollback scripts.
- `sing-box/` — sing-box Stable installation, upgrade, and configuration checks.
- `web/` — Web/PHP environment setup helpers.

## Design principles

- Prefer official APT repositories and official systemd services.
- Keep modifications to upstream service/configuration files to a minimum.
- Keep service users separated (`caddy`, `sing-box`, `www-data`) from the administrative login user (`ubuntu`).
- Use `/var/www/<site>` for website repositories, normally owned by `ubuntu:ubuntu`.
- Grant PHP-FPM write access only to application directories that require it.
- Let Caddy manage TLS certificates; sing-box reads certificates directly from Caddy storage.

## Caddy manager (Debian 12/13)

`caddy/manage-caddy.sh` keeps the official Stable APT package and its service/user
layout. The official executable is diverted to `/usr/bin/caddy.default`; the
custom executable is `/usr/bin/caddy.custom`, selected explicitly through
`update-alternatives` at `/usr/bin/caddy`. The only added modules are:

- `github.com/mholt/caddy-l4`
- `github.com/WeidiDeng/caddy-cloudflare-ip`
- `github.com/caddyserver/jsonc-adapter`

The configuration is always `/etc/caddy/caddy.jsonc` with adapter `jsonc`.
The manager writes only an `ExecStart`/`ExecReload` drop-in, never a replacement
for the vendor service. See the [official custom binary procedure](https://caddyserver.com/docs/build#package-support-files-for-custom-builds-for-debianubunturaspbian)
and [Stable APT repository instructions](https://caddyserver.com/docs/install#debian-ubuntu-raspbian).
It never runs experimental `caddy upgrade`.

### Prerequisites and commands

Run as root on a systemd host. Have `iproute2` (`ss`), `util-linux` (`flock`,
`runuser`), coreutils, dpkg and APT available. Upgrade also needs `curl`, a current
Go toolchain and `xcaddy` already installed in root's PATH; the script does not
silently install a compiler. All commands work without an interactive terminal.

Prepare your JSONC before installing. Provide a binary with the three modules
for installation; migration reuses the selected managed custom binary when present, otherwise
defaulting to `/usr/local/bin/caddy`. Examples:

```bash
# Fresh install: choose ports actually required by YOUR configuration.
sudo env CADDY_CUSTOM_BINARY=/path/to/custom-caddy \
  CADDY_REQUIRED_PORTS="tcp:80 tcp:443" bash caddy/manage-caddy.sh install

# Legacy www-data unit, /usr/local/bin/caddy, /home/tls:
sudo bash caddy/manage-caddy.sh migrate

# Build the latest upstream Stable release using xcaddy:
sudo bash caddy/manage-caddy.sh upgrade

sudo bash caddy/manage-caddy.sh check
sudo bash caddy/manage-caddy.sh status

# Latest committed snapshot, or a particular snapshot printed by the manager:
sudo bash caddy/manage-caddy.sh rollback
sudo bash caddy/manage-caddy.sh rollback /var/backups/caddy-manager/TIMESTAMP.SUFFIX
```

`CADDY_REQUIRED_PORTS` is a space-separated list such as `tcp:443 udp:443`.
The manager automatically preserves all TCP/UDP listening ports owned by the
running Caddy MainPID, including the admin port. Explicit ports augment that
baseline. For an inactive/fresh installation, explicit ports are required.
Port checks verify ownership by the new Caddy process, not just an unrelated
process listening on the same port. They do not replace application-level HTTP,
TLS, DNS or upstream connectivity checks.

### Upgrade and transaction recovery

Upgrade fetches GitHub's latest non-prerelease Caddy release, builds that exact
version with the three modules, verifies the reported version and exact module
IDs, and validates the current JSONC with the new binary as both root and caddy
before touching the installed binary. Module dependencies resolve at build time;
this is not a reproducible build with pinned plugin revisions.

The transaction is: preflight → private backup → change → validate → restart →
active/MainPID/executable/port checks → commit. Binary replacement uses a temporary
file in `/usr/bin` and a same-filesystem rename. Download/build failures fail
closed; a timeout bounds validation and building (`CADDY_BUILD_TIMEOUT`, default
1800 seconds). Health checks retry for approximately 15 seconds. A lock prevents
concurrent manager operations; avoid running other package/service management
commands during a transaction.

Snapshots under `/var/backups/caddy-manager` contain binaries, `/etc/caddy`, local
and runtime units/drop-ins, the usual multi-user enablement link, both storage
trees, alternatives selection/priorities/mode, diversion state and service
active/enabled metadata. They also contain private diagnostic unit metadata:
**treat backups as secrets**. The directory is root-only; status and validation
never print JSONC, certificate contents or journal messages.

On any error or handled INT/TERM/HUP after the transaction starts, the manager
restores the selected snapshot, validates the old configuration and starts/checks
the old executable if it was previously active. A previously inactive service
stays inactive. A failed recovery returns an error and retains its backup for
manual recovery. SIGKILL, kernel crashes and power loss cannot run a shell trap;
keep the printed snapshot path for explicit recovery. Manual rollback first
creates a rescue snapshot of the current environment. Old v1 snapshots without
transaction metadata are rejected.

Rollback removes only manager-supported alternatives/diversion changes. It
**does not uninstall the official Caddy package** or remove the newly configured
Stable APT repository: if the package was newly installed, its binary remains
available while the old local service and binary resume serving traffic.

Successful transactions retain five committed snapshots by default; change with
`CADDY_BACKUP_KEEP=10`. Incomplete, failed and restored snapshots are retained for
manual review. Rollback without an argument chooses the latest still-committed
snapshot; explicit paths also allow recovery from failed transactions.

### Migration details and limits

Migration stops the writer after the initial backup, refreshes the storage
snapshot, prevents APT maintainer scripts from auto-starting services with a
short-lived `policy-rc.d`, installs the official package, and removes legacy
local units/drop-ins after backing them up. It restores any pre-existing
`policy-rc.d` on exit. The effective target service must run as `caddy:caddy`.
Existing third-party legacy overrides are intentionally not carried into the new
service; review any environment files, bind mounts, capabilities or custom
sandbox requirements beforehand.

`/home/tls` is copied into `/var/lib/caddy/.local/share/caddy` without overwriting
existing destination files. Literal JSONC storage roots `/home/tls` and
`/home/tls/` are rewritten. Other references are rejected for manual adjustment.
The JSONC becomes `root:caddy` mode 0640; storage belongs to `caddy:caddy`.
Rollback overlays saved storage contents and ownership, preserving files created
since the snapshot. It never deletes `/home/tls`, even after a successful migration.
Repeated migration therefore cannot replace newer target certificates with stale
legacy ones. No sing-box files or services are changed.

Validation runs without importing arbitrary systemd environment directives. A
configuration that needs those variables or additional filesystem permissions
may fail validation safely; resolve that before restarting. Masked/transient
service states, foreign diversion owners, unusual enablement/alias links, alternatives slave links and foreign
binary candidates are rejected instead of guessed. Health checks cover the main
Caddy process; special multi-process wrappers are unsupported.

### Local verification

```bash
bash -n caddy/manage-caddy.sh
bash -n caddy/tests/transactions.sh
shellcheck caddy/manage-caddy.sh caddy/tests/transactions.sh
bash caddy/tests/transactions.sh
```

The test harness redirects production paths into a `mktemp` directory and uses
command doubles for systemd/divert/alternatives; it does not operate a real
service or package database. It exercises legacy/custom rollback, storage
preservation, inactive-state restoration, automatic error recovery and recovery
failure reporting, plus upgrade build/validation/replacement/restart/health failures. Windows Git Bash can run the suite, but does not establish
Debian ownership, symlink, APT or systemd integration correctness. Before production
use, verify fresh install, migration, failed restart and rollback in disposable
Debian 12 and 13 systemd VMs with representative non-secret configurations.
