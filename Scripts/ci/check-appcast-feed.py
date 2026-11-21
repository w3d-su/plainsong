#!/usr/bin/env python3
"""Checks a release's appcast.xml before the publish workflow pushes it.

The new feed must name this tag's download, that download must carry an EdDSA
signature, every download must come from this repository's releases, and in
every channel of the published feed the newest build must be at least the
published one. A release's feed is built from the feed that was published when
its tag ran, so a feed built before an earlier release was published lacks that
release. Publishing it would hide that release from its channel's users: a
beta-only feed over a stable item leaves stable users with no update.

This checks that the signature is present, not that it verifies: the signing
step (Scripts/make-appcast.sh) verifies it with Sparkle's tools on macOS.

Usage: check-appcast-feed.py <new appcast> <published appcast> <tag> <owner/repository>
"""
import os
import sys
import xml.etree.ElementTree as ET

if len(sys.argv) != 5:
    sys.exit(__doc__)
new_path, current_path, tag, repository = sys.argv[1:5]
namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"

def items(path):
    found = []
    for item in ET.parse(path).getroot().iter("item"):
        version = item.find(f"{namespace}version")
        channel = item.find(f"{namespace}channel")
        enclosure = item.find("enclosure")
        found.append((
            int(version.text.strip()),
            enclosure.get("url", "") if enclosure is not None else "",
            (channel.text or "").strip() if channel is not None else "",
            (enclosure.get(f"{namespace}edSignature", "") if enclosure is not None else "").strip(),
        ))
    return found

def newest_by_channel(found):
    newest = {}
    for version, _, channel, _ in found:
        newest[channel] = max(version, newest.get(channel, version))
    return newest

new = items(new_path)
if not new:
    sys.exit("error: the release's appcast.xml has no items")
prefix = f"https://github.com/{repository}/releases/download/{tag}/"
released = [item for item in new if item[1].startswith(prefix)]
if not released:
    sys.exit(f"error: no item downloads from {prefix}")
for version, url, _, signature in released:
    if not signature:
        sys.exit(f"error: the download for build {version} has no sparkle:edSignature: {url}")
for _, url, _, _ in new:
    if not url.startswith(f"https://github.com/{repository}/releases/download/"):
        sys.exit(f"error: an item downloads from outside this repository's releases: {url}")
current = items(current_path) if os.path.exists(current_path) else []
if current:
    newest_new = max(item[0] for item in new)
    newest_published = max(item[0] for item in current)
    if newest_new < newest_published:
        sys.exit(
            f"error: the published feed already has build {newest_published}, and this "
            f"release's feed stops at build {newest_new}. An older release cannot be "
            "added behind a newer one: tag a new release."
        )
    new_newest = newest_by_channel(new)
    for channel, published in sorted(newest_by_channel(current).items()):
        if new_newest.get(channel, -1) < published:
            name = channel or "default"
            have = f"stops at build {new_newest[channel]}" if channel in new_newest else "has no item"
            sys.exit(
                f"error: the published feed has build {published} in the {name} channel, "
                f"and this release's feed {have} in that channel. It was built before "
                f"that build's feed was published. Re-run the Release workflow for {tag} "
                "to rebuild its feed from the published one."
            )
print(f"feed ok: builds {sorted(item[0] for item in new)}")
