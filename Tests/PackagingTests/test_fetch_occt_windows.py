"""Offline regression tests for Windows dependency download/cache failure handling."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/fetch-occt-windows.sh'


class FetchOCCTTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.dest = self.root / "OCCT with spaces and 'quotes'"
        self.env = dict(os.environ, PATH=f'{self.bin}:{os.environ["PATH"]}')
        self.stub('cygpath', '#!/usr/bin/env bash\nprintf "%s\\n" "$2"\n')
        self.stub('curl', '''#!/usr/bin/env python3
import os, sys, zipfile
from pathlib import Path
out = Path(sys.argv[sys.argv.index('-o') + 1])
url = sys.argv[-1]
if os.environ.get('FAIL_DOWNLOAD') or '3rdparty' in url:
    out.write_text('partial failed transfer')
    sys.exit(22)
with zipfile.ZipFile(out, 'w') as z:
    z.writestr('install/include/opencascade/Standard.hxx', '// fixture')
    if not os.environ.get('NO_LIBRARY'):
        z.writestr('install/lib/TKernel.lib', 'fixture')
    z.writestr('install/bin/TKernel.dll', 'fixture')
''')

    def stub(self, name, body):
        path = self.bin / name
        path.write_text(body)
        path.chmod(0o755)

    def fetch(self):
        return subprocess.run(['bash', str(SCRIPT), str(self.dest)], env=self.env,
                              capture_output=True, text=True)

    def test_failed_download_rejects_stale_archive(self):
        self.dest.mkdir()
        (self.dest / 'occt.zip').write_text('stale archive')
        self.env['FAIL_DOWNLOAD'] = '1'
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('could not download OCCT', result.stderr)
        self.assertFalse((self.dest / '.fetched').exists())

    def test_invalid_install_is_not_cached(self):
        self.env['NO_LIBRARY'] = '1'
        result = self.fetch()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('TKernel.lib not found', result.stderr)
        self.assertFalse((self.dest / '.fetched').exists())

    def test_environment_quotes_paths_and_cache_can_be_reused(self):
        result = self.fetch()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((self.dest / '.fetched').exists())
        self.assertFalse((self.dest / '3rdparty.zip.download').exists())
        result = subprocess.run(['bash', '-c', '. "$1"; printf "%s\\n%s" "$FORGE_OCCT_PREFIX" "$PATH"',
                                 'test', str(self.dest / 'forge-env.sh')],
                                env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        prefix, path = result.stdout.split('\n', 1)
        self.assertEqual(prefix, str(self.dest / 'occt/install'))
        self.assertEqual(path.split(':')[0], str(self.dest / 'occt/install/bin'))
        self.env['FAIL_DOWNLOAD'] = '1'
        self.assertEqual(self.fetch().returncode, 0)


if __name__ == '__main__':
    unittest.main()
