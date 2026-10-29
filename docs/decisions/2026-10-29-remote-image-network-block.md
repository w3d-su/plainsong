# Block remote preview loads when Allow Remote Images is off

**Date:** 2026-10-29
**Status:** Accepted

## Decision

The live preview's Allow Remote Images switch is enforced by a WebKit content rule, not
only by the JavaScript that rewrites `<img src>`. The rules are compiled once per process
through `WKContentRuleListStore` and reused. They are not compiled on the typing path.

While the switch is off, the installed list is:

```json
[
  {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
  {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}}
]
```

A single filter `^(https?|wss?)://` failed to compile on this machine. WebKit reported
`Disjunctions are not supported yet`. `?` is accepted, so `ws:`/`wss:` is a second trigger.

While it is on, that list is replaced by one other list. The replacement blocks every
`http:`/`https:` and `ws:`/`wss:` load and then ignores that block for `https:` resources
whose type is `image`. `ignore-previous-rules` applies only inside the list that contains
it, so the exception cannot be a second list installed beside the block. Switching adds
the next list before removing the previous one and does not reload the page. Both lists
together still block, so the overlap fails closed. The existing JavaScript image policy
stays as the second layer.

Store identifiers are a prefix plus the first 12 hex characters of the rule source's
SHA-256, so a changed rule cannot reuse a previously compiled list. The first compilation
also deletes every other stored `plainsong-` identifier, except the two current hashes
and any identifier a test has marked in use. A later source change therefore does not
leave the previous hash behind.

If the blocking list fails to compile, the preview page is not loaded and the failure is
reported (`IOSPreviewEvent.contentRuleUnavailable`, a macOS preview-pane message, and an
iOS alert). That failure is not cached. The controller that saw it tries once more on
the next turn of the main queue, and once more when another document is shown. It does
not compile on every keystroke. If only the https-image list fails, the switch is treated
as off and the blocking list stays installed. Export uses the blocking list for the
controller's whole life, never installs the exception, and refuses
`setAllowsRemoteImages(true)` at the JavaScript layer too.
That replaces the export-only identifier `plainsong-export-no-http-v1` from
`2026-10-22-preview-webview-lifecycle.md`; the block action is the same, and the filter
now also matches `ws:`/`wss:`.

The rule blocks remote script, style, font, fetch, and navigation in both states.
CSP on the `file://` page is not that defense: with no content rule, the probe still
recorded `GET` for remote script, font, and stylesheet. Every preview and export
`WKWebView` has to be created by `PreviewController`, which installs the blocking list
before the page loads. A later print or Quick Look web view cannot rely on the CSP meta
element. Link clicks are still `preventDefault` plus the `linkClicked` bridge message,
so external opening does not depend on the web view navigating.

## Why this shape

The static CSP has always included `img-src https:`. The JavaScript rewriter only sees
`<img src>`, and it runs after a detached parse so those tags do not fetch early. Anything
else the document loads — CSS `url()`, `srcset`, `<picture><source>`, an SVG image's
`<image href>`, or future user CSS — could still request `https:` while the switch was
off. User CSS is not shipped yet. This is the network backstop that has to exist before
it does, and it closes the hole for the loads the preview can already produce.

Two `index.html` files with different CSP policies would also close the hole, but only by
reloading the page and resubmitting the latest render. That drops the live DOM, Mermaid
output, and scroll position on every toggle. The content-rule swap does not.

A stricter CSP meta element inserted by script also suppressed loads without a reload in
the macOS 27 probe. That is not the mechanism. A policy delivered after the document has
started is not a portable contract, and it was not measured on any other OS.

## What was measured

The comparison ran on this machine only: macOS 27.0 (26A428). No macOS 14 installation or
virtual machine was available, so this record does not claim a macOS 14 result.

A local HTTPS server with a self-signed certificate counted accepted connections and, once
the probe's navigation delegate accepted that server trust, the HTTP request line. The
system trust store was not modified. The page was loaded with `loadFileURL` from
`file:///tmp/remote-image-probe/page.html` and carried the production CSP meta. It was
not served by the HTTPS counter. Each load had its own port. `window.__marker` and
`WKNavigationDelegate` finish count detected reloads.

The CSP-only row is that file URL with no content rule. On this WebKit it still recorded
`GET` for the remote script, font, and stylesheet. `fetch` and the `http:` image made no
connection, which matches `default-src 'none'` and `img-src` without `http:`. That row is
not evidence that `script-src 'self'`, `font-src 'self'`, or `style-src 'self'` blocked
those loads. The content rule is what stopped them.

| Setup | img, srcset, picture, CSS background | script, font, stylesheet | fetch, http image | SVG-as-image `<image href>` | Page reload |
|---|---|---|---|---|---|
| CSP only, no content rule | `GET` each | `GET` each | no connection | no connection | — |
| Block list | no connection | no connection | no connection | no connection | — |
| Combined https-image list | `GET` each | no connection | no connection | no connection | — |
| Swap block to combined, then back | same as the installed list | no connection | no connection | no connection | no (`__marker` stayed 42, one finish, same URL) |
| Block list plus a separate ignore-only list | no connection | no connection | no connection | no connection | — |
| Second HTML document | — | — | — | — | yes (finish count 1 to 2, marker replaced) |

The first blocking compile took about 13 ms after a cold probe process; the next two
lists returned in under 1 ms. That cost sits on the first preview controller, not on a
keystroke.

SVG-as-image made no nested request even with no content rule, so the probe did not
observe the rule blocking a load WebKit never started. An inline `<svg><image href>` in
the document is different: the hosted test sees it as an image request. The https-image
list allows it, and the block list does not. `http:` images were already silent under CSP
alone (`img-src` has no `http:`). The allow list's exception is `https` only, so an
`http:` image still matches the block, but the probe did not separate that from CSP.

Automated tests use the existing loopback CONNECT proxy and distinct `.invalid` hosts.
They prove which hosts are contacted and that the tunnel is refused. They do not complete
TLS. The completed `GET` lines above are from the probe, not from those tests.

## Alternatives

| Alternative | Why not |
|---|---|
| Two preview documents and a reload (approach b) | Measured reload. It would discard preview state and resend the render on every toggle. Kept only as the behavior this decision rejects |
| Leave enforcement to the `<img>` rewriter | Does not see CSS, `srcset`, `<picture>`, or future user CSS |
| Stack a block list and an ignore-previous-rules list | Measured: the second list does not undo the first. Images stayed blocked |
| Remove `https:` from the static CSP | A content rule cannot grant a load CSP forbids, so turning the switch on could not show https images |
| Change the bridge | The preference already arrives as `allowRemoteImages`. The rule swap is native |
