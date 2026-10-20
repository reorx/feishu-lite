"""Exercise notarization boundaries without Apple credentials or network access."""

import os
import pathlib
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
NOTARIZE = ROOT / 'mac/scripts/notarize.sh'
MOCK_TOOL = r"""#!/bin/bash
set -eu
tool=${0##*/}
printf '%s %s\n' "$tool" "$*" >> "$EVENTS"
case "$tool:$1" in
    xcrun:notarytool)
        if [[ "$2" == submit ]]; then
            printf '{"id":"test-submission","status":"%s"}\n' "${NOTARY_STATUS:-Accepted}"
        fi
        ;;
    xcrun:stapler)
        if [[ "$2" == staple && "${FAIL_STAPLE_ONCE:-0}" == 1 && ! -f "$EVENTS.retry" ]]; then
            touch "$EVENTS.retry"
            exit 68
        fi
        if [[ "$2" == validate && "${FAIL_VALIDATE:-0}" == 1 ]]; then
            exit 65
        fi
        ;;
    spctl:*) echo 'source=Notarized Developer ID' ;;
    hdiutil:attach)
        while [[ "$1" != -mountpoint ]]; do shift; done
        mkdir -p "$2/FeishuLite.app"
        ;;
    hdiutil:detach) rmdir "$2/FeishuLite.app" ;;
esac
"""


class NotarizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = pathlib.Path(self.temporary.name)
        self.events = self.directory / 'events'
        self.bin = self.directory / 'bin'
        self.bin.mkdir()
        for tool in ('xcrun', 'ditto', 'codesign', 'spctl', 'hdiutil', 'sleep'):
            executable = self.bin / tool
            executable.write_text(MOCK_TOOL)
            executable.chmod(0o755)

    def run_notarize(self, name, **settings):
        environment = {
            **os.environ,
            'PATH': f'{self.bin}:{os.environ["PATH"]}',
            'EVENTS': str(self.events),
            'ASC_PRIVATE_KEY_PATH': '/test/key.p8',
            'ASC_KEY_ID': 'test-key',
            'ASC_ISSUER_ID': 'test-issuer',
            **settings,
        }
        result = subprocess.run(
            ['bash', str(NOTARIZE), str(self.directory / name)],
            env=environment,
            capture_output=True,
            text=True,
        )
        events = self.events.read_text().splitlines() if self.events.exists() else []
        return result, events

    def test_app_gets_its_own_ticket_before_gatekeeper_assessment(self):
        result, events = self.run_notarize('FeishuLite.app')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(events[0].startswith('ditto -c -k --keepParent '))
        submission = next(i for i, event in enumerate(events) if 'notarytool submit' in event)
        staple = next(i for i, event in enumerate(events) if 'stapler staple' in event)
        assessment = next(i for i, event in enumerate(events) if event.startswith('spctl '))
        self.assertIn('.zip ', events[submission])
        self.assertLess(submission, staple)
        self.assertLess(staple, assessment)
        self.assertTrue(events[staple].endswith('FeishuLite.app'))

    def test_dmg_checks_the_ticket_of_the_app_users_will_install(self):
        result, events = self.run_notarize('FeishuLite.dmg')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(events[0].startswith('codesign --sign '))
        self.assertTrue(any('stapler validate' in event and event.endswith('FeishuLite.app') for event in events))
        self.assertTrue(events[-1].startswith('hdiutil detach '))

    def test_apple_rejection_cannot_produce_a_stapled_artifact(self):
        result, events = self.run_notarize('FeishuLite.app', NOTARY_STATUS='Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any('notarytool log test-submission' in event for event in events))
        self.assertFalse(any('stapler' in event for event in events))

    def test_temporary_stapler_failure_is_retried(self):
        result, events = self.run_notarize('FeishuLite.app', FAIL_STAPLE_ONCE='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum('stapler staple' in event for event in events), 2)

    def test_missing_inner_app_ticket_fails_and_detaches_dmg(self):
        result, events = self.run_notarize('FeishuLite.dmg', FAIL_VALIDATE='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(events[-1].startswith('hdiutil detach '))


if __name__ == '__main__':
    unittest.main()
