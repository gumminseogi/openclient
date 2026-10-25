#!/usr/bin/env python3
"""Synthetic OpenCode v1 subset for OpenClient performance investigation (stdlib only)."""
import argparse
import base64
from collections import Counter, deque
import copy
import ipaddress
import json
from pathlib import Path
import re
import secrets
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.parse import parse_qs, urlsplit
from urllib.request import ProxyHandler, Request, build_opener


DIRECTORY = '/openclient-performance-lab'
VERSION = '1.19.0'
SESSION_SIZES = (20, 200, 2000)


def encoded(value):
    return json.dumps(value, separators=(',', ':'), ensure_ascii=True).encode('ascii')


def bounded(value, name, low, high):
    if isinstance(value, bool) or not isinstance(value, int) or not low <= value <= high:
        raise ValueError(f'{name} must be an integer from {low} to {high}')
    return value


def summary(path):
    """Aggregate completed HTTP responses; elapsed time is server time, not UI time."""
    rows = [json.loads(line) for line in Path(path).read_text().splitlines() if line.strip()]
    return summarize(rows)


def summarize(rows):
    return {'total_requests': len(rows),
            'response_bytes': sum(r['response_bytes'] for r in rows),
            'by_path': dict(sorted(Counter(r['path'] for r in rows).items())),
            'by_status': dict(sorted(Counter(str(r['status']) for r in rows).items()))}


class LabState:
    def __init__(self, text_bytes=512, tool_bytes=4096, assistants_per_turn=7, log_path=None):
        self.text_bytes = bounded(text_bytes, 'text_bytes', 0, 16384)
        self.tool_bytes = bounded(tool_bytes, 'tool_bytes', 0, 65536)
        self.assistants_per_turn = bounded(assistants_per_turn, 'assistants_per_turn', 1, 100)
        self.log_path = Path(log_path) if log_path else None
        self.condition = threading.Condition(threading.RLock())
        self.stop = threading.Event()
        self.events = deque(maxlen=4096)
        self.sequence = 0
        self.requests = []
        self.inflight = {}
        self.next_request = 0
        self.runs = {}
        self.project = {'id': 'lab', 'worktree': DIRECTORY, 'name': 'Performance Lab',
                        'sandboxes': [], 'time': {'created': 1720000000000, 'updated': 1720000000000}}
        self.sessions = {}
        self.messages = {}
        for size in SESSION_SIZES:
            sid = f'ses_{size}'
            self.sessions[sid] = {'id': sid, 'title': f'Lab: {size} messages',
                                  'directory': DIRECTORY, 'projectID': 'lab',
                                  'time': {'created': 1720000000000 + size,
                                           'updated': 1720000000000 + size}}
            self.messages[sid] = [self.seed_message(sid, index, size) for index in range(size)]

    def seed_message(self, sid, index, size):
        position = index % (self.assistants_per_turn + 1)
        role = 'user' if position == 0 else 'assistant'
        mid = f'msg_{sid}_{index:06d}'
        info = {'id': mid, 'sessionID': sid, 'role': role, 'agent': 'build',
                'time': {'created': 1720000000000 + index * 1000},
                'model': {'providerID': 'lab', 'modelID': 'synthetic'}}
        parts = []
        if role == 'assistant':
            user_index = index - position
            info.update(providerID='lab', modelID='synthetic', finish='stop',
                        parentID=f'msg_{sid}_{user_index:06d}')
            info['time']['completed'] = info['time']['created'] + 500
            parts.append({'id': f'prt_{mid}_tool', 'messageID': mid, 'sessionID': sid,
                          'type': 'tool', 'tool': 'bash', 'callID': f'call_{mid}',
                          'state': {'status': 'completed', 'title': 'Synthetic output',
                                    'input': {'command': 'printf synthetic'},
                                    'output': 'o' * self.tool_bytes}})
        if role == 'user' or position == self.assistants_per_turn or index == size - 1:
            text = f'Synthetic turn {index // (self.assistants_per_turn + 1) + 1}.' if role == 'user' else 'x' * self.text_bytes
            parts.append({'id': f'prt_{mid}_text', 'messageID': mid, 'sessionID': sid,
                          'type': 'text', 'text': text})
        return {'info': info, 'parts': parts}

    def emit(self, kind, properties):
        # Call while holding condition: canonical mutation and event creation are atomic.
        self.sequence += 1
        self.events.append((self.sequence, {'directory': DIRECTORY,
                            'payload': {'type': kind, 'properties': copy.deepcopy(properties)}}))
        self.condition.notify_all()

    def start_request(self, method, path, query):
        with self.condition:
            self.next_request += 1
            row = {'request_id': self.next_request, 'method': method, 'path': path,
                   'query': query, 'started_ns': time.monotonic_ns(), 'response_bytes': 0}
            self.inflight[row['request_id']] = row
            return row

    def finish_request(self, row, status):
        with self.condition:
            row.update(status=status, ended_ns=time.monotonic_ns())
            row['elapsed_ms'] = (row['ended_ns'] - row['started_ns']) / 1_000_000
            self.inflight.pop(row['request_id'], None)
            self.requests.append(copy.deepcopy(row))
            if self.log_path:
                with self.log_path.open('a', encoding='utf-8') as output:
                    output.write(encoded(row).decode('ascii') + '\n')
            self.condition.notify_all()

    def snapshot(self):
        with self.condition:
            return {'version': VERSION, 'synthetic': True,
                    'sessions': {sid: len(messages) for sid, messages in self.messages.items()},
                    'active': sorted(sid for sid, run in self.runs.items() if not run['done'].is_set()),
                    'event_sequence': self.sequence, 'event_capacity': self.events.maxlen,
                    'recent_requests': copy.deepcopy(self.requests[-100:]),
                    'sse_connections': sum(row['path'] in ('/event', '/global/event')
                                           for row in self.inflight.values()),
                    'summary': summarize(self.requests), 'inflight': copy.deepcopy(list(self.inflight.values()))}

    def start_stream(self, sid, chunks=50, interval_ms=100, chunk_bytes=80, part_type='text'):
        bounded(chunks, 'chunks', 1, 10000)
        bounded(interval_ms, 'interval_ms', 0, 60000)
        bounded(chunk_bytes, 'chunk_bytes', 1, 16384)
        if part_type not in ('text', 'reasoning'):
            raise ValueError('part_type must be text or reasoning')
        if chunks * chunk_bytes > 8 * 1024 * 1024:
            raise ValueError('stream output exceeds 8 MiB')
        with self.condition:
            if sid not in self.sessions:
                raise KeyError(sid)
            if sid in self.runs and not self.runs[sid]['done'].is_set():
                raise RuntimeError('session already streaming')
            cancel = threading.Event()
            run_state = {'cancel': cancel, 'done': threading.Event()}
            self.runs[sid] = run_state
            index = len(self.messages[sid])
            user = self.seed_message(sid, index, index + 1)
            user['info']['role'] = 'user'
            user['info'].pop('finish', None)
            user['info'].pop('parentID', None)
            user['info']['time'].pop('completed', None)
            now = time.time() * 1000
            user['info']['time']['created'] = now
            user['parts'] = [{'id': f"prt_{user['info']['id']}_text", 'messageID': user['info']['id'],
                              'sessionID': sid, 'type': 'text', 'text': 'Synthetic streamed turn.'}]
            assistant = self.seed_message(sid, index + 1, index + 2)
            assistant['info']['role'] = 'assistant'
            assistant['info'].pop('finish', None)
            assistant['info']['time'].pop('completed', None)
            assistant['info']['parentID'] = user['info']['id']
            assistant['info']['time']['created'] = now + 1
            mid = assistant['info']['id']
            part = {'id': f'prt_{mid}_{part_type}', 'messageID': mid, 'sessionID': sid,
                    'type': part_type, 'text': '', 'time': {'start': now + 1}}
            assistant['parts'] = [part]
            self.messages[sid].extend([user, assistant])
            for message in (user, assistant):
                self.emit('message.updated', {'info': message['info']})
                for item in message['parts']:
                    self.emit('message.part.updated', {'part': item})
            self.emit('session.status', {'sessionID': sid, 'status': {'type': 'busy'}})
        def run():
            for _ in range(chunks):
                if cancel.wait(interval_ms / 1000) or self.stop.is_set():
                    break
                with self.condition:
                    delta = 'd' * chunk_bytes
                    part['text'] += delta
                    self.emit('message.part.delta', {'sessionID': sid, 'messageID': mid,
                              'partID': part['id'], 'field': 'text', 'delta': delta})
            with self.condition:
                end = time.time() * 1000
                part['time']['end'] = end
                self.emit('message.part.updated', {'part': part})
                assistant['info']['time']['completed'] = end
                assistant['info']['finish'] = 'stop' if not cancel.is_set() else 'aborted'
                self.emit('message.updated', {'info': assistant['info']})
                self.emit('session.status', {'sessionID': sid, 'status': {'type': 'idle'}})
                self.emit('session.idle', {'sessionID': sid})
                run_state['done'].set()
                self.condition.notify_all()
        threading.Thread(target=run, daemon=True).start()
        return {'accepted': True, 'sessionID': sid, 'messageID': mid}


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass  # BaseHTTPRequestHandler otherwise logs the raw request line.

    def do_GET(self):
        self.dispatch()

    def do_POST(self):
        self.dispatch()

    def do_PUT(self):
        self.dispatch()

    def do_DELETE(self):
        self.dispatch()

    def do_PATCH(self):
        self.dispatch()

    def dispatch(self):
        state = self.server.state
        path = urlsplit(self.path).path
        query = parse_qs(urlsplit(self.path).query, keep_blank_values=True)
        row = state.start_request(self.command, path, query)
        self.row, self.status = row, 500
        try:
            expected = 'Basic ' + base64.b64encode(('opencode:' + self.server.password).encode()).decode()
            if not secrets.compare_digest(self.headers.get('Authorization', ''), expected):
                self.reply({'error': 'authentication required'}, 401)
                return
            delay = self.server.detail_latency_ms if re.fullmatch(r'/session/[^/]+/message/[^/]+', path) else self.server.latency_ms
            if not path.startswith('/_lab/') and path not in ('/event', '/global/event'):
                state.stop.wait(delay / 1000)
            if self.command == 'GET':
                self.get(path, query)
            elif self.command == 'POST' and path == '/_lab/stream':
                body = self.body()
                allowed = {'sessionID', 'chunks', 'interval_ms', 'chunk_bytes', 'part_type'}
                if set(body) - allowed or not isinstance(body.get('sessionID'), str):
                    raise ValueError('unknown stream option')
                self.reply(state.start_stream(body['sessionID'], **{k: v for k, v in body.items() if k != 'sessionID'}), 202)
            elif self.command == 'POST' and re.fullmatch(r'/session/[^/]+/abort', path):
                sid = path.split('/')[2]
                with state.condition:
                    if sid not in state.sessions:
                        raise KeyError(sid)
                    if sid in state.runs:
                        state.runs[sid]['cancel'].set()
                self.reply(True)
            else:
                self.reply({'error': 'unsupported fixture endpoint'}, 404)
        except KeyError:
            self.reply({'error': 'unknown session, message, or missing input'}, 404)
        except (ValueError, TypeError):
            self.reply({'error': 'invalid request'}, 400)
        except RuntimeError:
            self.reply({'error': 'session already streaming'}, 409)
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            self.close_connection = True
        finally:
            state.finish_request(row, self.status)
            # Unread request bodies must not become a second request on the connection.
            if self.command != 'GET':
                self.close_connection = True

    def body(self):
        if self.headers.get('Transfer-Encoding'):
            raise ValueError('chunked control bodies unsupported')
        size = int(self.headers.get('Content-Length', '0'))
        bounded(size, 'body size', 1, 16384)
        body = json.loads(self.rfile.read(size))
        if not isinstance(body, dict):
            raise ValueError('object required')
        return body

    def reply(self, value, code=200, headers=None):
        raw = encoded(value)
        self.status = code
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(raw)))
        self.send_header('Cache-Control', 'no-store')
        if code == 401:
            self.send_header('WWW-Authenticate', 'Basic realm="OpenClient Performance Lab"')
        for key, value in (headers or {}).items():
            self.send_header(key, str(value))
        self.end_headers()
        self.wfile.write(raw)
        self.wfile.flush()
        self.row['response_bytes'] += len(raw)

    def get(self, path, query):
        state = self.server.state
        # Return an explicit unavailable v2 probe so automatic mode selects legacy.
        if path in ('/api/health', '/api/info'):
            self.reply({'error': 'v1 fixture'}, 404)
            return
        if path == '/global/health':
            self.reply({'healthy': True, 'version': VERSION})
        elif path in ('/project', '/project/current'):
            self.reply([state.project] if path == '/project' else state.project)
        elif path == '/path':
            self.reply({'directory': DIRECTORY, 'worktree': DIRECTORY, 'home': '/synthetic',
                        'state': '/synthetic/state', 'config': '/synthetic/config'})
        elif path == '/agent':
            self.reply([{'name': 'build', 'mode': 'primary', 'description': 'Synthetic fixture'}])
        elif path == '/provider':
            self.reply({'all': [{'id': 'lab', 'name': 'Synthetic Lab', 'models': {
                'synthetic': {'id': 'synthetic', 'providerID': 'lab', 'name': 'Synthetic',
                              'capabilities': {'reasoning': True, 'toolcall': True}}}}],
                'connected': ['lab'], 'default': {'lab': 'synthetic'}})
        elif path in ('/permission', '/question', '/command', '/experimental/worktree'):
            self.reply([])
        elif path == '/session/status':
            with state.condition:
                statuses = {sid: {'type': 'busy'} for sid, run in state.runs.items() if not run['done'].is_set()}
            self.reply(statuses)
        elif path == '/session':
            roots = query.get('roots', ['false'])
            if roots not in (['true'], ['false']):
                raise ValueError('invalid roots')
            sessions = sorted(state.sessions.values(), key=lambda s: s['time']['updated'], reverse=True)
            self.reply(sessions[:self.limit(query, len(sessions))])
        elif path in ('/event', '/global/event'):
            self.sse(global_events=path == '/global/event')
        elif path == '/_lab/status':
            self.reply(state.snapshot())
        else:
            match = re.fullmatch(r'/session/([^/]+)(?:/(message|todo)(?:/([^/]+))?)?', path)
            if not match:
                self.reply({'error': 'unsupported fixture endpoint'}, 404)
                return
            sid, kind, mid = match.groups()
            headers = {}
            with state.condition:
                if sid not in state.sessions:
                    raise KeyError(sid)
                if kind is None:
                    value = state.sessions[sid]
                elif kind == 'todo' and mid is None:
                    value = []
                elif kind == 'message' and mid:
                    message = next((m for m in state.messages[sid] if m['info']['id'] == mid), None)
                    if message is None:
                        raise KeyError(mid)
                    value = message
                elif kind == 'message':
                    messages = state.messages[sid]
                    before = query.get('before')
                    if before:
                        if len(before) != 1:
                            raise ValueError('duplicate cursor')
                        end = next((i for i, m in enumerate(messages) if m['info']['id'] == before[0]), None)
                        if end is None:
                            raise ValueError('unknown cursor')
                    else:
                        end = len(messages)
                    start = max(0, end - self.limit(query, len(messages)))
                    headers = {'X-Next-Cursor': messages[start]['info']['id']} if start > 0 else {}
                    value = messages[start:end]
                else:
                    self.reply({'error': 'unsupported fixture endpoint'}, 404)
                    return
                value = copy.deepcopy(value)
            self.reply(value, headers=headers)

    @staticmethod
    def limit(query, default):
        values = query.get('limit', [str(default)])
        if len(values) != 1 or not re.fullmatch(r'[0-9]+', values[0]):
            raise ValueError('invalid limit')
        return bounded(int(values[0]), 'limit', 1, 100000)

    def sse(self, global_events):
        state = self.server.state
        with state.condition:
            supplied = self.headers.get('Last-Event-ID')
            if supplied is not None:
                if not re.fullmatch(r'[0-9]+', supplied):
                    raise ValueError('invalid event cursor')
                cursor = int(supplied)
                oldest = state.events[0][0] if state.events else state.sequence + 1
                if cursor < oldest - 1 or cursor > state.sequence:
                    self.reply({'error': 'event cursor expired; reload canonical messages'}, 409)
                    return
            else:
                cursor = state.sequence
        self.status = 200
        self.send_response(200)
        self.send_header('Content-Type', 'text/event-stream')
        self.send_header('Cache-Control', 'no-cache')
        self.send_header('Connection', 'close')
        self.end_headers()
        self.close_connection = True
        def send(payload, seq=None):
            value = payload if global_events else payload['payload']
            raw = ((f'id: {seq}\n' if seq is not None else '') + 'data: ' + encoded(value).decode('ascii') + '\n\n').encode()
            self.wfile.write(raw)
            self.wfile.flush()
            self.row['response_bytes'] += len(raw)
        send({'directory': DIRECTORY, 'payload': {'type': 'server.connected', 'properties': {}}})
        while not state.stop.is_set():
            with state.condition:
                state.condition.wait_for(lambda: state.sequence > cursor or state.stop.is_set(), timeout=10)
                if state.events and cursor < state.events[0][0] - 1:
                    return  # Slow subscriber must reconnect and reconcile canonical data.
                batch = [(seq, event) for seq, event in state.events if seq > cursor]
            if batch:
                for seq, event in batch:
                    send(event, seq)
                    cursor = seq
            elif not state.stop.is_set():
                heartbeat = b': heartbeat\n\n'
                self.wfile.write(heartbeat)
                self.wfile.flush()
                self.row['response_bytes'] += len(heartbeat)


class LabServer(ThreadingHTTPServer):
    daemon_threads = True

    @property
    def base_url(self):
        return f'http://{self.server_address[0]}:{self.server_address[1]}'

    def shutdown(self):
        self.state.stop.set()
        with self.state.condition:
            self.state.condition.notify_all()
        super().shutdown()


def make_server(host='127.0.0.1', port=0, *, state=None, password=None,
                latency_ms=0, detail_latency_ms=None):
    if not isinstance(ipaddress.ip_address(host), ipaddress.IPv4Address):
        raise ValueError('host must be a literal IPv4 address')
    bounded(port, 'port', 0, 65535)
    bounded(latency_ms, 'latency_ms', 0, 60000)
    if detail_latency_ms is None:
        detail_latency_ms = latency_ms
    bounded(detail_latency_ms, 'detail_latency_ms', 0, 60000)
    if password is not None and (not isinstance(password, str) or not password or ':' in password):
        raise ValueError('password must be nonempty and must not contain a colon')
    server = LabServer((host, port), Handler)
    server.state = state if state is not None else LabState()
    server.password = password or secrets.token_urlsafe(18)
    server.latency_ms = latency_ms
    server.detail_latency_ms = detail_latency_ms
    return server


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    serve = commands.add_parser('serve')
    serve.add_argument('--host', default='127.0.0.1')
    serve.add_argument('--port', type=int, default=14097)
    serve.add_argument('--password')
    serve.add_argument('--log', default='requests.jsonl')
    serve.add_argument('--latency-ms', type=int, default=0)
    serve.add_argument('--detail-latency-ms', type=int)
    serve.add_argument('--text-bytes', type=int, default=512)
    serve.add_argument('--tool-bytes', type=int, default=4096)
    serve.add_argument('--assistants-per-turn', type=int, default=7)
    stream = commands.add_parser('stream')
    stream.add_argument('--url', default='http://127.0.0.1:14097')
    stream.add_argument('--password', required=True)
    stream.add_argument('--session', default='ses_2000')
    stream.add_argument('--chunks', type=int, default=50)
    stream.add_argument('--interval-ms', type=int, default=100)
    stream.add_argument('--chunk-bytes', type=int, default=80)
    stream.add_argument('--part-type', choices=('text', 'reasoning'), default='text')
    stats = commands.add_parser('summary')
    stats.add_argument('log')
    args = parser.parse_args()
    try:
        if args.command == 'summary':
            print(json.dumps(summary(args.log), indent=2))
        elif args.command == 'stream':
            url = urlsplit(args.url)
            if url.scheme not in ('http', 'https') or not url.hostname or url.username or url.password or url.path not in ('', '/') or url.query or url.fragment:
                raise ValueError('url must be a plain server origin')
            auth = base64.b64encode(('opencode:' + args.password).encode()).decode()
            request = Request(args.url.rstrip('/') + '/_lab/stream', data=encoded({
                'sessionID': args.session, 'chunks': args.chunks, 'interval_ms': args.interval_ms,
                'chunk_bytes': args.chunk_bytes, 'part_type': args.part_type}),
                headers={'Authorization': 'Basic ' + auth, 'Content-Type': 'application/json'})
            with build_opener(ProxyHandler({})).open(request, timeout=10) as response:
                print(response.read().decode())
        else:
            state = LabState(args.text_bytes, args.tool_bytes, args.assistants_per_turn, args.log)
            server = make_server(args.host, args.port, state=state, password=args.password,
                                 latency_ms=args.latency_ms, detail_latency_ms=args.detail_latency_ms)
            print(json.dumps({'url': server.base_url, 'username': 'opencode', 'password': server.password,
                              'log': str(Path(args.log).resolve()), 'synthetic': True}), flush=True)
            try:
                server.serve_forever()
            except KeyboardInterrupt:
                state.stop.set()
                with state.condition:
                    state.condition.notify_all()
            finally:
                server.server_close()
    except (ValueError, OSError, HTTPError) as error:
        parser.exit(2, f'{type(error).__name__}: {error}\n')


if __name__ == '__main__':
    main()
