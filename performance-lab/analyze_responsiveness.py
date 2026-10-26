#!/usr/bin/env python3
"""Join CI-only app probes to native UI/fixture scopes (Python stdlib only).

Callback gaps describe main-runloop availability, not presented FPS. Heartbeat
delays describe sampled main-queue scheduling, not keyboard delivery latency.
"""
import argparse
import json
import math
from pathlib import Path
import re
import statistics
import sys


class EvidenceError(ValueError):
    pass


def number(value, name):
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        raise EvidenceError(f'{name} must be a finite number')
    return float(value)


def bounds(row):
    start = number(row.get('start_uptime_s'), 'start_uptime_s')
    end = number(row.get('end_uptime_s'), 'end_uptime_s')
    if end <= start:
        raise EvidenceError('interval must have positive duration')
    return start, end


def clock_offset(clock):
    if not isinstance(clock, dict):
        raise EvidenceError('clock sample must be an object')
    before = number(clock.get('uptime_before_s'), 'uptime_before_s')
    after = number(clock.get('uptime_after_s'), 'uptime_after_s')
    if not 0 <= after - before <= .1:
        raise EvidenceError('clock sample bracket is invalid or wider than 100 ms')
    return number(clock.get('epoch_s'), 'epoch_s') - (before + after) / 2


def percentile(values, quantile):
    if not values:
        return None
    ordered = sorted(values)
    index = (len(ordered) - 1) * quantile
    low = math.floor(index)
    high = math.ceil(index)
    return ordered[low] + (ordered[high] - ordered[low]) * (index - low)


def read_probe(path):
    raw = path.read_bytes()
    if not raw or not raw.endswith(b'\n'):
        raise EvidenceError(f'{path}: empty or truncated JSONL')
    try:
        rows = [json.loads(line) for line in raw.splitlines()]
    except (ValueError, UnicodeError) as error:
        raise EvidenceError(f'{path}: malformed JSONL: {error}') from error
    if any(not isinstance(row, dict) for row in rows):
        raise EvidenceError(f'{path}: every probe row must be an object')
    if not rows or rows[0].get('kind') != 'metadata' or rows[0].get('schema') != 1:
        raise EvidenceError(f'{path}: missing schema-1 metadata header')
    for row in rows[1:]:
        kind = row.get('kind')
        if kind in ('callback', 'heartbeat'):
            start = number(row.get('start_uptime_s'), 'sample start')
            end = number(row.get('end_uptime_s'), 'sample end')
            if end < start or (kind == 'callback' and end == start):
                raise EvidenceError(f'{path}: invalid {kind} interval')
            field = 'gap_ms' if kind == 'callback' else 'delay_ms'
            if abs(number(row.get(field), field) - (end - start) * 1000) > .01:
                raise EvidenceError(f'{path}: {field} disagrees with interval endpoints')
        elif kind in ('active', 'inactive'):
            number(row.get('uptime_s'), 'lifecycle uptime')
        else:
            raise EvidenceError(f'{path}: unsupported probe record {kind!r}')
    callbacks = [row for row in rows[1:] if row.get('kind') == 'callback']
    inactive = [row['uptime_s'] for row in rows[1:] if row.get('kind') == 'inactive']
    for previous, current in zip(callbacks, callbacks[1:]):
        left, right = previous['end_uptime_s'], current['start_uptime_s']
        if right < left - .001 or (right > left + .001 and not any(left <= at <= right for at in inactive)):
            raise EvidenceError(f'{path}: missing or out-of-order callback records')
    return rows[0], rows[1:]


def sample_metrics(rows, start, end, kind):
    selected = []
    boundary = []
    overlapping = []
    overlap_seconds = 0
    excess_seconds = 0
    for row in rows:
        if row.get('kind') != kind:
            continue
        left, right = row['start_uptime_s'], row['end_uptime_s']
        if left < end and right > start:
            overlapping.append(row)
            overlap_seconds += max(0, min(right, end) - max(left, start))
            # Explicit accounting convention: a gap's first 25 ms is its free
            # callback budget. Clip only its remaining time to this phase.
            excess_seconds += max(0, min(right, end) - max(left + .025, start))
        if left >= start and right <= end:
            selected.append(row)
        elif left < end and right > start:
            boundary.append({'start_uptime_s': left, 'end_uptime_s': right,
                             'full_interval_ms': (right - left) * 1000,
                             'clipped_overlap_ms': max(0, min(right, end) - max(left, start)) * 1000})
    if not overlapping:
        raise EvidenceError(f'no overlapping {kind} samples in [{start}, {end}]')
    field = 'gap_ms' if kind == 'callback' else 'delay_ms'
    values = [row[field] for row in selected]
    all_values = [row[field] for row in overlapping]
    duration = end - start
    result = {'samples': len(values), 'p50_ms': percentile(values, .5),
              'p95_ms': percentile(values, .95), 'max_ms': max(values) if values else None,
              'boundary_intervals_excluded_from_contained_metrics': boundary,
              'boundary_interval_count': len(boundary),
              'boundary_max_full_interval_ms': max((row['full_interval_ms'] for row in boundary), default=None),
              'boundary_clipped_overlap_ms': sum(row['clipped_overlap_ms'] for row in boundary),
              'overlap_interval_count': len(all_values),
              'overlap_full_interval_p50_ms': percentile(all_values, .5),
              'overlap_full_interval_p95_ms': percentile(all_values, .95),
              'overlap_full_interval_max_ms': max(all_values),
              'overlap_interval_time_ms': overlap_seconds * 1000}
    for threshold in ((50, 100, 250) if kind == 'callback' else (100,)):
        count = sum(value > threshold for value in values)
        result[f'over_{threshold}ms_count'] = count
        result[f'over_{threshold}ms_per_second'] = count / duration
        overlap_count = sum(value > threshold for value in all_values)
        result[f'overlap_full_interval_over_{threshold}ms_count'] = overlap_count
        result[f'overlap_full_interval_over_{threshold}ms_per_second'] = overlap_count / duration
        result[f'boundary_full_interval_over_{threshold}ms_count'] = sum(
            row['full_interval_ms'] > threshold for row in boundary)
    if kind == 'callback':
        result['excess_over_25ms_ms_per_second'] = sum(max(0, value - 25) for value in values) / duration
        result['contained_interval_coverage_seconds'] = sum(values) / 1000
        result['overlap_excess_after_25ms_ms_per_second'] = excess_seconds * 1000 / duration
        result['overlap_coverage_fraction'] = overlap_seconds / duration
        if not .999 <= result['overlap_coverage_fraction'] <= 1.001:
            raise EvidenceError(f'callback phase coverage is {result["overlap_coverage_fraction"]:.6f}, expected 1')
    return result


def summarize_phase(rows, name, start, end, source):
    callbacks = [row for row in rows if row.get('kind') == 'callback']
    if not callbacks or min(row['start_uptime_s'] for row in callbacks) > start \
            or max(row['end_uptime_s'] for row in callbacks) < end:
        raise EvidenceError(f'{name}: probe does not cover the whole phase (missing/truncated data)')
    lifecycle = sorted((row['uptime_s'], row['kind']) for row in rows if row.get('kind') in ('active', 'inactive'))
    active = True
    for at, kind in lifecycle:
        if at >= end:
            break
        if kind == 'inactive' and at >= start:
            raise EvidenceError(f'{name}: app became inactive inside the phase')
        active = kind == 'active'
        if at <= start and not active:
            # A later active marker before start may restore the state.
            continue
        if at > start and not active:
            raise EvidenceError(f'{name}: inactive app samples')
    active_before = [kind for at, kind in lifecycle if at <= start]
    if active_before and active_before[-1] != 'active':
        raise EvidenceError(f'{name}: phase begins while app is inactive')
    return {'name': name, 'source': source, 'start_uptime_s': start, 'end_uptime_s': end,
            'duration_seconds': end - start,
            'callback': sample_metrics(rows, start, end, 'callback'),
            'heartbeat': sample_metrics(rows, start, end, 'heartbeat')}


def analyze_case(folder, allow_partial=False):
    match = re.fullmatch(r'(.+?)-(.+?)-g([01])', folder.name)
    if not match:
        raise EvidenceError(f'{folder}: expected trial-variant-g0 or trial-variant-g1 directory')
    trial, variant, grouping = match.group(1), match.group(2), match.group(3) == '1'
    evidence = []
    for path in (folder / 'attachments').rglob('*.json'):
        try:
            data = json.loads(path.read_text())
        except (ValueError, UnicodeError):
            continue  # Other XCTest attachments need not be JSON evidence.
        if isinstance(data, dict) and data.get('schema') == 1 and 'phases' in data and 'clock' in data:
            evidence.append((path, data))
    if not evidence:
        raise EvidenceError(f'{folder}: no responsiveness attachment')
    # The UI attaches text immediately, then the accumulated text+reasoning
    # result. Keep the furthest completed checkpoint, never merge clocks.
    largest = max(len(item[1].get('streams', [])) for item in evidence)
    selected = [item for item in evidence if len(item[1].get('streams', [])) == largest]
    if len(selected) != 1:
        raise EvidenceError(f'{folder}: ambiguous final responsiveness checkpoints')
    evidence_path, data = selected[0]
    if str(data.get('variant')) != variant or str(data.get('trial')) != trial or data.get('grouping') is not grouping:
        raise EvidenceError(f'{folder}: attachment labels disagree with directory')
    loaded = data.get('minimum_loaded_messages', data.get('minimum_loaded'))
    if number(loaded, 'minimum_loaded_messages') < 2000:
        raise EvidenceError(f'{folder}: fewer than 2000 canonically loaded messages')
    offset = clock_offset(data['clock'])
    phases = []
    names = set()
    for phase in data['phases']:
        if not isinstance(phase, dict):
            raise EvidenceError(f'{folder}: phase must be an object')
        name = phase.get('name')
        if not isinstance(name, str) or name in names:
            raise EvidenceError(f'{folder}: duplicate or invalid phase name')
        names.add(name)
        phases.append((name, *bounds(phase), 'native_ui_phase'))
    completed_parts = {item.get('part_type') for item in data.get('streams', []) if isinstance(item, dict)}
    expected_parts = completed_parts if allow_partial else {'text', 'reasoning'}
    if not expected_parts or not expected_parts.issubset({'text', 'reasoning'}):
        raise EvidenceError(f'{folder}: no recognized completed stream checkpoint')
    required = {f'{part}_{suffix}' for part in expected_parts
                for suffix in ('steady', 'typing', 'scrolling', 'after_completion')}
    if not required.issubset(names):
        raise EvidenceError(f'{folder}: missing native phases: {sorted(required - names)}')
    stream_bounds = {}
    for stream in data.get('streams', []):
        if not isinstance(stream, dict) or not isinstance(stream.get('completed_run'), dict) \
                or not isinstance(stream.get('accepted'), dict):
            raise EvidenceError(f'{folder}: stream identity/timing metadata must be objects')
        part = stream.get('part_type')
        run = stream.get('completed_run', {})
        if part not in ('text', 'reasoning') or part in stream_bounds or run.get('done') is not True:
            raise EvidenceError(f'{folder}: invalid or duplicate completed stream')
        if run.get('message_id') != stream.get('accepted', {}).get('messageID'):
            raise EvidenceError(f'{folder}: completed stream identity mismatch')
        start = number(run.get('started_epoch_s'), 'stream start epoch') - offset
        end = number(run.get('ended_epoch_s'), 'stream end epoch') - offset
        if end <= start:
            raise EvidenceError(f'{folder}: completed stream has invalid time bounds')
        stream_bounds[part] = (start, end)
        phases.extend([(f'{part}_whole_stream', start, end, 'fixture_stream_bounds'),
                       (f'{part}_terminal_8s', end, end + 8, 'fixture_completion_bounds')])
    if set(stream_bounds) != expected_parts:
        raise EvidenceError(f'{folder}: missing actual text/reasoning stream bounds')
    for name, start, end, _ in phases:
        part = name.split('_')[0]
        if name.endswith(('_steady', '_typing', '_scrolling')):
            left, right = stream_bounds[part]
            if start < left - .1 or end > right + .1:
                raise EvidenceError(f'{folder}: {name} did not occur wholly during the actual stream')
    probe_candidates = []
    failures = []
    for path in (folder / 'probes').rglob('*.jsonl'):
        try:
            meta, rows = read_probe(path)
            if str(meta.get('variant')) != variant or str(meta.get('trial')) != trial:
                continue
            expected_path = 'legacy_normalized' if variant == 'baseline' else 'reduced_direct'
            if meta.get('publication_path') != expected_path:
                raise EvidenceError(f'{path}: publication path does not match runtime variant')
            delta = clock_offset(meta) - offset
            if abs(delta) > .1:
                raise EvidenceError(f'{path}: app/UI clock offsets disagree by {delta:.6f}s')
            summaries = [summarize_phase(rows, *phase) for phase in phases]
            probe_candidates.append((path, meta, delta, summaries))
        except EvidenceError as error:
            failures.append(str(error))
    if len(probe_candidates) != 1:
        detail = '; '.join(failures) or 'no matching complete app probe'
        raise EvidenceError(f'{folder}: expected one matching complete probe, found {len(probe_candidates)}; {detail}')
    path, meta, delta, summaries = probe_candidates[0]
    return {'trial': trial, 'variant': variant, 'grouping': grouping, 'minimum_loaded_messages': loaded,
            'partial': set(stream_bounds) != {'text', 'reasoning'}, 'completed_stream_types': sorted(stream_bounds),
            'attachment_path': str(evidence_path), 'probe_path': str(path),
            'app_ui_clock_offset_difference_seconds': delta, 'probe_metadata': meta, 'phases': summaries}


SUMMARY_METRICS = [('callback', 'overlap_full_interval_p50_ms'),
                   ('callback', 'overlap_full_interval_p95_ms'), ('callback', 'overlap_full_interval_max_ms'),
                   ('callback', 'overlap_full_interval_over_50ms_per_second'),
                   ('callback', 'overlap_full_interval_over_100ms_per_second'),
                   ('callback', 'overlap_full_interval_over_250ms_per_second'),
                   ('callback', 'overlap_excess_after_25ms_ms_per_second'),
                   ('heartbeat', 'overlap_full_interval_p95_ms'), ('heartbeat', 'overlap_full_interval_max_ms'),
                   ('heartbeat', 'overlap_full_interval_over_100ms_per_second')]


def compact(phase):
    return {f'{kind}_{metric}': phase[kind][metric] for kind, metric in SUMMARY_METRICS}


def paired_summary(cases, expected_trials):
    output = []
    errors = []
    variants = sorted({case['variant'] for case in cases})
    if len(variants) != 2:
        errors.append(f'expected two variants, found {variants}')
    for grouped in (True, False):
        selected = [case for case in cases if case['grouping'] is grouped]
        trials = sorted({case['trial'] for case in selected})
        if len(trials) != expected_trials:
            errors.append(f'grouping={grouped}: expected {expected_trials} trials, found {len(trials)}')
        phase_names = sorted({phase['name'] for case in selected for phase in case['phases']})
        for name in phase_names:
            values = []
            for trial in trials:
                row = {'trial': trial, 'variants': {}}
                for case in selected:
                    if case['trial'] != trial:
                        continue
                    phase = next((phase for phase in case['phases'] if phase['name'] == name), None)
                    if phase is not None:
                        row['variants'][case['variant']] = compact(phase)
                row['paired'] = len(variants) == 2 and set(row['variants']) == set(variants)
                if not row['paired']:
                    errors.append(f'grouping={grouped} {trial} {name}: missing paired variant')
                elif len(variants) == 2:
                    first, second = variants
                    row['difference_second_minus_first'] = {
                        metric: row['variants'][second][metric] - row['variants'][first][metric]
                        for metric in row['variants'][first]}
                values.append(row)
            medians = {}
            for variant in variants:
                rows = [row['variants'][variant] for row in values if variant in row['variants']]
                medians[variant] = {metric: statistics.median(row[metric] for row in rows)
                                    for metric in rows[0]} if rows else {}
            paired = [row['difference_second_minus_first'] for row in values if row['paired']]
            output.append({'grouping': grouped, 'phase': name, 'variant_order': variants,
                           'trials': values, 'medians': medians,
                           'median_paired_difference_second_minus_first': {
                               metric: statistics.median(row[metric] for row in paired)
                               for metric in paired[0]} if paired else {}})
    return output, errors


def analyze(root, expected_trials=3):
    cases, partial_cases, errors = [], [], []
    folders = sorted(path for path in Path(root).iterdir()
                     if path.is_dir() and re.fullmatch(r'.+?-.+?-g[01]', path.name)
                     and not path.name.startswith('warmup-'))
    if not folders:
        errors.append('no trial-variant-g0/g1 run directories')
    for folder in folders:
        try:
            cases.append(analyze_case(folder))
        except (EvidenceError, OSError, KeyError, TypeError) as error:
            errors.append(f'{folder.name}: {error}')
            try:
                partial = analyze_case(folder, allow_partial=True)
                if partial['partial']:
                    partial_cases.append(partial)
            except (EvidenceError, OSError, KeyError, TypeError):
                pass
    summary, pairing_errors = paired_summary(cases + partial_cases, expected_trials)
    errors.extend(pairing_errors)
    return {'schema': 1, 'complete': not errors, 'expected_paired_trials_per_grouping': expected_trials,
            'scope': 'Simulator app callback gaps and sampled main-queue delay only. Not FPS, exact keyboard latency, physical-device performance, heat, or battery. No improvement percentages estimated.',
            'boundary_rule': 'Contained metrics exclude crossing intervals; overlap metrics include their original full durations and also list clipped overlap, so large boundary stalls remain visible. Primary paired summaries use overlap metrics. Callback excess clips the portion after each gap first 25ms to the phase. Callback overlap coverage must be 100%. Overlap event counts across adjacent phases are not additive. All rates use the entire phase duration.',
            'cases': cases, 'partial_cases': partial_cases, 'paired_summary': summary, 'errors': errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('result_root', type=Path)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--expected-trials', type=int, default=3)
    args = parser.parse_args()
    if args.expected_trials < 1:
        parser.error('--expected-trials must be positive')
    try:
        result = analyze(args.result_root, args.expected_trials)
    except OSError as error:
        result = {'schema': 1, 'complete': False, 'cases': [], 'errors': [str(error)]}
    content = json.dumps(result, indent=2, sort_keys=True) + '\n'
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(content)
        print(json.dumps({'complete': result['complete'], 'valid_cases': len(result['cases']),
                          'errors': result['errors'], 'output': str(args.output)}, indent=2))
    else:
        print(content, end='')
    return 0 if result['complete'] else 1


if __name__ == '__main__':
    sys.exit(main())
