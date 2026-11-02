"""Evidence-integrity tests; no simulator or generated giant message body needed."""
import copy
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).with_name('validate-window-results.py')
SPEC = importlib.util.spec_from_file_location('window_results', SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value) + '\n')


def write_rows(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(''.join(json.dumps(row) + '\n' for row in rows))


def make_run(root, variant='patched', count=1000):
    """Small raw artifacts with separate native/UI timing and full retained history."""
    case = root / validator.CASE
    seed = root / 'cache-seed'
    loaded = min(count, 400) if variant == 'patched' else count
    limit = 400 if variant == 'patched' else count
    full_bytes = count * 100
    page_bytes = min(count, 400) * 100
    body = page_bytes if variant == 'patched' else full_bytes
    profile = {'session_id': 'ses_extreme', 'messages': count, 'ready_sentinel': 'LATEST_ANSWER_001',
               'encoded_messages_bytes': full_bytes, 'encoded_page_bytes': {'400': page_bytes, '800': min(count, 800) * 100}}
    source = {'schema': 1, 'variant': variant, 'configured_message_count': count, 'groupings': [False],
              'input_validation_policy': 'loading-only', 'input_validation_performed': False,
              'paired_baseline_sha': 'a' * 40, 'test_checkout_sha': ('a' if variant == 'baseline' else 'b') * 40,
              'harness_checkout_sha': 'b' * 40}
    write(root / 'provenance.json', source)
    write(root / 'case-status.json', {'failed_measured_ui_cases': 0, 'expected_measured_ui_cases': 1, 'cache_seed_exit_code': 0})
    status = {'synthetic': True, 'legacy_cursorless': True, 'sessions': {'ses_extreme': count}, 'extreme_profile': profile}
    for path in (case, seed):
        write(path / 'fixture-initial-status.json', status)
        write(path / 'summary.json', {'result': 'Passed', 'totalTestCount': 1, 'passedTests': 1, 'failedTests': 0, 'skippedTests': 0})
        write(path / 'xcodebuild-status.json', {'xcodebuild_exit_code': 0})
    write(seed / 'validation.json', {'complete': True, 'errors': []})
    write(seed / 'cache-seed-proof.json', {'schema': 1, 'synthetic': True, 'setup_only': True, 'session_id': 'ses_extreme',
        'messages': count, 'readback_messages': count, 'readback_used_second_repository': True,
        'directory_sessions': 1, 'readback_directory_sessions': 1, 'readback_directory_session_ids': ['ses_extreme'],
        'todos_via_production_api': True, 'readback_todos_known': True, 'readback_todos_stale': True,
        'todos': 3, 'readback_todos': 3, 'encoded_response_bytes': full_bytes,
        'readback_preview_messages': min(count, 400), 'readback_preview_retained_messages': count})
    rows = []

    def phase(name, operation, at, **details):
        row = {'phase': name, 'operation': operation, 'operation_kind': 'startup' if not operation else 'bottom_refresh' if operation == 3 else 'selection',
               'uptime_before_s': at, 'uptime_after_s': at + .0001, 'epoch_s': 1000 + at + .00005}
        if name != 'metadata':
            row['grouping_actual'] = False
        row.update(details)
        rows.append(row)
        return copy.deepcopy(row)

    phase('metadata', 0, 0, schema=1, case='seeded-revisit', trial='trial1', grouping_requested=False)
    phase('appearance_configured', 0, 1, tools_actual=True, reasoning_actual=True)
    phase('legacy_stream_open', 0, 2)
    phase('startup_cache_published', 0, 3, loaded_messages=loaded)
    requests, actions = [], []
    for operation, stage in enumerate(validator.STAGES, 1):
        cached = variant == 'patched' and operation == 2
        at = [10, 40, 75][operation - 1]
        before = [10, 30, 50][operation - 1]
        after = before + 10
        phase('bottom_refresh_started' if operation == 3 else 'selection_started', operation, at)
        if cached:
            ready = phase('cached_transcript_reused', operation, at + 3, loaded_messages=loaded)
        else:
            phase('canonical_request_started', operation, at + .1, request_limit=limit)
            phase('canonical_typed_page_returned', operation, at + 14, page_messages=loaded)
            ready = phase('canonical_published', operation, at + 15, loaded_messages=loaded)
        end = phase('bottom_refresh_method_completed' if operation == 3 else 'transcript_reveal_completed', operation, at + (20 if operation == 3 else 10))
        proof = []
        if not cached:
            request = {'request_id': before + 2, 'method': 'GET', 'path': validator.MESSAGE_PATH,
                       'query': {'limit': [str(limit)], 'directory': ['/openclient-performance-lab']},
                       'status': 200, 'response_bytes': body, 'started_ns': operation * 100000, 'ended_ns': operation * 100000 + 20000}
            requests.append(request)
            proof = [copy.deepcopy(request)]
        # Keep real control/polling traffic inside cached action windows too.
        requests.append({'request_id': after, 'method': 'GET', 'path': '/_lab/status', 'query': {}, 'status': 200, 'response_bytes': 1000})
        action = {'stage': stage, 'operation': operation, 'ready_kind': 'cached' if cached else 'http',
                  'start_uptime_s': at - .5, 'request_id_before_action': before, 'request_id_after_action': after,
                  'minimum_expected_loaded': loaded, 'requests': proof,
                  'native_probe_status': {'refresh' if operation == 3 else 'reveal': end,
                                          'cache_reuse' if cached else 'canonical': ready}}
        if operation == 3:
            action['canonical_and_method_observed_uptime_s'] = at + 20.5
        else:
            action['content_observed_uptime_s'] = at + 10.5
            action['canonical_observed_uptime_s'] = at + (10.6 if cached else 15.5)
        actions.append(action)
    # Unmeasured app prefetch and web preview must appear in case totals.
    requests += [{'request_id': 1, 'method': 'GET', 'path': validator.MESSAGE_PATH, 'query': {'limit': ['20']}, 'status': 200, 'response_bytes': 2000},
                 {'request_id': 2, 'method': 'GET', 'path': '/_lab/reference', 'query': {}, 'status': 200, 'response_bytes': 321},
                 {'request_id': 25, 'method': 'GET', 'path': validator.MESSAGE_PATH + '/msg_tool', 'query': {}, 'status': 200, 'response_bytes': 456}]
    ui = {'schema': 1, 'experiment': 'window_session_load', 'case': 'seeded-revisit', 'trial': 'trial1',
          'grouping': False, 'checkpoint': 'complete', 'complete': True, 'profile': profile, 'actions': actions,
          'input_validation_policy': 'loading-only', 'input_validation_performed': False,
          'launch_start_uptime_s': 0, 'home_observed_uptime_s': 4,
          'project_navigation': {'project_tap_uptime_s': 5, 'session_row_observed_uptime_s': 6},
          'clock': {'uptime_before_s': 100, 'uptime_after_s': 100.0001, 'epoch_s': 1100.00005}}
    write(case / 'attachments' / 'completed.json', ui)
    write(case / 'attachments' / 'manifest.json', [])  # xcresult export metadata is not evidence.
    write_rows(case / 'probes' / 'app.jsonl', rows)
    write_rows(case / 'requests.jsonl', requests)
    return case


def add_cached_callbacks(case):
    """Model facade reentry and remount callbacks; polling sees the latest."""
    path = case / 'probes/app.jsonl'
    rows = validator.read_jsonl(path)
    first = next(row for row in rows if row['phase'] == 'cached_transcript_reused')
    later = []
    for offset in (1, 2):
        row = copy.deepcopy(first)
        for key in ('uptime_before_s', 'uptime_after_s', 'epoch_s'):
            row[key] += offset
        later.append(row)
    index = rows.index(first) + 1
    rows[index:index] = later
    reentry = copy.deepcopy(first)
    reentry['operation'] = 1
    for key in ('uptime_before_s', 'uptime_after_s', 'epoch_s'):
        reentry[key] -= 17  # After op1's canonical publication, before op2 starts.
    index = next(index for index, row in enumerate(rows) if row.get('operation') == 2)
    rows.insert(index, reentry)
    write_rows(path, rows)
    ui_path = case / 'attachments/completed.json'
    ui = json.loads(ui_path.read_text())
    ui['actions'][1]['native_probe_status']['cache_reuse'] = copy.deepcopy(later[-1])
    write(ui_path, ui)


class WindowResultsTests(unittest.TestCase):
    def test_realistic_variants_and_small_canary_metrics(self):
        for variant in ('baseline', 'patched'):
            for count in (64, 20000):
                with self.subTest(variant=variant, count=count), tempfile.TemporaryDirectory() as directory:
                    root = Path(directory)
                    make_run(root, variant, count)
                    result = validator.validate(root)
                    self.assertTrue(result['complete'])
                    self.assertEqual([a['canonical_get_count'] for a in result['actions']], [1, 0 if variant == 'patched' else 1, 1])
                    self.assertAlmostEqual(result['actions'][0]['native_seconds'], 10)
                    self.assertEqual(result['actions'][0]['ui_visible_seconds'], 11)
                    self.assertEqual(result['startup']['ui_launch_to_first_visible_seconds'], 20.5)
                    self.assertEqual(result['startup']['cache_messages'], min(count, 400) if variant == 'patched' else count)
                    self.assertEqual(result['totals']['message_detail_get_count'], 1)
                    self.assertEqual(result['totals']['canonical_get_count'], 3 if variant == 'patched' else 4)
                    self.assertEqual(result['totals']['app_response_body_bytes'] - result['totals']['canonical_response_bytes'], 321 + 456)

    def test_repeated_consistent_cached_callbacks_use_earliest_ready_time(self):
        for count in (64, 1000):
            with self.subTest(count=count), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                case = make_run(root, count=count)
                add_cached_callbacks(case)
                original = (case / 'probes/app.jsonl').read_bytes()
                result = validator.validate(root)
                self.assertTrue(result['complete'])
                self.assertEqual([action['native_ready_callback_count'] for action in result['actions']], [1, 3, 1])
                revisit = result['actions'][1]
                self.assertAlmostEqual(revisit['native_ready_seconds'], 3)
                self.assertAlmostEqual(revisit['native_ready_uptime_s'], 43.00005)
                self.assertEqual(revisit['loaded_messages'], min(count, 400))
                self.assertEqual(revisit['canonical_get_count'], 0)
                self.assertEqual((case / 'probes/app.jsonl').read_bytes(), original, 'Validation must preserve every raw callback')

    def test_repeated_cached_callbacks_cannot_hide_inconsistent_or_fabricated_proof(self):
        flaws = ('later_wrong_count', 'wrong_operation', 'wrong_kind', 'wrong_group', 'missing_all',
                 'embedded_fake_phase', 'unexpected_canonical', 'unexpected_http')
        for flaw in flaws:
            with self.subTest(flaw=flaw), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                case = make_run(root)
                add_cached_callbacks(case)
                path = case / 'probes/app.jsonl'
                rows = validator.read_jsonl(path)
                callbacks = [r for r in rows if r['phase'] == 'cached_transcript_reused']
                latest = callbacks[-1]
                if flaw == 'later_wrong_count':
                    latest['loaded_messages'] = 1000
                elif flaw == 'wrong_operation':
                    for callback in callbacks:
                        callback['operation'] = 1
                elif flaw == 'wrong_kind':
                    latest['operation_kind'] = 'bottom_refresh'
                elif flaw == 'wrong_group':
                    latest['grouping_actual'] = True
                elif flaw == 'missing_all':
                    rows = [r for r in rows if r['phase'] != 'cached_transcript_reused']
                elif flaw == 'embedded_fake_phase':
                    ui_path = case / 'attachments/completed.json'
                    ui = json.loads(ui_path.read_text())
                    ui['actions'][1]['native_probe_status']['cache_reuse']['phase'] = 'canonical_published'
                    write(ui_path, ui)
                elif flaw == 'unexpected_canonical':
                    unexpected = copy.deepcopy(latest)
                    unexpected['phase'] = 'canonical_published'
                    rows.append(unexpected)
                else:
                    log_path = case / 'requests.jsonl'
                    log = validator.read_jsonl(log_path)
                    unexpected = copy.deepcopy(next(r for r in log if r['request_id'] == 12))
                    unexpected['request_id'] = 32
                    log.append(unexpected)
                    write_rows(log_path, log)
                write_rows(path, rows)
                with self.assertRaises(ValueError):
                    validator.validate(root)

    def test_rejects_misleading_or_incomplete_evidence(self):
        mutations = {
            'retained archive lost': ('cache-seed/cache-seed-proof.json', lambda v: v.update(readback_messages=400)),
            'preview pretends full history': ('cache-seed/cache-seed-proof.json', lambda v: v.update(readback_preview_messages=1000)),
            'preview lost retention metadata': ('cache-seed/cache-seed-proof.json', lambda v: v.update(readback_preview_retained_messages=400)),
            'source mismatch': ('provenance.json', lambda v: v.update(test_checkout_sha='c' * 40)),
            'conflicting source pin': ('provenance.json', lambda v: v.update(pinned_baseline_sha='c' * 40)),
            'keyboard scope creep': ('provenance.json', lambda v: v.update(input_validation_performed=True)),
            'grouping mismatch': ('provenance.json', lambda v: v.update(groupings=[True])),
            'not cursorless server': (validator.CASE + '/fixture-initial-status.json', lambda v: v.update(legacy_cursorless=False)),
            'UI profile is from another session': (validator.CASE + '/attachments/completed.json', lambda v: v['profile'].update(ready_sentinel='wrong')),
            'cached action claims HTTP': (validator.CASE + '/attachments/completed.json', lambda v: v['actions'][1].update(ready_kind='http')),
            'native proof substituted': (validator.CASE + '/attachments/completed.json', lambda v: v['actions'][1]['native_probe_status']['cache_reuse'].update(loaded_messages=1000)),
            'reused HTTP window': (validator.CASE + '/attachments/completed.json', lambda v: v['actions'][2].update(request_id_before_action=10)),
        }
        for name, (relative, mutate) in mutations.items():
            with self.subTest(name=name), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                make_run(root)
                path = root / relative
                value = json.loads(path.read_text())
                mutate(value)
                write(path, value)
                with self.assertRaises(ValueError):
                    validator.validate(root)

    def test_raw_http_log_overrules_ui_claims(self):
        for flaw in ('hidden_cached_get', 'hidden_between_actions_get', 'truncated_body', 'cursor', 'wrong_limit', 'repeated_id'):
            with self.subTest(flaw=flaw), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                case = make_run(root)
                rows = validator.read_jsonl(case / 'requests.jsonl')
                main = next(r for r in rows if r['request_id'] == 12)
                if flaw.startswith('hidden_'):
                    hidden = copy.deepcopy(main)
                    hidden['request_id'] = 32 if flaw == 'hidden_cached_get' else 26
                    rows.append(hidden)
                elif flaw == 'truncated_body':
                    main['response_bytes'] -= 1
                elif flaw == 'cursor':
                    main['query']['before'] = ['msg_old']
                elif flaw == 'wrong_limit':
                    main['query']['limit'] = ['1000']
                else:
                    rows.append(copy.deepcopy(main))
                write_rows(case / 'requests.jsonl', rows)
                with self.assertRaises(ValueError):
                    validator.validate(root)

    def test_native_phases_must_prove_healthy_bounded_path(self):
        for flaw in ('missing_stream', 'stream_reopened', 'late_startup', 'disk_full_read', 'no_refresh_end', 'missing_cached_ready', 'bad_native_count'):
            with self.subTest(flaw=flaw), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                case = make_run(root)
                path = case / 'probes/app.jsonl'
                rows = validator.read_jsonl(path)
                if flaw == 'missing_stream':
                    rows = [r for r in rows if r['phase'] != 'legacy_stream_open']
                elif flaw == 'stream_reopened':
                    row = copy.deepcopy(next(r for r in rows if r['operation'] == 2))
                    row['phase'] = 'legacy_stream_open'
                    rows.append(row)
                elif flaw == 'late_startup':
                    next(r for r in rows if r['phase'] == 'startup_cache_published')['uptime_after_s'] = 11
                elif flaw == 'disk_full_read':
                    row = copy.deepcopy(next(r for r in rows if r['operation'] == 2))
                    row['phase'] = 'disk_cache_load_started'
                    rows.append(row)
                elif flaw == 'no_refresh_end':
                    rows = [r for r in rows if r['phase'] != 'bottom_refresh_method_completed']
                elif flaw == 'missing_cached_ready':
                    rows = [r for r in rows if r['phase'] != 'cached_transcript_reused']
                else:
                    next(r for r in rows if r['phase'] == 'canonical_typed_page_returned')['page_messages'] = 1000
                write_rows(path, rows)
                with self.assertRaises(ValueError):
                    validator.validate(root)

    def test_duplicate_checkpoint_and_truncated_probe_fail(self):
        for flaw in ('duplicate_checkpoint', 'truncated_probe'):
            with self.subTest(flaw=flaw), tempfile.TemporaryDirectory() as directory:
                root = Path(directory)
                case = make_run(root)
                if flaw == 'duplicate_checkpoint':
                    source = case / 'attachments/completed.json'
                    (source.parent / 'duplicate.json').write_bytes(source.read_bytes())
                else:
                    path = case / 'probes/app.jsonl'
                    path.write_bytes(path.read_bytes().rstrip(b'\n'))
                with self.assertRaises(ValueError):
                    validator.validate(root)

    def test_cli_always_writes_machine_readable_failure(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            make_run(root)
            valid = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
            self.assertEqual(valid.returncode, 0, valid.stderr)
            self.assertTrue(json.loads((root / 'measurements.json').read_text())['complete'])
            (root / validator.CASE / 'probes/app.jsonl').write_text('{broken\n')
            failed = subprocess.run([sys.executable, str(SCRIPT), str(root)], capture_output=True, text=True)
            self.assertEqual(failed.returncode, 1)
            self.assertFalse(json.loads((root / 'validation.json').read_text())['complete'])
            self.assertFalse(json.loads((root / 'measurements.json').read_text())['complete'])


if __name__ == '__main__':
    unittest.main()
