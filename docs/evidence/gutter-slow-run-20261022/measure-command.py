import sys,subprocess
print("load-before "+subprocess.check_output(["sysctl","-n","vm.loadavg"],text=True).strip(),flush=True)
r=subprocess.run(sys.argv[1:])
print("load-after "+subprocess.check_output(["sysctl","-n","vm.loadavg"],text=True).strip(),flush=True)
sys.exit(r.returncode)
