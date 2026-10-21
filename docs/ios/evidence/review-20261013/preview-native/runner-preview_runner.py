#!/usr/bin/env python3
"""Exact-source temporary iOS PreviewKit runner; no repository mutation or service reset."""
import argparse,datetime,hashlib,importlib.util,json,os,plistlib,re,signal,subprocess,time
from pathlib import Path

LOCK='/private/tmp/plainsong-xcodebuild-test.lock'
ROOT=Path('/Users/davis._.su/.codex/worktrees/ios-review-integration/blogeditor')
WORK=Path('/private/tmp/plainsong-preview-ios-native-c1-20261013')
FROZEN_REF='ios-c0-v1'
FROZEN_SHA='642cb212703220409874a2741c5adbfb8c80fe8a'
DEST='A24A1CB9-2861-4AA4-A79F-E53F768950D8'
SOURCE_ROOTS=('Packages/PreviewKit/','Packages/MarkdownCore/','App/Resources/preview/','Fixtures/')
FROZEN_FILES=[
 'Packages/MarkdownCore/Sources/MarkdownCore/IOSDocumentContracts.swift',
 'Packages/MarkdownCore/Tests/MarkdownCoreTests/IOSDocumentContractTests.swift',
 'Packages/SyntaxKit/Sources/SyntaxKit/Contracts.swift',
 'Packages/SyntaxKit/Sources/SyntaxKit/MarkdownSyntaxToken.swift',
 'Packages/WorkspaceCore/Sources/WorkspaceCore/Contracts.swift',
 'Packages/EditorKitIOS/Sources/EditorKitIOS/Contracts.swift',
 'Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/Contracts.swift',
 'Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/DocumentContracts.swift',
 'Packages/WorkspaceKitIOS/Sources/WorkspaceKitIOS/ImageContracts.swift',
 'Packages/PreviewKit/Sources/PreviewKit/PreviewAssetReading.swift',
 'Packages/PreviewKit/Sources/PreviewKit/PreviewContracts.swift',
 'Packages/PreviewKit/Sources/PreviewKit/PreviewContractExports.swift',
]

def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def sha(data):return hashlib.sha256(data).hexdigest()
def write(path,data):
 path.parent.mkdir(parents=True,exist_ok=True)
 path.write_text(json.dumps(data,indent=2,sort_keys=True)+'\n')
def git(*args):return subprocess.check_output(['git','-C',str(ROOT),*args])
def limited(command,timeout=5):
 try:
  r=subprocess.run(command,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,timeout=timeout)
  return {'command':command,'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr}
 except subprocess.TimeoutExpired:return {'command':command,'exit':124,'stdout':'','stderr':'utility timeout'}

def prepare():
 if WORK.exists():raise RuntimeError('Prepared source already exists; verify it rather than overwriting')
 assert git('rev-parse',FROZEN_REF).decode().strip()==FROZEN_SHA
 names=git('ls-files','-z').decode().split('\0')
 names=sorted(n for n in names if n and (n.startswith(SOURCE_ROOTS) or n=='Scripts/ios/ios-test-results.py'))
 frozen=sorted(set(FROZEN_FILES+git('ls-tree','-r','--name-only',FROZEN_REF,'AppIOS/App','AppIOS/Composition','AppIOS/State','AppIOSTests/Integration','Packages/WorkspaceKitIOS/Tests/WorkspaceKitIOSTests/Contracts').decode().splitlines()))
 records={}
 for name in frozen:
  baseline=git('show',FROZEN_REF+':'+name)
  current=(ROOT/name).read_bytes()
  assert baseline==current,'Frozen C0 mismatch: '+name
  records[name]={'baseline_sha256':sha(baseline),'current_sha256':sha(current)}
 WORK.mkdir()
 copies={}
 for name in names:
  source=ROOT/name
  assert source.is_file() and not source.is_symlink(),name
  data=source.read_bytes()
  destination=WORK/name
  destination.parent.mkdir(parents=True,exist_ok=True)
  destination.write_bytes(data)
  assert destination.read_bytes()==data
  copies[name]=sha(data)
 required=[]
 for path in (WORK/'Packages/PreviewKit/Tests/PreviewKitTests').glob('*.swift'):
  text=path.read_text()
  if text.lstrip().startswith('#if os(macOS)'):continue
  classes=re.findall(r'(?:final\s+)?class\s+(\w+)\s*:\s*XCTestCase',text)
  functions=re.findall(r'\bfunc (test\w+)\s*\(',text)
  if functions:
   assert len(classes)==1,(path,classes)
   required += [classes[0]+'/'+f for f in functions]
 assert len(required)==len(set(required))==46,required
 manifest={'prepared_at':now(),'source_root':str(ROOT),'source_head':git('rev-parse','HEAD').decode().strip(),'source_dirty':bool(git('status','--porcelain')),'copy_root':str(WORK),'files':copies,'source_fingerprint':sha(json.dumps(copies,sort_keys=True,separators=(',',':')).encode()),'frozen_ref':FROZEN_REF,'frozen_sha':FROZEN_SHA,'frozen':records,'required_full_cases':sorted(required),'hosted_cases':sorted(n for n in required if n.startswith('PreviewIOSHostedTests/')),'copy_policy':'Full original tracked files only; no source/platform/test adaptation or fake native provider','input_manifest_copy':{'Scripts/ios/ios-test-results.py':copies['Scripts/ios/ios-test-results.py']}}
 assert len(manifest['hosted_cases'])==2
 write(WORK/'prepared-source.json',manifest)
 print('PREPARED',manifest['source_head'],'files',len(copies),'frozen',len(records),'full cases',len(required),flush=True)

def verify(manifest):
 differences=[]
 for name,digest in manifest['files'].items():
  if sha((ROOT/name).read_bytes())!=digest or sha((WORK/name).read_bytes())!=digest:differences.append(name)
 for name,record in manifest['frozen'].items():
  if sha((ROOT/name).read_bytes())!=record['baseline_sha256']:differences.append('frozen:'+name)
 if differences:raise RuntimeError('Source/frozen inputs changed: '+repr(differences))
 return {'checked_at':now(),'source_head':git('rev-parse','HEAD').decode().strip(),'source_dirty':bool(git('status','--porcelain')),'input_and_frozen_differences':differences}

# Process inventory is used for identities and sampled RSS, never attribution of a historical spike.
def processes():
 result=limited(['/bin/ps','-axo','pid=,ppid=,pgid=,uid=,lstart=,rss=,comm=,args='],3)
 if result['exit']!=0:return {},result['stderr']
 found={}
 for line in result['stdout'].splitlines():
  parts=line.split(None,11)
  if len(parts)!=12:continue
  try:pid,ppid,pgid,uid=map(int,parts[:4]);rss=int(parts[9])
  except ValueError:continue
  found[pid]={'pid':pid,'ppid':ppid,'pgid':pgid,'uid':uid,'started': ' '.join(parts[4:9]),'rss_kib':rss,'comm':parts[10],'args':parts[11]}
 return found,None

def identity(record):return tuple(record[k] for k in ('pid','uid','started','comm'))
def image_proof(record,targets,baseline):
 if record['uid']!=os.getuid() or record['pid'] in baseline:return None
 if not ('xctest' in (record['comm']+' '+record['args']).lower() or 'PreviewKit' in record['args']):return None
 listing=limited(['/usr/sbin/lsof','-p',str(record['pid']),'-Fn'],3)
 if listing['exit'] not in (0,1):return None
 for line in listing['stdout'].splitlines():
  if not line.startswith('n'):continue
  name=line[1:]
  for suffix,digest in targets.items():
   if name.endswith(suffix) and (f'/CoreSimulator/Devices/{DEST}/' in name or name.startswith(str(WORK/'runs'))):
    path=Path(name)
    try:
     if path.is_file() and sha(path.read_bytes())==digest:
      return {'identity':identity(record),'loaded_test_image':name,'image_sha256':digest,'destination':DEST,'ownership':'new native process with exact loaded test image on the designated device or unique task derived-data root'}
    except OSError:pass
 return None

# Helpers are observed but never signalled: shared/reused WebKit helper ownership is not established.
def compact(record,role):return {k:record[k] for k in ('pid','ppid','pgid','uid','started','rss_kib')}|{'executable':Path(record['comm']).name,'role':role}

def run_phase(command,folder,name,timeout,targets=None):
 targets=targets or {}
 baseline,_=processes()
 log=folder/(name+'.log')
 telemetry=folder/(name+'-process-rss.jsonl')
 started=time.monotonic();owned={};peak={};diagnosed=set();exit_reason=None
 with log.open('w') as stream,telemetry.open('w') as monitor:
  process=subprocess.Popen(command,cwd=WORK/'Packages/PreviewKit',stdout=stream,stderr=subprocess.STDOUT,start_new_session=True)
  write(folder/(name+'-driver.json'),{'pid':process.pid,'pgid':process.pid,'started_at':now(),'command':command,'source_manifest':str(WORK/'prepared-source.json'),'destination':DEST,'phase_timeout_seconds':timeout})
  while process.poll() is None:
   snapshot,error=processes()
   records=[]
   for pid,record in snapshot.items():
    role=None
    if pid==process.pid or record['pgid']==process.pid:role='owned-driver-process-group'
    elif targets and pid not in baseline:
     proof=owned.get(pid)
     if proof is None:proof=image_proof(record,targets,baseline)
     if proof and identity(record)==tuple(proof['identity']):owned[pid]=proof;role='owned-native-test-host'
    executable=Path(record['comm']).name
    if role is None and record['uid']==os.getuid() and 'com.apple.WebKit' in (record['comm']+' '+record['args']) and ('CoreSimulator' in record['comm'] or 'simruntime' in record['args']):role='simulator-WebKit-candidate-not-owned'
    if role:
     row=compact(record,role);row['new_since_baseline']=pid not in baseline
     records.append(row);peak[str(pid)]=max(peak.get(str(pid),0),record['rss_kib'])
    if role=='owned-native-test-host' and pid not in diagnosed:
     diagnosed.add(pid)
     diagnostic=limited(['/usr/bin/vmmap','-summary',str(pid)],5)
     write(folder/(name+'-vmmap-'+str(pid)+'.json'),{'pid':pid,'proof':owned[pid],'result':diagnostic,'scope':'Bounded observed physical-footprint summary; not peak allocation attribution'})
    if role=='owned-native-test-host' and record['rss_kib']>2*1024*1024:exit_reason='owned native test host sampled RSS exceeded 2 GiB watchdog'
   monitor.write(json.dumps({'at':now(),'elapsed_seconds':time.monotonic()-started,'records':records,'inventory_error':error})+'\n');monitor.flush()
   if time.monotonic()-started>timeout:exit_reason='owned driver outer deadline'
   if exit_reason:
    # The Popen child remains live/unreaped while its own reserved process group is signalled.
    if process.poll() is None:os.killpg(process.pid,signal.SIGINT)
    try:process.wait(timeout=10)
    except subprocess.TimeoutExpired:
     if process.poll() is None:os.killpg(process.pid,signal.SIGTERM)
     try:process.wait(timeout=5)
     except subprocess.TimeoutExpired:
      if process.poll() is None:os.killpg(process.pid,signal.SIGKILL)
      process.wait(timeout=5)
    break
   time.sleep(1)
  code=process.returncode
 # Never signal a native process merely by name. Reprove exact identity/image before terminal cleanup.
 snapshot,_=processes();cleanup=[]
 for pid,proof in owned.items():
  record=snapshot.get(pid)
  if record and identity(record)==tuple(proof['identity']):
   current=image_proof(record,targets,baseline)
   if current and tuple(current['identity'])==tuple(proof['identity']):
    fresh,_=processes()
    if pid in fresh and identity(fresh[pid])==tuple(proof['identity']):
     try:os.kill(pid,signal.SIGTERM);cleanup.append({'pid':pid,'action':'SIGTERM','proof':current})
     except ProcessLookupError:cleanup.append({'pid':pid,'action':'already-exited','proof':current})
 result={'command':command,'exit_code':code,'watchdog_reason':exit_reason,'effective_exit_code':124 if exit_reason else code,'elapsed_seconds':time.monotonic()-started,'log_path':str(log),'log_sha256':sha(log.read_bytes()),'telemetry_path':str(telemetry),'sampled_peak_rss_kib_by_pid':peak,'owned_native_hosts':owned,'terminal_cleanup':cleanup,'memory_scope':'sampled ps RSS, plus bounded vmmap summary for verified native hosts; helpers have unproven ownership and were never signalled'}
 write(folder/(name+'-phase.json'),result)
 print(name,'exit',result['effective_exit_code'],'owned native hosts',list(owned),'elapsed',round(result['elapsed_seconds'],1),flush=True)
 return result

def execute(mode,diagnostics):
 manifest=json.loads((WORK/'prepared-source.json').read_text())
 before=verify(manifest)
 folder=WORK/'runs'/datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
 folder.mkdir(parents=True)
 write(folder/'before-source-verify.json',before)
 base=['xcodebuild','-scheme','PreviewKit-Package','-configuration','Debug','-sdk','iphonesimulator','-destination','platform=iOS Simulator,id='+DEST,'-derivedDataPath',str(folder/'DerivedData'),'-parallel-testing-enabled','NO','CODE_SIGNING_ALLOWED=NO','CODE_SIGNING_REQUIRED=NO']
 build=run_phase(base+['build-for-testing'],folder,'build',600)
 if build['effective_exit_code']!=0:raise RuntimeError('Build did not pass: '+str(folder))
 verify(manifest)
 targets={}
 for bundle in (folder/'DerivedData/Build/Products').rglob('PreviewKitTests.xctest'):
  info=plistlib.loads((bundle/'Info.plist').read_bytes())
  executable=info['CFBundleExecutable'];targets['/'+bundle.name+'/'+executable]=sha((bundle/executable).read_bytes())
 if not targets:raise RuntimeError('No exact PreviewKitTests bundle image built')
 write(folder/'test-images.json',targets)
 flags=['-resultBundlePath',str(folder/'Results.xcresult'),'-collect-test-diagnostics',diagnostics,'-test-timeouts-enabled','YES','-default-test-execution-time-allowance','60','-maximum-test-execution-time-allowance','120']
 required=manifest['required_full_cases'] if mode=='full' else manifest['hosted_cases']
 selected=['-only-testing:PreviewKitTests'] if mode=='full' else ['-only-testing:PreviewKitTests/'+name for name in required]
 test=run_phase(base+flags+selected+['test-without-building'],folder,'test',600,targets)
 extract=limited(['xcrun','xcresulttool','get','test-results','tests','--path',str(folder/'Results.xcresult'),'--format','json'],30)
 (folder/'test-results.json').write_text(extract['stdout']);write(folder/'extraction.json',{k:v for k,v in extract.items() if k!='stdout'})
 spec=importlib.util.spec_from_file_location('copied_ios_results',WORK/'Scripts/ios/ios-test-results.py')
 module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
 cases=module.executed_tests(json.loads(extract['stdout'])) if extract['exit']==0 else {}
 normalized={'/'.join(name.split('/')[-2:]):value for name,value in cases.items()}
 gate={'expected_count':len(required),'cases':normalized,'missing':sorted(set(required)-set(normalized)),'unexpected':sorted(set(normalized)-set(required)),'not_passed':sorted(n for n in required if normalized.get(n)!='Passed'),'skipped':sorted(n for n,s in normalized.items() if s=='Skipped')}
 gate['passed']=test['effective_exit_code']==0 and extract['exit']==0 and not any(gate[k] for k in ['missing','unexpected','not_passed','skipped']) and len(normalized)==len(required)
 write(folder/'test-gate.json',gate)
 after=verify(manifest);write(folder/'after-source-verify.json',after)
 receipt={'source_manifest_sha256':sha((WORK/'prepared-source.json').read_bytes()),'source_head_at_copy':manifest['source_head'],'source_head_before':before['source_head'],'source_head_after':after['source_head'],'frozen_sha':manifest['frozen_sha'],'destination':DEST,'mode':mode,'diagnostics_policy':diagnostics,'public_runner_diagnostics_policy':'on-failure','diagnostics_differs_from_public_runner':diagnostics!='on-failure','build':build,'test':test,'gate':gate,'scope':'Actual iOS PreviewKit module and WebKit hosted tests; no physical device/production composition/IME/performance acceptance'}
 write(folder/'receipt.json',receipt)
 print('SEALED',str(folder),'gate',gate['passed'],'cases',len(normalized),'skipped',len(gate['skipped']),flush=True)
 return 0 if gate['passed'] else 65

def main():
 parser=argparse.ArgumentParser();parser.add_argument('--prepare',action='store_true');parser.add_argument('--run',choices=['full','hosted']);parser.add_argument('--diagnostics',choices=['on-failure','never'],default='on-failure');parser.add_argument('--lock-held',action='store_true');args=parser.parse_args()
 if args.prepare:prepare();return 0
 if not args.run:parser.error('choose --prepare or --run')
 if not args.lock_held:
  result=subprocess.run(['/usr/bin/lockf','-k','-t','45',LOCK,'python3',str(Path(__file__).resolve()),'--run',args.run,'--diagnostics',args.diagnostics,'--lock-held'])
  return result.returncode
 return execute(args.run,args.diagnostics)
if __name__=='__main__':
 try:sys_exit=main()
 except Exception as error:print('PREVIEW RUN FAILED:',repr(error),flush=True);sys_exit=65
 raise SystemExit(sys_exit)
