"""Interleaved no-export/export typing and Debug/Release E9 recorded-load evidence."""
import json
import math
import os
from pathlib import Path
import random
import re
import statistics
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent.parent
PAIRS = int(os.environ.get('PLAINSONG_PAIRS', '10'))


def percentile(samples, fraction):
    ordered = sorted(samples)
    index = (len(ordered) - 1) * fraction
    lo, hi = math.floor(index), math.ceil(index)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (index - lo)


def summary(samples):
    return {'count': len(samples), 'median': statistics.median(samples), 'range': [min(samples), max(samples)], 'p95': percentile(samples, .95)}


def comparison(pairs):
    diffs = [p['export_typing_ms'] - p['plain_typing_ms'] for p in pairs]
    rng = random.Random(20261004)
    boot = [statistics.median(rng.choices(diffs, k=len(diffs))) for _ in range(10000)]
    ci = [percentile(boot, .025), percentile(boot, .975)]
    complete = len(pairs) >= PAIRS
    worse = sum(x > 0 for x in diffs)
    signal = complete and ci[0] > .5 and worse >= math.ceil(.8 * len(pairs))
    return {'pair_differences_ms': diffs, 'median_difference_ms': statistics.median(diffs), 'bootstrap_95_ci_ms': ci, 'bootstrap_resamples': 10000, 'seed': 20261004, 'candidate_worse_pairs': worse, 'plain': summary([p['plain_typing_ms'] for p in pairs]), 'export': summary([p['export_typing_ms'] for p in pairs]), 'fraction_over_16ms': {mode: sum(p[mode + '_typing_ms'] > 16 for p in pairs) / len(pairs) for mode in ('plain', 'export')}, 'verdict': ('regression signal' if signal else 'no regression signal detected under recorded load') if complete else 'still pending; insufficient pairs', 'limitations': 'One keystroke per batch, so per-batch median/p95/max coincide. Across-batch distribution and pair differences are reported. Absolute idle acceptance remains open; differences smaller than the CI width cannot be excluded.'}


def parse(directory, mode):
    raw = (directory / 'run.log').read_text()
    kind = 'without export' if mode == 'plain' else 'during active export'
    matches = re.findall(r'EXPORT E9 native input \+ public-view update ' + kind + r' ([0-9.eE+-]+) ms', raw)
    if len(matches) != 1:
        raise ValueError('Expected exactly one named typing sample: ' + str(directory))
    record = {'typing_ms': float(matches[0]), 'start': json.loads((directory / 'start.json').read_text()), 'end': json.loads((directory / 'end.json').read_text()), 'raw_log': str(directory / 'run.log'), 'xcresult': str(directory / 'Results.xcresult')}
    failures = [line for line in raw.splitlines() if ' error: ' in line and ('failed' in line or 'XCT' in line)]
    record['assertion_failure_lines'] = failures
    if record['end']['exit_code'] != 0 and not (record['end']['exit_code'] == 65 and failures and all('WS3B PERF typing ' in line and 'exceeded 16 ms budget' in line for line in failures)):
        raise ValueError('Non-budget test failure; no valid comparison: ' + str(directory))
    if mode == 'export':
        record['fixtures'] = {}
        for fixture in ('large-1mb.md', 'export-f-heavy.md'):
            rows = re.findall(r'EXPORT E9 ' + re.escape(fixture) + r' production milliseconds (\[[^\]\n]+\]); peak sampled host RSS MiB ([0-9.eE+-]+)', raw)
            if len(rows) != 1:
                raise ValueError('Missing fixture samples: ' + fixture)
            record['fixtures'][fixture] = {'wall_ms': json.loads(rows[0][0]), 'peak_sampled_host_rss_mib': float(rows[0][1])}
        writer = re.findall(r'EXPORT E9 64 MiB synchronous main-actor writer milliseconds (\[[^\]\n]+\])', raw)
        if len(writer) != 1:
            raise ValueError('Missing writer samples')
        record['writer_ms'] = json.loads(writer[0])
        if len(record['writer_ms']) != 3 or any(len(v['wall_ms']) != 3 for v in record['fixtures'].values()):
            raise ValueError('Incomplete fixture/writer samples')
    return record


def main():
    if PAIRS < 10:
        raise SystemExit('At least 10 pairs per configuration are required.')
    output = Path(os.environ.get('PLAINSONG_E9_EVIDENCE_ROOT', '/private/tmp/plainsong-e9-paired-' + time.strftime('%Y%m%d-%H%M%S')))
    output.mkdir(parents=True, exist_ok=False)
    env = dict(os.environ, PLAINSONG_E9_EVIDENCE_ROOT=str(output))
    evidence = {'status': 'running', 'label': 'observed under recorded load', 'method': 'Debug/Release interleaved; plain/export AB; 10 pairs per configuration; no documented warm-up discarded; fixed-seed 10000-resample bootstrap', 'requested_pairs_per_configuration': PAIRS, 'product_sha': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(), 'runs': [], 'pairs': {'Debug': [], 'Release': []}, 'absolute_idle_acceptance': 'pending owner run', 'owner_writer_decision_required': False}
    def save():
        evidence['admission_checks'] = [{'path': str(p), 'snapshot': json.loads(p.read_text())} for p in sorted(output.glob('*/start.json'))]
        analysis = {}
        for config in ('Debug', 'Release'):
            pairs = evidence['pairs'][config]
            runs = [r for r in evidence['runs'] if r['configuration'] == config and r['mode'] == 'export']
            if pairs:
                analysis[config] = {'typing': comparison(pairs)}
            else:
                analysis[config] = {'status': 'still pending', 'complete_pairs': 0}
            if runs:
                analysis[config]['fixtures'] = {f: {'wall_ms': summary([t for r in runs for t in r['fixtures'][f]['wall_ms']]), 'peak_sampled_host_rss_mib': summary([r['fixtures'][f]['peak_sampled_host_rss_mib'] for r in runs])} for f in ('large-1mb.md', 'export-f-heavy.md')}
                analysis[config]['writer_ms'] = summary([t for r in runs for t in r['writer_ms']])
                if analysis[config]['writer_ms']['range'][1] >= 100 or analysis[config].get('typing', {}).get('verdict') == 'regression signal':
                    evidence['owner_writer_decision_required'] = True
        evidence['analysis'] = analysis
        (output / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    def run(config, mode, iteration):
        flags = {'build': ['--build-only'], 'plain': ['--plain'], 'export': []}[mode]
        log = output / f'{config}-{mode}-{iteration}-runner.log'
        with log.open('w') as stream:
            code = subprocess.run([str(ROOT / 'Scripts/run-export-html-e9.sh'), *flags, config], cwd=ROOT, env=env, stdout=stream, stderr=subprocess.STDOUT).returncode
        print(f'{config} {mode} {iteration} exit={code} log={log}', flush=True)
        save()
        if code == 75:
            evidence['status'] = 'still pending; quiet-machine admission timeout'
            save()
            raise SystemExit(75)
        if mode == 'build':
            if code != 0:
                evidence['status'] = 'blocked by build failure; no verdict'
                save()
                raise SystemExit(code)
            return
        paths = re.findall(r'^Evidence: (.+)$', log.read_text(), re.MULTILINE)
        try:
            if not paths:
                raise ValueError('No measurement evidence directory')
            record = parse(Path(paths[-1]), mode)
        except ValueError as error:
            evidence['status'] = 'blocked by test failure; no verdict'
            evidence['error'] = str(error)
            save()
            raise SystemExit(2)
        record.update(configuration=config, mode=mode, iteration=iteration)
        evidence['runs'].append(record)
        save()
        return record
    print('EVIDENCE ' + str(output), flush=True)
    save()
    for config in ('Debug', 'Release'):
        run(config, 'build', 0)
    for iteration in range(1, PAIRS + 1):
        for config in ('Debug', 'Release'):
            a = run(config, 'plain', iteration)
            b = run(config, 'export', iteration)
            evidence['pairs'][config].append({'pair': iteration, 'plain_typing_ms': a['typing_ms'], 'export_typing_ms': b['typing_ms'], 'plain_log': a['raw_log'], 'export_log': b['raw_log']})
            save()
    evidence['status'] = 'complete; observed under recorded load'
    save()


if __name__ == '__main__':
    main()
