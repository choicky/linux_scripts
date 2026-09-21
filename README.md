# linux_scripts

Personal Linux server administration and deployment scripts.

Planned components:

- `caddy/` — Caddy installation, upgrade, validation, and rollback scripts.
- `sing-box/` — sing-box Stable installation and configuration checks.
- `web/` — Web/PHP environment setup helpers.

## Design principles

- Prefer official APT repositories and official systemd services.
- Keep modifications to upstream service/configuration files to a minimum.
- Run Caddy, sing-box, and PHP-FPM as `www-data:www-data`; keep the administrative login user (`ubuntu`) separate.
- Use `/var/www/<site>` for website repositories, normally owned by `ubuntu:ubuntu`.
- Grant PHP-FPM write access only to application directories that require it.
- Let Caddy manage TLS certificates; sing-box reads certificates directly from Caddy storage.
