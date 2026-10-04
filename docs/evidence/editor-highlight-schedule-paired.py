"""Recorded-load paired typing probes. Absolute idle acceptance remains open."""
import hashlib
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

LOCK = os.environ.get('PLAINSONG_XCODEBUILD_LOCK', str(Path(os.environ.get('TMPDIR') or '/tmp') / 'plainsong-xcodebuild-test.lock'))
ROOT_VARS = {'main': 'PLAINSONG_BASELINE_ROOT', 'fix': 'PLAINSONG_FIX_ROOT', 'stack': 'PLAINSONG_STACK_ROOT'}
MODES = ('source-only', 'wysiwyg')
BUILD_NAMES = ('xcodebuild', 'swift-build', 'swift-frontend', 'clang', 'ld')
MAX_LOAD = float(os.environ.get('PLAINSONG_MAX_LOAD', '6'))
PAIRS = int(os.environ.get('PLAINSONG_PAIRS', '10'))
WAIT = 300


def command(args, cwd=None):
    return subprocess.check_output(args, cwd=cwd, text=True).strip()


def snapshot():
    builds = {}
    for name in BUILD_NAMES:
        result = subprocess.run(['pgrep', '-x', name], text=True, capture_output=True)
        if result.returncode not in (0, 1):
            raise RuntimeError('pgrep failed: ' + result.stderr)
        if result.returncode == 0:
            builds[name] = result.stdout.splitlines()
    return {'load': list(os.getloadavg()), 'top_cpu': command(['ps', '-Ao', '%cpu,comm', '-r']).splitlines()[:6], 'build_processes': builds}


def percentile(values, p):
    ordered = sorted(values)
    index = (len(ordered) - 1) * p
    lo, hi = math.floor(index), math.ceil(index)
    return ordered[lo] + (ordered[hi] - ordered[lo]) * (index - lo)


def summary(samples):
    return {'count': len(samples), 'median_ms': statistics.median(samples), 'p95_ms': percentile(samples, .95), 'maximum_ms': max(samples), 'fraction_over_16ms': sum(x > 16 for x in samples) / len(samples)}


def differences(values):
    rng = random.Random(20261004)
    boot = [statistics.median(rng.choices(values, k=len(values))) for _ in range(10000)]
    ci = [percentile(boot, .025), percentile(boot, .975)]
    worse = sum(x > 0 for x in values)
    return {'pair_differences_ms': values, 'median_difference_ms': statistics.median(values), 'bootstrap_95_ci_ms': ci, 'bootstrap_resamples': 10000, 'seed': 20261004, 'candidate_worse_pairs': worse, 'regression_signal': ci[0] > .5 and worse >= math.ceil(.8 * len(values)), 'ci_width_ms': ci[1] - ci[0]}


def analyze(batches):
    analysis = {}
    for candidate in ('fix', 'stack'):
        analysis[candidate] = {}
        for mode in MODES:
            pairs = []
            all_a, all_b = [], []
            for iteration in range(1, PAIRS + 1):
                label = f'{candidate}-{iteration}'
                a = next((b for b in batches if b['product'] == 'main' and b['iteration'] == label and b['action'] == 'test-without-building'), None)
                b = next((b for b in batches if b['product'] == candidate and b['iteration'] == label and b['action'] == 'test-without-building'), None)
                if not a or not b or not a['valid_measurement_batch'] or not b['valid_measurement_batch']:
                    continue
                sa, sb = a['samples'][mode], b['samples'][mode]
                pairs.append({'pair': iteration, 'baseline': summary(sa), 'candidate': summary(sb)})
                all_a.extend(sa)
                all_b.extend(sb)
            if not pairs:
                analysis[candidate][mode] = {'status': 'still pending', 'complete_pairs': 0}
                continue
            metrics = {metric: differences([p['candidate'][metric] - p['baseline'][metric] for p in pairs]) for metric in ('median_ms', 'p95_ms')}
            complete = len(pairs) >= PAIRS
            signal = any(m['regression_signal'] for m in metrics.values()) if complete else False
            analysis[candidate][mode] = {'complete_pairs': len(pairs), 'baseline': summary(all_a), 'candidate': summary(all_b), 'pairs': pairs, 'metrics': metrics, 'verdict': ('regression signal' if signal else 'no regression signal detected under recorded load') if complete else 'still pending; insufficient pairs', 'limitation': 'Differences smaller than the CI width cannot be excluded. Observed fractions above 16 ms do not decide absolute idle acceptance.'}
    return analysis


def batch(roots, output, name, iteration, action):
    start = snapshot()
    with (output / 'admission.jsonl').open('a') as stream:
        stream.write(json.dumps({'product': name, 'iteration': iteration, 'action': action, 'snapshot': start}) + '\n')
    if start['load'][0] > MAX_LOAD or start['build_processes']:
        print('NOT_QUIET ' + json.dumps(start), flush=True)
        return 75
    root = roots[name]
    metadata = {'product': name, 'iteration': iteration, 'action': action, 'product_sha': command(['git', 'rev-parse', 'HEAD'], root), 'start': start}
    probe = Path(root) / 'AppTests/EditorHighlightScheduleHostedTests.swift'
    metadata['probe_sha256'] = hashlib.sha256(probe.read_bytes()).hexdigest()
    timed = probe.read_text().split('    private func assertHostedLargeFixtureTyping', 1)[1].split('    /// Waits until', 1)[0].split('    private static func requireHostedOptIn', 1)[0].strip()
    metadata['typing_probe_sha256'] = hashlib.sha256(timed.encode()).hexdigest()
    stem = f'{name}-{iteration}-{action}'
    log = output / (stem + '.log')
    cmd = ['xcodebuild', '-project', 'Plainsong.xcodeproj', '-scheme', 'Plainsong', '-configuration', 'Debug', '-destination', 'platform=macOS', '-parallel-testing-enabled', 'NO', '-resultBundlePath', str(output / (stem + '.xcresult')), action]
    if action == 'test-without-building':
        cmd += ['-only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget', '-only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget']
    env = dict(os.environ, TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE='1')
    with log.open('w') as stream:
        stream.write(json.dumps(metadata) + '\n')
        stream.flush()
        result = subprocess.run(cmd, cwd=root, env=env, stdout=stream, stderr=subprocess.STDOUT)
    metadata.update(end=snapshot(), exit_code=result.returncode, raw_log=str(log), samples={})
    if action == 'test-without-building':
        raw = log.read_text()
        for mode in MODES:
            matches = re.findall(r'Hosted ' + re.escape(mode) + r' large-1mb\.md typing milliseconds: (\[[^\]\n]+\]); maximum:', raw)
            if matches:
                metadata['samples'][mode] = json.loads(matches[-1])
        failures = [line for line in raw.splitlines() if ' error: ' in line and ('failed' in line or 'XCT' in line)]
        metadata['assertion_failure_lines'] = failures
        # Only the existing maximum <16 assertion may fail in a complete batch.
        valid = all(len(metadata['samples'].get(mode, [])) == 30 for mode in MODES)
        valid = valid and (result.returncode == 0 or (result.returncode == 65 and failures and all('native input including debounce scheduling:' in line for line in failures)))
    else:
        valid = result.returncode == 0
    metadata['valid_measurement_batch'] = bool(valid)
    (output / (stem + '.json')).write_text(json.dumps(metadata, indent=2) + '\n')
    print(f'BATCH {stem} exit={result.returncode} valid={bool(valid)} log={log}', flush=True)
    return 0 if valid else 2


def main():
    missing = [v for v in ROOT_VARS.values() if not os.environ.get(v)]
    if missing or PAIRS < 10 or not math.isfinite(MAX_LOAD) or MAX_LOAD <= 0:
        raise SystemExit('Supply all worktree roots, >=10 pairs and a finite positive max load. Missing: ' + ', '.join(missing))
    roots = {k: os.environ[v] for k, v in ROOT_VARS.items()}
    if len(sys.argv) == 1:
        source = (Path(roots['fix']) / 'AppTests/EditorHighlightScheduleHostedTests.swift').read_text()
        a, b = source.index('    /// Stress reproduction'), source.index('    /// Opt-in local typing probe')
        source = source[:a] + source[b:]
        a, b = source.index('    /// Waits until no highlight'), source.index('    private static func requireHostedOptIn')
        source = source[:a] + source[b:]
        probe = Path(roots['main']) / 'AppTests/EditorHighlightScheduleHostedTests.swift'
        if probe.exists() and probe.read_text() != source:
            raise SystemExit('Baseline probe already exists with different contents; preserve it and prepare a clean baseline.')
        probe.write_text(source)
    Path(LOCK).parent.mkdir(parents=True, exist_ok=True)
    if len(sys.argv) > 1 and sys.argv[1] == 'batch':
        raise SystemExit(batch(roots, Path(sys.argv[2]), *sys.argv[3:]))
    output = Path(os.environ.get('PLAINSONG_EVIDENCE_ROOT', '/private/tmp/plainsong-paired-' + time.strftime('%Y%m%d-%H%M%S')))
    output.mkdir(parents=True, exist_ok=False)
    evidence = {'method': 'AB interleaved; 30 keystrokes per mode; no documented warm-up discarded; per-pair median and p95; 10000 bootstrap resamples', 'absolute_idle_acceptance': 'pending R9 / PR I or owner run', 'max_load': MAX_LOAD, 'requested_pairs': PAIRS, 'baseline_sha': command(['git', 'rev-parse', 'HEAD'], roots['main']), 'product_shas': {k: command(['git', 'rev-parse', 'HEAD'], v) for k, v in roots.items()}, 'batches': [], 'status': 'running'}
    def save():
        evidence['batches'] = [json.loads(p.read_text()) for p in sorted(output.glob('*.json')) if p.name != 'evidence.json']
        admissions = output / 'admission.jsonl'
        evidence['admission_checks'] = [json.loads(line) for line in admissions.read_text().splitlines()] if admissions.exists() else []
        evidence['analysis'] = analyze(evidence['batches'])
        (output / 'evidence.json').write_text(json.dumps(evidence, indent=2) + '\n')
    def run(name, iteration, action):
        deadline = time.monotonic() + WAIT
        while True:
            code = subprocess.run(['lockf', '-k', '-t', '0', LOCK, sys.executable, str(Path(__file__).resolve()), 'batch', str(output), name, str(iteration), action]).returncode
            save()
            if code == 0:
                return
            if code not in (1, 75):
                evidence['status'] = 'blocked by build/test failure; no verdict'
                save()
                raise SystemExit(code)
            if time.monotonic() >= deadline:
                evidence['status'] = 'still pending; quiet-machine admission timeout'
                save()
                print('still pending; quiet-machine admission timeout; evidence=' + str(output), flush=True)
                raise SystemExit(75)
            time.sleep(30)
    print('EVIDENCE ' + str(output), flush=True)
    save()
    for product in ('main', 'fix', 'stack'):
        run(product, 0, 'build-for-testing')
    for comparison in ('fix', 'stack'):
        for iteration in range(1, PAIRS + 1):
            run('main', f'{comparison}-{iteration}', 'test-without-building')
            run(comparison, f'{comparison}-{iteration}', 'test-without-building')
        save()
        if any(v.get('verdict') == 'regression signal' for v in evidence['analysis'][comparison].values()):
            evidence['status'] = 'regression signal; stopped'
            save()
            raise SystemExit(3)
    evidence['status'] = 'complete; observed under recorded load'
    save()


if __name__ == '__main__':
    main()
