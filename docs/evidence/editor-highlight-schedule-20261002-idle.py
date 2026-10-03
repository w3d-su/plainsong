import subprocess,sys,time,json,os
from pathlib import Path
# Example roots: /private/tmp/plainsong-highlight-baseline,
# /Users/davis._.su/Documents/plainsong-highlight-schedule-fix,
# /private/tmp/plainsong-replace-wysiwyg. All roots must be supplied explicitly.
lock=os.environ.get('PLAINSONG_XCODEBUILD_LOCK',str(Path(os.environ.get('TMPDIR') or '/tmp')/'plainsong-xcodebuild-test.lock'))
Path(lock).parent.mkdir(parents=True,exist_ok=True)
root_vars={'main':'PLAINSONG_BASELINE_ROOT','fix':'PLAINSONG_FIX_ROOT','stack':'PLAINSONG_STACK_ROOT'}
missing=[v for v in root_vars.values() if not os.environ.get(v)]
if missing:
 print('Missing worktree environment variables: '+', '.join(missing),file=sys.stderr); sys.exit(2)
roots={k:os.environ[v] for k,v in root_vars.items()}
baseline_sha=subprocess.check_output(['git','rev-parse','HEAD'],cwd=roots['main'],text=True).strip()
print('BASELINE_HEAD '+baseline_sha,flush=True)
filters=['-only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget','-only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget']
if len(sys.argv)>1 and sys.argv[1]=='batch':
 name,iteration,action=sys.argv[2:]
 load=subprocess.check_output(['sysctl','-n','vm.loadavg'],text=True).strip()
 processes=subprocess.check_output(['ps','-axo','comm'],text=True).splitlines()
 if os.getloadavg()[0]>=3 or any(p.endswith('/xcodebuild') for p in processes):
  print('NOT_IDLE '+load,flush=True); sys.exit(75)
 log=Path('/private/tmp/review-idle-'+name+'-'+iteration+'-'+action+'.log')
 with log.open('w') as f:
  f.write('BASELINE_HEAD '+baseline_sha+'\n')
  f.write('PRODUCT_HEAD '+subprocess.check_output(['git','rev-parse','HEAD'],cwd=roots[name],text=True).strip()+'\n')
  f.write('SYSCTL_LOAD_START '+load+'\n'); f.flush()
  cmd=['env','TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE=1','xcodebuild','-project','Plainsong.xcodeproj','-scheme','Plainsong','-configuration','Debug','-destination','platform=macOS',action]
  if action=='test-without-building': cmd+=filters
  result=subprocess.run(cmd,cwd=roots[name],stdout=f,stderr=subprocess.STDOUT)
  f.write('\nSYSCTL_LOAD_END '+subprocess.check_output(['sysctl','-n','vm.loadavg'],text=True).strip()+'\nEXIT '+str(result.returncode)+'\n')
 print(str(log)+' exit='+str(result.returncode),flush=True)
 sys.exit(result.returncode)
# Each batch rechecks load *after* nonblocking lock acquisition. Wait at most five minutes
# for a qualifying slot; never turn a loaded run into idle evidence.
def run(name,iteration,action):
 deadline=time.monotonic()+300
 while True:
  code=subprocess.run(['lockf','-k','-t','0',lock,sys.executable,__file__,'batch',name,str(iteration),action]).returncode
  if code==0 or code==65:return code
  if code not in (1,75):sys.exit(code)
  if time.monotonic()>=deadline:
   print('idle measurement still pending',flush=True); sys.exit(75)
  time.sleep(30)
for product in ['main','fix','stack']:
 run(product,0,'build-for-testing')
for comparison in ['fix','stack']:
 for i in range(1,4):
  run('main',comparison+'-'+str(i),'test-without-building')
  run(comparison,comparison+'-'+str(i),'test-without-building')
