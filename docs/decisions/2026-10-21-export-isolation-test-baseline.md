# Establish a settled visible-preview baseline before testing offscreen export isolation

Main integration CI run 39540297936 observed scroll899 versus baseline900 at the
existing0.5-point assertion in the E0 offscreen-isolation test. The fixture and
preview JS had not changed from main. Waiting only for scrollY>0 did not establish
that resources, viewport geometry and queued scroll/reflow observations had settled.
The individual historical cause of that one-pixel observation remains unproven.

Before the baseline, require loaded fonts/images and three consecutive equal
viewport/root/scroll/theme signatures inside the existing5-second bounded wait.
Keep the original post-capture0.5-point, HTML, theme, first-responder and render-ID
assertions. This changes test setup only; production export/scroll code and the
iOS8-second/2-second gates are unchanged.

The fixed case passed five separate native executions. A controlled64-point
visible-scroll mutation during export failed the exact original assertion with
one named failed case and xcodebuild65. Restoring the byte-identical sources passed
the complete7-case E0 class. Sources,908 input hashes, patch, raw logs and complete
results are retained. These controls prove retained mutation detection and stronger
setup; they do not certify a platform root cause.

Alternatives: increasing the0.5-point tolerance would weaken the invariant; a blind
sleep or retry-until-green would not establish readiness; resetting the visible
scroll after export would hide the defect the test must detect. Removing the case
or changing production scroll behavior without a reproduced production cause was
rejected.
