# `make release` strips the shipped executable and keeps the dSYM as a private CI artifact

`Scripts/release.sh` ran `xcodebuild … clean build` with no deployment postprocessing, so the
DMG shipped the full symbol table: 32.2 MiB of the universal executable, 14 MiB of which is
symbols that a separate dSYM already carries. The script now passes
`PLAINSONG_STRIP_SHIPPED_BINARY=YES`, and `project.yml` maps that switch to
`DEPLOYMENT_POSTPROCESSING=YES`, `STRIP_INSTALLED_PRODUCT=YES` and `STRIP_STYLE=all` on the
app target's Release configuration. Xcode then does what an archive does: it writes the dSYM
from the linked binary, strips, and signs last, so the signature covers the stripped bytes
on both the ad-hoc and Developer ID paths. The script refuses to package unless the dSYM's
per-architecture UUIDs equal the executable's, and zips the dSYM next to the DMG.
`release.yml` uploads that zip as a workflow artifact on every run and never as a Release
asset; the release upload names the DMG and its checksum explicitly. Measured on the
unsigned path: executable 32.2 → 18.3 MiB, app 37.4 → 23.5 MiB, DMG 12.1 → 9.4 MiB, dSYM zip
17.1 MiB. The stripped app launched, and `atos` with the zipped dSYM resolved a live stack
frame that the stripped binary shows as `???`.

Alternatives: passing the three `STRIP_*`/postprocessing settings on the `xcodebuild`
command line (tried first; command-line settings reach every SwiftPM target, Xcode tried to
strip the packages' object files, and the build failed); setting them unconditionally on the
Release configuration (rejected: the Release perf harness and the F2/E9 scripts link test
bundles against the app, which needs its symbols); a post-build `strip -rSTx` (rejected: it
saves only 0.3 MiB more and invalidates Xcode's signature, so the script would have to
re-sign with the right entitlements, hardened runtime and timestamp itself); publishing the
dSYM as a Release asset (rejected: symbols are for the maintainer's crash symbolication, not
for downloaders); not keeping the dSYM (rejected: crash reports from a stripped build would
be unreadable). Workflow artifacts expire after 90 days, so the maintainer downloads the dSYM
of any build that is published.
