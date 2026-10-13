import asyncio
import sys
import time

import pytest


@pytest.mark.parametrize('phase',['idle','fetch','greeting','dns'])
async def test_mail_service_full_subprocess_stops_in_two_seconds(phase, record_property):
    process = await asyncio.create_subprocess_exec(sys.executable,'-m','tests.mail.service_stop_child',phase,
                                                  stdin=asyncio.subprocess.PIPE,stdout=asyncio.subprocess.PIPE,
                                                  stderr=asyncio.subprocess.PIPE)
    try:
        ready = await asyncio.wait_for(process.stdout.readline(),5)
        assert ready == b'READY\n', (await process.stderr.read()).decode()
        began = time.monotonic()
        process.stdin.write(b'STOP\n')
        await process.stdin.drain()
        stdout, stderr = await asyncio.wait_for(process.communicate(),2)
        elapsed = time.monotonic()-began
        record_property('stop_seconds',elapsed)
        assert process.returncode == 0, stderr.decode()
        assert b'CLOSED' in stdout and not stderr
        assert elapsed < 2
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()
