#!/usr/bin/env python3
"""Plan archival without guessing which historical filenames are inactive."""
import importlib.util
import json
from pathlib import Path
import sys


def plan(configs):
    roots = [Path(p).parent for p in configs]
    for root in roots:
        if root.is_symlink() or any(p.is_symlink() for p in root.rglob('*')):
            raise ValueError(f'Configuration directory contains symlinks; review dependencies: {root}')
    spec = importlib.util.spec_from_file_location('migration_config', Path(__file__).with_name('migration-config.py'))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    keep = {Path(p) for p in configs}
    # Native JSON/JSONC configurations have no adapter imports. Preserve local
    # file/directory references, including rule sets and TLS/client-auth files.
    for config in configs:
        for key, (_, _, value) in module.document(config)[2].items():
            if not isinstance(value, str):
                continue
            path = Path(value)
            if not path.is_absolute():
                if value and (str(key[-1]).endswith(('_path', '_file')) or str(key[-1]) in ('path', 'filename', 'certificate', 'key', 'root') or value.startswith(('./', '../'))):
                    raise ValueError(f'Review relative file reference in {config}: {".".join(map(str, key))}')
                continue
            if '..' in path.parts:
                raise ValueError(f'Review non-normalized path in {config}')
            if any(path == root or root in path.parents for root in roots):
                if not path.exists():
                    raise ValueError(f'Missing configuration dependency: {path}')
                keep.add(path)
                if path.is_dir():
                    keep.update(path.rglob('*'))
    for path in list(keep):
        for parent in path.parents:
            if parent in roots:
                break
            if any(root in parent.parents for root in roots):
                keep.add(parent)
    files = {p for root in roots for p in root.rglob('*') if p.is_file()}
    return {'keep': sorted(str(p) for p in keep),
            'exclude': sorted(str(p) for p in files - keep),
            'roots': [str(p) for p in roots]}


if __name__ == '__main__':
    try:
        print(json.dumps(plan(sys.argv[1:])))
    except (OSError, ValueError, KeyError) as exc:
        sys.exit(f'Configuration archive preflight: {exc}')
