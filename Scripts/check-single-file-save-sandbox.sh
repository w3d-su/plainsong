#!/bin/bash
# Compile the production WorkspaceKit save path into a signed app-sandbox process, hand it one
# Markdown file through LaunchServices (a file-only grant, as Finder "Open With" or the Open
# panel gives), and require durable saves without any new entry in the document's folder.
set -euo pipefail
repository="$(cd "$(dirname "$0")/.." && pwd)"
package="$repository/Packages/WorkspaceKit"
swift build --package-path "$package"
build_path="$(swift build --package-path "$package" --show-bin-path)"
work="$(mktemp -d "${TMPDIR:-/tmp}/plainsong-single-file-save-probe.XXXXXX")"
bundle="$work/PlainsongSingleFileSaveProbe.app"
bundle_id="app.plainsong.single-file-save-probe"
cleanup() {
    pkill -f "$bundle/Contents/MacOS/" 2>/dev/null || true
    rm -rf "$work"
}
trap cleanup EXIT
mkdir -p "$bundle/Contents/MacOS"
objects=()
for module in WorkspaceKit MarkdownCore Yams CYaml; do
    if [[ -f "$build_path/$module.o" ]]; then
        objects+=("$build_path/$module.o")
    else
        module_build="$build_path/$module.build"
        [[ -d "$module_build" ]] || { echo "Missing build directory for $module" >&2; exit 1; }
        count_before=${#objects[@]}
        while IFS= read -r -d '' object; do
            objects+=("$object")
        done < <(/usr/bin/find "$module_build" -type f -name '*.o' -print0)
        [[ ${#objects[@]} -gt $count_before ]] || { echo "Missing built objects for $module" >&2; exit 1; }
    fi
done
swiftc -parse-as-library -I "$build_path" -I "$build_path/Modules" \
    -I "$package/.build/checkouts/Yams/Sources/CYaml/include" \
    "$repository/Scripts/single-file-save-sandbox-probe/SingleFileSaveSandboxProbe.swift" \
    "${objects[@]}" -o "$bundle/Contents/MacOS/PlainsongSingleFileSaveProbe"
cat > "$bundle/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>$bundle_id</string>
<key>CFBundleExecutable</key><string>PlainsongSingleFileSaveProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
<key>CFBundleDocumentTypes</key><array><dict>
<key>CFBundleTypeRole</key><string>Editor</string>
<key>LSHandlerRank</key><string>None</string>
<key>LSItemContentTypes</key><array><string>net.daringfireball.markdown</string><string>public.plain-text</string></array>
</dict></array>
</dict></plist>
PLIST
codesign --force --sign - --entitlements "$repository/App/Plainsong.entitlements" "$bundle"
codesign -d --entitlements :- "$bundle" 2>/dev/null | grep -q com.apple.security.app-sandbox

# The document lives outside the probe's container, so the LaunchServices grant is its only access.
document_folder="$work/documents"
mkdir -p "$document_folder"
document="$document_folder/post.md"
printf '# Original\n' > "$document"
output="$work/probe.out"
open -W -n -g -a "$bundle" --stdout "$output" --stderr "$output" "$document" &
open_pid=$!
for _ in $(seq 1 90); do
    kill -0 "$open_pid" 2>/dev/null || break
    sleep 1
done
if kill -0 "$open_pid" 2>/dev/null; then
    kill "$open_pid" 2>/dev/null || true
    cat "$output" 2>/dev/null || true
    echo "FAIL: the sandbox probe did not finish within 90 seconds" >&2
    exit 1
fi
wait "$open_pid" || true
cat "$output"
grep -q '^PASS:' "$output" || { echo "FAIL: the sandbox probe did not pass" >&2; exit 1; }

[[ "$(cat "$document")" == "# Saved 2" ]] || { echo "FAIL: unexpected saved bytes" >&2; exit 1; }
leftovers="$(/usr/bin/find "$document_folder" -mindepth 1 ! -name post.md -print)"
[[ -z "$leftovers" ]] || { echo "FAIL: the save left entries beside the document: $leftovers" >&2; exit 1; }
staging_root="$HOME/Library/Containers/$bundle_id/Data/tmp/TemporaryItems"
if [[ -d "$staging_root" ]]; then
    staged="$(/usr/bin/find "$staging_root" -mindepth 1 -name 'NSIRD_*' -print)"
    [[ -z "$staged" ]] || { echo "FAIL: staging directories were not removed: $staged" >&2; exit 1; }
fi
echo "PASS: sandboxed single-file save"
