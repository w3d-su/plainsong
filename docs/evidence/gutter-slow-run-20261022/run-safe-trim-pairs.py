from pathlib import Path
import os,re,json,subprocess,runpy,statistics
root=Path('/private/tmp/plainsong-gutter-slow-evidence');run=runpy.run_path(str(root/'run-probes.py'))['run']
cells={'H':('/private/tmp/plainsong-gutter-head-dd','/Users/davis._.su/.codex/worktrees/gutter-slow-head-baseline/blogeditor'),'F':('/private/tmp/plainsong-gutter-slow-dd','/Users/davis._.su/.codex/worktrees/gutter-slow-run-probe/blogeditor'),'M':('/private/tmp/plainsong-gutter-main-dd','/Users/davis._.su/.codex/worktrees/gutter-slow-main-baseline/blogeditor')}
os.environ.update(TEST_RUNNER_PLAINSONG_SCROLL_PROBE_USE_ADMISSION='1',TEST_RUNNER_PLAINSONG_SCROLL_PROBE_DRAW_AFTER_TRIM='0',TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_YIELD_MS='1',TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_SCROLL_AFTER='16',TEST_RUNNER_PLAINSONG_SCROLL_PROBE_PARAGRAPH_TRACE='1',TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_TRACE='1',TEST_RUNNER_PLAINSONG_SCROLL_PROBE_CAPTURE_BEYOND_OFFSET='600000')
def archive_bootstrap(tag):
 p=root/(tag+'.log');s=p.read_text()
 if 'Test Case ' in s or 'signal kill before establishing connection' not in s: raise RuntimeError('Not an excluded zero-test bootstrap termination: '+tag)
 pid=re.findall(r'Plainsong \((\d+)\) encountered',s)[-1]
 reason=subprocess.check_output(['/usr/bin/log','show','--last','20m','--style','compact','--predicate',f'process == "runningboardd" AND eventMessage CONTAINS "{pid}" AND eventMessage CONTAINS "Terminating"'],text=True)
 if 'CacheDeleteAppContainerCaches' not in reason: raise RuntimeError('Bootstrap termination cause not confirmed: '+tag)
 i=1
 while (root/f'{tag}-bootstrap-{i}.log').exists():i+=1
 p.rename(root/f'{tag}-bootstrap-{i}.log');(root/f'{tag}-bootstrap-{i}-reason.log').write_text(reason)
 print('Excluded zero-test CacheDelete bootstrap',tag,pid,flush=True)
for i,order in enumerate(['HFM','FMH','MHF','HMF','FHM'],1):
 for cell in order:
  tag=f'safe-trim-paired-{i}-{cell}';dd,tree=cells[cell]
  if (root/(tag+'.json')).exists():r=json.loads((root/(tag+'.json')).read_text())['report']
  else:
   if (root/(tag+'.log')).exists():archive_bootstrap(tag)
   for attempt in range(3):
    try:r=run(tag,1,30,dd=dd,tree=tree);break
    except RuntimeError:
     archive_bootstrap(tag)
     if attempt==2:raise
  ranges=r['explicitTrimRanges'];print(tag,'chunks',len(ranges),'median',statistics.median(r['insertMilliseconds']),flush=True)
  if cell in ('H','M') and len(ranges)!=30:raise RuntimeError('Unguarded control did not finish30 stale chunks')
  if cell=='F':
   for entry in ranges:
    start=entry['location'];end=start+entry['length']
    if not 0<entry['length']<=32768:raise RuntimeError('Invalid admitted length')
    if entry['nativeViewportBeforeLength']<=0 or start<entry['viewportPrefetchBeforeEnd']:raise RuntimeError('Admitted chunk overlaps live viewport prefix')
    if start<entry['selectedProtectionBeforeEnd'] and end>entry['selectedProtectionBeforeStart']:raise RuntimeError('Admitted chunk overlaps selected paragraph band')
   if any(a['location']<b['location']+b['length'] for a,b in zip(ranges,ranges[1:])):raise RuntimeError('Admitted chunks did not descend')

