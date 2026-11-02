#!/usr/bin/env python3
"""Validate one real-route legacy-window run without equating it to full sync."""
import json
import math
import re
import sys
from pathlib import Path


CASE = 'seeded-revisit-trial1-g0'
MESSAGE_PATH = '/session/ses_extreme/message'
STAGES = ['first_open', 'same_process_revisit', 'bottom_refresh']
SCOPE = ('recent_content_readiness: baseline full inventory versus patched newest '
         'window/cache; not equal full-sync completion, presented-frame/FPS, '
         'keyboard responsiveness, physical-iPhone or cellular wire-byte measurement')


def require(condition, message):
    if not condition:
        raise ValueError(message)


def read_json(path):
    value = json.loads(path.read_text())
    require(isinstance(value, dict), f'{path.name}: expected a JSON object')
    return value


def read_jsonl(path):
    raw = path.read_bytes()
    require(raw and raw.endswith(b'\n'), f'{path.name}: empty or truncated JSONL')
    rows = [json.loads(line) for line in raw.splitlines()]
    require(all(isinstance(row, dict) for row in rows), f'{path.name}: invalid JSONL rows')
    return rows


def number(value):
    return type(value) in (int, float) and math.isfinite(value) and value >= 0


def integer(value):
    return type(value) is int and value >= 0


def midpoint(row):
    before, after, epoch = (row.get(key) for key in ('uptime_before_s', 'uptime_after_s', 'epoch_s'))
    require(all(number(v) for v in (before, after, epoch)) and 0 <= after - before <= .1,
            'Invalid or imprecise native/UI clock sample')
    return (before + after) / 2


def delta(end, start, label):
    require(number(start) and number(end) and end >= start, f'Invalid {label} timing')
    return end - start


def one(rows, phase):
    found = [row for row in rows if row.get('phase') == phase]
    require(len(found) == 1, f'Expected exactly one native {phase}, found {len(found)}')
    return found[0]


def passed_test(path):
    status = read_json(path / 'xcodebuild-status.json')
    summary = read_json(path / 'summary.json')
    require(status.get('xcodebuild_exit_code') == 0 and summary.get('result') == 'Passed'
            and summary.get('totalTestCount') == 1 and summary.get('passedTests') == 1
            and summary.get('failedTests') == 0 and summary.get('skippedTests') == 0,
            f'{path.name}: expected exactly one passed native test')


def fixture(path, count):
    value = read_json(path / 'fixture-initial-status.json')
    require(value.get('synthetic') is True and value.get('legacy_cursorless') is True
            and value.get('sessions') == {'ses_extreme': count}, 'Wrong cursorless single-session fixture')
    profile = value.get('extreme_profile', {})
    require(profile.get('session_id') == 'ses_extreme' and profile.get('messages') == count,
            'Wrong fixture history size')
    require(integer(profile.get('encoded_messages_bytes')) and profile['encoded_messages_bytes'] > 0
            and isinstance(profile.get('encoded_page_bytes'), dict)
            and integer(profile['encoded_page_bytes'].get('400')) and profile['encoded_page_bytes']['400'] > 0,
            'Fixture lacks exact encoded full/page body sizes')
    require(isinstance(profile.get('ready_sentinel'), str) and bool(profile['ready_sentinel']),
            'Fixture lacks the latest-answer visibility sentinel')
    return profile


def validate(root):
    source = read_json(root / 'provenance.json')
    variant, count = source.get('variant'), source.get('configured_message_count')
    require(source.get('schema') == 1 and variant in ('baseline', 'patched'), 'Invalid provenance variant/schema')
    require(type(count) is int and 64 <= count <= 50000, 'Invalid configured message count')
    require(source.get('groupings') == [False] and type(source['groupings'][0]) is bool
            and source.get('input_validation_policy') == 'loading-only'
            and source.get('input_validation_performed') is False, 'Wrong grouping or loading-only policy')
    pin = source.get('pinned_baseline_sha', source.get('paired_baseline_sha'))
    require(all(isinstance(v, str) and re.fullmatch(r'[0-9a-f]{40}', v)
                for v in (pin, source.get('test_checkout_sha'), source.get('harness_checkout_sha'))),
            'Missing or invalid source revisions')
    require('paired_baseline_sha' not in source or source['paired_baseline_sha'] == pin,
            'Conflicting baseline source pins')
    expected_source = pin if variant == 'baseline' else source['harness_checkout_sha']
    require(source['test_checkout_sha'] == expected_source, 'Test source does not match the declared variant revision')
    require({p.name for p in root.iterdir() if p.is_dir() and '-trial' in p.name} == {CASE},
            'Missing or unexpected measured case directories')
    case_status = read_json(root / 'case-status.json')
    require(case_status.get('failed_measured_ui_cases') == 0 and case_status.get('expected_measured_ui_cases') == 1
            and case_status.get('cache_seed_exit_code') == 0, 'Native case/cache preparation did not finish successfully')
    case, seed = root / CASE, root / 'cache-seed'
    passed_test(case)
    passed_test(seed)
    require(read_json(seed / 'validation.json').get('complete') is True, 'Cache preparation validation failed')
    profile = fixture(case, count)
    require(fixture(seed, count) == profile, 'Seed and measured histories differ')
    expected_loaded = min(count, 400) if variant == 'patched' else count
    limit = 400 if variant == 'patched' else count
    expected_bytes = profile['encoded_page_bytes']['400'] if variant == 'patched' else profile['encoded_messages_bytes']
    proof = read_json(seed / 'cache-seed-proof.json')
    require(proof.get('schema') == 1 and proof.get('synthetic') is True and proof.get('setup_only') is True
            and proof.get('session_id') == 'ses_extreme' and proof.get('messages') == count
            and proof.get('readback_messages') == count and proof.get('readback_used_second_repository') is True,
            'Seed did not retain and read back the full archive through a second production repository')
    require(proof.get('directory_sessions') == 1 and proof.get('readback_directory_sessions') == 1
            and proof.get('readback_directory_session_ids') == ['ses_extreme'], 'Seed session metadata readback is incomplete')
    require(proof.get('todos_via_production_api') is True and proof.get('readback_todos_known') is True
            and proof.get('readback_todos_stale') is True and integer(proof.get('todos'))
            and proof.get('readback_todos') == proof['todos'], 'Seed todo readback is incomplete')
    require(proof.get('encoded_response_bytes') == profile['encoded_messages_bytes'], 'Seed full body size mismatch')
    if variant == 'patched':
        require(proof.get('readback_preview_messages') == expected_loaded
                and proof.get('readback_preview_retained_messages') == count,
                'Bounded preview readback lost its recent count or retained archive count')

    attachments = [json.loads(path.read_text()) for path in (case / 'attachments').rglob('*.json')]
    evidence = [value for value in attachments if isinstance(value, dict) and value.get('experiment') == 'window_session_load'
                and value.get('checkpoint') == 'complete' and value.get('complete') is True]
    require(len(evidence) == 1, 'Expected one completed window UI checkpoint')
    ui = evidence[0]
    require(ui.get('schema') == 1 and ui.get('case') == 'seeded-revisit' and ui.get('trial') == 'trial1'
            and ui.get('grouping') is False, 'Completed UI checkpoint has wrong identity')
    require(ui.get('input_validation_policy') == 'loading-only' and ui.get('input_validation_performed') is False,
            'UI workload disagrees with loading-only provenance')
    require(ui.get('profile') == profile, 'UI latest-content profile differs from the actual fixture')
    probe_sets = []
    for path in sorted((case / 'probes').glob('*.jsonl')):
        rows = read_jsonl(path)
        meta = rows[0]
        if meta.get('phase') == 'metadata' and meta.get('schema') == 1 and meta.get('case') == 'seeded-revisit' \
                and meta.get('trial') == 'trial1' and meta.get('grouping_requested') is False:
            probe_sets.append(rows)
    require(len(probe_sets) == 1, 'Expected one matching native phase probe')
    rows = probe_sets[0]
    for row in rows:
        midpoint(row)
        require(integer(row.get('operation')), 'Native phase lacks a valid operation')
        if row.get('phase') != 'metadata':
            require(row.get('grouping_actual') is False, 'Native grouping changed during the workload')
    require(not any('typed_token' in row.get('phase', '') for row in rows), 'Loading-only native run contains keyboard validation')
    appearance = [r for r in rows if r.get('phase') == 'appearance_configured']
    require(appearance and all(r.get('tools_actual') is True and r.get('reasoning_actual') is True for r in appearance),
            'Actual tool/reasoning appearance was not verified')
    first_selection = one([r for r in rows if r.get('operation') == 1], 'selection_started')
    startup = one([r for r in rows if r.get('operation') == 0], 'startup_cache_published')
    require(startup.get('operation_kind') == 'startup' and startup.get('loaded_messages') == expected_loaded
            and startup['uptime_after_s'] <= first_selection['uptime_before_s'],
            'Expected startup cache was not published before first selection')
    require(any(r.get('phase') == 'legacy_stream_open' and r.get('operation') == 0 and r.get('operation_kind') == 'startup'
                and r['uptime_after_s'] <= first_selection['uptime_before_s'] for r in rows),
            'Healthy legacy stream was not open before first selection')
    require(not any(r.get('phase') == 'legacy_stream_open' and r.get('operation', 0) > 0 for r in rows),
            'Legacy stream reopened during the uninterrupted-stream experiment')
    if variant == 'patched':
        require(not any(r.get('operation', 0) > 0 and r.get('phase') in ('disk_cache_load_started', 'disk_cache_json_decoded')
                        for r in rows), 'Patched warm path read the full disk archive')
    midpoint(ui.get('clock', {}))
    native_offset = rows[0]['epoch_s'] - midpoint(rows[0])
    ui_offset = ui['clock']['epoch_s'] - midpoint(ui['clock'])
    require(abs(native_offset - ui_offset) <= .1, 'App and UI clocks differ by more than 100ms')
    launch, home = ui.get('launch_start_uptime_s'), ui.get('home_observed_uptime_s')
    navigation = ui.get('project_navigation', {})
    project_tap, session_row = (navigation.get(k) for k in ('project_tap_uptime_s', 'session_row_observed_uptime_s'))
    require(all(number(t) for t in (launch, home, project_tap, session_row))
            and launch <= home <= project_tap <= session_row, 'Missing real project-to-session route timing')

    log = read_jsonl(case / 'requests.jsonl')
    require(all(integer(r.get('request_id')) and r['request_id'] > 0 and integer(r.get('response_bytes'))
                and type(r.get('status')) is int and isinstance(r.get('path'), str)
                and isinstance(r.get('query'), dict) for r in log), 'Invalid completed HTTP request log')
    by_id = {r['request_id']: r for r in log}
    require(len(by_id) == len(log), 'Duplicate completed HTTP request IDs')
    actions = ui.get('actions', [])
    require(isinstance(actions, list) and [a.get('stage') for a in actions] == STAGES, 'Completed UI checkpoint lacks all three actions')
    used_ids, measured, previous_after, previous_ui_end = set(), [], 0, session_row
    for operation, action in enumerate(actions, 1):
        stage = action['stage']
        cached = variant == 'patched' and operation == 2
        require(action.get('operation') == operation and action.get('minimum_expected_loaded') == expected_loaded,
                f'{stage}: wrong operation or loaded count')
        require(action.get('ready_kind') == ('cached' if cached else 'http'), f'{stage}: wrong ready kind')
        require(not any('typed_token' in key for key in action), f'{stage}: loading-only action claims keyboard validation')
        native = [r for r in rows if r.get('operation') == operation]
        require(all(r.get('operation_kind') == ('bottom_refresh' if operation == 3 else 'selection') for r in native),
                f'{stage}: native operation kind disagrees')
        start = one(native, 'bottom_refresh_started' if operation == 3 else 'selection_started')
        end_phase = 'bottom_refresh_method_completed' if operation == 3 else 'transcript_reveal_completed'
        ends = [r for r in native if r.get('phase') == end_phase]
        require(ends and (operation != 3 or len(ends) == 1), f'{stage}: missing or duplicate native completion')
        end = min(ends, key=midpoint)
        status = action.get('native_probe_status', {})
        expected_status = {'refresh' if operation == 3 else 'reveal': end}
        if cached:
            require(not any(r.get('phase') in ('canonical_request_started', 'canonical_typed_page_returned', 'canonical_published')
                            for r in native), 'Cached revisit unexpectedly performed canonical loading')
            ready = one(native, 'cached_transcript_reused')
            expected_status['cache_reuse'] = ready
        else:
            requested = one(native, 'canonical_request_started')
            returned = one(native, 'canonical_typed_page_returned')
            ready = one(native, 'canonical_published')
            require(requested.get('request_limit') == limit and returned.get('page_messages') == expected_loaded,
                    f'{stage}: wrong native canonical request/page size')
            require(midpoint(start) <= midpoint(requested) <= midpoint(returned) <= midpoint(ready),
                    f'{stage}: native canonical phases run backwards')
            expected_status['canonical'] = ready
        require(ready.get('loaded_messages') == expected_loaded, f'{stage}: wrong native ready count')
        require(set(status) == set(expected_status), f'{stage}: wrong UI native phase proof keys')
        for key, row in expected_status.items():
            embedded = status[key]
            candidates = [r for r in native if r.get('phase') == row['phase']]
            require(isinstance(embedded, dict) and any(all(embedded.get(k) == v for k, v in candidate.items())
                                                       for candidate in candidates),
                    f'{stage}: UI {key} does not match the native JSONL event')
        native_start, native_end, native_ready = midpoint(start), midpoint(end), midpoint(ready)
        seconds = delta(native_end, native_start, f'{stage} native completion')
        ready_seconds = delta(native_ready, native_start, f'{stage} native ready')
        ui_start = action.get('start_uptime_s')
        ui_visible = None if operation == 3 else action.get('content_observed_uptime_s')
        ui_ready = action.get('canonical_and_method_observed_uptime_s' if operation == 3 else 'canonical_observed_uptime_s')
        require(number(ui_start) and ui_start >= previous_ui_end, f'{stage}: UI actions overlap or run backwards')
        ui_ready_seconds = delta(ui_ready, ui_start, f'{stage} UI ready')
        ui_visible_seconds = None if operation == 3 else delta(ui_visible, ui_start, f'{stage} UI visibility')
        require(operation == 3 or ui_ready >= ui_visible, f'{stage}: UI ready predates content observation')
        require(native_start >= ui_start - .1 and native_ready <= ui_ready + .1
                and native_end <= (ui_ready if operation == 3 else ui_visible) + .1,
                f'{stage}: native phase timestamps fall outside the UI observation')
        previous_ui_end = ui_ready
        before, after = action.get('request_id_before_action'), action.get('request_id_after_action')
        require(integer(before) and integer(after) and previous_after <= before <= after,
                f'{stage}: overlapping or invalid HTTP action windows')
        previous_after = after
        window = [r for r in log if before < r['request_id'] <= after]
        canonical = [r for r in window if r.get('method') == 'GET' and r['path'] == MESSAGE_PATH]
        expected_requests = 0 if cached else 1
        require(len(canonical) == expected_requests, f'{stage}: expected {expected_requests} canonical GETs, found {len(canonical)}')
        proofs = action.get('requests')
        require(isinstance(proofs, list) and len(proofs) == expected_requests, f'{stage}: wrong canonical HTTP proof count')
        ids = {r['request_id'] for r in canonical}
        require(not ids & used_ids, f'{stage}: reused canonical request evidence')
        used_ids |= ids
        require({r.get('request_id') for r in proofs} == ids, f'{stage}: UI and raw HTTP request IDs disagree')
        for request in canonical:
            require(request['status'] == 200 and request['query'].get('limit') == [str(limit)]
                    and 'before' not in request['query'] and request['response_bytes'] == expected_bytes,
                    f'{stage}: wrong limit/cursor/status/exact canonical body size')
            require(integer(request.get('started_ns')) and integer(request.get('ended_ns'))
                    and request['ended_ns'] >= request['started_ns'], f'{stage}: missing raw HTTP request timing')
        for request in proofs:
            actual = by_id[request['request_id']]
            require(all(request.get(k) == actual.get(k) for k in
                        ('request_id', 'method', 'path', 'query', 'status', 'response_bytes', 'started_ns', 'ended_ns')),
                    f'{stage}: UI HTTP proof differs from raw completed request')
        details = [r for r in window if r.get('method') == 'GET' and r['path'].startswith(MESSAGE_PATH + '/')]
        measured.append({'stage': stage, 'operation': operation, 'ready_kind': 'cached' if cached else 'http',
            'loaded_messages': expected_loaded, 'native_metric': end_phase, 'native_seconds': seconds,
            'native_ready_seconds': ready_seconds, 'ui_visible_seconds': ui_visible_seconds, 'ui_ready_seconds': ui_ready_seconds,
            'native_start_uptime_s': native_start, 'native_completion_uptime_s': native_end, 'native_ready_uptime_s': native_ready,
            'ui_start_uptime_s': ui_start, 'ui_visible_uptime_s': ui_visible, 'ui_ready_uptime_s': ui_ready,
            'request_id_before_action': before, 'request_id_after_action': after,
            'canonical_get_count': len(canonical), 'canonical_response_bytes': sum(r['response_bytes'] for r in canonical),
            'canonical_request_ids': sorted(ids), 'canonical_requests': canonical, 'native_ready_phase': ready['phase'],
            'message_detail_get_count': len(details),
            'message_detail_response_bytes': sum(r['response_bytes'] for r in details),
            'app_response_body_bytes': sum(r['response_bytes'] for r in window if app_get(r)),
            'disk_cache_decode_count': sum(r.get('phase') == 'disk_cache_json_decoded' for r in native)})
    # Smaller preview prefetches are counted below; a hidden full/window reload is a failed experiment.
    canonical = [r for r in log if r.get('method') == 'GET' and r['path'] == MESSAGE_PATH]
    main = [r for r in canonical if r['query'].get('limit') == [str(limit)]]
    require({r['request_id'] for r in main} == used_ids, 'Extra canonical target-size GET outside measured action windows')
    if variant == 'patched':
        require(all(r['request_id'] in used_ids or (r.get('query', {}).get('limit') and
                    str(r['query']['limit'][0]).isdigit() and 0 < int(r['query']['limit'][0]) < 400)
                    for r in canonical), 'Patched run performed a hidden full-history or oversized message GET')
    app = [r for r in log if app_get(r)]
    details = [r for r in app if r['path'].startswith(MESSAGE_PATH + '/')]
    return {'schema': 1, 'complete': True, 'variant': variant, 'message_count': count, 'scope': SCOPE,
        'source': source, 'actions': measured,
        'startup': {'cache_messages': expected_loaded,
            'native_cache_publication_seconds': delta(midpoint(startup), midpoint(rows[0]), 'startup cache publication'),
            'native_metadata_to_first_reveal_seconds': delta(measured[0]['native_completion_uptime_s'], midpoint(rows[0]), 'startup to reveal'),
            'ui_launch_to_first_visible_seconds': delta(measured[0]['ui_visible_uptime_s'], launch, 'launch to visible'),
            'ui_launch_uptime_s': launch, 'native_metadata_uptime_s': midpoint(rows[0]),
            'native_cache_publication_uptime_s': midpoint(startup), 'clock_offset_difference_seconds': abs(native_offset - ui_offset)},
        'totals': {'app_get_count': len(app), 'app_response_body_bytes': sum(r['response_bytes'] for r in app),
            'canonical_get_count': len(canonical), 'canonical_response_bytes': sum(r['response_bytes'] for r in canonical),
            'measured_canonical_get_count': len(used_ids), 'message_detail_get_count': len(details),
            'message_detail_response_bytes': sum(r['response_bytes'] for r in details)}}


def app_get(row):
    return row.get('method') == 'GET' and (not row['path'].startswith('/_lab/') or row['path'] == '/_lab/reference')


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if len(args) != 1:
        print('Usage: validate-window-results.py <results directory>', file=sys.stderr)
        return 2
    root = Path(args[0])
    try:
        measurements = validate(root)
        errors = []
    except (OSError, ValueError, KeyError, TypeError, AttributeError, IndexError) as error:
        errors = [str(error)]
        measurements = {'schema': 1, 'complete': False, 'scope': SCOPE, 'actions': [], 'errors': errors}
    validation = {'schema': 1, 'complete': not errors, 'errors': errors, 'scope': SCOPE}
    for name, value in (('validation.json', validation), ('measurements.json', measurements)):
        (root / name).write_text(json.dumps(value, indent=2, allow_nan=False) + '\n')
    if errors:
        print('\n'.join(errors), file=sys.stderr)
    return int(bool(errors))


if __name__ == '__main__':
    raise SystemExit(main())
