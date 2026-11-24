#!/bin/bash
# Generates Plainsong.xcodeproj and installs the committed package pins.
#
# The generated project is not committed, so without this every `xcodegen
# generate` leaves Xcode to resolve the package graph again: Yams floats from
# 6.2.2, a version tag can be moved, and the packages STTextView and
# swift-tree-sitter depend on are not named here at all. The repository's
# Package.resolved records the revision of every package. It is copied to where
# Xcode reads it, and the release, archive and hosted-test builds pass
# -onlyUsePackageVersionsFromResolvedFile, which fails instead of resolving
# anything the file does not pin.
#
# After a deliberate dependency change: `make generate`, resolve in Xcode (or
# `xcodebuild -resolvePackageDependencies -project Plainsong.xcodeproj`), and
# copy Plainsong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
# back to the repository root in the same commit.
#
# Usage: generate-project.sh [repository root]
set -euo pipefail

root="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$root"
[[ -s Package.resolved ]] || { echo "error: $root/Package.resolved is missing: the package pins are not committed" >&2; exit 1; }
xcodegen generate
destination="Plainsong.xcodeproj/project.xcworkspace/xcshareddata/swiftpm"
mkdir -p "$destination"
cp Package.resolved "$destination/Package.resolved"
