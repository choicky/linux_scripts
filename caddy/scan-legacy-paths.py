#!/usr/bin/env python3
"""Report legacy certificate consumers without printing configuration secrets."""
import difflib
import re
import sys
from pathlib import Path

ROOTS = ['/etc/caddy', '/etc/sing-box', '/etc/systemd/system',
         '/usr/lib/systemd/system', '/etc/nginx', '/etc/haproxy', '/etc/cron.d']


def scan(caddy, sing, candidate_caddy, candidate_sing, *exclude):
    replacements = {Path(caddy).resolve(): Path(candidate_caddy),
                    Path(sing).resolve(): Path(candidate_sing)}
    files = set(replacements)
    for root in ROOTS:
        directory = Path(root)
        if directory.exists():
            files.update(p for p in directory.rglob('*') if p.is_file())
    excluded = {Path(p).resolve() for p in exclude}
    seen = set()
    findings = []
    for path in sorted(files):
        resolved = path.resolve()
        if resolved in excluded or resolved in seen:
            continue
        # Backups do not consume certificates. Report files, not secret contents.
        if re.fullmatch(r'(?:caddy\.jsonc|config\.json)-good-\d{8}', path.name):
            print(f'INFO: historical config backup ignored: {path}', file=sys.stderr)
            continue
        if any(marker in path.name for marker in ('.bak', '.old', '.before-', '.migration-')):
            continue
        seen.add(resolved)
        actual = replacements.get(resolved, path)
        if not actual.exists():
            continue
        for line, content in enumerate(actual.read_bytes().splitlines(), 1):
            if b'/home/tls' in content:
                findings.append(f'{path}:{line}')
    return findings


def changes(paths):
    import importlib.util
    spec = importlib.util.spec_from_file_location('migration_config', Path(__file__).with_name('migration-config.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    # Diff only changed path fields. Full config diffs could expose passwords
    # when input is minified or credentials share a line with a certificate path.
    for original, candidate in ((paths[0], paths[2]), (paths[1], paths[3])):
        if original == '-':
            continue
        before = module.document(original)[2]
        after = module.document(candidate)[2]
        old, new = [], []
        for key, (_, _, value) in before.items():
            updated = after[key][2]
            if value != updated:
                label = '.'.join(map(str, key))
                old.append(f'{label}: {value}\n')
                new.append(f'{label}: {updated}\n')
        sys.stdout.writelines(difflib.unified_diff(old, new, fromfile=original, tofile=candidate))


if __name__ == '__main__':
    try:
        if sys.argv[1] == '--changes':
            changes(sys.argv[2:])
        else:
            print('\n'.join(scan(*sys.argv[1:])))
    except (OSError, ValueError, IndexError, KeyError) as exc:
        sys.exit(f'Legacy reference inspection failed: {exc}')
