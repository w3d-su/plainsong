#!/usr/bin/env python3
"""Summarize retained hosted typing evidence; never run or modify a benchmark.

The only FINAL cohort is safe-trim-paired-{1..5}-{H,F,M}. Older admission,
relocation and snapshot candidates remain separately labelled comparison cohorts.
Default execution refuses incomplete final data before writing output.
"""
import argparse
import csv
import datetime
import hashlib
import json
import re
import statistics
from pathlib import Path

ORDER = ['HFM', 'FMH', 'MHF', 'HMF', 'FHM']
FINAL_PREFIX = 'safe-trim-paired'
FINAL_GROUP = 'FINAL_safe_trim_triplets'
COHORTS = {
    'safe-trim-paired': {
        'group': FINAL_GROUP, 'status': 'FINAL',
        'F': 'live native viewport and selected-paragraph interval planner plus selection-report liveness dedup',
        'manifest': 'safe-trim-paired-builds.json',
    },
    'admission-paired': {
        'group': 'SUPERSEDED_suffix_only_admission_triplets', 'status': 'SUPERSEDED',
        'F': 'SUPERSEDED suffix-only guard; unavailable-viewport fallback and offscreen-caret policy replaced',
        'manifest': 'admission-paired-builds.json',
    },
    'relocation-paired': {
        'group': 'REJECTED_height_adapter_triplets', 'status': 'REJECTED',
        'F': 'REJECTED empty-viewport middle-relocation height adapter',
        'manifest': 'relocation-paired-builds.json',
    },
    'paired-split16': {
        'group': 'REJECTED_snapshot_triplets', 'status': 'REJECTED',
        'F': 'REJECTED viewport-snapshot gutter candidate', 'manifest': None,
    },
}
REPRODUCTIONS = {
    'branch-split15-on-1.json', 'branch-split16-on-1.json', 'branch-split17-on-1.json',
    'head-split16-on-2.json', 'head-early-hidden-forced-split16.json',
}


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    return json.loads(path.read_text())


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')


def describe(letter, fixed_description):
    return {'H': 'PR189 reference; unchanged pre-fix production',
            'F': fixed_description, 'M': 'main; unchanged native-gutter production'}[letter]


def classify(name):
    for prefix, cohort in COHORTS.items():
        match = re.fullmatch(re.escape(prefix) + r'-([1-5])-([HFM])(?:-retry)?\.json', name)
        if match:
            return dict(cohort, prefix=prefix, letter=match[2], round=int(match[1]),
                        variant=describe(match[2], cohort['F']))
    if re.fullmatch(r'forced-draw(?:0|18)-[1-4]-[HF]\.json', name):
        letter = name.removesuffix('.json')[-1]
        return dict(group='REJECTED_snapshot_forced_draw_controls', status='REJECTED',
                    prefix=None, manifest=None, letter=letter, round=None,
                    variant=describe(letter, 'REJECTED viewport-snapshot gutter candidate'))
    if re.fullmatch(r'relocation-stress-[1-4]-F\.json', name):
        return dict(group='REJECTED_height_adapter_stress', status='REJECTED', prefix=None,
                    manifest=None, letter='F', round=None,
                    variant='REJECTED middle-relocation height adapter; exploratory stress')
    if re.match(r'^formation-control-', name):
        return dict(group='PR189_formation_controls', status='CONTROL', prefix=None,
                    manifest=None, letter='H', round=None, variant=describe('H', ''))
    if re.fullmatch(r'main-formation-\d+-(?:on|off408)\.json', name):
        return dict(group='main_formation_controls', status='CONTROL', prefix=None,
                    manifest=None, letter='M', round=None, variant=describe('M', ''))
    if name in REPRODUCTIONS:
        return dict(group='reproduction_and_order_neighbors', status='CONTROL', prefix=None,
                    manifest=None, letter='H', round=None, variant=describe('H', ''))
    return None


def percentile(values, fraction):
    values = sorted(values)
    if not values:
        return None
    position = (len(values) - 1) * fraction
    lower = int(position)
    upper = min(lower + 1, len(values) - 1)
    return values[lower] + (values[upper] - values[lower]) * (position - lower)


def numeric_summary(values):
    return dict(values=values, median=statistics.median(values), minimum=min(values),
                maximum=max(values)) if values else None


def paragraph_summary(report):
    phases = report.get('paragraphRequests', [])
    best_key, best = None, {}
    for key, phase in enumerate(phases):
        current = phase.get('throughRunLoop', {})
        if current.get('paragraphRequests', 0) > best.get('paragraphRequests', -1):
            best_key, best = key, current
    extent = best.get('paragraphRequestedExtent', {})
    return dict(key_index=best_key, requests=best.get('paragraphRequests', 0) if phases else None,
                requested_location=extent.get('location'), requested_length=extent.get('length'),
                requested_end=(extent['location'] + extent['length']) if extent else None)


def overlap(start, end, other_start, other_end):
    return start < other_end and end > other_start


def admission_validation(report, fixture_length=None):
    ranges = report.get('explicitTrimRanges', [])
    result = {'use_admission': report.get('useAdmission', False), 'actual_range_count': len(ranges),
              'range_length_maximum': max((r['length'] for r in ranges), default=0),
              'bounds_and_descending_violations': [], 'admission_violations': [],
              'post_navigation_checks': [], 'missing_native_viewport_chunks': [],
              'exact_capture_chunks': 0}
    if not ranges:
        return result
    document_length = fixture_length or ranges[0]['location'] + ranges[0]['length']
    result['document_length'] = document_length
    result['document_length_source'] = 'verified fixture UTF-16 length' if fixture_length else 'first reverse range end; not independently verified'
    previous_start = document_length
    navigation_chunk = report.get('trimScrollAfter', -1)
    for chunk, value in enumerate(ranges, 1):
        start, length = value['location'], value['length']
        end = start + length
        if start < 0 or not 0 < length <= 32768 or end > document_length or end > previous_start:
            result['bounds_and_descending_violations'].append(chunk)
        previous_start = start
        if 'nativeViewportBeforeLocation' not in value:
            continue  # Old and production-loop reports do not claim a same-turn capture.
        result['exact_capture_chunks'] += 1
        viewport_start = value['nativeViewportBeforeLocation']
        viewport_length = value['nativeViewportBeforeLength']
        native_valid = viewport_start >= 0 and viewport_length > 0
        prefix_end = value.get('viewportPrefetchBeforeEnd', -1)
        band_start = value.get('selectedProtectionBeforeStart', -1)
        band_end = value.get('selectedProtectionBeforeEnd', -1)
        paragraph_start = value.get('selectedParagraphBeforeLocation', -1)
        paragraph_length = value.get('selectedParagraphBeforeLength', 0)
        paragraph_valid = paragraph_start >= 0 and paragraph_length >= 0
        viewport_collision = overlap(start, end, viewport_start, viewport_start + viewport_length) if native_valid else None
        prefix_collision = start < prefix_end if prefix_end >= 0 else None
        selection_collision = overlap(start, end, band_start, band_end) if band_start >= 0 and band_end >= band_start else None
        expected_prefix = min(document_length, viewport_start + viewport_length + max(viewport_length, 8192)) if native_valid else None
        fields_consistent = (prefix_end == expected_prefix if native_valid else prefix_end == -1)
        if paragraph_valid:
            fields_consistent &= band_start == max(0, paragraph_start - 8192)
            fields_consistent &= band_end == min(document_length, paragraph_start + paragraph_length + 8192)
        check = dict(chunk=chunk, range_location=start, range_length=length,
                     native_viewport_location=viewport_start, native_viewport_length=viewport_length,
                     viewport_prefetch_end=prefix_end, selected_paragraph_location=paragraph_start,
                     selected_paragraph_length=paragraph_length, selected_protection_start=band_start,
                     selected_protection_end=band_end, intersects_native_viewport=viewport_collision,
                     intersects_viewport_prefix_and_prefetch=prefix_collision,
                     intersects_selected_paragraph_band=selection_collision,
                     capture_fields_consistent=fields_consistent)
        if not native_valid:
            result['missing_native_viewport_chunks'].append(chunk)
        if not native_valid or not fields_consistent or prefix_collision or selection_collision:
            result['admission_violations'].append(check)
        if chunk > navigation_chunk > 0:
            result['post_navigation_checks'].append(check)
    return result


def symbol_stack(stack):
    result = []
    for line in stack or []:
        line = re.sub(r'0x[0-9a-fA-F]+\s+', '', line)
        line = re.sub(r'\s+\+\s+\d+\s*$', '', line)
        result.append(re.sub(r'^\d+\s+', '', line).strip())
    return result[:14]


def mechanism_extract(name, document):
    report = document['report']
    phases = report.get('paragraphRequests', [])
    stacks = []
    for key, phase in enumerate(phases):
        current = phase.get('throughRunLoop', {})
        if current.get('paragraphFirstBeyondLocationCallStack'):
            stacks.append(dict(key_index=key, threshold=current.get('paragraphCaptureBeyondLocation'),
                               first_range=current.get('paragraphFirstBeyondLocationRange'),
                               symbols=symbol_stack(current['paragraphFirstBeyondLocationCallStack'])))
    transitions, previous = [], None
    for event in report.get('trimmerEvents', []):
        geometry = tuple(event.get(k) for k in ['height', 'viewportLocation', 'viewportLength'])
        if geometry != previous or event.get('event') in ['typing-start', 'typing-end', 'diagnostic-tail-recovery']:
            transitions.append({k: event[k] for k in ['event', 'milliseconds', 'height', 'viewportLocation',
                                                    'viewportLength', 'selectionLocation'] if k in event})
            previous = geometry
    return dict(source_report=name, geometry_before=report.get('geometryBeforeTyping'),
                geometry_after=report.get('geometryAfterTyping'),
                scheduled_trimmed_during_typing=report.get('trimmedDuringTyping'),
                insert_milliseconds=report['insertMilliseconds'],
                paragraph_requests_per_key=[p.get('throughRunLoop', {}).get('paragraphRequests', 0) for p in phases],
                peak_paragraph_requests=paragraph_summary(report), threshold_stacks=stacks[:2],
                geometry_transitions=transitions[:24])


def cohort_summary(rows):
    result = {}
    for letter in 'HFM':
        selected = [row for row in rows if row['product_letter'] == letter]
        result[letter] = dict(run_count=len(selected),
            busy_ms=numeric_summary([r['busy_ms'] for r in selected]),
            insert_total_ms=numeric_summary([r['insert_total_ms'] for r in selected]),
            per_run_insert_median_ms=numeric_summary([r['insert_median_ms'] for r in selected]),
            peak_paragraph_requests=[r['peak_paragraph_requests'] for r in selected],
            runs_with_10000_paragraph_refill=sum((r['peak_paragraph_requests'] or 0) >= 10000 for r in selected),
            actual_range_counts=[r['actual_range_count'] for r in selected])
    return result


def pair_comparisons(rows, prefix):
    indexed = {(r['round'], r['product_letter']): r for r in rows}
    pairs = []
    for number in range(1, 6):
        if not all((number, letter) in indexed for letter in 'HFM'):
            continue
        h, f, m = [indexed[number, letter] for letter in 'HFM']
        pairs.append(dict(round=number, scheduled_order=ORDER[number - 1],
            runs={letter: indexed[number, letter]['run'] for letter in 'HFM'},
            F_minus_H_busy_ms=f['busy_ms'] - h['busy_ms'],
            F_minus_H_busy_percent=(f['busy_ms'] / h['busy_ms'] - 1) * 100,
            F_minus_M_busy_ms=f['busy_ms'] - m['busy_ms'],
            F_minus_M_busy_percent=(f['busy_ms'] / m['busy_ms'] - 1) * 100,
            F_minus_H_insert_median_ms=f['insert_median_ms'] - h['insert_median_ms'],
            F_minus_M_insert_median_ms=f['insert_median_ms'] - m['insert_median_ms'],
            H_had_10000_paragraph_refill=(h['peak_paragraph_requests'] or 0) >= 10000))
    fast = [p for p in pairs if not p['H_had_10000_paragraph_refill']]
    return dict(prefix=prefix, all_pairs=pairs,
        fast_H_subset_criterion='H peak per-key paragraph requests <10000; diagnostic only, never a replacement for all pairs',
        F_vs_fast_H_busy_percent=numeric_summary([p['F_minus_H_busy_percent'] for p in fast]),
        F_vs_fast_H_insert_median_difference_ms=numeric_summary([p['F_minus_H_insert_median_ms'] for p in fast]),
        F_vs_main_busy_percent=numeric_summary([p['F_minus_M_busy_percent'] for p in pairs]))


def number(value, digits=1):
    return 'pending' if value is None else f'{value:,.{digits}f}'


def median(stats, metric):
    return stats[metric]['median'] if stats.get(metric) else None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--input-dir', type=Path, default=Path(__file__).resolve().parent)
    parser.add_argument('--output-dir', type=Path)
    parser.add_argument('--fixture', type=Path, default=Path('/Users/davis._.su/.codex/worktrees/gutter-slow-run-probe/blogeditor/Fixtures/large-1mb.md'))
    parser.add_argument('--allow-partial', action='store_true')
    parser.add_argument('--date', default='2026-10-22')
    args = parser.parse_args()
    root = args.input_dir.resolve()
    output = (args.output_dir or root / 'safe-trim-final-summary').resolve()
    expected = [f'{FINAL_PREFIX}-{i}-{letter}.json' for i in range(1, 6) for letter in 'HFM']
    missing = [name for name in expected if not (root / name).exists()]
    final_manifest_path = root / COHORTS[FINAL_PREFIX]['manifest']
    if missing and not args.allow_partial:
        raise SystemExit('Final campaign incomplete; no output written. Missing: ' + ', '.join(missing))
    if not final_manifest_path.exists():
        raise SystemExit('Final build manifest missing; no output written: ' + str(final_manifest_path))
    manifests = {value['manifest']: read_json(root / value['manifest']) for value in COHORTS.values()
                 if value['manifest'] and (root / value['manifest']).exists()}
    final_manifest = manifests[COHORTS[FINAL_PREFIX]['manifest']]
    overlays = {}
    for letter, variant in final_manifest.items():
        overlay = variant.get('testOnlyBaselineOverlay')
        if overlay:
            patch = root / overlay['file']
            if not patch.exists() or digest(patch) != overlay['sha256']:
                raise SystemExit(f'{letter} baseline overlay patch is absent or has changed; no output written')
            overlays[overlay['file']] = dict(sha256=digest(patch), bytes=patch.stat().st_size)
    fixture_length, fixture_hash = None, None
    if args.fixture and args.fixture.exists():
        fixture_bytes = args.fixture.read_bytes()
        fixture_length = len(fixture_bytes.decode('utf-8').encode('utf-16-le')) // 2
        fixture_hash = hashlib.sha256(fixture_bytes).hexdigest()
        for letter in 'HFM':
            expected_hash = final_manifest[letter].get('sources', {}).get('Fixtures/large-1mb.md')
            if fixture_hash != expected_hash:
                raise SystemExit(f'Fixture SHA-256 does not match final {letter} manifest; no output written')
    rows, documents, raw_manifest, validations = [], {}, [], {}
    for path in sorted(root.glob('*.json')):
        category = classify(path.name)
        if category is None:
            continue
        document = read_json(path)
        report = document.get('report', {})
        samples = report.get('insertMilliseconds', [])
        if document.get('exit') != 0 or len(samples) != 50:
            raise SystemExit(f'{path.name}: selected report is not a successful complete 50-key run')
        final = category['group'] == FINAL_GROUP
        if final:
            controls = dict(controlledTrimChunks=30, trimScrollAfter=16, trimYieldMilliseconds=1,
                            drawAfterTrim=0, useAdmission=True, useProductionTrim=False,
                            layoutBetweenTrims=False, lineNumbers=True, hiddenGutterDraw=False,
                            hiddenGutterEarly=False)
            for key, expected_value in controls.items():
                if report.get(key) != expected_value:
                    raise SystemExit(f'{path.name}: final control {key}={report.get(key)!r}, expected {expected_value!r}')
            if len(report.get('paragraphRequests', [])) != 50:
                raise SystemExit(f'{path.name}: final report lacks all 50 paragraph phases')
        validation = admission_validation(report, fixture_length)
        if final:
            validations[path.name] = validation
            if validation['bounds_and_descending_violations']:
                raise SystemExit(f'{path.name}: explicit ranges violate bounds or descending order')
            if validation['exact_capture_chunks'] != validation['actual_range_count']:
                raise SystemExit(f'{path.name}: final manual admission ranges lack exact native before-state captures')
            if validation['actual_range_count'] < 16:
                raise SystemExit(f'{path.name}: preparation stopped before navigation boundary')
            if category['letter'] == 'F' and validation['admission_violations']:
                raise SystemExit(f'{path.name}: final F released a protected or unverified range; see raw report')
        geometry, peak = report.get('geometryBeforeTyping', {}), paragraph_summary(report)
        attestation = manifests.get(category['manifest'], {}).get(category['letter'], {})
        row = dict(run=path.name, group=category['group'], candidate_status=category['status'],
            variant=category['variant'], product_letter=category['letter'], round=category['round'],
            product_base_sha=attestation.get('head', ''), product_sha256=attestation.get('productSha256', ''),
            build_manifest=category['manifest'] if attestation else '',
            line_numbers=report.get('lineNumbers'), hidden_early=report.get('hiddenGutterEarly', False),
            hidden_during_typing=report.get('hiddenGutterDraw', False), use_admission=report.get('useAdmission', False),
            use_production_trim=report.get('useProductionTrim', False), trim_chunks=report.get('controlledTrimChunks'),
            actual_range_count=validation['actual_range_count'], trim_scroll_after=report.get('trimScrollAfter', -1),
            trim_yield_ms=report.get('trimYieldMilliseconds', 0), draw_after_trim=report.get('drawAfterTrim', -1),
            window_width=report.get('requestedWindowWidth', 1000), container_width=geometry.get('textContainerWidth'),
            clip_width=geometry.get('clipWidth'), initial_height=geometry.get('editorHeight'),
            initial_viewport_location=geometry.get('viewportLocation'), initial_viewport_length=geometry.get('viewportLength'),
            busy_ms=report['totalBusyMilliseconds'], cpu_busy_ms=report.get('totalCPUMilliseconds'),
            insert_total_ms=sum(samples), insert_median_ms=statistics.median(samples),
            insert_p95_ms=percentile(samples, .95), insert_max_ms=max(samples),
            peak_paragraph_requests=peak['requests'], peak_request_key=peak['key_index'],
            peak_requested_location=peak['requested_location'], peak_requested_end=peak['requested_end'],
            protected_range_collisions=len(validation['admission_violations']) if validation['exact_capture_chunks'] else None,
            scheduled_trimmed_during_typing=report.get('trimmedDuringTyping'),
            load_before=document.get('loadBefore'), load_after=document.get('loadAfter'), raw_json_sha256=digest(path))
        rows.append(row)
        documents[path.name] = document
        raw_manifest.append(dict(file=path.name, absolute_local_path=str(path), bytes=path.stat().st_size,
            sha256=digest(path), group=category['group'], candidate_status=category['status'],
            variant=category['variant'], build_provenance=(category['manifest'] + ':' + category['letter'])
            if attestation else 'Exploratory report; no matching retained binary attestation'))
    final_rows = [r for r in rows if r['group'] == FINAL_GROUP]
    final_stats = cohort_summary(final_rows)
    comparisons = pair_comparisons(final_rows, FINAL_PREFIX)
    previous = {}
    for prefix, value in COHORTS.items():
        if prefix == FINAL_PREFIX:
            continue
        cohort_rows = [r for r in rows if r['group'] == value['group']]
        previous[prefix] = dict(status=value['status'], F_variant=value['F'],
                               summary=cohort_summary(cohort_rows), comparisons=pair_comparisons(cohort_rows, prefix))
    # Keep mechanistic negative controls and all final F arrays; never pool their statistics.
    selected = [name for name in ['branch-split16-on-1.json', 'forced-draw0-3-F.json',
                 'formation-control-1-off408.json', 'main-formation-1-off408.json', 'main-formation-1-on.json']
                if name in documents]
    for letter in 'HFM':
        candidates = [r for r in final_rows if r['product_letter'] == letter]
        if candidates:
            selected.append(max(candidates, key=lambda r: r['busy_ms'])['run'])
    selected += [r['run'] for r in final_rows if r['product_letter'] == 'F']
    mechanism = dict(schema_version=2, final_prefix=FINAL_PREFIX,
        status='FINAL campaign complete' if not missing else 'PARTIAL DRAFT', missing_final_reports=missing,
        metric_definitions=dict(busy_ms='Sum of main-run-loop wall busy slices during 50 native insertions and ensuing scheduled work',
            insert_median_ms='Median of 50 synchronous insertText wall durations within one run',
            large_refill='Diagnostic: at least 10000 paragraph requests through one key run-loop interval',
            comparison_unit='A complete run; its 50 keystrokes are not independent trials'),
        variant_warning='Only safe-trim-paired is FINAL. admission-paired is SUPERSEDED suffix-only admission; relocation is REJECTED height adapter; older snapshot F variants are REJECTED. No cross-candidate pooling.',
        final_campaign=final_stats, final_comparisons=comparisons, final_admission_validation=validations,
        previous_candidates_separate=previous,
        control_group_summaries={group: cohort_summary([r for r in rows if r['group'] == group])
            for group in sorted({r['group'] for r in rows}) if group not in {c['group'] for c in COHORTS.values()}},
        mechanistic_representatives=[mechanism_extract(name, documents[name]) for name in dict.fromkeys(selected)],
        limitations=['Main formation controls have not reproduced the slow mode; do not conclude #189 is unrelated.',
            'Report ordinary total-busy overhead even if synchronous insertion medians improve.',
            'Before-state captures share the admission main-actor turn and contain no forced layout; they are diagnostics, not a proof of native framework internals.',
            'Build manifests attest listed sources only; retain the exact commit/diff and every helper to bind complete source state.',
            'Loaded paired timings do not establish owner manual/IME/device acceptance or exact-head CI.'])
    output.mkdir(parents=True, exist_ok=True)
    for name, selected_rows in [('typing-runs.csv', rows), ('final-typing-runs.csv', final_rows)]:
        with (output / name).open('w', newline='') as stream:
            writer = csv.DictWriter(stream, fieldnames=list(rows[0]), lineterminator='\n')
            writer.writeheader(); writer.writerows(selected_rows)
    save_json(output / 'mechanism.json', mechanism)
    save_json(output / 'raw-manifest.json', dict(reports=raw_manifest, generator_sha256=digest(Path(__file__)),
        build_manifests={name: digest(root / name) for name in manifests}, baseline_overlay_patches=overlays,
        fixture=dict(path=str(args.fixture), sha256=fixture_hash, utf16_length=fixture_length)))
    for name in list(manifests) + list(overlays):
        (output / name).write_bytes((root / name).read_bytes())
    date = datetime.date.fromisoformat(args.date).isoformat()
    status = 'DRAFT — incomplete final campaign. ' if missing else ''
    indexed = {(r['round'], r['product_letter']): r for r in final_rows}
    table = ['| Round/order | H busy ms / insert median ms | F busy ms / insert median ms | M busy ms / insert median ms | F−H busy ms |',
             '|---|---:|---:|---:|---:|']
    for i in range(1, 6):
        cells = []
        for letter in 'HFM':
            row = indexed.get((i, letter))
            cells.append('pending' if row is None else f"{row['busy_ms']:,.1f} / {row['insert_median_ms']:.2f}")
        pair = next((p for p in comparisons['all_pairs'] if p['round'] == i), None)
        table.append(f'| {i} / {ORDER[i-1]} | ' + ' | '.join(cells) + ' | ' +
                     ('pending' if pair is None else f"{pair['F_minus_H_busy_ms']:+,.1f}") + ' |')
    loads = [float(re.findall(r'\d+(?:\.\d+)?', r[key] or '')[0]) for r in final_rows
             for key in ['load_before', 'load_after'] if re.findall(r'\d+(?:\.\d+)?', r[key] or '')]
    load_text = f'{min(loads):.2f}–{max(loads):.2f}' if loads else 'pending'
    f, h, m = [final_stats[letter] for letter in 'FHM']
    perf = [f'## Intermittent hosted typing: revalidate each cache trim — {date}', '',
        status + 'H is PR #189 reference `8081904`; M is main `2138165`. F adds the live native-viewport and selected-paragraph admission planner plus coordinator selection-report liveness dedup. The exact safe-trim build manifest binds the products and listed source hashes. Earlier suffix-only admission is SUPERSEDED; the height adapter and gutter-snapshot candidates are REJECTED and remain separate cohorts.', '',
        'The hosted source-only `large-1mb.md` probe records 50 native insertions and ensuing main-run-loop work. Replay the old formation sequence: at most 30 reverse 32768-unit tail ranges, scroll after chunk16, settle10ms, yield1ms between trims, direct gutter draw after each trim. `USE_ADMISSION=1` asks the real final planner before every trim. H/M use a test-only identity shim for their old admission policy; their production code remains unchanged. F may admit fewer ranges or a shorter/skipped range. Each manual range records its same-turn direct native viewport, prefetch end, selection and selected paragraph protection band immediately before trimming.', '',
        f'Retained final reports {len(final_rows)}/15; complete triplets {len(comparisons["all_pairs"])}/5. One-minute load start/end range {load_text}; no idle-load admission gate. Runs are serialized under the shared Xcode lock, use optimized Debug, and exclude PlainsongUITests/XCUITest.', ''] + table + ['',
        f'Median run busy time: H {number(median(h,"busy_ms"))}ms, F {number(median(f,"busy_ms"))}ms, M {number(median(m,"busy_ms"))}ms. Median of per-run synchronous insertion medians: H {number(median(h,"per_run_insert_median_ms"),2)}ms, F {number(median(f,"per_run_insert_median_ms"),2)}ms, M {number(median(m,"per_run_insert_median_ms"),2)}ms. These metrics are not interchangeable.', '',
        f'Large refill episodes (>=10000 paragraph requests in one key interval): H {h["runs_with_10000_paragraph_refill"]}/{h["run_count"]}, F {f["runs_with_10000_paragraph_refill"]}/{f["run_count"]}, M {m["runs_with_10000_paragraph_refill"]}/{m["run_count"]}. Actual F admitted range counts: {f["actual_range_counts"]}. The mechanism JSON validates bounded, descending ranges and lists exact post-navigation viewport/prefetch and selected-paragraph collisions for each variant.', '']
    fast = comparisons['F_vs_fast_H_busy_percent']
    med = comparisons['F_vs_fast_H_insert_median_difference_ms']
    main_busy = comparisons['F_vs_main_busy_percent']
    if fast:
        perf += [f'Ordinary fast-H diagnostic subset: paired F busy change {fast["minimum"]:+.1f}% to {fast["maximum"]:+.1f}% (median {fast["median"]:+.1f}%); insertion-median change {med["minimum"]:+.3f} to {med["maximum"]:+.3f}ms. Report this overhead alongside all-pair results.', '']
    if main_busy:
        perf += [f'Against main, paired F busy change {main_busy["minimum"]:+.1f}% to {main_busy["maximum"]:+.1f}% (median {main_busy["median"]:+.1f}%).', '']
    perf += ['Mechanism: the reproduced slow state causes native TextKit viewport layout to request roughly10000 below-caret paragraphs, after which later insertions pay cached-element range updates. A matched-width gutter-off reference reproduced5325ms, and the rejected snapshot candidate reproduced5299ms despite drawing without TextKit requests. Draw-time enumeration alone is insufficient. Main formation controls stayed fast, so this is not evidence that #189 is unrelated.', '',
        'The final planner requires a real nonempty native viewport, protects its prefix/prefetch and full selected paragraphs±8192, and can skip the selected interval to trim safe middle text when a stale caret remains offscreen. Coordinator liveness dedup prevents selection-only callbacks from repeatedly postponing that work. Review the exact product predicates and regression evidence separately from timing data.', '',
        'Retain `final-typing-runs.csv`, `typing-runs.csv`, `mechanism.json`, `raw-manifest.json`, `safe-trim-paired-builds.json`, the older manifests, generator and exact probe/helper sources together. Raw local paths/digests are in the manifest. This generated draft does not certify manual acceptance, full-suite status, CI or merge readiness.', '']
    (output / 'perf-log-entry-draft.md').write_text('\n'.join(perf))
    readme = ['# Hosted cache-trim slowdown evidence', '', status + 'Generated from retained reports; this script runs no benchmark.', '',
        'Rebuild only after all five final triplets and the final build manifest arrive:', '', '```sh',
        f'python3 {Path(__file__).resolve()} --input-dir {root} --output-dir {output} --fixture {args.fixture}', '```', '',
        'The default refuses incomplete final input before writing output. `--allow-partial` is draft-only and explicitly lists missing reports. The final control flags and per-trim range safety are validated; a final F collision, missing before-state or source-fixture mismatch aborts generation.', '',
        'Variant identities:', '',
        '- `safe-trim-paired-*-H`: FINAL PR189 reference plus equivalent probes and a test-only identity admission shim.',
        '- `safe-trim-paired-*-F`: FINAL live native-viewport/selected-paragraph interval planner plus selection-report liveness dedup.',
        '- `safe-trim-paired-*-M`: FINAL main/native-gutter reference with equivalent probe/native-gutter adaptation and identity admission shim.',
        '- `admission-paired-*`: SUPERSEDED suffix-only guard; unavailable-viewport fallback/offscreen-caret policy was replaced. Never pool with FINAL.',
        '- `relocation-paired-*` / `relocation-stress-*`: REJECTED height adapter. Never pool with FINAL.',
        '- `paired-split16-*` and `forced-draw*-F`: REJECTED snapshot candidate; negative controls. Never pool with FINAL.', '',
        'Provenance:', '',
        'Each copied campaign manifest binds variant base commits, executable SHA-256 and only the source paths listed in its `sources` object. The FINAL manifest also records app-hosted PlainsongTests/PerformanceTests MachO hashes, build flags, toolchain/hardware, and the full H/M tracked-plus-untracked baseline overlay patch hashes. Those patches are digest-checked and copied beside the final summary. The FINAL manifest cannot attest an older binary. Exploratory rows without their own matching manifest leave binary attestation blank. Keep exact commit/diffs and every helper beside the manifests; unlisted sources are not independently bound by a partial source list.', '',
        'Final manual admission records use direct native viewport ranges, never the visible-range helper fallback. Every successful range records before-state after admission and before static trim in one synchronous main-actor turn. `final_admission_validation` checks range bounds/descending order, computes prefix/prefetch collision and selected-paragraph-band collision, and retains all post-chunk16 checks. H/M identity shims intentionally expose old-policy collisions; only final F is required to pass fresh-state admission. Production-loop loc/len entries from older cohorts make no before-state claim.', '',
        'Files:', '',
        '- `final-typing-runs.csv`: compact final15-run comparison table with controls, geometry, metrics, collisions, loads and digests.',
        '- `typing-runs.csv`: all selected final, formation/reproduction controls and separate superseded/rejected candidates.',
        '- `mechanism.json`: final statistics/pairs, exact admission validation, representative per-key arrays/stacks and separate old-candidate comparisons.',
        '- `raw-manifest.json`: local raw report paths, SHA-256, cohort identity, generator digest, fixture digest and copied-manifest digests.',
        '- `*-builds.json`: unchanged copies of supplied campaign provenance.',
        '- `safe-trim-{H,M}-baseline-test-overlay.patch`: exact digest-checked diagnostic/baseline harness overlays, including untracked helpers; the old production admission policy remains unchanged.',
        '- `perf-log-entry-draft.md`: reviewable draft; replace evidence links and reconcile final test/CI/manual status before publication.', '',
        f'Selected complete runs: {len(rows)}; FINAL reports: {len(final_rows)}/15. Raw local JSON paths are evidence locations, not portable public links. Suggested check-in is these compact outputs, generator, exact probe/helpers and reviewable product diff; archive large raw reports separately when independent reconstruction is required.', '',
        'A run is the comparison unit. Busy totals and insertion medians measure different work. Retain any ordinary busy overhead; fast-H subset statistics are mechanistic diagnostics and do not replace all pairs. Main has not reproduced the rare mode, so do not call #189 unrelated. Loaded measurements do not establish idle latency, screen-to-photon latency, owner IME/manual acceptance or exact-head CI.', '']
    (output / 'README-draft.md').write_text('\n'.join(readme))
    print(json.dumps(dict(output=str(output), rows=len(rows), final_reports=len(final_rows),
                          complete_triplets=len(comparisons['all_pairs']), missing=missing)))


if __name__ == '__main__':
    main()
