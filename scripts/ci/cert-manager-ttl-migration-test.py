import io
import json
import os
import unittest
from unittest.mock import patch
import urllib.error
import subprocess
from pathlib import Path

# Run from repository root: nix develop -c python3 scripts/ci/cert-manager-ttl-migration-test.py
# Mock only HTTPS transport; execute the actual inline Job program, never provider writes.
ROOT = Path(__file__).resolve().parents[2]
JOB = ROOT / 'infrastructure/base/network/cert-manager-issuer/media-acme-ttl-migration.job.yaml'
manifest = json.loads(subprocess.check_output(['yq', '-o=json', str(JOB)], text=True))
code = manifest['spec']['template']['spec']['containers'][0]['command'][2]
ns = {'__name__': 'migration_test'}
exec(compile(code, JOB, 'exec'), ns)

class MigrationTest(unittest.TestCase):
    def run_main(self, responses):
        calls = []
        def transport(req, timeout):
            self.assertEqual(timeout, 15)
            calls.append(req)
            item = next(responses)
            if isinstance(item, Exception):
                raise item
            return io.StringIO(json.dumps(item))
        with patch.dict(os.environ, HETZNER_TOKEN='secret-test-value'), patch('urllib.request.urlopen', transport), patch('time.sleep'):
            ns['main']()
        return calls

    def test_migrate_preserves_records(self):
        calls = self.run_main(iter([{'rrset': {'ttl': 120, 'records': [{'value':'original'}]}}, {'action': {'status': 'running'}}, {'rrset': {'ttl':120}}, {'rrset': {'ttl':300}}]))
        writes = [c for c in calls if c.get_method() == 'POST']
        self.assertEqual(len(writes), 1)
        self.assertEqual(writes[0].full_url, 'https://api.hetzner.cloud/v1/zones/f4mily.net/rrsets/_acme-challenge.media/TXT/actions/change_ttl')
        self.assertEqual(json.loads(writes[0].data), {'ttl':300})

    def test_idempotent(self):
        calls = self.run_main(iter([{'rrset': {'ttl':300}}]))
        self.assertEqual(len(calls), 1)
        self.assertEqual(calls[0].get_method(), 'GET')

    def test_unexpected_ttl_refuses_write(self):
        with self.assertRaisesRegex(RuntimeError, 'Unexpected media ACME TXT TTL'):
            self.run_main(iter([{'rrset': {'ttl': 600}}]))

    def test_failure_logs_are_sanitized(self):
        stderr = io.StringIO()
        secret = 'never-print-token-or-provider-response'
        error = urllib.error.HTTPError('https://provider', 403, secret, {}, io.BytesIO(secret.encode()))
        with patch.dict(os.environ, HETZNER_TOKEN=secret), patch('urllib.request.urlopen', side_effect=error), patch('sys.stderr', stderr):
            with self.assertRaises(SystemExit) as exit_info:
                exec(compile(code, str(JOB), 'exec'), {'__name__': '__main__'})
        self.assertEqual(exit_info.exception.code, 1)
        self.assertEqual(stderr.getvalue(), 'Media ACME TTL migration failed: Hetzner API HTTP 403\n')
        self.assertNotIn(secret, stderr.getvalue())

    def test_timeout(self):
        with self.assertRaisesRegex(RuntimeError, 'TTL update timed out'):
            self.run_main(iter([{'rrset':{'ttl':120}}, {'action':{}}] + [{'rrset':{'ttl':120}}] * 24))

    def test_api_error_sanitized(self):
        exc = urllib.error.HTTPError('https://private-url', 403, 'secret response text', {}, io.BytesIO(b'secret-token'))
        with self.assertRaisesRegex(RuntimeError, '^Hetzner API HTTP 403$'):
            self.run_main(iter([exc]))

    def test_network_error_sanitized(self):
        with self.assertRaisesRegex(RuntimeError, '^Hetzner API connection failed$'):
            self.run_main(iter([urllib.error.URLError('secret-response')]))

unittest.main()
