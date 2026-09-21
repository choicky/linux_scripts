#!/usr/bin/env python3
"""Read-only sing-box path/ACL audit; never print configuration values or errors.

Exit 0: selected check passed; 1: unsafe dependency/ACL; 2: incomplete scan.
Default ACLs cannot override CertMagic's restrictive creation modes. Migration
with a detected dependency on the new storage therefore fails closed too.
"""
import argparse
import json
import posixpath
from pathlib import Path
import re
import stat
import subprocess
import sys

CONFIG_ROOT = Path('/etc/sing-box')
STORAGE = Path('/var/lib/caddy/.local/share/caddy')
CERTIFICATES = STORAGE / 'certificates'
PARENTS = tuple(Path(p) for p in (
    '/var/lib/caddy', '/var/lib/caddy/.local',
    '/var/lib/caddy/.local/share', str(STORAGE)))
STRING = re.compile(r'"(?:[^"\\]|\\.)*"', re.DOTALL)
MAX_BYTES = 16 * 1024 * 1024


def report(code, path=None):
    # JSON-escape filenames as well (newlines/control characters cannot forge output).
    print(code + (': ' + json.dumps(str(path), ensure_ascii=True) if path else ''))


def config_files(root):
    """Follow config symlinks, reject cycles, broken links and non-regular files.

    All regular files are scanned, including extensionless files and backups.
    This deliberately errs on the side of blocking, not missing dependencies.
    """
    def walk(path, ancestors):
        resolved = path.resolve(strict=True)
        mode = path.stat().st_mode
        if stat.S_ISDIR(mode):
            if resolved in ancestors:
                raise OSError('cycle')
            for child in sorted(path.iterdir()):
                yield from walk(child, ancestors | {resolved})
        elif stat.S_ISREG(mode):
            yield path
        else:
            raise OSError('non-regular file')
    yield from walk(root, set())


def contains_path(text, prefix):
    # Conservative matching includes comments, JSON escaped slashes and Unicode.
    values = [text]
    for match in STRING.finditer(text):
        try:
            values.append(json.loads(match.group()))
        except (ValueError, UnicodeError):
            continue
    return any(prefix in value or prefix in posixpath.normpath(value)
               for value in values)


def scan_paths(root):
    legacy, shared = [], []
    try:
        root.lstat()
    except FileNotFoundError:
        return legacy, shared
    if not root.is_dir():
        raise OSError('configuration root is not a directory')
    for path in config_files(root):
        with path.open('rb') as stream:
            data = stream.read(MAX_BYTES + 1)
        if len(data) > MAX_BYTES:
            raise OSError('file too large to audit')
        text = data.decode('utf-8', errors='surrogateescape')
        if contains_path(text, '/home/tls'):
            legacy.append(path)
        if contains_path(text, str(STORAGE)):
            shared.append(path)
    return legacy, shared


def acl_entries(text):
    entries = {}
    for line in text.splitlines():
        line = line.partition('#')[0].strip()
        if not line:
            continue
        fields = line.split(':')
        key, perms = ':'.join(fields[:-1]), fields[-1]
        if len(perms) != 3 or any(c not in 'rwx-' for c in perms):
            raise ValueError('invalid ACL')
        entries[key] = set(perms) - {'-'}
    return entries


def acl_matches(text, uid, needed, default=False):
    entries = acl_entries(text)
    prefix = 'default:' if default else ''
    named = entries.get(prefix + 'user:' + str(uid))
    mask = entries.get(prefix + 'mask:')
    if named is None or mask is None:
        return False
    # Reject a masked write grant too: a future mask change could enable it.
    return named == set(needed) and named & mask == set(needed)


def read_acl(path):
    result = subprocess.run(['getfacl', '-cpn', '--', str(path)],
                            capture_output=True, text=True, check=True)
    return result.stdout


def sing_box_uid():
    result = subprocess.run(['id', '-u', 'sing-box'],
                            capture_output=True, text=True, check=True)
    uid = int(result.stdout.strip())
    if uid == 0:
        raise ValueError('sing-box must not be root')
    return uid


def audit_acl():
    uid = sing_box_uid()
    ok = True
    for path in PARENTS:
        if path.is_symlink() or not path.is_dir():
            report('ACL_PARENT_MISSING_OR_SYMLINK', path)
            # Stop here: descendants may resolve through this unsafe parent.
            return False
        if not acl_matches(read_acl(path), uid, 'x'):
            report('ACL_PARENT_REQUIRES_TRAVERSE_ONLY', path)
            ok = False
    if CERTIFICATES.is_symlink() or not CERTIFICATES.is_dir():
        report('ACL_CERTIFICATES_MISSING_OR_SYMLINK', CERTIFICATES)
        return False
    # Do not follow storage symlinks or inspect anything outside certificates.
    stack = [CERTIFICATES]
    while stack:
        path = stack.pop()
        mode = path.lstat().st_mode
        directory = stat.S_ISDIR(mode)
        if not directory and not stat.S_ISREG(mode):
            report('ACL_UNSUPPORTED_STORAGE_ENTRY', path)
            ok = False
            continue
        acl = read_acl(path)
        if not acl_matches(acl, uid, 'rx' if directory else 'r'):
            report('ACL_ACCESS_MISSING_MASKED_OR_EXCESSIVE', path)
            ok = False
        if directory:
            if not acl_matches(acl, uid, 'rx', default=True):
                report('ACL_DEFAULT_MISSING_MASKED_OR_EXCESSIVE', path)
                ok = False
            stack.extend(sorted(path.iterdir(), reverse=True))
    if ok:
        report('CURRENT_ACL_ENTRIES_OK_NOT_A_RENEWAL_GUARANTEE')
    return ok


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('check', choices=('paths', 'access', 'migration'))
    args = parser.parse_args(argv)
    try:
        legacy, shared = scan_paths(CONFIG_ROOT)
        for path in legacy:
            report('LEGACY_STORAGE_REFERENCE', path)
        for path in shared:
            report('SHARED_CADDY_STORAGE_REFERENCE', path)
        if legacy:
            report('BLOCKED: manually change sing-box certificate_path/key_path; '
                   '/home/tls is rollback data, not renewed storage. See README.')
        if args.check == 'paths':
            if not legacy:
                report('NO_LEGACY_STORAGE_REFERENCES_FOUND')
            return int(bool(legacy))
        if args.check == 'access':
            audit_acl()
            # Even perfect current/default ACLs cannot guarantee future access.
            report('RENEWAL_ACCESS_UNPROVEN: CertMagic creates 0600 files/0700 '
                   'directories; default ACLs alone cannot grant future access.')
            return 1
        if shared:
            report('BLOCKED: shared-storage renewal permissions require a separate '
                   'design; default ACLs alone are insufficient. See README.')
        return int(bool(legacy or shared))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        # Never expose exception strings, subprocess output or config fragments.
        report('CHECK_INCOMPLETE: cannot safely inspect configuration/ACLs; '
               'check access, symlink loops, file types, python3/acl tools and sing-box user.')
        return 2


if __name__ == '__main__':
    sys.exit(main())
