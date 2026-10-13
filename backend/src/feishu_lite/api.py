"""HTTP + SSE API for the Mac app. Bound to 127.0.0.1; every request needs the launch token."""

import asyncio
import json
import secrets
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, HTTPException, Query, Request
from fastapi.responses import JSONResponse, Response, StreamingResponse
from pydantic import BaseModel, Field

from .mail.api import router as mail_router
from .mail.service import MailService
from .mail.store import MailStore
from .service import ChatNotFound, Service
from .types import AuthExpired, Chat, Message, Status

HEARTBEAT_SECONDS = 15


class SendBody(BaseModel):
    text: str = Field(min_length=1)


def _sse(event: str, data: dict) -> str:
    return f'event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n'


class TokenAuth:
    """Authenticate before parsing JSON, including malformed credential bodies."""
    def __init__(self, app, expected: bytes):
        self.app, self.expected = app, expected

    async def __call__(self, scope, receive, send):
        if scope['type'] == 'http':
            authorization = next((value for key, value in scope['headers'] if key == b'authorization'), b'')
            if not secrets.compare_digest(authorization, self.expected):
                await JSONResponse({'detail': 'invalid token'}, status_code=401)(scope, receive, send)
                return
        await self.app(scope, receive, send)


def create_app(service: Service, token: str, *, mail_path: Path | None = None,
               mail_factory=MailService) -> FastAPI:
    expected = f'Bearer {token}'.encode()

    @asynccontextmanager
    async def lifespan(app):
        # MailStore is constructed on the serving event loop, never in run_server
        # before asyncio.run or on an IMAP owner thread.
        store = MailStore(mail_path or service.store.path.with_name('mail.db'))
        mail = mail_factory(store, emit=service.emit_mail)
        app.state.mail = mail
        try:
            await mail.start()
            await service.start()
            yield
        finally:
            service.close_subscribers()
            try:
                await asyncio.gather(mail.stop(), service.stop())
            finally:
                store.close()

    app = FastAPI(title='feishu-lite-backend', lifespan=lifespan)
    app.state.chat = service
    app.add_middleware(TokenAuth, expected=expected)
    app.include_router(mail_router)

    @app.exception_handler(AuthExpired)
    async def _auth_expired(request: Request, exc: AuthExpired):
        service.handle_auth_expired(exc)
        return JSONResponse({'detail': 'logged_out'}, status_code=409)

    @app.exception_handler(ChatNotFound)
    async def _chat_not_found(request: Request, exc: ChatNotFound):
        return JSONResponse({'detail': 'chat not found'}, status_code=404)

    @app.get('/status')
    async def get_status() -> Status:
        return service.status()

    @app.post('/login/qr')
    async def start_qr_login():
        return {'qr_content': await service.start_qr_login()}

    @app.get('/login/qr/status')
    async def qr_login_status():
        return {'status': service.qr_status}

    @app.post('/logout')
    async def logout():
        await service.logout()
        return {'ok': True}

    @app.get('/chats')
    async def list_chats() -> list[Chat]:
        return service.list_chats()

    @app.get('/chats/{chat_id}/messages')
    async def get_messages(
        chat_id: str, before_position: int | None = None, limit: int = Query(30, ge=1, le=50)
    ) -> list[Message]:
        return await service.get_messages(chat_id, before_position, limit)

    @app.post('/chats/{chat_id}/messages')
    async def send_message(chat_id: str, body: SendBody) -> Message:
        return await service.send_text(chat_id, body.text)

    @app.get('/messages/{message_id}/image')
    async def get_image(message_id: str):
        try:
            data, media_type = await service.get_image(message_id)
        except AuthExpired:
            raise
        except LookupError as exc:
            raise HTTPException(status_code=404, detail='图片已撤回或不可用') from exc
        except Exception as exc:
            raise HTTPException(status_code=502, detail='图片加载失败，请重试') from exc
        return Response(data, media_type=media_type, headers={'Cache-Control': 'no-store'})

    @app.post('/chats/{chat_id}/read')
    async def mark_read(chat_id: str):
        await service.mark_read(chat_id)
        return {'ok': True}

    @app.get('/events')
    async def events():
        queue = service.subscribe()

        async def stream():
            try:
                yield _sse('status', service.status().model_dump())
                mail = app.state.mail
                yield _sse('mail.status', mail._event('mail.status', status=mail.status()).model_dump(mode='json'))
                while True:
                    try:
                        item = await asyncio.wait_for(queue.get(), HEARTBEAT_SECONDS)
                    except TimeoutError:
                        yield ': ping\n\n'
                        continue
                    if item is None:
                        return
                    event, data = item
                    yield _sse(event, data)
            finally:
                service.unsubscribe(queue)

        return StreamingResponse(
            stream(), media_type='text/event-stream', headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'}
        )

    return app
