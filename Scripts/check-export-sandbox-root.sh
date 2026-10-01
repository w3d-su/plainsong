#!/bin/bash
# Compile the production AppState resolver into a signed app-sandbox process, and exercise
# production Foundation staging/containment without granting access to the user's home leaf.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
package="$repository/Packages/WorkspaceKit"
swift test --package-path "$package" --filter ExportArtifactWriterTests
build_path="$(swift build --package-path "$package" --show-bin-path)"
probe_build="$(mktemp -d "${TMPDIR:-/tmp}/plainsong-export-sandbox-probe.XXXXXX")"
trap 'rm -rf "$probe_build"' EXIT
bundle="$probe_build/PlainsongExportRootProbe.app"
mkdir -p "$bundle/Contents/MacOS"
objects=()
for module in WorkspaceKit MarkdownCore Yams CYaml; do
    if [[ -f "$build_path/$module.o" ]]; then
        objects+=("$build_path/$module.o")
    else
        module_build="$build_path/$module.build"
        [[ -d "$module_build" ]] || { echo "Missing build directory for $module" >&2; exit 1; }
        count_before=${#objects[@]}
        # Native SwiftPM preserves C source subdirectories (for example CYaml.build/src/*.o).
        while IFS= read -r -d '' object; do
            objects+=("$object")
        done < <(/usr/bin/find "$module_build" -type f -name '*.o' -print0)
        [[ ${#objects[@]} -gt $count_before ]] || { echo "Missing built objects for $module" >&2; exit 1; }
    fi
done
swiftc -I "$build_path" -I "$build_path/Modules" \
    -I "$package/.build/checkouts/Yams/Sources/CYaml/include" \
    "$repository/App/AppState+ExportAppPrivateRoot.swift" \
    "$repository/Scripts/export-sandbox-root-probe/ExportSandboxRootProbe.swift" \
    "${objects[@]}" -o "$bundle/Contents/MacOS/PlainsongExportRootProbe"
cat > "$bundle/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>app.plainsong.export-root-probe</string><key>CFBundleExecutable</key><string>PlainsongExportRootProbe</string><key>CFBundlePackageType</key><string>APPL</string></dict></plist>
PLIST
codesign --force --sign - --entitlements "$repository/App/Plainsong.entitlements" "$bundle"
codesign -d --entitlements :- "$bundle"
"$bundle/Contents/MacOS/PlainsongExportRootProbe"
