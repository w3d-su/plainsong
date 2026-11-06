#!/bin/bash
# Shipped Info.plist guard for auto-update.
# PLAINSONG_UPDATES_ENABLED=NO is the U1 default and passes.
# Any other value must have a 32-byte EdDSA key, the expected HTTPS feed,
# and both SURequireSignedFeed and SUVerifyUpdateBeforeExtraction.
# This script never signs. --deep is not used here.
set -euo pipefail

EXPECTED_FEED_URL="https://w3d-su.github.io/plainsong/appcast.xml"

check_plist() {
    python3 - "$1" "$EXPECTED_FEED_URL" << 'PY'
import base64
import plistlib
import sys
from urllib.parse import urlparse

path, expected = sys.argv[1], sys.argv[2]
try:
    with open(path, "rb") as handle:
        info = plistlib.load(handle)
except Exception as error:
    print(f"error: cannot read {path}: {error}", file=sys.stderr)
    sys.exit(1)

enabled = info.get("PLAINSONG_UPDATES_ENABLED")
if enabled == "NO":
    sys.exit(0)

# Sparkle trims with whitespaceAndNewlineCharacterSet before decoding.
# These 26 scalars are that set. Python str.strip() also removes
# U+001C-U+001F, which Foundation keeps and then rejects. U+200B is in
# the Foundation set even though its Unicode category is Cf, not Z.
SPARKLE_WHITESPACE = (
    "\t\n\v\f\r \u0085\u00a0\u1680"
    "\u2000\u2001\u2002\u2003\u2004\u2005\u2006\u2007\u2008\u2009"
    "\u200a\u200b\u2028\u2029\u202f\u205f\u3000"
)

def sparkle_trim(value):
    return value.strip(SPARKLE_WHITESPACE)

def decoded_length(value):
    # Sparkle 2.10.0 decode(): trim ends only, then
    # initWithBase64EncodedString:options:0. Missing padding and interior
    # whitespace are invalid. Do not repair either. Non-zero trailing bits
    # are accepted: NSData options 0 returns the same 32 bytes.
    if not isinstance(value, str):
        return None
    stripped = sparkle_trim(value)
    if not stripped or len(stripped) % 4 != 0:
        return None
    try:
        raw = base64.b64decode(stripped, validate=True)
    except Exception:
        return None
    return len(raw)

def is_yes(value):
    if value is True:
        return True
    if isinstance(value, str) and value.strip().lower() in {"yes", "true", "1"}:
        return True
    return False

errors = []
parsed = urlparse(expected)
if parsed.scheme != "https" or parsed.hostname != "w3d-su.github.io":
    errors.append("expected feed constant must be https on w3d-su.github.io")

key_length = decoded_length(info.get("SUPublicEDKey"))
if key_length != 32:
    errors.append("SUPublicEDKey must be base64 that decodes to 32 bytes")

feed = info.get("SUFeedURL")
# Sparkle strips quotes only. Surrounding whitespace stays and will not parse.
normalized = feed.strip("\"'") if isinstance(feed, str) else None
if normalized != expected:
    errors.append(f"SUFeedURL must be {expected}")

for name in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
    if not is_yes(info.get(name)):
        errors.append(f"{name} must be true")

if errors:
    print(f"error: shipped update configuration in {path} is not releasable", file=sys.stderr)
    for item in errors:
        print(f"error: {item}", file=sys.stderr)
    sys.exit(1)
PY
}

self_test() {
    local tmp name expect failed
    tmp="$(mktemp -d "${TMPDIR:-/tmp}/plainsong-update-plist.XXXXXX")"
    python3 - "$tmp" "$EXPECTED_FEED_URL" << 'PY'
import base64
import os
import plistlib
import sys

root, expected = sys.argv[1], sys.argv[2]
good_key = base64.b64encode(b"\x11" * 32).decode("ascii")
short_key = base64.b64encode(b"\x11" * 31).decode("ascii")

def write(name, payload):
    with open(os.path.join(root, name), "wb") as handle:
        # Binary plists can hold the U+001F case. XML rejects control characters.
        plistlib.dump(payload, handle, fmt=plistlib.FMT_BINARY)

write("disabled.plist", {
    "PLAINSONG_UPDATES_ENABLED": "NO",
    "SUFeedURL": "http://evil.example/appcast.xml",
    "SUPublicEDKey": "not-a-key",
})
write("enabled-ok.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": good_key,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("enabled-empty.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": "",
    "SUPublicEDKey": "",
})
write("short-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": short_key,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("bad-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": "!!!!",
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("http-feed.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": "http://w3d-su.github.io/plainsong/appcast.xml",
    "SUPublicEDKey": good_key,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("wrong-host.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": "https://example.invalid/plainsong/appcast.xml",
    "SUPublicEDKey": good_key,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("missing-verify.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": good_key,
    "SURequireSignedFeed": True,
})
write("missing-flag.plist", {
    "SUFeedURL": expected,
    "SUPublicEDKey": good_key,
})
write("unpadded-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": good_key.rstrip("="),
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("inner-space-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": good_key[:8] + " " + good_key[8:],
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("surrounding-whitespace-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": "\n" + good_key + " ",
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("padded-feed.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": " " + expected + " ",
    "SUPublicEDKey": good_key,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("quoted-feed.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": '"' + expected + '"',
    "SUPublicEDKey": good_key,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("unit-separator-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": good_key + "\x1f",
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
write("zero-width-space-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": "\u200b" + good_key,
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
noncanonical = list(good_key)
noncanonical[42] = "F"
write("nonzero-tail-key.plist", {
    "PLAINSONG_UPDATES_ENABLED": "YES",
    "SUFeedURL": expected,
    "SUPublicEDKey": "".join(noncanonical),
    "SURequireSignedFeed": True,
    "SUVerifyUpdateBeforeExtraction": True,
})
PY
    failed=0
    while IFS=$'\t' read -r name expect; do
        if [[ "$expect" == "pass" ]]; then
            if ! check_plist "$tmp/$name"; then
                echo "error: $name should pass" >&2
                failed=1
            fi
        else
            # Expected failures must not look like a real CI error.
            if check_plist "$tmp/$name" 2>/dev/null; then
                echo "error: $name should fail" >&2
                failed=1
            else
                echo "expected failure: $name"
            fi
        fi
    done << 'CASES'
disabled.plist	pass
enabled-ok.plist	pass
enabled-empty.plist	fail
short-key.plist	fail
bad-key.plist	fail
http-feed.plist	fail
wrong-host.plist	fail
missing-verify.plist	fail
missing-flag.plist	fail
unpadded-key.plist	fail
inner-space-key.plist	fail
surrounding-whitespace-key.plist	pass
padded-feed.plist	fail
quoted-feed.plist	pass
unit-separator-key.plist	fail
zero-width-space-key.plist	pass
nonzero-tail-key.plist	pass
CASES
    rm -rf "$tmp"
    if [[ "$failed" -ne 0 ]]; then
        exit 1
    fi
    echo "shipped update configuration self-test passed"
}

if [[ "${1:-}" == "--self-test" ]]; then
    self_test
    exit 0
fi

if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "usage: $0 <Info.plist> | --self-test" >&2
    exit 2
fi

check_plist "$1"
