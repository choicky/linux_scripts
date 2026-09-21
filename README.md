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
