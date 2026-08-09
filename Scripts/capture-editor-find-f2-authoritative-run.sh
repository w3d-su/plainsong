#!/bin/bash -p

set -euo pipefail
builtin umask 077

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

    acl_listing="$(LC_ALL=C /bin/ls -lde "$1")" || return
    [[ "$acl_listing" != *$'\n'*" allow " ]]
}

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

f2_require_owner_controlled_path() {
    local path="$1"
    local kind="$2"
    local metadata_mode

    [[ "$path" == /* && ! -L "$path" ]] || return 1
    if [[ "$kind" == file ]]; then
        [[ -f "$path" ]] || return 1
    else
        [[ -d "$path" && "$(builtin cd "$path" && /bin/pwd -P)" == "$path" ]] ||
            return 1
    fi
    metadata_mode="$(/usr/bin/stat -f '%Lp' "$path")" || return
    [[ "$(/usr/bin/stat -f '%u' "$path")" == "$(/usr/bin/id -u)" &&
        "$((8#$metadata_mode & 8#022))" == 0 ]] || return 1
    f2_reject_acl_allows "$path"
}

if ! f2_require_owner_controlled_path "$f2_wrapper_source" file ||
    ! f2_require_owner_controlled_path "$f2_script_directory" directory; then
    echo "F2 tooling entry point and directory must be owner-controlled" >&2
    exit 2
fi

f2_verify_module() {
    local relative="$1"
    local expected_digest="$2"
    local path="$f2_script_directory/$relative"
    local module_directory="${path%/*}"
    local actual_digest

    if [[ "$relative" == /* || "$relative" == *".."* ||
        "$module_directory" == "$f2_script_directory" ||
        ! -d "$module_directory" || -L "$module_directory" ||
        "$(builtin cd "$module_directory" && /bin/pwd -P)" != "$module_directory" ]] ||
        ! f2_require_owner_controlled_path "$module_directory" directory ||
        ! f2_require_owner_controlled_path "$path" file; then
        echo "invalid or uncontrolled F2 tooling module: $relative" >&2
        exit 2
    fi
    actual_digest="$(f2_sha256_file "$path")"
    if [[ "$actual_digest" != "$expected_digest" ]]; then
        echo "F2 tooling module hash mismatch: $relative" >&2
        exit 2
    fi
}

f2_verify_module "editor-find-f2-capture/common.sh" "e8a41b63d2b1fb4042aff7412cdacf7be2e19fd2c1b8e0cf3ac5c656a7d9ad7e"
f2_verify_module "editor-find-f2-capture/processes.sh" "196f82193a08fafd3b530a81c1795d63e950a31cc2c1647f3a6183c073ef9098"
f2_verify_module "editor-find-f2-capture/monitor.sh" "755249f0798091a7fb4c857bd619894754b3ec21bf59385a6bc856094e6f15b4"
f2_verify_module "editor-find-f2-capture/run.sh" "528eb4519cb8aca241a8d8544411c67529294266d2c9996e6c199e1bed0dcd9d"
f2_verify_module "editor-find-f2-capture/session_status.py" "3cff713e0bf7385eaa355b0f116e142bf7a76736007294d20fb3c21a45ef33e5"
f2_verify_module "editor-find-f2-evidence/schema.json" "156177ae6c047e7f1295381c557c440263dcac63d48a3fbaf01dd69d4bcb3d56"
f2_verify_module "editor-find-f2-evidence/schema_check.py" "ffacce11ab1fdaac1dd2a328900d2eb98794650801eb028363f9de444b6f93f4"

builtin source "$f2_script_directory/editor-find-f2-capture/common.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/processes.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/monitor.sh"
builtin source "$f2_script_directory/editor-find-f2-capture/run.sh"

f2_capture_main "$@"
