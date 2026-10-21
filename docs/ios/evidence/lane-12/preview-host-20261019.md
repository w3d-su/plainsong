# App-hosted PreviewKit validation

Lane 12 owns `IOSPreviewTestHost`, `IOSPreviewTests`, the serial `IOSPreview`
scheme and the public `make ios-preview` entry. The host links system frameworks
only; the test bundle links PreviewKit and MarkdownCore. All 94 original case
names are required and any skipped case fails admission. This is a test scaffold;
the production C0 providers and owner-device gates remain unchanged.

The coordinator permits one related inventory update in
`EditorReplaceLayeringTests.testNoProjectOrPackageDependencyChange`: add exactly
the two approved targets and the test-to-host dependency. The package/npm pins,
Mac targets, and separate C0 provider-layering assertion remain intact. This
keeps the exact inventory assertion useful after the approved project change;
it does not ignore or dynamically accept additional targets or dependencies.
The architecture decision is recorded by lane 13 in the 2026-10-18 dedicated
app-host row of `docs/decision-log.md` (companion PR #175).

The first CI of the host scaffold (`4f1ccb08ef9ca84b393bbab99968c22b4f77594f`)
failed only this stale inventory pin before hosted tests. Its raw failure is
run [39063148023](https://github.com/w3d-su/plainsong/actions/runs/39063148023).
The updated pin requires a new CI result; that old failure is not a passing
receipt. Native preview proof additionally requires companion #173's tests.

Current execution logs, source manifests and complete xcresults are retained
separately under
`/Users/davis._.su/.codex/visualizations/2026/10/08/01a11aa3-ca4c-7832-aa4e-1a1bf0fbe88d/ios-13-07-completion-20261019/`.
The final review receipt there distinguishes module, tooling, exact-head CI,
and the still-open M0/device/product gates.
