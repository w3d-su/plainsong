#!/bin/bash -p

set -euo pipefail
/usr/bin/umask 077

if [[ "$-" != *p* ]]; then
    echo "F2 tooling entry point requires privileged Bash mode" >&2
    echo "invoke the absolute path directly or use /bin/bash -p" >&2
    exit 2
fi

f2_wrapper_source="${BASH_SOURCE[0]}"
if [[ "$f2_wrapper_source" != /* || -L "$f2_wrapper_source" ||
    ! -f "$f2_wrapper_source" ]]; then
    echo "F2 tooling entry point must be an absolute regular non-symlink" >&2
    exit 2
fi
f2_script_directory="$(
    builtin cd "$(/usr/bin/dirname "$f2_wrapper_source")" && /bin/pwd -P
)"
if [[ "$f2_wrapper_source" != "$f2_script_directory/${f2_wrapper_source##*/}" ||
    -L "$f2_script_directory" ]]; then
    echo "F2 tooling directory must be canonical" >&2
    exit 2
fi
readonly f2_script_directory

f2_reject_acl_allows() {
    local acl_listing

    if ! acl_listing="$(LC_ALL=C /bin/ls -lde "$1")"; then
        return 1
    fi
    [[ "$acl_listing" != *$'\n'*" allow "* ]]
}

f2_reject_tree_acls() {
    local acl_entry

    if ! acl_entry="$(/usr/bin/find "$1" -acl -print -quit)"; then
        return 1
    fi
    [[ -z "$acl_entry" ]]
}

f2_wrapper_owner="$(/usr/bin/stat -f '%u' "$f2_wrapper_source")"
f2_wrapper_mode="$(/usr/bin/stat -f '%Lp' "$f2_wrapper_source")"
f2_directory_owner="$(/usr/bin/stat -f '%u' "$f2_script_directory")"
f2_directory_mode="$(/usr/bin/stat -f '%Lp' "$f2_script_directory")"
if [[ "$f2_wrapper_owner" != "$(/usr/bin/id -u)" ||
    "$f2_directory_owner" != "$(/usr/bin/id -u)" ||
    "$((8#$f2_wrapper_mode & 8#022))" != "0" ||
    "$((8#$f2_directory_mode & 8#022))" != "0" ]] ||
    ! f2_reject_acl_allows "$f2_wrapper_source" ||
    ! f2_reject_acl_allows "$f2_script_directory"; then
    echo "F2 tooling entry point and directory must be owner-controlled" >&2
    exit 2
fi

f2_sha256_file() {
    /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
        /usr/bin/python3 -I -S -c \
        'import hashlib, sys
digest = hashlib.sha256()
with open(sys.argv[1], "rb") as stream:
    for chunk in iter(lambda: stream.read(1024 * 1024), b""):
        digest.update(chunk)
print(digest.hexdigest())' "$1"
}

f2_verify_module() {
    local relative="$1"
    local expected_digest="$2"
    local path="$f2_script_directory/$relative"
    local module_directory="${path%/*}"
    local actual_digest
    local directory_mode
    local directory_owner
    local owner
    local mode

    if [[ "$relative" == /* || "$relative" == *".."* ||
        ! -f "$path" || -L "$path" || -L "$module_directory" ||
        "$(builtin cd "$module_directory" && /bin/pwd -P)" != "$module_directory" ]]; then
        echo "invalid F2 tooling module: $relative" >&2
        exit 2
    fi
    directory_owner="$(/usr/bin/stat -f '%u' "$module_directory")"
    directory_mode="$(/usr/bin/stat -f '%Lp' "$module_directory")"
    owner="$(/usr/bin/stat -f '%u' "$path")"
    mode="$(/usr/bin/stat -f '%Lp' "$path")"
    if [[ "$directory_owner" != "$(/usr/bin/id -u)" ||
        "$owner" != "$(/usr/bin/id -u)" ||
        "$((8#$directory_mode & 8#022))" != "0" ||
        "$((8#$mode & 8#022))" != "0" ]] ||
        ! f2_reject_acl_allows "$module_directory" ||
        ! f2_reject_acl_allows "$path"; then
        echo "F2 tooling module is not owner-controlled: $relative" >&2
        exit 2
    fi
    actual_digest="$(f2_sha256_file "$path")"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        echo "F2 tooling module hash mismatch: $relative" >&2
        exit 2
    fi
}

f2_verify_module "editor-find-f2-capture/setup.sh" "c4affbe6021c07def1ba31d326971bb4a64ee2ff948ad52d94f5b365d2d02b57"
f2_verify_module "editor-find-f2-capture/processes.sh" "4f1f1efe0a79e22859f330236093277131e4ff64d1579aa30578105a235e64a3"
f2_verify_module "editor-find-f2-capture/monitor.sh" "9e6c30a8d19d86935f1fff726829085fe41e230df89b925248fa149e5a128a6e"
f2_verify_module "editor-find-f2-capture/preflight.sh" "0794f86bbd541c403aa772dea6e4600d730eed5466f3218ce27841a9ea390c1e"
f2_verify_module "editor-find-f2-capture/monitor-loop.sh" "2bd622239433c0b97ad07e0f6617c46b13d8b912ccecd61cea96975d12a33ad7"
f2_verify_module "editor-find-f2-capture/run-session.sh" "4e1decb2484d3219a7ff2159d936f0345ddf700217490affa446b7891ea0aa7a"
f2_verify_module "editor-find-f2-capture/finalize.sh" "72aef87b9abc8dc6b4183e165c50125897df378b04d7ba801bbae9a5268b2755"

builtin source "$f2_script_directory/editor-find-f2-capture/setup.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/processes.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/monitor.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/preflight.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/monitor-loop.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/run-session.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/finalize.sh"
