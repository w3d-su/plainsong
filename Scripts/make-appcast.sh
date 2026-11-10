#!/bin/bash
# Build the Sparkle appcast for one release (docs/auto-update-plan.md §3.4, U2).
#
# Runs Sparkle's generate_appcast over a feed directory that holds the previous
# appcast.xml, if there is one, and adds the given DMG to it. generate_appcast
# signs the DMG, and signs the feed itself when the app in the DMG sets
# SURequireSignedFeed. Earlier items stay in the feed without their DMGs.
#
# The EdDSA private key is read from the SPARKLE_ED_PRIVATE_KEY environment
# variable and passed on standard input. It is never written to disk, put on a
# command line, or printed.
#
# Usage:
#   SPARKLE_ED_PRIVATE_KEY=... Scripts/make-appcast.sh \
#       --dmg build/release/Plainsong-0.1.0-300-unsigned.dmg \
#       --tag v0.9.0 --feed-dir build/appcast [--channel beta] \
#       [--release-notes notes.md] [--sparkle-bin <dir>]
#
#   Scripts/make-appcast.sh --self-test [--sparkle-bin <dir>]
#
# --sparkle-bin defaults to the Sparkle artifact that `make release` resolves.
# Delta updates are not generated: the release job has only the new DMG.
set -euo pipefail

REPOSITORY_URL="https://github.com/w3d-su/plainsong"
FEED_NAME="appcast.xml"
DEFAULT_SPARKLE_BIN="build/release/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"

fail() {
    echo "error: $*" >&2
    exit 1
}

# Prints the feed's item versions, newest first as generate_appcast wrote them.
feed_versions() {
    python3 - "$1" << 'PY'
import sys
import xml.etree.ElementTree as ET

namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    version = item.find(f"{namespace}version")
    if version is not None and version.text:
        print(version.text.strip())
PY
}

# Prints "<version>\t<channel>\t<enclosure url>" for the item with that version.
feed_item() {
    python3 - "$1" "$2" << 'PY'
import sys
import xml.etree.ElementTree as ET

namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
for item in ET.parse(sys.argv[1]).getroot().iter("item"):
    version = item.find(f"{namespace}version")
    if version is None or (version.text or "").strip() != sys.argv[2]:
        continue
    channel = item.find(f"{namespace}channel")
    enclosure = item.find("enclosure")
    print("\t".join([
        sys.argv[2],
        (channel.text or "").strip() if channel is not None else "",
        enclosure.get("url", "") if enclosure is not None else "",
    ]))
PY
}

# Reads CFBundleVersion and SURequireSignedFeed from the app inside a DMG.
dmg_app_info() {
    local dmg="$1" mount
    mount="$(mktemp -d "${TMPDIR:-/tmp}/plainsong-appcast-mount.XXXXXX")"
    hdiutil attach -quiet -nobrowse -readonly -mountpoint "$mount" "$dmg"
    python3 - "$mount" << 'PY' || { hdiutil detach -quiet "$mount"; rmdir "$mount"; return 1; }
import glob
import plistlib
import sys

apps = glob.glob(f"{sys.argv[1]}/*.app/Contents/Info.plist")
if len(apps) != 1:
    print(f"error: expected one app in the disk image, found {len(apps)}", file=sys.stderr)
    sys.exit(1)
with open(apps[0], "rb") as handle:
    info = plistlib.load(handle)
signed = info.get("SURequireSignedFeed")
signed = signed is True or (isinstance(signed, str) and signed.strip().lower() in {"yes", "true", "1"})
print(f"{info.get('CFBundleVersion', '')}\t{'signed' if signed else 'unsigned'}")
PY
    hdiutil detach -quiet "$mount"
    rmdir "$mount"
}

make_appcast() {
    local dmg="" tag="" feed_dir="" channel="" notes="" sparkle_bin="$DEFAULT_SPARKLE_BIN"
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dmg) dmg="$2"; shift 2 ;;
            --tag) tag="$2"; shift 2 ;;
            --feed-dir) feed_dir="$2"; shift 2 ;;
            --channel) channel="$2"; shift 2 ;;
            --release-notes) notes="$2"; shift 2 ;;
            --sparkle-bin) sparkle_bin="$2"; shift 2 ;;
            *) fail "unknown argument: $1" ;;
        esac
    done
    [[ -n "$dmg" && -n "$tag" && -n "$feed_dir" ]] || fail "--dmg, --tag and --feed-dir are required"
    [[ -f "$dmg" ]] || fail "no disk image at $dmg"
    [[ "$tag" =~ ^v[0-9A-Za-z.+-]+$ ]] || fail "tag must look like v1.2.3: $tag"
    [[ -z "$channel" || "$channel" =~ ^[A-Za-z0-9._-]+$ ]] || fail "invalid channel: $channel"
    [[ -n "${SPARKLE_ED_PRIVATE_KEY:-}" ]] || fail "SPARKLE_ED_PRIVATE_KEY is not set"
    local generate_appcast="$sparkle_bin/generate_appcast" sign_update="$sparkle_bin/sign_update"
    [[ -x "$generate_appcast" && -x "$sign_update" ]] || fail "Sparkle tools not found in $sparkle_bin"

    local info version feed_signing
    info="$(dmg_app_info "$dmg")"
    version="${info%%$'\t'*}"
    feed_signing="${info##*$'\t'}"
    [[ "$version" =~ ^[0-9]+$ ]] || fail "the app's CFBundleVersion is not a number: '$version'"

    mkdir -p "$feed_dir"
    local feed="$feed_dir/$FEED_NAME" previous_versions=""
    if [[ -f "$feed" ]]; then
        previous_versions="$(feed_versions "$feed")"
        # Sparkle never downgrades, so a release older than the feed's newest item
        # is a mistake (a re-run of an old tag), not an update.
        local newest
        newest="$(sort -n <<< "$previous_versions" | tail -1)"
        if [[ -n "$newest" && "$version" -lt "$newest" ]]; then
            fail "build $version is older than the feed's newest build $newest"
        fi
    fi

    local name
    name="$(basename "$dmg")"
    cp "$dmg" "$feed_dir/$name"
    local arguments=(
        --ed-key-file -
        --download-url-prefix "$REPOSITORY_URL/releases/download/$tag/"
        --link "$REPOSITORY_URL/releases/tag/$tag"
        --versions "$version"
        --maximum-deltas 0
        -o "$feed"
    )
    if [[ -n "$channel" ]]; then
        arguments+=(--channel "$channel")
    fi
    if [[ -n "$notes" ]]; then
        [[ -f "$notes" ]] || fail "no release notes at $notes"
        cp "$notes" "$feed_dir/${name%.dmg}.md"
        arguments+=(--embed-release-notes)
    fi

    echo "==> generate_appcast: build $version, tag $tag, channel ${channel:-default}, feed $feed_signing"
    printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$generate_appcast" "${arguments[@]}" "$feed_dir"

    # The feed directory is what gets published: keep only the feed in it.
    rm -f "$feed_dir/$name" "$feed_dir/${name%.dmg}.md"
    rm -rf "$feed_dir/old_updates"

    echo "==> Verify the feed"
    [[ -f "$feed" ]] || fail "generate_appcast wrote no $FEED_NAME"
    local item expected_url
    item="$(feed_item "$feed" "$version")"
    expected_url="$REPOSITORY_URL/releases/download/$tag/$name"
    [[ -n "$item" ]] || fail "the feed has no item for build $version"
    [[ "$(cut -f3 <<< "$item")" == "$expected_url" ]] || fail "the item's download URL is not $expected_url"
    [[ "$(cut -f2 <<< "$item")" == "$channel" ]] || fail "the item's channel is not '${channel}'"
    local earlier
    for earlier in $previous_versions; do
        grep -qx "$earlier" <<< "$(feed_versions "$feed")" || echo "note: build $earlier left the feed (generate_appcast keeps the newest items)"
    done
    if [[ "$feed_signing" == "signed" ]]; then
        printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$sign_update" --verify --ed-key-file - "$feed" \
            || fail "the feed's signature does not verify"
        echo "    feed signature verified"
    else
        echo "    the app does not set SURequireSignedFeed, so the feed is not signed"
    fi
    echo "==> Done: $feed"
}

# Builds a disk image holding a minimal app: enough for generate_appcast, which
# reads the bundle's version, minimum system version and update keys.
self_test_dmg() {
    local root="$1" version="$2" public_key="$3" signed_feed="$4" output="$5"
    local stage="$root/stage-$version"
    mkdir -p "$stage/Plainsong.app/Contents/MacOS"
    cp /usr/bin/true "$stage/Plainsong.app/Contents/MacOS/Plainsong"
    python3 - "$stage/Plainsong.app/Contents/Info.plist" "$version" "$public_key" "$signed_feed" << 'PY'
import plistlib
import sys

path, version, public_key, signed_feed = sys.argv[1:5]
info = {
    "CFBundleIdentifier": "app.plainsong.editor.appcast-self-test",
    "CFBundleExecutable": "Plainsong",
    "CFBundleName": "Plainsong",
    "CFBundlePackageType": "APPL",
    "CFBundleVersion": version,
    "CFBundleShortVersionString": "0.0.0",
    "LSMinimumSystemVersion": "14.0",
    "SUPublicEDKey": public_key,
}
if signed_feed == "signed":
    info["SURequireSignedFeed"] = True
    info["SUVerifyUpdateBeforeExtraction"] = True
with open(path, "wb") as handle:
    plistlib.dump(info, handle)
PY
    codesign --force --sign - "$stage/Plainsong.app" 2> /dev/null
    hdiutil create -quiet -volname Plainsong -srcfolder "$stage" -ov -format UDZO "$output" 2> /dev/null
}

self_test() {
    local sparkle_bin="$DEFAULT_SPARKLE_BIN"
    if [[ "${1:-}" == "--sparkle-bin" ]]; then
        sparkle_bin="$2"
    fi
    [[ -x "$sparkle_bin/generate_appcast" ]] || fail "Sparkle tools not found in $sparkle_bin"

    local root key public_key feed failed=0
    root="$(mktemp -d "${TMPDIR:-/tmp}/plainsong-appcast-test.XXXXXX")"
    # A throwaway key that exists only for this run. Sparkle's private key file
    # is the base64 of the 32-byte Ed25519 seed.
    openssl genpkey -algorithm ed25519 -out "$root/key.pem" 2> /dev/null
    key="$(openssl pkey -in "$root/key.pem" -outform DER | tail -c 32 | base64)"
    public_key="$(openssl pkey -in "$root/key.pem" -pubout -outform DER | tail -c 32 | base64)"
    feed="$root/feed/$FEED_NAME"

    expect() {
        local name="$1" want="$2"
        shift 2
        local got=pass
        if ! SPARKLE_ED_PRIVATE_KEY="$key" "$0" "$@" --sparkle-bin "$sparkle_bin" > "$root/$name.log" 2>&1; then
            got=fail
        fi
        if [[ "$got" != "$want" ]]; then
            echo "self-test: $name expected $want, got $got" >&2
            sed 's/^/    /' "$root/$name.log" >&2
            failed=1
        fi
    }

    self_test_dmg "$root" 300 "$public_key" signed "$root/Plainsong-0.0.0-300-unsigned.dmg"
    self_test_dmg "$root" 301 "$public_key" signed "$root/Plainsong-0.0.0-301-unsigned.dmg"
    self_test_dmg "$root" 299 "$public_key" signed "$root/Plainsong-0.0.0-299-unsigned.dmg"
    self_test_dmg "$root" 400 "$public_key" unsigned "$root/Plainsong-0.0.0-400-unsigned.dmg"
    printf '## Changes\n\n- A change.\n' > "$root/notes.md"

    expect first pass --dmg "$root/Plainsong-0.0.0-300-unsigned.dmg" --tag v0.0.0-beta.1 \
        --feed-dir "$root/feed" --channel beta --release-notes "$root/notes.md"
    expect second pass --dmg "$root/Plainsong-0.0.0-301-unsigned.dmg" --tag v0.0.1 --feed-dir "$root/feed"
    expect older fail --dmg "$root/Plainsong-0.0.0-299-unsigned.dmg" --tag v0.0.0-old --feed-dir "$root/feed"
    expect bad-tag fail --dmg "$root/Plainsong-0.0.0-301-unsigned.dmg" --tag 'v1 2' --feed-dir "$root/other"
    expect unsigned-feed pass --dmg "$root/Plainsong-0.0.0-400-unsigned.dmg" --tag v0.0.2 --feed-dir "$root/plain"

    if [[ "$failed" == 0 ]]; then
        # Both items are in the feed, the first kept its channel and URL without
        # its disk image, and only the feed file is left to publish.
        [[ "$(feed_versions "$feed" | sort -n | tr '\n' ' ')" == "300 301 " ]] \
            || { echo "self-test: feed versions are not 300 and 301" >&2; failed=1; }
        [[ "$(feed_item "$feed" 300)" == $'300\tbeta\thttps://github.com/w3d-su/plainsong/releases/download/v0.0.0-beta.1/Plainsong-0.0.0-300-unsigned.dmg' ]] \
            || { echo "self-test: build 300's item changed" >&2; failed=1; }
        [[ "$(feed_item "$feed" 301)" == $'301\t\thttps://github.com/w3d-su/plainsong/releases/download/v0.0.1/Plainsong-0.0.0-301-unsigned.dmg' ]] \
            || { echo "self-test: build 301's item is wrong" >&2; failed=1; }
        grep -q 'A change' "$feed" || { echo "self-test: release notes are not embedded" >&2; failed=1; }
        [[ "$(ls "$root/feed")" == "$FEED_NAME" ]] \
            || { echo "self-test: the feed directory holds more than the feed" >&2; failed=1; }
        grep -q 'sparkle-signatures' "$root/plain/$FEED_NAME" \
            && { echo "self-test: a feed for an app without SURequireSignedFeed was signed" >&2; failed=1; }
        # A changed feed must stop verifying.
        sed -i '' 's/<sparkle:version>301</<sparkle:version>302</' "$feed"
        if printf '%s' "$key" | "$sparkle_bin/sign_update" --verify --ed-key-file - "$feed" > /dev/null 2>&1; then
            echo "self-test: a tampered feed still verifies" >&2
            failed=1
        fi
        # The key must not reach any log.
        if grep -rqF "$key" "$root"/*.log; then
            echo "self-test: the private key was printed" >&2
            failed=1
        fi
    fi

    rm -rf "$root"
    if [[ "$failed" != 0 ]]; then
        exit 1
    fi
    echo "make-appcast self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
    shift
    self_test "$@"
else
    make_appcast "$@"
fi
