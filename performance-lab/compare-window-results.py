#!/usr/bin/env python3
"""Compare two counterbalanced same-host pairs without conflating full-sync scope."""
import json
import os
import statistics
import sys
from pathlib import Path


def compare(root):
    preflight = root / 'preflight-patched64'
    preflight_validation = json.loads((preflight / 'validation.json').read_text())
    preflight_metrics = json.loads((preflight / 'measurements.json').read_text())
    regressions = json.loads((preflight / 'native-regressions/summary.json').read_text())
    if preflight_validation.get('complete') is not True or preflight_metrics.get('complete') is not True \
            or preflight_metrics.get('variant') != 'patched' or preflight_metrics.get('message_count') != 64:
        raise ValueError('Patched 64-message preflight evidence is incomplete')
    if regressions.get('result') != 'Passed' or regressions.get('totalTestCount', 0) <= 0 \
            or regressions.get('passedTests') != regressions.get('totalTestCount') \
            or regressions.get('failedTests') != 0 or regressions.get('skippedTests') != 0:
        raise ValueError('Patched native preflight regressions did not all pass')
    observations = {}
    for label, variant in [('01-baseline', 'baseline'), ('02-patched', 'patched'),
                           ('03-patched', 'patched'), ('04-baseline', 'baseline')]:
        folder = root / label
        validation = json.loads((folder / 'validation.json').read_text())
        measurements = json.loads((folder / 'measurements.json').read_text())
        provenance = json.loads((folder / 'provenance.json').read_text())
        if validation.get('complete') is not True or measurements.get('complete') is not True:
            raise ValueError(label + ': incomplete benchmark evidence')
        if measurements['variant'] != variant or provenance['variant'] != variant:
            raise ValueError(label + ': variant mismatch')
        if measurements['message_count'] != 20000:
            raise ValueError(label + ': expected extreme 20k observation')
        observations[label] = measurements
    if preflight_metrics['source']['test_checkout_sha'] != observations['02-patched']['source']['test_checkout_sha']:
        raise ValueError('Preflight source differs from measured patched source')
    pairs = []
    for baseline, patched in [('01-baseline', '02-patched'), ('04-baseline', '03-patched')]:
        old, new = observations[baseline], observations[patched]
        action_pairs = []
        for a, b in zip(old['actions'], new['actions'], strict=True):
            if a['stage'] != b['stage']:
                raise ValueError('Action mismatch between paired observations')
            timings = {}
            for metric in ['native_ready_seconds', 'ui_visible_seconds', 'ui_ready_seconds']:
                if a.get(metric) is None or b.get(metric) is None:
                    continue
                before, after = a[metric], b[metric]
                timings[metric] = {'baseline': before, 'patched': after,
                                  'saved_seconds': before - after,
                                  'speedup': before / after if after > 0 else None}
            action_pairs.append({'stage': a['stage'], 'timings': timings,
                                 'baseline_message_gets': a['canonical_get_count'],
                                 'patched_message_gets': b['canonical_get_count'],
                                 'baseline_response_bytes': a['canonical_response_bytes'],
                                 'patched_response_bytes': b['canonical_response_bytes']})
        startup = {}
        for metric in ['native_metadata_to_first_reveal_seconds', 'ui_launch_to_first_visible_seconds']:
            before, after = old['startup'][metric], new['startup'][metric]
            startup[metric] = {'baseline': before, 'patched': after, 'saved_seconds': before - after,
                               'speedup': before / after if after > 0 else None}
        pairs.append({'baseline': baseline, 'patched': patched, 'actions': action_pairs, 'startup': startup})
    medians = []
    for index in range(3):
        metrics = {}
        keys = pairs[0]['actions'][index]['timings'].keys()
        for key in keys:
            samples = [pair['actions'][index]['timings'][key] for pair in pairs]
            metrics[key] = {'paired_saved_seconds_median': statistics.median(v['saved_seconds'] for v in samples),
                            'paired_speedup_median': statistics.median(v['speedup'] for v in samples if v['speedup'] is not None)}
        medians.append({'stage': pairs[0]['actions'][index]['stage'], 'metrics': metrics})
    return {'schema': 1, 'complete': True, 'design': 'same-host ABBA, two builds, fresh production cache seed per observation',
            'preflight': {'measurements': preflight_metrics, 'native_regression_summary': regressions},
            'observations': observations, 'pairs': pairs, 'paired_medians': medians,
            'scope': 'Recent latest-answer visibility and HTTP/cache readiness. Baseline completes a full 20k inventory; patched loads a 400-message window. These are not equal full-sync completion times.',
            'limitations': ['Two paired observations are descriptive, not a confidence interval.',
                            'Healthy uninterrupted SSE; continuity-loss full inventory fallback is tested separately.',
                            'Simulator Debug build, synthetic tool-heavy payload, no keyboard or physical iPhone FPS measurement.',
                            'UI durations include XCTest/Accessibility overhead; native callback timings are separate.']}


if __name__ == '__main__':
    root = Path(sys.argv[1])
    try:
        result = compare(root)
    except (OSError, ValueError, KeyError, TypeError) as error:
        result = {'schema': 1, 'complete': False, 'error': str(error)}
    (root / 'paired-comparison.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))
    summary = os.environ.get('GITHUB_STEP_SUMMARY')
    if summary:
        with open(summary, 'a') as handle:
            handle.write('### Legacy window-loading benchmark\n\n')
            handle.write('Same-host ABBA. Comparable recent-content readiness; full-sync work differs.\n\n')
            if result['complete']:
                handle.write('| Action | Native ready speedup (paired median) | UI ready speedup (paired median) |\n|---|---:|---:|\n')
                for row in result['paired_medians']:
                    native = row['metrics'].get('native_ready_seconds', {}).get('paired_speedup_median')
                    ui = row['metrics'].get('ui_ready_seconds', {}).get('paired_speedup_median')
                    handle.write(f"| {row['stage']} | {native:.2f}x | {ui:.2f}x |\n")
                handle.write('\nOnly two pairs; see raw observations and artifact scope before interpreting.\n')
            else:
                handle.write('Incomplete evidence: ' + result['error'] + '\n')
    raise SystemExit(0 if result['complete'] else 1)
