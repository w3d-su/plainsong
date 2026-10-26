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
source_fixture = pathlib.Path(__file__).resolve().parent.parent / 'Fixtures' / 'm0.md'
if source_fixture.is_symlink() or not source_fixture.is_file():
    raise SystemExit('M0 source fixture is missing or not a regular file: Fixtures/m0.md')
expected_fixture_bytes = source_fixture.read_bytes()
bundled_fixture = app / 'm0.md'
if bundled_fixture.is_symlink() or not bundled_fixture.is_file():
    raise SystemExit('M0 bundled fixture is missing or not a regular file: m0.md')
if bundled_fixture.read_bytes() != expected_fixture_bytes:
    raise SystemExit('M0 bundled fixture byte mismatch: m0.md differs from the source fixture')
fixture_member = f'Payload/{app.name}/m0.md'
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
    if fixture_member not in archive.namelist():
        raise SystemExit('M0 archive fixture is missing: ' + fixture_member)
    if archive.read(fixture_member) != expected_fixture_bytes:
        raise SystemExit('M0 archive fixture byte mismatch: ' + fixture_member)
receipt = dict(artifact=output.name, sha256=hashlib.sha256(output.read_bytes()).hexdigest(),
    architectures=architectures, minimum_os=info['MinimumOSVersion'], device_family=info['UIDeviceFamily'],
    unsigned=True, owner_resign_install_gate='OPEN', fixture_member=fixture_member,
    fixture_sha256=hashlib.sha256(expected_fixture_bytes).hexdigest(),
    fixture_bytes=len(expected_fixture_bytes))
output.with_suffix('.json').write_text(json.dumps(receipt, indent=2) + '\n')
print(json.dumps(receipt, indent=2))
