import os, subprocess, json, sys, time
from pathlib import Path
root=Path("/Users/davis._.su/.codex/worktrees/gutter-slow-run-probe/blogeditor")
ev=Path("/private/tmp/plainsong-gutter-slow-evidence")
def run(tag, ln, chunks="", hidden="0", dd="/private/tmp/plainsong-gutter-slow-dd", tree=root):
    env=os.environ.copy()
    env.update(TEST_RUNNER_PLAINSONG_RUN_SCROLL_PROBE="1", TEST_RUNNER_PLAINSONG_RUN_HOSTED_TYPING_GATE="1", TEST_RUNNER_PLAINSONG_SCROLL_PROBE_LINE_NUMBERS=str(ln), TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_CHUNKS=str(chunks), TEST_RUNNER_PLAINSONG_SCROLL_PROBE_HIDE_GUTTER_DRAW=str(hidden))
    args=["/usr/bin/lockf","-k","/private/tmp/plainsong-xcodebuild-test.lock","xcodebuild","-project","Plainsong.xcodeproj","-scheme","Plainsong","-configuration","Debug","-destination","platform=macOS","-derivedDataPath",dd,"-parallel-testing-enabled","NO","-skip-testing:PlainsongUITests","-only-testing:PlainsongTests/EditorFindHostedGateTests/testHostedSourceOnlyTypingMainThreadBusySlices","test-without-building"]
    args=args[:3]+[sys.executable,str(ev/"measure-command.py")]+args[3:]
    path=ev/(tag+".log")
    before=subprocess.check_output(["sysctl","-n","vm.loadavg"],text=True).strip()
    with path.open("w") as f:
        f.write("load-before "+before+"\n"); f.flush()
        r=subprocess.run(args,cwd=tree,env=env,stdout=f,stderr=subprocess.STDOUT)
        after=subprocess.check_output(["sysctl","-n","vm.loadavg"],text=True).strip()
        f.write("load-after "+after+"\nexit "+str(r.returncode)+"\n")
    lines=path.read_text().splitlines()
    files=[l.split(": ",1)[1] for l in lines if l.startswith("TypingProbeReportFile: ")]
    reports=[]
    for l in lines:
        if l.startswith("Source-only typing"):
            try: reports.append(json.loads(l[l.index("{"):]))
            except ValueError: pass
    d=json.loads(Path(files[-1]).read_text()) if files else (reports[-1] if reports else {})
    loads=[l.split(" ",1)[1] for l in lines if l.startswith("load-before ") or l.startswith("load-after ")]
    if len(loads)>=4: before,after=loads[1],loads[-2]
    if r.returncode != 0 or not d:
        raise RuntimeError(f"{tag}: probe failed or produced no report ({r.returncode})")
    if len(d.get("insertMilliseconds", [])) != 50:
        raise RuntimeError(f"{tag}: expected exactly50 native insertions")
    if env.get("TEST_RUNNER_PLAINSONG_SCROLL_PROBE_USE_PRODUCTION_TRIM") == "1" and not d.get("useProductionTrim"):
        raise RuntimeError(f"{tag}: binary did not execute production trim mode")
    if env.get("TEST_RUNNER_PLAINSONG_SCROLL_PROBE_USE_ADMISSION") == "1" and not d.get("useAdmission"):
        raise RuntimeError(f"{tag}: binary did not execute live admission mode")
    split=env.get("TEST_RUNNER_PLAINSONG_SCROLL_PROBE_TRIM_SCROLL_AFTER", "-1")
    if int(split) >= 0 and d.get("trimScrollAfter") != int(split):
        raise RuntimeError(f"{tag}: binary did not execute requested trim/scroll split")
    if env.get("TEST_RUNNER_PLAINSONG_SCROLL_PROBE_PARAGRAPH_TRACE") == "1" and len(d.get("paragraphRequests", [])) != 50:
        raise RuntimeError(f"{tag}: paragraph trace incomplete")
    if d:
        ins=d.get("insertMilliseconds",[])
        print(tag, "busy",round(d["totalBusyMilliseconds"]),"insert",round(sum(ins)),"draw",round(d.get("gutterDrawMilliseconds",0)),"height",d.get("editorHeightBeforeTyping"),"trim",d.get("trimmedBeforeTyping"),"geom",json.dumps(d.get("geometryBeforeTyping")),"load",before,after,flush=True)
        (ev/(tag+".json")).write_text(json.dumps({"tag":tag,"exit":r.returncode,"loadBefore":before,"loadAfter":after,"report":d},indent=2))
    else: print(tag,"FAIL",r.returncode,flush=True)
    return d
if __name__=="__main__":
    for i in range(1,4):
        for tag,ln,chunks,hidden in [("natural-on",1,"","0"),("top30-on",1,30,"0"),("top30-hidden",1,30,"1"),("top30-off",0,30,"0")]:
            run(f"{tag}-{i}",ln,chunks,hidden)
