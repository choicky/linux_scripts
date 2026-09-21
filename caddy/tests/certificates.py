#!/usr/bin/env python3
"""Isolated read-only scanner/ACL tests; only synthetic secrets are used."""
import contextlib
import importlib.util
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location(
    'certificate_check', Path(__file__).resolve().parents[1] / 'certificate-check.py')
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class CertificateAuditTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.config = self.root / 'sing-box'
        self.config.mkdir()
        self.storage = self.root / 'caddy'
        self.certs = self.storage / 'certificates'
        self.patches = [patch.object(audit, 'CONFIG_ROOT', self.config),
                        patch.object(audit, 'STORAGE', self.storage),
                        patch.object(audit, 'CERTIFICATES', self.certs),
                        patch.object(audit, 'PARENTS', (self.storage,))]
        for item in self.patches:
            item.start()
            self.addCleanup(item.stop)

    def write(self, text, name='config.json'):
        path = self.config / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, encoding='utf-8')
        return path

    def run_check(self, command):
        stream = io.StringIO()
        with contextlib.redirect_stdout(stream):
            rc = audit.main([command])
        output = stream.getvalue()
        self.assertNotIn('synthetic-secret', output)
        return rc, output

    def test_absent_config_is_safe(self):
        self.config.rmdir()
        self.assertEqual(self.run_check('migration')[0], 0)

    def test_clean_config_and_read_only(self):
        path = self.write('{"password":"synthetic-secret"}')
        before = path.read_bytes(), path.stat().st_mtime_ns
        self.assertEqual(self.run_check('paths')[0], 0)
        self.assertEqual(self.run_check('migration')[0], 0)
        self.assertEqual(before, (path.read_bytes(), path.stat().st_mtime_ns))
        self.assertFalse(self.storage.exists())

    def test_literal_nested_extensionless_and_comments(self):
        for text in ('{"key_path":"/home/tls/site.key", "uuid":"synthetic-secret"}',
                     '// previously /home/tls; synthetic-secret',
                     '{"certificate_path":"/home/tls/site.crt"}'):
            with self.subTest(text=text):
                path = self.write(text, 'nested/fragment')
                rc, output = self.run_check('migration')
                self.assertEqual(rc, 1)
                self.assertIn(str(path).replace('\\', '\\\\'), output)
                self.assertNotIn('site.key', output)
                self.assertNotIn('site.crt', output)

    def test_json_slash_unicode_and_normalized_paths(self):
        values = (r'\/home\/tls\/site.key', r'\u002fhome\u002ftls/site.key',
                  '/home//tls/site.key', '/home/tmp/../tls/site.key')
        for value in values:
            with self.subTest(value=value):
                self.write('{"key_path":"' + value + '"}')
                self.assertEqual(self.run_check('paths')[0], 1)

    def test_read_failure_is_not_clean(self):
        self.write('{}')
        with patch.object(Path, 'open', side_effect=PermissionError('synthetic-secret')):
            rc, output = self.run_check('migration')
        self.assertEqual(rc, 2)
        self.assertIn('CHECK_INCOMPLETE', output)

    def test_inaccessible_root_is_not_treated_as_absent(self):
        with patch.object(Path, 'lstat', side_effect=PermissionError('synthetic-secret')):
            self.assertEqual(self.run_check('migration')[0], 2)

    def test_broken_link_or_scan_failure_is_not_clean(self):
        with patch.object(audit, 'config_files', side_effect=OSError('synthetic-secret')):
            self.assertEqual(self.run_check('migration')[0], 2)

    def test_shared_new_storage_blocks_even_without_old_path(self):
        import json
        self.write(json.dumps({'key_path': str(self.certs / 'site.key')}))
        self.assertEqual(self.run_check('paths')[0], 0)
        rc, output = self.run_check('migration')
        self.assertEqual(rc, 1)
        self.assertIn('SHARED_CADDY_STORAGE_REFERENCE', output)
        self.assertIn('default ACLs alone are insufficient', output)

    def test_acl_masks_defaults_and_excess_rights(self):
        acl = 'user::rwx\nuser:123:r-x\ngroup::---\nmask::r-x\nother::---\n'
        self.assertTrue(audit.acl_matches(acl, 123, 'rx'))
        self.assertFalse(audit.acl_matches(acl.replace('mask::r-x', 'mask::---'), 123, 'rx'))
        self.assertFalse(audit.acl_matches(acl.replace('user:123:r-x', 'user:123:rwx'), 123, 'rx'))
        self.assertFalse(audit.acl_matches(acl, 123, 'rx', default=True))
        defaults = ''.join('default:' + line + '\n' for line in acl.splitlines())
        self.assertTrue(audit.acl_matches(acl + defaults, 123, 'rx', default=True))

    def test_acl_scope_and_no_false_renewal_guarantee(self):
        self.certs.mkdir(parents=True)
        (self.certs / 'site.key').write_text('synthetic-secret')
        (self.storage / 'acme-account.key').write_text('synthetic-secret')
        seen = []

        def getacl(path):
            seen.append(path)
            perm = '--x' if path == self.storage else 'r-x' if path.is_dir() else 'r--'
            value = f'user::rwx\nuser:123:{perm}\ngroup::---\nmask::{perm}\nother::---\n'
            if path == self.certs:
                value += 'default:user:123:r-x\ndefault:mask::r-x\n'
            return value

        with patch.object(audit, 'sing_box_uid', return_value=123), \
                patch.object(audit, 'read_acl', side_effect=getacl):
            rc, output = self.run_check('access')
        self.assertEqual(rc, 1)
        self.assertIn('CURRENT_ACL_ENTRIES_OK_NOT_A_RENEWAL_GUARANTEE', output)
        self.assertIn('RENEWAL_ACCESS_UNPROVEN', output)
        self.assertNotIn(self.storage / 'acme-account.key', seen)
        self.assertEqual(set(seen), {self.storage, self.certs, self.certs / 'site.key'})

    def test_parent_symlink_stops_acl_walk(self):
        with patch.object(audit, 'sing_box_uid', return_value=123), \
                patch.object(Path, 'is_symlink', return_value=True), \
                patch.object(audit, 'read_acl') as read_acl:
            rc, output = self.run_check('access')
        self.assertEqual(rc, 1)
        self.assertIn('ACL_PARENT_MISSING_OR_SYMLINK', output)
        read_acl.assert_not_called()

    def test_missing_tool_or_user_fails_closed(self):
        with patch.object(audit, 'sing_box_uid', side_effect=FileNotFoundError('synthetic-secret')):
            self.assertEqual(self.run_check('access')[0], 2)

    def test_missing_tree_and_default_acl_are_reported(self):
        self.certs.mkdir(parents=True)
        with patch.object(audit, 'sing_box_uid', return_value=123), \
                patch.object(audit, 'read_acl', return_value='user::rwx\ngroup::---\nother::---\n'):
            rc, output = self.run_check('access')
        self.assertEqual(rc, 1)
        self.assertIn('ACL_PARENT_REQUIRES_TRAVERSE_ONLY', output)
        self.assertIn('ACL_DEFAULT_MISSING_MASKED_OR_EXCESSIVE', output)


if __name__ == '__main__':
    unittest.main()
