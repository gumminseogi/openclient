"""SSE replay, cancellation, and metadata boundaries; these are contract checks."""
import base64
import http.client
import json
from pathlib import Path
import tempfile
import threading
import unittest

import lab


class StreamEdgeTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.log = Path(self.temporary.name) / 'requests.jsonl'
        self.state = lab.LabState(text_bytes=32, tool_bytes=16, log_path=self.log)
        self.server = lab.make_server(state=self.state, password='edge-test-only')
        self.thread = threading.Thread(target=self.server.serve_forever,
                                       kwargs={'poll_interval': .01}, daemon=True)
        self.thread.start()
        self.connections = []
        self.headers = {'Authorization': 'Basic ' + base64.b64encode(b'opencode:edge-test-only').decode()}

    def tearDown(self):
        for connection in self.connections:
            connection.close()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=2)
        self.temporary.cleanup()

    def request(self, path, method='GET', body=None, headers=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=2)
        self.connections.append(connection)
        connection.request(method, path, json.dumps(body) if body is not None else None,
                           self.headers if headers is None else headers)
        return connection.getresponse()

    @staticmethod
    def event(response):
        seq, payload = None, None
        while True:
            line = response.readline().decode().strip()
            if line.startswith('id: '):
                seq = int(line[4:])
            if line.startswith('data: '):
                payload = json.loads(line[6:])
            if not line and payload is not None:
                return seq, payload

    def test_reconnect_replays_only_events_after_cursor(self):
        accepted = self.state.start_stream('ses_20', chunks=3, interval_ms=1, chunk_bytes=5)
        with self.state.condition:
            self.assertTrue(self.state.condition.wait_for(
                lambda: self.state.runs['ses_20']['done'].is_set(), timeout=2))
            frames = list(self.state.events)
        cursor = next(seq for seq, item in frames if item['payload']['type'] == 'message.part.delta')
        expected = [(seq, item) for seq, item in frames if seq > cursor]
        response = self.request('/global/event', headers={**self.headers, 'Last-Event-ID': str(cursor)})
        self.assertEqual(response.status, 200)
        self.assertEqual(self.event(response)[1]['payload']['type'], 'server.connected')
        actual = [self.event(response) for _ in expected]
        self.assertEqual(actual, expected)
        self.assertEqual(len({seq for seq, _ in actual}), len(actual))
        latest = json.loads(self.request('/session/ses_20/message/' + accepted['messageID']).read())
        self.assertEqual(latest['parts'][0]['text'], 'd' * 15)

    def test_expired_or_future_sse_cursor_is_explicit_conflict(self):
        with self.state.condition:
            for _ in range(self.state.events.maxlen + 1):
                self.state.emit('server.connected', {})
        for cursor in ('0', str(self.state.sequence + 1)):
            response = self.request('/global/event', headers={**self.headers, 'Last-Event-ID': cursor})
            self.assertEqual(response.status, 409)
            self.assertIn('canonical', json.loads(response.read())['error'])
        self.assertEqual(len(self.state.events), self.state.events.maxlen)

    def test_duplicate_stream_is_rejected_and_abort_finishes_before_reuse(self):
        response = self.request('/_lab/stream', 'POST', {'sessionID': 'ses_20', 'interval_ms': 1000})
        accepted = json.loads(response.read())
        self.assertEqual(response.status, 202)
        response = self.request('/_lab/stream', 'POST', {'sessionID': 'ses_20'})
        self.assertEqual(response.status, 409)
        response.read()
        response = self.request('/session/ses_20/abort', 'POST', {})
        self.assertEqual(response.status, 200)
        response.read()
        with self.state.condition:
            self.assertTrue(self.state.condition.wait_for(
                lambda: self.state.runs['ses_20']['done'].is_set(), timeout=2))
        latest = json.loads(self.request('/session/ses_20/message/' + accepted['messageID']).read())
        self.assertEqual(latest['info']['finish'], 'aborted')
        self.assertEqual(json.loads(self.request('/session/status').read()), {})
        response = self.request('/_lab/stream', 'POST', {'sessionID': 'ses_20', 'chunks': 1, 'interval_ms': 1})
        self.assertEqual(response.status, 202)
        response.read()

    def test_request_log_has_exact_body_bytes_and_no_body_or_authorization(self):
        response = self.request('/session/ses_20/message?limit=2')
        raw = response.read()
        response = self.request('/_lab/stream', 'POST', {'sessionID': 'ses_20', 'unexpected': 'BODY-SECRET'})
        self.assertEqual(response.status, 400)
        response.read()
        # Completion logging follows the socket write, so wait for its own condition.
        with self.state.condition:
            self.state.condition.wait_for(lambda: len(self.state.requests) == 2, timeout=.2)
            self.assertEqual(self.state.requests[0]['response_bytes'], len(raw))
        text = self.log.read_text()
        self.assertNotIn('edge-test-only', text)
        self.assertNotIn('Authorization', text)
        self.assertNotIn('BODY-SECRET', text)
        self.assertNotIn('"parts"', text)


if __name__ == '__main__':
    unittest.main(verbosity=2)
