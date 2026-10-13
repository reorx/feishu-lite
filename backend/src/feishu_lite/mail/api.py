"""Mail HTTP boundary: typed wire models, safe errors and caller cancellation."""
import asyncio
import logging

from fastapi import APIRouter, Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse, Response
from fastapi.routing import APIRoute
from starlette.exceptions import HTTPException

from .types import (MailAccountChange, MailAccountRequest, MailAckRequest,
                    MailAPIError, MailBody, MailConnectionTest,
                    MailCredentialRequest, MailError, MailFolder, MailPage,
                    MailReadResult, MailStatus, MailSummary)

log = logging.getLogger(__name__)
MAIL_REQUEST_TIMEOUT = 30.0

# Unlisted codes are internal errors, never reflected from a library exception.
ERROR_STATUS = {
    400: {'unconfigured', 'account_mismatch', 'invalid_id', 'unsupported_folder', 'invalid_page_size'},
    403: {'credential_missing', 'authentication_failed', 'mailbox_readonly'},
    404: {'message_missing', 'folder_missing', 'inbox_missing'},
    410: {'stale_message', 'stale_cursor', 'stale_request'},
    413: {'body_too_large', 'response_too_large', 'headers_too_large', 'mime_too_deep', 'too_many_parts'},
    422: {'invalid_request', 'malformed_mime', 'malformed_encoding', 'unsupported_charset', 'unsupported_transfer_encoding',
          'unsupported_body', 'malformed_response'},
    502: {'seen_not_persisted', 'command_rejected', 'disconnected', 'imap_failed', 'tls_failed'},
    503: {'offline', 'not_synced', 'service_stopped', 'executor_stopped', 'stop_timeout', 'queue_full',
          'connection_test_busy'},
    504: {'idle_done_timeout', 'command_timeout', 'request_timeout'},
}


def mail_error_response(code):
    status = next((status for status, codes in ERROR_STATUS.items() if code in codes), 500)
    safe_code = code if status != 500 else 'internal_error'
    return JSONResponse(MailAPIError(code=safe_code).model_dump(), status_code=status,
                        headers={'Cache-Control': 'no-store'})


class MailRoute(APIRoute):
    def get_route_handler(self):
        original = super().get_route_handler()

        async def handle(request: Request):
            # Consume once before monitoring receive, so the watcher cannot
            # steal body chunks from FastAPI. Validation never logs/echoes it.
            await request.body()
            work = asyncio.create_task(original(request), name='mail-http')
            disconnected = asyncio.create_task(wait_disconnect(request), name='mail-http-disconnect')
            try:
                done, _ = await asyncio.wait((work, disconnected), timeout=MAIL_REQUEST_TIMEOUT,
                                            return_when=asyncio.FIRST_COMPLETED)
                if work in done:
                    response = await work
                    response.headers['Cache-Control'] = 'no-store'
                    return response
                work.cancel()
                await asyncio.gather(work, return_exceptions=True)
                if not done:
                    return mail_error_response('request_timeout')
                return Response(status_code=499)
            except RequestValidationError:
                return mail_error_response('invalid_request')
            except HTTPException as exc:
                # FastAPI wraps invalid UTF-8 JSON as a parsing HTTP 400.
                return mail_error_response('invalid_request' if exc.status_code == 400 else 'internal_error')
            except MailError as exc:
                return mail_error_response(exc.code)
            except Exception:
                # ASGI's generic exception handler re-raises into Uvicorn's
                # traceback logger. Catch here without cause/str/traceback.
                log.error('mail request failed: internal_error')
                return mail_error_response('internal_error')
            finally:
                work.cancel()
                disconnected.cancel()
                await asyncio.gather(work, disconnected, return_exceptions=True)
        return handle


async def wait_disconnect(request):
    while (await request.receive())['type'] != 'http.disconnect':
        pass


router = APIRouter(prefix='/mail', route_class=MailRoute)


@router.get('/status')
async def status(request: Request) -> MailStatus:
    return request.app.state.mail.status()


@router.post('/account/test')
async def test_connection(request: Request, body: MailAccountRequest) -> MailConnectionTest:
    return await request.app.state.mail.test_connection(body.address, body.password)


@router.put('/account')
async def configure(request: Request, body: MailAccountRequest) -> MailAccountChange:
    return await request.app.state.mail.configure(body.address, body.password)


@router.put('/account/credential')
async def credential(request: Request, body: MailCredentialRequest) -> MailStatus:
    mail = request.app.state.mail
    await mail.inject_credential(body.mail_account_id, body.password)
    return mail.status()


@router.delete('/account')
async def remove(request: Request) -> MailAccountChange:
    return await request.app.state.mail.remove_account()


@router.get('/folders')
async def folders(request: Request) -> list[MailFolder]:
    return request.app.state.mail.folders()


@router.get('/messages')
async def messages(request: Request, folder: str = 'INBOX', cursor: str | None = None) -> MailPage:
    return await request.app.state.mail.messages(folder=folder, cursor=cursor)


@router.get('/messages/{message_id}')
async def body(request: Request, message_id: str) -> MailBody:
    return await request.app.state.mail.body(message_id)


@router.get('/messages/{message_id}/summary')
async def summary(request: Request, message_id: str) -> MailSummary:
    return request.app.state.mail.summary(message_id)


@router.post('/messages/{message_id}/read')
async def read(request: Request, message_id: str) -> MailReadResult:
    return MailReadResult(read_ids=await request.app.state.mail.read(message_id))


@router.post('/sync')
async def sync(request: Request, reconnect: bool = False, wait: bool = True) -> MailStatus:
    mail = request.app.state.mail
    await mail.refresh(reconnect=reconnect, wait=wait)
    return mail.status()


@router.post('/notifications/ack')
async def ack(request: Request, body: MailAckRequest) -> MailStatus:
    mail = request.app.state.mail
    await mail.ack(body.mail_account_id, body.uidvalidity, body.batch_id)
    return mail.status()
