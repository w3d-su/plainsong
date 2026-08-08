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

f2_verify_module "editor-find-f2-runner/setup.sh" "4f5ee56e7314963103f40f60379cfc0e54b0e54c5df2e34b7a0ca1003e91d62e"
f2_verify_module "editor-find-f2-runner/build-integrity.sh" "b910cc6d6e2b8e7020d5e23a138f7d23f016f874fbf3ad88c4f921a11a3781ae"
f2_verify_module "editor-find-f2-runner/capture-integrity.sh" "d208a3a0ef886483bba79df1d99bdf5f44bf84392217ca915fa7f0b08443ca83"
f2_verify_module "editor-find-f2-runner/inspection.sh" "12921ec63354a5ee5be3073040eb82eebd9444483892d3b5b876cc812b1ded14"

builtin source "$f2_script_directory/editor-find-f2-runner/setup.sh"
builtin source "$f2_script_directory/editor-find-f2-runner/build-integrity.sh"
builtin source "$f2_script_directory/editor-find-f2-runner/capture-integrity.sh"
builtin source "$f2_script_directory/editor-find-f2-runner/inspection.sh"
