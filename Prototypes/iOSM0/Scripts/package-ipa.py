#!/usr/bin/env python3
"""Package an unsigned arm64 application; never sign or handle credentials."""
import hashlib
import json
import pathlib
import plistlib
import subprocess
import sys
import zipfile

app, output = map(pathlib.Path, sys.argv[1:])
assert app.is_dir() and app.suffix == '.app'
info = plistlib.loads((app / 'Info.plist').read_bytes())
executable = app / info['CFBundleExecutable']
architectures = subprocess.check_output(['lipo', '-archs', str(executable)], text=True).strip()
assert architectures == 'arm64', architectures
assert float(info['MinimumOSVersion']) >= 26
assert info['UIDeviceFamily'] == [1, 2]
signature = subprocess.run(['codesign', '--verify', str(app)], capture_output=True, text=True)
assert signature.returncode != 0 and 'not signed at all' in signature.stderr, signature.stderr
assert not (app / '_CodeSignature').exists()
assert not (app / 'embedded.mobileprovision').exists()
with zipfile.ZipFile(output, 'w', zipfile.ZIP_DEFLATED) as archive:
    for file in sorted(app.rglob('*')):
        assert not file.is_symlink(), f'Unexpected symlink: {file.name}'
        if file.is_file():
            archive.write(file, pathlib.Path('Payload') / app.name / file.relative_to(app))
with zipfile.ZipFile(output) as archive:
    assert archive.testzip() is None
    expected = f'Payload/{app.name}/{info["CFBundleExecutable"]}'
    assert expected in archive.namelist()
receipt = dict(artifact=output.name, sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
    architectures=architectures, minimum_os=info['MinimumOSVersion'], device_family=info['UIDeviceFamily'],
    unsigned=True, owner_resign_install_gate='OPEN')
output.with_suffix('.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
