# Integrate the iOS production patch against main and retain its preview resources

PR #191 was squashed into main before #209 was squashed into the old #191
branch. Main therefore still had the unavailable C0 entry point. Port only the
single #209 squash patch `e13e2bd3d7ebbeda7bdb016620da4548c229aa61` onto main
`cdb528d4a565cd15e31ddc1b6312b5a45b27236a`; do not merge its divergent history.
The original transplant is `af1d895b37f5db1bdfebf539524dc0bf9e12145f` and has
the same patch-id as #209. Main's Mac code and newer #195 preview bundle remain.

The acceptance manifest inherited #209's older bundle.js digest. Change only
that digest to the bytes already committed on main. Its strict hash check and
preview inventory assertions stay unchanged. A retained pre-change checksum
probe rejects exactly this resource; the corrected full manifest must pass.
No preview source or generated resource is rebuilt or replaced by this adaptation.

Run the current combined source through complete modules/workflows, complete
IOSPreview and an unchanged-source complete repeat, enabled-plan/Mach-O admitted
UI launch smoke, Mac regression/CI and a new unsigned Release IPA. Preserve raw
results and bind each run to its actual head and input fingerprint. The shell
launch case only proves Files/Open; owner Files/iCloud writing and installation
of this new artifact remain separate from pre-composition M0 reports. Recovery
and conflict-copy UI are subsequent independent PRs.

Alternatives: merge the old branch (rejected: reintroduces divergent squash
history); restore the old preview bundle (rejected: loses main's #195 fix);
relax resource assertions (rejected: masks stale integration inputs); reuse
#209's IPA or native results as current-main evidence (rejected: different
source and preview inputs).
