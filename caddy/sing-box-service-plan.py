#!/usr/bin/env python3
"""Recognize the supported sing-box launch forms without changing live files."""
import json
from pathlib import Path
import re
import shlex
import sys


def plan(start, config='/etc/sing-box/config.json', state='/var/lib/sing-box'):
    match = re.search(r'argv\[\]=(.*?)\s*;\s*ignore_errors=', start)
    if not match:
        # Some systemd versions/test fixtures omit the remaining properties.
        match = re.search(r'argv\[\]=(.*?)\s*;', start)
    if not match:
        raise ValueError('Cannot read effective sing-box argv')
    argv = shlex.split(match[1])
    core = argv[0]
    base = [core, '-D', state]
    single = argv == base + ['-c', config, 'run']
    directory = argv == base + ['-C', str(Path(config).parent), 'run']
    if not single and not directory:
        raise ValueError('Unsupported sing-box argv; expected -D STATE with -c CONFIG or -C CONFIG_DIR')
    if directory:
        files = sorted(p.name for p in Path(config).parent.iterdir()
                       if p.name.lower().endswith(('.json', '.jsonc')))
        if files != [Path(config).name]:
            raise ValueError('Directory mode has additional/missing configuration files: ' + ', '.join(files))
    return {'change': directory, 'core': core}


if __name__ == '__main__':
    try:
        print(json.dumps(plan(sys.argv[1])))
    except (ValueError, OSError, IndexError) as exc:
        sys.exit('sing-box launch preflight: ' + str(exc))
