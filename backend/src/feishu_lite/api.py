"""HTTP + SSE API for the Mac app. Bound to 127.0.0.1; every request needs the launch token."""

import asyncio
import json
import secrets
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import JSONResponse, StreamingResponse
from pydantic import BaseModel, Field

from .service import ChatNotFound, Service
from .types import AuthExpired, Chat, Message, Status

HEARTBEAT_SECONDS = 15


class SendBody(BaseModel):
    text: str = Field(min_length=1)


def _sse(event: str, data: dict) -> str:
    return f'event: {event}\ndata: {json.dumps(data, ensure_ascii=False)}\n\n'


def create_app(service: Service, token: str) -> FastAPI:
    expected = f'Bearer {token}'.encode()

    def require_token(authorization: str | None = Header(default=None)):
        if not authorization or not secrets.compare_digest(authorization.encode(), expected):
            raise HTTPException(status_code=401, detail='invalid token')

    @asynccontextmanager
    async def lifespan(app):
        await service.start()
        yield
        await service.stop()

    app = FastAPI(title='feishu-lite-backend', lifespan=lifespan, dependencies=[Depends(require_token)])

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
                while True:
                    try:
                        event, data = await asyncio.wait_for(queue.get(), HEARTBEAT_SECONDS)
                    except TimeoutError:
                        yield ': ping\n\n'
                        continue
                    yield _sse(event, data)
            finally:
                service.unsubscribe(queue)

        return StreamingResponse(
            stream(), media_type='text/event-stream', headers={'Cache-Control': 'no-cache', 'X-Accel-Buffering': 'no'}
        )

    return app
