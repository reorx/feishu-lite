import asyncio
import signal
import sys
import time

import pytest


@pytest.mark.parametrize('phase',['idle','fetch','probe','greeting','dns-probes'])
async def test_actual_http_backend_sigterm_stops_in_two_seconds(phase,record_property):
    process = await asyncio.create_subprocess_exec(sys.executable,'-m','tests.mail.api_stop_child',phase,
                                                  stdout=asyncio.subprocess.PIPE,stderr=asyncio.subprocess.PIPE)
    try:
        ready = await asyncio.wait_for(process.stdout.readline(),8)
        assert ready == b'READY\n', (await process.stderr.read()).decode()
        began = time.monotonic()
        process.send_signal(signal.SIGTERM)
        stdout,stderr = await asyncio.wait_for(process.communicate(),2)
        elapsed = time.monotonic()-began
        record_property('http_stop_seconds',elapsed)
        assert process.returncode == -signal.SIGTERM, stderr.decode()
        assert b'CLOSED' in stdout and not stderr
        assert elapsed < 2
    finally:
        if process.returncode is None:
            process.kill()
            await process.wait()
