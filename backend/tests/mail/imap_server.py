"""Synthetic asyncio IMAP peer, deliberately independent of the client library."""
import asyncio
import re
import ssl
import time
from contextlib import asynccontextmanager

from imapclient.imap_utf7 import encode

HEADER = b'Subject: Synthetic\r\nFrom: Sender <sender@example.invalid>\r\n\r\n'
STRUCTURE = b'(("TEXT" "PLAIN" ("CHARSET" "UTF-8") NIL NIL "7BIT" 5 1)("TEXT" "HTML" ("CHARSET" "UTF-8") NIL NIL "7BIT" 12 1)("APPLICATION" "PDF" NIL NIL NIL "BASE64" 999 NIL ("ATTACHMENT" ("FILENAME" "sample.pdf"))) "ALTERNATIVE")'


class ScriptedIMAP:
    def __init__(self, scenario='normal', *, idle=True, readonly=False, tls=None):
        self.scenario = scenario
        self.has_idle = idle
        self.readonly = readonly
        self.tls = tls
        self.commands = []  # synthetic only; never used with a real account
        self.events = {name: asyncio.Event() for name in ('connected', 'idle', 'done', 'fetch', 'search', 'logout')}
        self.writers = set()
        self.tasks = set()
        self.flags = {3: {b'\\Flagged'}, 9: set(), 22: {b'\\Seen'}}
        self.fetch_at = None
        self.serialized = True
        self.done_delay = .06

    async def start(self):
        self.server = await asyncio.start_server(self.accept, '127.0.0.1', 0, ssl=self.tls)
        self.port = self.server.sockets[0].getsockname()[1]
        return self

    async def close(self):
        self.server.close()
        await self.server.wait_closed()
        for writer in list(self.writers):
            writer.close()
        for task in list(self.tasks):
            task.cancel()
        await asyncio.gather(*self.tasks, return_exceptions=True)
        self.writers.clear()

    async def accept(self, reader, writer):
        task = asyncio.current_task()
        self.tasks.add(task)
        self.writers.add(writer)
        try:
            await self.serve(reader, writer)
        except (ConnectionError, ssl.SSLError):
            pass
        finally:
            writer.close()
            try:
                await writer.wait_closed()
            except (ConnectionError, ssl.SSLError):
                pass
            self.writers.discard(writer)
            self.tasks.discard(task)

    async def serve(self, reader, writer):
        self.events['connected'].set()
        if self.scenario == 'greeting_stall':
            await reader.read()
            return
        await self.send(writer, b'* OK synthetic ready\r\n')
        while line := await reader.readline():
            self.commands.append(line.rstrip())
            tag, command, *rest = line.rstrip().split(b' ', 2)
            args = rest[0] if rest else b''
            if command == b'CAPABILITY':
                await self.send(writer, b'* CAPABILITY IMAP4rev1' + (b' IDLE' if self.has_idle else b'') + b'\r\n')
            elif command == b'LOGIN':
                if self.scenario == 'auth_failed':
                    await self.send(writer, tag + b' NO secret-like rejected response\r\n')
                    continue
            elif command == b'LIST':
                for flags, name in [(b'()', 'inbox'), (b'(\\Noselect)', '目录'), (b'()', '目录/归档')]:
                    await self.send(writer, b'* LIST ' + flags + b' "/" "' + encode(name) + b'"\r\n')
            elif command in (b'SELECT', b'EXAMINE'):
                await self.send(writer, b'* 3 EXISTS\r\n* FLAGS (\\Seen \\Flagged)\r\n* OK [UIDVALIDITY 77] generation\r\n* OK [UIDNEXT 23] next\r\n* OK [UNSEEN 99] sequence not count\r\n* OK [PERMANENTFLAGS (\\Seen \\Flagged \\*)] flags\r\n')
                mode = b'READ-ONLY' if self.readonly or command == b'EXAMINE' else b'READ-WRITE'
                await self.send(writer, tag + b' OK [' + mode + b'] selected\r\n')
                continue
            elif command == b'IDLE':
                await self.send(writer, b'+ idling\r\n')
                self.events['idle'].set()
                await self.run_idle(reader, writer, tag)
                continue
            elif command == b'UID':
                action, uid_args = args.split(b' ', 1)
                if action == b'SEARCH':
                    self.events['search'].set()
                    if self.scenario == 'search_delay':
                        await asyncio.sleep(.15)
                    if b'UNSEEN' in uid_args:
                        uids = [uid for uid, flags in self.flags.items() if b'\\Seen' not in flags]
                    elif b'UID' in uid_args:
                        term = uid_args.split(b'UID ', 1)[1].split()[0]
                        if b':' in term:
                            start = int(term.split(b':')[0])
                            uids = [uid for uid in self.flags if uid >= start] or [max(self.flags)]
                        else:
                            uids = [int(uid) for uid in term.split(b',') if int(uid) in self.flags]
                    else:
                        uids = list(self.flags)
                    await self.send(writer, b'* SEARCH ' + b' '.join(str(uid).encode() for uid in uids) + b'\r\n')
                elif action == b'FETCH':
                    self.fetch_at = time.monotonic()
                    self.events['fetch'].set()
                    if self.scenario in ('fetch_stall', 'half_line'):
                        if self.scenario == 'half_line':
                            await self.send(writer, b'* 1 FETCH (UID ')
                        await reader.read()
                        return
                    if self.scenario == 'disconnect':
                        return
                    if self.scenario == 'fetch_empty':
                        pass
                    else:
                        await self.fetch(writer, uid_args)
                elif action == b'STORE':
                    if self.scenario == 'store_failed':
                        await self.send(writer, tag + b' NO cannot write\r\n')
                        continue
                    uid = int(uid_args.split()[0])
                    if self.scenario == 'store_disappeared':
                        self.flags.pop(uid, None)
                    elif uid in self.flags and self.scenario != 'store_noop':
                        self.flags[uid].add(b'\\Seen')
            elif command == b'LOGOUT':
                self.events['logout'].set()
                await self.send(writer, b'* BYE closing\r\n' + tag + b' OK logout\r\n')
                return
            else:
                await self.send(writer, tag + b' BAD unknown command\r\n')
                continue
            await self.send(writer, tag + b' OK completed\r\n')

    async def run_idle(self, reader, writer, tag):
        if self.scenario == 'idle_disconnect':
            writer.close()
            return
        if self.scenario in ('idle_half_line', 'idle_partial_stall'):
            await self.send(writer, b'* 1 FET')
        if self.scenario in ('push', 'flood'):
            await self.send(writer, b'* 1 EXPUNGE\r\n* 4 EXISTS\r\n* 2 FETCH (FLAGS (\\Seen))\r\n')
        done_task = asyncio.create_task(reader.readline())
        premature = None
        try:
            if self.scenario == 'flood':
                while not done_task.done():
                    await self.send(writer, b'* 4 EXISTS\r\n' * 20)
                    await asyncio.sleep(.001)
            line = await done_task
            if line != b'DONE\r\n':
                self.serialized = False
                return
            self.commands.append(b'DONE')
            self.events['done'].set()
            if self.scenario in ('done_stall', 'idle_partial_stall'):
                extra = await reader.read()
                self.serialized = not extra
                return
            if self.scenario == 'idle_half_line':
                await self.send(writer, b'CH (FLAGS (\\Seen))\r\n')
            premature = asyncio.create_task(reader.readline())
            await asyncio.sleep(self.done_delay)
            if premature.done() and premature.result():
                self.serialized = False
            premature.cancel()
            await asyncio.gather(premature, return_exceptions=True)
            await self.send(writer, tag + b' OK idle ended\r\n')
        finally:
            done_task.cancel()
            await asyncio.gather(done_task, return_exceptions=True)
            if premature is not None:
                premature.cancel()
                await asyncio.gather(premature, return_exceptions=True)

    async def fetch(self, writer, args):
        ids, fields = args.split(b' ', 1)
        for uid in (int(value) for value in ids.split(b',')):
            if uid not in self.flags:
                continue
            if self.scenario == 'missing_one' and uid == 9:
                continue
            prefix = b'* 1 FETCH (UID ' + str(uid).encode() + b' '
            if fields == b'(FLAGS)':
                await self.send(writer, prefix + b'FLAGS (' + b' '.join(sorted(self.flags[uid])) + b'))\r\n')
            elif b'HEADER.FIELDS' in fields:
                structure = STRUCTURE
                if self.scenario == 'bad_structure' and uid == 9:
                    structure = b'("TEXT" "PLAIN")'
                if self.scenario == 'deep_structure':
                    structure = b'(' * 100 + b'NIL' + b')' * 100
                header = HEADER
                if self.scenario == 'missing_header' and uid == 9:
                    await self.send(writer, prefix + b'FLAGS () BODYSTRUCTURE ' + structure + b')\r\n')
                    continue
                if self.scenario == 'header_oversize':
                    await self.send(writer, prefix + b'BODY[HEADER.FIELDS (SUBJECT)] {999999999}\r\n')
                    return
                data = prefix + b'FLAGS (' + b' '.join(sorted(self.flags[uid])) + b') INTERNALDATE "13-Oct-2026 01:00:00 +0000" RFC822.SIZE 1200 BODYSTRUCTURE ' + structure
                if self.scenario == 'bad_date' and uid == 9:
                    data = data.replace(b'13-Oct-2026 01:00:00 +0000', b'not-a-date')
                if self.scenario == 'wire_oversize':
                    await self.send(writer, b'* 1 FETCH (' + b'X' * 4096 + b'\r\n')
                    return
                if self.scenario == 'too_many_atoms':
                    data = prefix + b'BODYSTRUCTURE (' + b'NIL ' * 300 + b')'
                await self.send(writer, data + b' BODY[HEADER.FIELDS (FROM TO CC SUBJECT DATE MESSAGE-ID)] {' + str(len(header)).encode() + b'}\r\n' + header + b')\r\n')
            else:
                section = re.search(rb'BODY.PEEK\[([0-9.]+)\]', fields).group(1)
                body = b'<b>hello</b>'
                size = 999999999 if self.scenario == 'body_oversize' else len(body)
                await self.send(writer, prefix + b'BODY[' + section + b'] {' + str(size).encode() + b'}\r\n')
                if self.scenario != 'body_oversize':
                    await self.send(writer, body + b')\r\n')

    async def send(self, writer, data):
        writer.write(data)
        await writer.drain()


@asynccontextmanager
async def imap_server(*args, **kwargs):
    server = await ScriptedIMAP(*args, **kwargs).start()
    try:
        yield server
    finally:
        await server.close()
