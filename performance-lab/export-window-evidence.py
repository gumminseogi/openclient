#!/usr/bin/env python3
"""Payload-free readable fallback when artifact upload is unavailable."""
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
root.mkdir(parents=True, exist_ok=True)


def load(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        return {'unavailable': str(error)}


def observation(folder):
    case = folder / 'seeded-revisit-trial1-g0'
    value = {name: load(folder / path) for name, path in {
        'provenance': 'provenance.json', 'measurements': 'measurements.json', 'validation': 'validation.json',
        'driver_status': 'driver-status.json', 'seed_proof': 'cache-seed/cache-seed-proof.json',
        'seed_validation': 'cache-seed/validation.json', 'regression_summary': 'native-regressions/summary.json',
        'ui_summary': 'seeded-revisit-trial1-g0/summary.json'}.items()}
    value.update(native_rows=[], app_requests=[], completed_ui_evidence=[])
    for path in sorted((case / 'probes').glob('*.jsonl')):
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
                if row.get('phase') != 'heartbeat':
                    value['native_rows'].append(row)
            except ValueError as error:
                value.setdefault('parse_errors', []).append(str(error))
    path = case / 'requests.jsonl'
    if path.exists():
        for line in path.read_text().splitlines():
            try:
                row = json.loads(line)
                if not row.get('path', '').startswith('/_lab/'):
                    value['app_requests'].append(row)
            except ValueError as error:
                value.setdefault('parse_errors', []).append(str(error))
    for path in (case / 'attachments').rglob('*.json'):
        row = load(path)
        if isinstance(row, dict) and row.get('experiment') == 'window_session_load' and row.get('checkpoint') == 'complete':
            value['completed_ui_evidence'].append(row)
    canary = folder / 'canary-64'
    if canary.exists():
        value['canary'] = observation(canary)
    return value


evidence = {'schema': 1, 'comparison': load(root / 'paired-comparison.json'),
            'preflight_patched64': observation(root / 'preflight-patched64'),
            'observations': {label: observation(root / label) for label in
                             ['01-baseline', '02-patched', '03-patched', '04-baseline']}}
encoded = json.dumps(evidence, indent=2, sort_keys=True)
(root / 'core-evidence.json').write_text(encoded + '\n')
print('WINDOW_BENCHMARK_EVIDENCE_JSON_BEGIN')
print(encoded)
print('WINDOW_BENCHMARK_EVIDENCE_JSON_END')
