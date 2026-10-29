# The warm-session LRU is one global cache of 8 warm sessions plus every installed document

`docs/window-state-gates.md` §9 splits WD6. On 2026-10-29 the owner chose the recommended
LRU default, and only that half. The cache stays one global LRU: 8 warm sessions, plus
every installed document. Installed documents do not count toward the capacity of 8 and
cannot be evicted. Other protected entries, including a failed or fenced eviction and a
fenced, quarantined, or retired candidate, still count toward capacity and still cannot be
evicted, so a trim that cannot finish may stay over the limit (`agent.md` §5). Do not
subtract the whole protected set from capacity. D1a adds the separate `installedURLs`
input. The residency half (a lazy preview, visible previews always live, and two hidden
previews inside a 30-second grace) and the restated §7.3 budget stay open until G.
Recorded in §9.1.

Alternatives: a per-window LRU was rejected. It costs 8 times N sessions, and a session
warm for two windows would still need one cross-window owner. Counting installed documents
toward the 8, which is what the policy does today, was rejected, because N windows would
leave 8 minus N warm slots. Treating every protected URL as free capacity was rejected,
because a failed eviction would no longer be visible as an over-limit cache.
