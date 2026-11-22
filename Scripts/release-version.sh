#!/bin/bash
# Marketing version (CFBundleShortVersionString) for one release build
# (docs/decisions/2026-11-12-release-marketing-version-from-tag.md).
# Scripts/release.sh calls this before it builds, locally and in CI alike.
#
# Prints the version on standard output. The first of these that is set wins:
#
#   PLAINSONG_MARKETING_VERSION  an explicit X.Y.Z
#   a release tag                PLAINSONG_RELEASE_TAG, or GITHUB_REF_NAME when
#                                GITHUB_REF_TYPE is "tag" (a tag run of release.yml)
#   0.1.0                        the project.yml value: dispatch and local runs
#
# A tag is vX.Y.Z or vX.Y.Z-<prerelease>: v1.0.0, v0.9.0-beta.1, v0.1.0-alpha.5.
# X, Y and Z are integers without leading zeros. The prerelease part is letters
# and digits in groups separated by "." or "-". It is not part of the marketing
# version: CFBundleShortVersionString holds three integers, so v0.9.0-beta.1
# and v0.9.0-beta.2 are both 0.9.0 and differ by build number. The suffix stays
# in the tag, the GitHub Release and the download URL, and its hyphen is what
# puts the build on Sparkle's beta channel (release.yml).
#
# A tag that is present and does not match is an error even when
# PLAINSONG_MARKETING_VERSION is set, so a tag run never builds from a bad tag.
#
# Usage:
#   Scripts/release-version.sh
#   Scripts/release-version.sh --self-test
set -euo pipefail

DEFAULT_MARKETING_VERSION="0.1.0"
NUMBER='(0|[1-9][0-9]*)'
VERSION_PATTERN="^$NUMBER\\.$NUMBER\\.$NUMBER\$"
TAG_PATTERN="^v($NUMBER\\.$NUMBER\\.$NUMBER)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?\$"

fail() {
    echo "error: $*" >&2
    exit 1
}

resolve() {
    local explicit="${PLAINSONG_MARKETING_VERSION:-}"
    local tag="${PLAINSONG_RELEASE_TAG:-}"
    if [[ -z "$tag" && "${GITHUB_REF_TYPE:-}" == "tag" ]]; then
        tag="${GITHUB_REF_NAME:-}"
        [[ -n "$tag" ]] || fail "GITHUB_REF_TYPE is tag but GITHUB_REF_NAME is empty"
    fi

    local from_tag=""
    if [[ -n "$tag" ]]; then
        if [[ ! "$tag" =~ $TAG_PATTERN ]]; then
            fail "release tag '$tag' is not vX.Y.Z or vX.Y.Z-<prerelease> (for example v1.0.0 or v0.9.0-beta.1); nothing was built"
        fi
        from_tag="${BASH_REMATCH[1]}"
    fi

    if [[ -n "$explicit" ]]; then
        if [[ ! "$explicit" =~ $VERSION_PATTERN ]]; then
            fail "PLAINSONG_MARKETING_VERSION '$explicit' is not X.Y.Z (three integers, no leading zeros); nothing was built"
        fi
        if [[ -n "$from_tag" && "$from_tag" != "$explicit" ]]; then
            echo "note: PLAINSONG_MARKETING_VERSION $explicit overrides tag $tag ($from_tag)" >&2
        fi
        echo "$explicit"
    elif [[ -n "$from_tag" ]]; then
        echo "note: marketing version $from_tag from tag $tag" >&2
        echo "$from_tag"
    else
        echo "$DEFAULT_MARKETING_VERSION"
    fi
}

self_test() {
    local failed=0 line want explicit tag ref_type ref_name got

    # Each case runs this script with only the four inputs set, so the caller's
    # own environment (a real tag run) cannot change a result.
    run_case() {
        env -i PATH="$PATH" \
            PLAINSONG_MARKETING_VERSION="$1" PLAINSONG_RELEASE_TAG="$2" \
            GITHUB_REF_TYPE="$3" GITHUB_REF_NAME="$4" "$0"
    }

    # want | PLAINSONG_MARKETING_VERSION | PLAINSONG_RELEASE_TAG | GITHUB_REF_TYPE | GITHUB_REF_NAME
    # "fail" in the first column means the case must be refused.
    while IFS='|' read -r want explicit tag ref_type ref_name; do
        [[ -n "$want" ]] || continue
        line="version='$explicit' tag='$tag' ref=$ref_type:'$ref_name'"
        if got="$(run_case "$explicit" "$tag" "$ref_type" "$ref_name" 2> /dev/null)"; then
            if [[ "$want" == "fail" ]]; then
                echo "self-test: $line should be refused, got $got" >&2
                failed=1
            elif [[ "$got" != "$want" ]]; then
                echo "self-test: $line expected $want, got $got" >&2
                failed=1
            fi
        elif [[ "$want" != "fail" ]]; then
            echo "self-test: $line expected $want, was refused" >&2
            failed=1
        fi
    done << 'CASES'
0.1.0||||
0.1.0|||branch|main
0.1.0|||branch|v9.9.9
1.0.0||v1.0.0||
0.9.0||v0.9.0-beta.1||
0.9.0||v0.9.0-beta.12||
0.9.1||v0.9.1-rc.1||
0.1.0||v0.1.0-alpha.5||
10.20.30||v10.20.30||
1.0.0||v1.0.0-rc1||
1.0.0||v1.0.0-beta-2||
1.0.0|||tag|v1.0.0
0.9.0|||tag|v0.9.0-beta.1
0.9.0||v0.9.0-beta.1|tag|v1.0.0
0.9.0||v0.9.0-beta.1|branch|main
2.0.0|2.0.0|||
2.0.0|2.0.0|v0.9.0-beta.1||
2.0.0|2.0.0||tag|v1.0.0
fail||1.0.0||
fail||V1.0.0||
fail||v1.0||
fail||v1||
fail||v1.0.0.0||
fail||v01.0.0||
fail||v1.00.0||
fail||v1.0.0-||
fail||v1.0.0-.1||
fail||v1.0.0-beta.||
fail||v1.0.0-beta..1||
fail||v1.0.0-beta_1||
fail||v1.0.0+5||
fail||v1.0.0 ||
fail|| v1.0.0||
fail||v1.x.0||
fail||v-1.0.0||
fail||vnext||
fail||refs/tags/v1.0.0||
fail||release-1.0.0||
fail|||tag|nightly
fail|||tag|v1.0
fail|||tag|
fail|2.0.0|vnext||
fail|2.0.0||tag|v1.0
fail|1.0||||
fail|v1.0.0||||
fail|1.0.0-beta.1||||
fail|1.0.0.0||||
fail|01.0.0||||
fail|latest|v1.0.0||
CASES

    # A newline cannot hide a bad tail: the pattern is anchored to the whole string.
    if run_case "" $'v1.0.0\nv2' "" "" > /dev/null 2>&1; then
        echo "self-test: a tag with a newline should be refused" >&2
        failed=1
    fi
    # The version is the only thing on standard output; notes go to standard error.
    if [[ "$(run_case "" v0.9.0-beta.1 "" "" 2> /dev/null | wc -l | tr -d ' ')" != 1 ]]; then
        echo "self-test: standard output is not exactly one line" >&2
        failed=1
    fi
    # A refusal names the tag, so the tag run's log says what to fix.
    got="$(run_case "" vnext "" "" 2>&1 || true)"
    if [[ "$got" != *"release tag 'vnext' is not vX.Y.Z"* ]]; then
        echo "self-test: a refused tag is not named in the error" >&2
        failed=1
    fi

    if [[ "$failed" != 0 ]]; then
        exit 1
    fi
    echo "release-version self-test passed"
}

case "${1:-}" in
    --self-test)
        self_test
        ;;
    "")
        resolve
        ;;
    *)
        echo "usage: $0 [--self-test]" >&2
        exit 2
        ;;
esac
