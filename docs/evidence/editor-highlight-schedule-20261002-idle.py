import subprocess,sys,time,json,os
from pathlib import Path
lock='/private/tmp/claude-501/-Users-davis---su-Documents-blogeditor/50f4130b-7177-4f95-827c-f97a63ad8e24/scratchpad/plainsong-xcodebuild-test.lock'
roots={'main':'/private/tmp/plainsong-highlight-baseline','fix':'/Users/davis._.su/Documents/plainsong-highlight-schedule-fix','stack':'/private/tmp/plainsong-replace-wysiwyg'}
filters=['-only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureSourceOnlyTypingStaysUnderBudget','-only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedLargeFixtureWYSIWYGTypingStaysUnderBudget']
if len(sys.argv)>1 and sys.argv[1]=='batch':
 name,iteration,action=sys.argv[2:]
 load=subprocess.check_output(['sysctl','-n','vm.loadavg'],text=True).strip()
 processes=subprocess.check_output(['ps','-axo','comm'],text=True).splitlines()
 if os.getloadavg()[0]>=3 or any(p.endswith('/xcodebuild') for p in processes):
  print('NOT_IDLE '+load,flush=True); sys.exit(75)
 log=Path('/private/tmp/review-idle-'+name+'-'+iteration+'-'+action+'.log')
 with log.open('w') as f:
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
run('main',0,'build-for-testing')
for comparison in ['fix','stack']:
 for i in range(1,4):
  run('main',comparison+'-'+str(i),'test-without-building')
  run(comparison,comparison+'-'+str(i),'test-without-building')
