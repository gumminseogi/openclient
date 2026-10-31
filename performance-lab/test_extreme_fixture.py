"""Contracts for generated long history; these checks are not app loading timings."""
import base64
import http.client
import json
import re
import threading
import unittest
from urllib.parse import urlencode

import lab


class ExtremeFixtureTests(unittest.TestCase):
    def test_startup_phase_retry_keeps_original_payload_and_does_not_mutate_history(self):
        with self.assertRaises(ValueError):
            lab.LabState(fail_first_startup_phase=True)
        state = lab.LabState(profile='extreme', extreme_messages=64, fail_first_startup_phase=True)
        server = lab.make_server(state=state, password='ci-fixture-only')
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        worker.start()
        auth = 'Basic ' + base64.b64encode(b'opencode:ci-fixture-only').decode()
        event = {'schema': 1, 'case': 'seeded-revisit', 'trial': 'trial1',
                 'phase': 'startup_cache_published', 'operation': 0, 'operation_kind': 'startup',
                 'grouping_actual': False, 'uptime_before_s': 10.0, 'uptime_after_s': 10.1,
                 'epoch_s': 1793390400.0, 'loaded_messages': 5000}

        def post(body, authorized=True):
            connection = http.client.HTTPConnection(*server.server_address, timeout=3)
            try:
                connection.request('POST', '/_lab/native-phase', lab.encoded(body),
                                   {'Authorization': auth} if authorized else {})
                response = connection.getresponse()
                response.read()
                return response.status
            finally:
                connection.close()

        try:
            self.assertEqual(post(event, authorized=False), 401)
            self.assertEqual(post(dict(event, loaded_messages='invalid')), 400)
            self.assertEqual(post(event), 503)
            self.assertEqual(state.snapshot()['native_events'], [])
            self.assertEqual(post(event), 202)
            self.assertEqual(post(event), 202)
            self.assertEqual(state.snapshot()['native_events'], [event, event])
            self.assertEqual(len(state.messages['ses_extreme']), 64)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_native_phase_metadata_is_authenticated_bounded_and_extreme_only(self):
        state = lab.LabState(profile='extreme', extreme_messages=64)
        server = lab.make_server(state=state, password='ci-fixture-only')
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        worker.start()
        auth = 'Basic ' + base64.b64encode(b'opencode:ci-fixture-only').decode()

        def request(method, path, body=None, authorized=True):
            connection = http.client.HTTPConnection(*server.server_address, timeout=3)
            try:
                headers = {'Authorization': auth} if authorized else {}
                connection.request(method, path, body=body, headers=headers)
                response = connection.getresponse()
                return response.status, json.loads(response.read())
            finally:
                connection.close()

        event = {'schema': 1, 'case': 'seeded-revisit', 'trial': 'trial1',
                 'phase': 'canonical_published', 'operation': 1, 'operation_kind': 'selection',
                 'grouping_actual': True, 'uptime_before_s': 10.0, 'uptime_after_s': 10.1,
                 'epoch_s': 1793390400.0, 'loaded_messages': 5000}
        try:
            self.assertEqual(request('POST', '/_lab/native-phase', lab.encoded(event), False)[0], 401)
            self.assertEqual(state.snapshot()['native_events'], [])
            self.assertEqual(request('POST', '/_lab/native-phase', lab.encoded(event)), (202, {'accepted': True}))
            self.assertEqual(request('GET', '/_lab/status')[1]['native_events'], [event])
            for index in range(129):
                row = dict(event, operation=index)
                self.assertEqual(request('POST', '/_lab/native-phase', lab.encoded(row))[0], 202)
            events = request('GET', '/_lab/status')[1]['native_events']
            self.assertEqual(len(events), 128)
            self.assertEqual([row['operation'] for row in events], list(range(1, 129)))
            self.assertEqual(state.extreme_profile['messages'], 64)
            self.assertEqual(len(state.messages['ses_extreme']), 64)
            # The standard fixture exposes neither the endpoint nor the status field.
            server.state = lab.LabState()
            self.assertEqual(request('POST', '/_lab/native-phase', lab.encoded(event))[0], 404)
            self.assertNotIn('native_events', request('GET', '/_lab/status')[1])
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_native_phase_rejects_unknown_content_and_bad_values(self):
        state = lab.LabState(profile='extreme', extreme_messages=64)
        server = lab.make_server(state=state, password='ci-fixture-only')
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        worker.start()
        auth = 'Basic ' + base64.b64encode(b'opencode:ci-fixture-only').decode()
        event = {'schema': 1, 'case': 'cold', 'trial': 'trial1', 'phase': 'metadata',
                 'operation': 0, 'operation_kind': 'startup', 'uptime_before_s': 10,
                 'uptime_after_s': 10.1, 'epoch_s': 1793390400, 'grouping_requested': False,
                 'scope': 'Synthetic native phase metadata only.'}
        invalid = [[], {'schema': 1}, dict(event, transcript='not accepted'),
                   dict(event, schema=True), dict(event, operation=True), dict(event, operation=-1),
                   dict(event, case='real-session'), dict(event, trial=''), dict(event, phase='heartbeat'),
                   dict(event, scope={'body': 'not accepted'}), dict(event, scope='x' * 513),
                   dict(event, grouping_requested=1), dict(event, grouping_actual=True),
                   dict(event, epoch_s=float('nan')), dict(event, epoch_s=10 ** 100),
                   dict(event, uptime_after_s=9)]
        startup = {key: value for key, value in event.items() if key not in ('grouping_requested', 'scope')}
        startup.update(phase='startup_cache_published', grouping_actual=False, loaded_messages=5000)
        invalid.extend(dict(startup, loaded_messages=value) for value in (True, -1, 100001, 5000.0, '5000'))
        try:
            for body in [lab.encoded(row) for row in invalid] + [b'{', b' ' * 16385]:
                with self.subTest(body_size=len(body)):
                    connection = http.client.HTTPConnection(*server.server_address, timeout=3)
                    try:
                        connection.request('POST', '/_lab/native-phase', body,
                                           {'Authorization': auth, 'Content-Type': 'application/json'})
                        response = connection.getresponse()
                        self.assertEqual(response.status, 400)
                        response.read()
                    finally:
                        connection.close()
            self.assertEqual(state.snapshot()['native_events'], [])
            # Every permitted callback shape is metadata, never a transcript or typed token.
            for phase, details in (
                ('metadata', {}),
                ('appearance_configured', {'tools_actual': True, 'reasoning_actual': True}),
                ('connection_overlay_dismissed', {'connected_actual': True}),
                ('startup_cache_published', {'loaded_messages': 5000}),
                ('selection_started', {}), ('canonical_published', {'loaded_messages': 5000}),
                ('transcript_reveal_completed', {}), ('bottom_refresh_method_completed', {}),
            ):
                row = {key: value for key, value in event.items() if key not in ('grouping_requested', 'scope')}
                row.update(phase=phase, **details)
                if phase != 'metadata':
                    row['grouping_actual'] = False
                state.record_native_phase(row)
            self.assertEqual(len(state.snapshot()['native_events']), 8)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_extreme_history_is_single_valid_paginated_session(self):
        state = lab.LabState(profile='extreme', extreme_messages=65)
        self.assertEqual(set(state.sessions), {'ses_extreme'})
        messages = state.messages['ses_extreme']
        ids = [message['info']['id'] for message in messages]
        self.assertEqual(ids, [f'msg_ses_extreme_{index:06d}' for index in range(65)])
        self.assertEqual(messages[-1]['info']['role'], 'assistant')
        self.assertIn(messages[-1]['info']['parentID'], ids[:-1])
        self.assertTrue(messages[-1]['parts'][-1]['text'].endswith('EXTREME_SESSION_READY_000065'))
        part_ids = []
        preview_count = 0
        for message in messages:
            for part in message['parts']:
                part_ids.append(part['id'])
                self.assertEqual(part['messageID'], message['info']['id'])
                self.assertEqual(part['sessionID'], 'ses_extreme')
                if part['type'] != 'tool':
                    continue
                self.assertIn(part['state']['status'], ('completed', 'error'))
                self.assertIsInstance(part['state']['input'], dict)
                self.assertIsInstance(part['state']['output'], str)
                if part['tool'] == 'webfetch':
                    self.assertEqual(part['state']['input']['url'], 'http://127.0.0.1:14097/_lab/reference')
                if part['tool'] == 'openclient_execute_tool':
                    preview_count += 1
                    tool_input, metadata = part['state']['input'], part['state']['metadata']
                    self.assertEqual(tool_input['toolID'], 'openclient_visual_html')
                    self.assertEqual(metadata['renderer'], 'openclient.html.v1')
                    self.assertEqual(tool_input['arguments'], metadata['payload'])
                    payload = metadata['payload']
                    self.assertEqual(payload['schemaVersion'], 1)
                    self.assertGreater(payload['height'], 0)
                    self.assertLessEqual(len(payload['html'].encode()), 65536)
                    self.assertLessEqual(len(re.findall(r'<\s*[A-Za-z][^>]*>', payload['html'])), 200)
                    self.assertNotRegex(payload['html'], r'(?i)script|iframe|src=|href=|url\(|@import')
        self.assertEqual(len(part_ids), len(set(part_ids)))
        self.assertGreater(preview_count, 0)
        self.assertEqual(set(state.extreme_profile['tool_type_counts']), set(lab.EXTREME_TOOL_NAMES))
        self.assertEqual(state.extreme_profile['encoded_messages_bytes'], len(lab.encoded(messages)))

        server = lab.make_server(state=state, password='synthetic-contract-only')
        worker = threading.Thread(target=server.serve_forever, kwargs={'poll_interval': .01}, daemon=True)
        worker.start()
        auth = 'Basic ' + base64.b64encode(b'opencode:synthetic-contract-only').decode()

        def get(path):
            connection = http.client.HTTPConnection(*server.server_address, timeout=3)
            try:
                connection.request('GET', path, headers={'Authorization': auth})
                response = connection.getresponse()
                self.assertEqual(response.status, 200)
                return json.loads(response.read()), response.getheader('X-Next-Cursor')
            finally:
                connection.close()

        try:
            connection = http.client.HTTPConnection(*server.server_address, timeout=3)
            try:
                connection.request('GET', '/_lab/reference')
                reference = connection.getresponse()
                raw = reference.read()
                self.assertEqual(reference.status, 200)
                self.assertEqual(int(reference.getheader('Content-Length')), len(raw))
                self.assertTrue(reference.getheader('Content-Type').startswith('text/html'))
                self.assertEqual(reference.getheader('Content-Security-Policy'), "default-src 'none'")
                self.assertIn(b'Synthetic local reference', raw)
                self.assertNotRegex(raw, b'(?i)<script|<img|src=|href=')
            finally:
                connection.close()
            session_list, _ = get('/session?roots=true&limit=55')
            self.assertEqual([session['id'] for session in session_list], ['ses_extreme'])
            profile = get('/_lab/status')[0]['extreme_profile']
            self.assertEqual(profile['messages'], 65)
            self.assertGreater(profile['reasoning_utf8_bytes'], 0)
            page, cursor = get('/session/ses_extreme/message?limit=13')
            self.assertEqual(len(page), 13)
            collected = list(page)
            while cursor:
                page, cursor = get('/session/ses_extreme/message?' + urlencode({'limit': 13, 'before': cursor}))
                self.assertLessEqual(len(page), 13)
                collected = page + collected
            self.assertEqual(collected, messages, 'Real cursors must cover the entire history once, in order.')
            latest = messages[-1]
            detail = get('/session/ses_extreme/message/' + latest['info']['id'])[0]
            self.assertEqual(detail, latest)
        finally:
            server.shutdown()
            server.server_close()
            worker.join(timeout=2)

    def test_default_extreme_payload_has_a_bounded_documented_budget(self):
        state = lab.LabState(profile='extreme')
        profile = state.extreme_profile
        self.assertEqual(profile['messages'], 5000)
        self.assertEqual(profile['tool_parts'], 8750)
        self.assertEqual(profile['parts'], 18125)
        self.assertGreaterEqual(profile['encoded_messages_bytes'], 100 * 1024 * 1024)
        self.assertLessEqual(profile['encoded_messages_bytes'], 150 * 1024 * 1024)
        self.assertEqual(profile['ready_sentinel'], 'EXTREME_SESSION_READY_005000')
        self.assertIn('openclient_execute_tool', {part.get('tool') for message in state.messages['ses_extreme'][-20:]
                                                for part in message['parts']})
        self.assertEqual(state.snapshot()['active'], [])
        for value in (0, 63, 10001):
            with self.assertRaises(ValueError):
                lab.LabState(profile='extreme', extreme_messages=value)


if __name__ == '__main__':
    unittest.main()
