"""Release contracts: generated casks pin backend and execute install/upgrade hooks."""
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
RENDER = ROOT / 'scripts/render-cask.sh'
REVISION = 'a' * 40
SHA256 = 'b' * 64


class CaskReleaseTests(unittest.TestCase):
    def render(self, version='1.2.3', sha256=SHA256, revision=REVISION):
        return subprocess.run(
            ['bash', str(RENDER), version, sha256, revision],
            capture_output=True, text=True,
        )

    def test_release_pins_dmg_checksum_and_backend_commit(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('version "1.2.3"', result.stdout)
        self.assertIn(f'sha256 "{SHA256}"', result.stdout)
        self.assertIn('/reorx/feishu-lite/releases/download/v#{version}/FeishuChat-#{version}.dmg', result.stdout)
        self.assertIn(f'feishu-lite.git@{REVISION}#subdirectory=backend', result.stdout)
        self.assertIn('app "FeishuChat.app"', result.stdout)

    def test_invalid_release_metadata_produces_no_cask(self):
        for args in [('v1.2.3', SHA256, REVISION), ('1.2.3', 'bad', REVISION),
                     ('1.2.3', SHA256, 'master'), ('1.2.3";exit', SHA256, REVISION)]:
            with self.subTest(args=args):
                result = self.render(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')

    def test_homebrew_install_and_upgrade_execute_required_backend_install(self):
        result = self.render()
        self.assertEqual(result.returncode, 0, result.stderr)
        with tempfile.TemporaryDirectory() as directory:
            cask = pathlib.Path(directory) / 'feishu-lite.rb'
            cask.write_text(result.stdout)
            checked = subprocess.run(
                ['ruby', str(ROOT / 'scripts/tests/cask_contract.rb'), str(cask)],
                capture_output=True, text=True,
            )
        self.assertEqual(checked.returncode, 0, checked.stderr)


if __name__ == '__main__':
    unittest.main()
