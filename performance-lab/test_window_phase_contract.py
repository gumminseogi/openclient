"""Real HTTP contract between the window probe publisher and fixture telemetry."""
import base64
import http.client
import json
from pathlib import Path
import re
import threading
import unittest

import lab


DETAILS = {
    'metadata': {'grouping_requested': False, 'scope': 'Synthetic phase timings only.'},
    'appearance_configured': {'tools_actual': True, 'reasoning_actual': True},
    'connection_overlay_dismissed': {'connected_actual': True},
    'startup_cache_published': {'loaded_messages': 64},
    'selection_started': {},
    'canonical_published': {'loaded_messages': 64},
    'transcript_reveal_completed': {},
    'bottom_refresh_method_completed': {},
    'cached_transcript_reused': {'loaded_messages': 64},
    'legacy_stream_open': {},
}
LOCAL_ONLY = {'canonical_request_started', 'canonical_typed_page_returned'}


def event(phase):
    startup = phase in ('metadata', 'appearance_configured', 'connection_overlay_dismissed',
                        'startup_cache_published', 'legacy_stream_open')
    operation = 0 if startup else 2 if phase == 'cached_transcript_reused' else 3 if phase == 'bottom_refresh_method_completed' else 1
    value = {'schema': 1, 'case': 'seeded-revisit', 'trial': 'trial1', 'phase': phase,
             'operation': operation, 'operation_kind': 'startup' if startup else 'bottom_refresh' if operation == 3 else 'selection',
             'uptime_before_s': 10, 'uptime_after_s': 10.0001, 'epoch_s': 1000}
    if phase != 'metadata':
        value['grouping_actual'] = False
    value.update(DETAILS.get(phase, {}))
    return value


class WindowPhaseContractTests(unittest.TestCase):
    def setUp(self):
        self.state = lab.LabState(profile='extreme', extreme_messages=64, legacy_cursorless=True)
        self.server = lab.make_server(state=self.state, password='window-phase-contract-only')
        self.worker = threading.Thread(target=self.server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        self.worker.start()
        self.auth = 'Basic ' + base64.b64encode(b'opencode:window-phase-contract-only').decode()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=2)

    def request(self, method, path, body=None, auth=None):
        connection = http.client.HTTPConnection(*self.server.server_address, timeout=5)
        try:
            headers = {'Authorization': self.auth if auth is None else auth}
            if body is not None:
                headers['Content-Type'] = 'application/json'
            connection.request(method, path, body=None if body is None else json.dumps(body), headers=headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def native_events(self):
        status, body = self.request('GET', '/_lab/status')
        self.assertEqual(status, 200)
        self.assertIs(body['legacy_cursorless'], True)
        self.assertEqual(body['sessions'], {'ses_extreme': 64})
        return body['native_events']

    def test_every_source_published_phase_roundtrips_exact_metadata(self):
        source = Path(__file__).with_name('window_session_probe.swift').read_text()
        match = re.search(r'publishedPhases\s*:\s*Set<String>\s*=\s*\[(.*?)\]', source, re.S)
        self.assertIsNotNone(match, 'Cannot locate the actual Swift publisher allowlist')
        phases = re.findall(r'"([a-z_]+)"', match.group(1))
        self.assertEqual(len(phases), 10)
        self.assertEqual(len(phases), len(set(phases)), 'Duplicate published phase')
        self.assertEqual(set(phases), set(DETAILS), 'Update HTTP contract fixtures when the Swift publisher changes')
        self.assertFalse(LOCAL_ONLY & set(phases), 'Typed HTTP timing markers stay local to native JSONL')
        # The publisher must never acquire a transcript/body key. Local input
        # validation tokens are separate and are not in the published phase set.
        self.assertNotRegex(source, r'(?:\[\s*|row\[)"(?:messages|parts|payload|prompt|transcript|text|reasoning)"\s*(?::|\]\s*=)')
        expected = []
        for phase in phases:
            with self.subTest(phase=phase):
                payload = event(phase)
                status, response = self.request('POST', '/_lab/native-phase', payload)
                self.assertEqual(status, 202, response)
                self.assertEqual(response, {'accepted': True})
                expected.append(payload)
                self.assertEqual(self.native_events(), expected)

    def test_invalid_new_cache_metadata_is_rejected_without_status_pollution(self):
        good = event('legacy_stream_open')
        self.assertEqual(self.request('POST', '/_lab/native-phase', good)[0], 202)
        invalid = []
        for count in (True, 64.0, '64', None, -1, 100001):
            value = event('cached_transcript_reused')
            value['loaded_messages'] = count
            invalid.append(value)
        missing = event('cached_transcript_reused')
        del missing['loaded_messages']
        invalid.append(missing)
        extra = event('cached_transcript_reused')
        extra['transcript'] = ['not accepted']
        invalid.append(extra)
        for payload in invalid:
            with self.subTest(payload=payload):
                status, response = self.request('POST', '/_lab/native-phase', payload)
                self.assertEqual(status, 400, response)
                self.assertEqual(self.native_events(), [good])

    def test_stream_unknown_fields_unknown_phase_and_local_markers_are_rejected(self):
        extra_stream = event('legacy_stream_open')
        extra_stream['loaded_messages'] = 64
        payloads = [extra_stream, event('not_a_phase')]
        payloads += [event(phase) for phase in sorted(LOCAL_ONLY)]
        for payload in payloads:
            with self.subTest(phase=payload['phase']):
                status, response = self.request('POST', '/_lab/native-phase', payload)
                self.assertEqual(status, 400, response)
                self.assertEqual(self.native_events(), [])

    def test_wrong_auth_cannot_publish_or_read_native_status(self):
        payload = event('cached_transcript_reused')
        status, response = self.request('POST', '/_lab/native-phase', payload, auth='Basic wrong')
        self.assertEqual(status, 401, response)
        self.assertEqual(self.native_events(), [])
        self.assertEqual(self.request('GET', '/_lab/status', auth='Basic wrong')[0], 401)


if __name__ == '__main__':
    unittest.main()
