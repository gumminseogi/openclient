"""Contract tests for joining app samples to UI/fixture clocks and intervals."""
import json
from pathlib import Path
import tempfile
import unittest

import analyze_responsiveness as analysis


class ResponsivenessAnalysisTests(unittest.TestCase):
    def make_case(self, root, variant='baseline', clock_shift=0):
        folder = Path(root) / f'pair1-{variant}-g1'
        (folder / 'attachments').mkdir(parents=True)
        (folder / 'probes').mkdir()
        phases = []
        streams = []
        for part, offset in [('text', 0), ('reasoning', 20)]:
            for suffix, start, end in [('steady', 3, 4), ('typing', 4, 5),
                                       ('scrolling', 5, 6), ('after_completion', 12, 20)]:
                phases.append({'name': f'{part}_{suffix}', 'start_uptime_s': start + offset,
                               'end_uptime_s': end + offset})
            streams.append({'part_type': part, 'accepted': {'messageID': part},
                            'completed_run': {'message_id': part, 'done': True,
                                              'started_epoch_s': 1002 + offset,
                                              'ended_epoch_s': 1012 + offset}})
        evidence = {'schema': 1, 'trial': 'pair1', 'variant': variant, 'grouping': True,
                    'minimum_loaded_messages': 2000, 'phases': phases, 'streams': streams,
                    'clock': {'uptime_before_s': 40, 'uptime_after_s': 40, 'epoch_s': 1040}}
        (folder / 'attachments' / 'evidence.json').write_text(json.dumps(evidence))
        rows = [{'kind': 'metadata', 'schema': 1, 'trial': 'pair1', 'variant': variant,
                 'uptime_before_s': 0, 'uptime_after_s': 0, 'epoch_s': 1000 + clock_shift}]
        for index in range(2200):
            start = index / 50
            rows.extend([{'kind': 'callback', 'start_uptime_s': start,
                          'end_uptime_s': start + .02, 'gap_ms': 20},
                         {'kind': 'heartbeat', 'start_uptime_s': start,
                          'end_uptime_s': start + .001, 'delay_ms': 1}])
        (folder / 'probes' / 'probe.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
        return folder

    def test_phase_join_uses_native_samples_and_actual_fixture_stream_bounds(self):
        with tempfile.TemporaryDirectory() as root:
            result = analysis.analyze_case(self.make_case(root))
        phases = {phase['name']: phase for phase in result['phases']}
        self.assertEqual(len(phases), 12)
        steady = phases['text_steady']
        self.assertEqual(steady['duration_seconds'], 1)
        self.assertAlmostEqual(steady['callback']['p95_ms'], 20)
        self.assertEqual(steady['callback']['over_50ms_count'], 0)
        self.assertAlmostEqual(steady['heartbeat']['p95_ms'], 1)
        self.assertEqual(phases['text_whole_stream']['start_uptime_s'], 2)
        self.assertEqual(phases['text_terminal_8s']['start_uptime_s'], 12)
        self.assertEqual(phases['reasoning_terminal_8s']['end_uptime_s'], 40)

    def test_clock_mismatch_rejects_case_and_partial_report_is_explicit(self):
        with tempfile.TemporaryDirectory() as root:
            self.make_case(root, clock_shift=.2)
            result = analysis.analyze(root, expected_trials=1)
        self.assertFalse(result['complete'])
        self.assertEqual(result['cases'], [])
        self.assertTrue(any('clock offsets disagree' in error for error in result['errors']))

    def test_boundary_gap_is_excluded_instead_of_fabricating_short_in_phase_gap(self):
        rows = [{'kind': 'callback', 'start_uptime_s': .8, 'end_uptime_s': 1.2, 'gap_ms': 400},
                {'kind': 'callback', 'start_uptime_s': 1.2, 'end_uptime_s': 1.3, 'gap_ms': 100},
                {'kind': 'callback', 'start_uptime_s': 1.3, 'end_uptime_s': 2.1, 'gap_ms': 800}]
        result = analysis.sample_metrics(rows, 1, 2, 'callback')
        self.assertEqual(result['samples'], 1)
        self.assertEqual(result['max_ms'], 100)
        self.assertEqual(result['over_250ms_count'], 0)
        self.assertAlmostEqual(result['boundary_intervals_excluded_from_contained_metrics'][0]['clipped_overlap_ms'], 200)
        self.assertEqual(result['excess_over_25ms_ms_per_second'], 75)
        self.assertEqual(result['boundary_interval_count'], 2)
        self.assertAlmostEqual(result['boundary_max_full_interval_ms'], 800)
        self.assertEqual(result['overlap_full_interval_max_ms'], 800)
        self.assertEqual(result['overlap_full_interval_over_250ms_count'], 2)
        self.assertAlmostEqual(result['overlap_excess_after_25ms_ms_per_second'], 950)
        self.assertAlmostEqual(result['overlap_coverage_fraction'], 1)

    def test_stall_covering_entire_phase_is_reported_without_contained_samples(self):
        rows = [{'kind': 'callback', 'start_uptime_s': .5, 'end_uptime_s': 2.5, 'gap_ms': 2000}]
        result = analysis.sample_metrics(rows, 1, 2, 'callback')
        self.assertEqual(result['samples'], 0)
        self.assertIsNone(result['p95_ms'])
        self.assertEqual(result['overlap_full_interval_max_ms'], 2000)
        self.assertEqual(result['overlap_excess_after_25ms_ms_per_second'], 1000)


if __name__ == '__main__':
    unittest.main()
