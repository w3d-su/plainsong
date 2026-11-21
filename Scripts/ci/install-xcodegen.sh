#!/bin/bash
# Installs the pinned XcodeGen release on a GitHub macOS runner.
#
# `brew install xcodegen` takes whatever Homebrew serves that day, so the
# project a release is built from could change without a commit. This downloads
# one release, refuses it unless the SHA-256 matches, and puts it on PATH for
# the following steps. Bump the version and the digest together.
set -euo pipefail

XCODEGEN_VERSION="2.48.0"
XCODEGEN_SHA256="620c9f0dc10849f94728ab5df52d225ebab8187439dd6fee1925e59e80dff892"

install_dir="${RUNNER_TEMP:?RUNNER_TEMP is not set}/xcodegen-$XCODEGEN_VERSION"
rm -rf "$install_dir"
mkdir -p "$install_dir"
curl -fsSL --retry 3 -o "$install_dir/xcodegen.zip" \
    "https://github.com/yonaskolb/XcodeGen/releases/download/$XCODEGEN_VERSION/xcodegen.zip"
echo "$XCODEGEN_SHA256  $install_dir/xcodegen.zip" | shasum -a 256 -c -
# The binary reads its setting presets from ../share/xcodegen, so keep the tree.
unzip -oq "$install_dir/xcodegen.zip" -d "$install_dir"
actual="$("$install_dir/xcodegen/bin/xcodegen" --version)"
if [[ "$actual" != "Version: $XCODEGEN_VERSION" ]]; then
    echo "pinned xcodegen $XCODEGEN_VERSION but the binary reports: $actual" >&2
    exit 1
fi
echo "$install_dir/xcodegen/bin" >> "${GITHUB_PATH:?GITHUB_PATH is not set}"
echo "xcodegen: $XCODEGEN_VERSION (pinned)"
