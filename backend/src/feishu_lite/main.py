"""Entry point: `feishu-lite-backend --port P` (token in FEISHU_LITE_TOKEN), or `feishu-lite-backend login`."""

import argparse
import asyncio
import logging
import os
import sys
from pathlib import Path

import uvicorn

log = logging.getLogger('feishu_lite')

DEFAULT_HOME = Path.home() / 'Library' / 'Application Support' / 'FeishuChat'
PARENT_CHECK_SECONDS = 2


def prepare_home() -> Path:
    """Create the data dir with private permissions and point larkx at it (must precede any larkx import)."""
    os.umask(0o077)
    home = Path(os.environ.get('FEISHU_LITE_HOME') or DEFAULT_HOME).expanduser()
    larkx_home = home / 'larkx'
    larkx_home.mkdir(parents=True, exist_ok=True)
    home.chmod(0o700)
    larkx_home.chmod(0o700)
    credentials = larkx_home / 'credentials.json'
    if credentials.exists():
        credentials.chmod(0o600)
    os.environ['LARKX_HOME'] = str(larkx_home)
    return home


def run_server(home: Path, port: int) -> int:
    token = os.environ.get('FEISHU_LITE_TOKEN')
    if not token:
        print('FEISHU_LITE_TOKEN is required', file=sys.stderr)
        return 2
    from .api import create_app
    from .service import Service
    from .source import LarkxSource
    from .store import Store

    service = Service(LarkxSource(), Store(home / 'cache.db'))
    app = create_app(service, token)
    server = uvicorn.Server(uvicorn.Config(app, host='127.0.0.1', port=port, log_level='info', access_log=False))
    parent_pid = os.environ.get('FEISHU_LITE_PARENT_PID')
    asyncio.run(_serve(server, int(parent_pid) if parent_pid else None))
    return 0


async def _serve(server: uvicorn.Server, parent_pid: int | None):
    if parent_pid:
        asyncio.create_task(_exit_with_parent(server, parent_pid))
    await server.serve()


async def _exit_with_parent(server: uvicorn.Server, pid: int):
    """The app may die without stopping us (crash, kill -9); `uv run` in between hides our real parent."""
    while True:
        await asyncio.sleep(PARENT_CHECK_SECONDS)
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            log.warning('parent process %s is gone, shutting down', pid)
            server.should_exit = True
            return


def run_login() -> int:
    import qrcode

    from .source import LarkxSource

    source = LarkxSource()

    async def flow():
        qr = qrcode.QRCode(border=1)
        qr.add_data(await source.qr_login_start())
        qr.print_ascii(invert=True)
        print('Scan with Feishu on your phone and confirm.', flush=True)
        status = None
        while status not in ('success', 'expired', 'failed'):
            await asyncio.sleep(2)
            new_status = await source.qr_login_poll()
            if new_status != status:
                print(f'status: {new_status}', flush=True)
            status = new_status
        return status

    return 0 if asyncio.run(flow()) == 'success' else 1


def main():
    parser = argparse.ArgumentParser(
        prog='feishu-lite-backend', description='FeishuChat local backend (127.0.0.1 REST + SSE)'
    )
    parser.add_argument('--port', type=int, default=18765)
    sub = parser.add_subparsers(dest='command')
    sub.add_parser('login', help='log in by scanning a QR code printed in the terminal')
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(name)s: %(message)s')
    home = prepare_home()
    if args.command == 'login':
        sys.exit(run_login())
    sys.exit(run_server(home, args.port))
