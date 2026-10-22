import subprocess,sys
from pathlib import Path
tree,dd,tag=sys.argv[1:]
ev=Path("/private/tmp/plainsong-gutter-slow-evidence")
with (ev/(tag+".log")).open("w") as log:
    subprocess.run(["xcodegen","generate"],cwd=tree,stdout=log,stderr=subprocess.STDOUT,check=True)
    subprocess.run(["/usr/bin/lockf","-k","/private/tmp/plainsong-xcodebuild-test.lock","xcodebuild","-project","Plainsong.xcodeproj","-scheme","Plainsong","-configuration","Debug","-destination","platform=macOS","-derivedDataPath",dd,"SWIFT_OPTIMIZATION_LEVEL=-O","GCC_OPTIMIZATION_LEVEL=s","-parallel-testing-enabled","NO","-skip-testing:PlainsongUITests","-only-testing:PlainsongTests","-only-testing:PerformanceTests","build-for-testing"],cwd=tree,stdout=log,stderr=subprocess.STDOUT,check=True)
print(tag,"BUILD SUCCEEDED",flush=True)
