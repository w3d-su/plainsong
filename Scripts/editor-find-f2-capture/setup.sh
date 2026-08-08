set -euo pipefail
/usr/bin/umask 077

if [[ "$#" -ne 4 ]]; then
    echo "usage: $0 CONFIGURATION SOURCE_ROOT DERIVED_DATA_PATH OUTPUT_PREFIX" >&2
    exit 2
fi

configuration="$1"
source_root="$2"
derived_data_path="$3"
output_prefix="$4"
source_commit="c871ddf5c66c17f03fd9456b53f79411f9b2e979"
process_filter="xcodebuild|swift-frontend|swiftc|swift-driver|xctest|Plainsong|PlainsongUITests-Runner"
runner="$source_root/Scripts/run-editor-find-f2-performance-gate.sh"
control_directory=""
control_directory_identity=""
monitor_pid=""
run_pid=""
run_active=0
termination_failed=0
done_signal=""
run_timeout_seconds=180
runner_environment_policy="env-i-git-no-replace-home-lang-lc-all-path-tmpdir-user-logname"
process_ownership_rule="runner-ancestry-or-private-output-prefix-correlation"

if [[ "$configuration" != "Debug" && "$configuration" != "Release" ]]; then
    echo "configuration must be Debug or Release, got: $configuration" >&2
    exit 2
fi
if [[ ! -x "$runner" || ! -d "$derived_data_path" ]]; then
    echo "missing exact-source F2 runner or DerivedData" >&2
    exit 2
fi
if [[ "$output_prefix" != /* ]]; then
    echo "F2 output prefix must be absolute" >&2
    exit 2
fi

output_directory="${output_prefix%/*}"
output_basename="${output_prefix##*/}"
allowed_host_executable="$output_prefix.products/Build/Products/$configuration/Plainsong.app/Contents/MacOS/Plainsong"
if [[ -z "$output_directory" || -z "$output_basename" ||
    ! "$output_basename" =~ ^[A-Za-z0-9._-]+$ ||
    "$output_prefix" == *[[:space:]]* ||
    ! -d "$output_directory" || -L "$output_directory" ||
    "$(builtin cd "$output_directory" && /bin/pwd -P)" != "$output_directory" ]]; then
    echo "F2 output prefix must name a simple leaf in a real canonical directory" >&2
    exit 2
fi
output_owner="$(/usr/bin/stat -f '%u' "$output_directory")"
output_mode="$(/usr/bin/stat -f '%Lp' "$output_directory")"
if [[ "$output_owner" != "$(/usr/bin/id -u)" || "$output_mode" != "700" ]] ||
    ! f2_reject_acl_allows "$output_directory"; then
    echo "F2 output directory must be owner-controlled mode 0700" >&2
    exit 2
fi
for exact_directory in "$source_root" "$derived_data_path"; do
    if [[ "$exact_directory" != /* || ! -d "$exact_directory" ||
        "$exact_directory" == *[[:space:]]* ||
        -L "$exact_directory" ||
        "$(builtin cd "$exact_directory" && /bin/pwd -P)" != "$exact_directory" ]]; then
        echo "F2 source/build path is not a real canonical directory: $exact_directory" >&2
        exit 2
    fi
    exact_owner="$(/usr/bin/stat -f '%u' "$exact_directory")"
    exact_mode="$(/usr/bin/stat -f '%Lp' "$exact_directory")"
    if [[ "$exact_owner" != "$(/usr/bin/id -u)" ||
        "$((8#$exact_mode & 8#022))" != "0" ]] ||
        ! f2_reject_acl_allows "$exact_directory" ||
        ! f2_reject_tree_acls "$exact_directory"; then
        echo "F2 source/build path is not owner-controlled: $exact_directory" >&2
        exit 2
    fi
    if [[ "$output_prefix" == "$exact_directory" ||
        "$output_prefix" == "$exact_directory/"* ]]; then
        echo "F2 output prefix overlaps a source/build root" >&2
        exit 2
    fi
done
if [[ "$source_root" == "$derived_data_path" ||
    "$source_root" == "$derived_data_path/"* ||
    "$derived_data_path" == "$source_root/"* ]]; then
    echo "F2 source and DerivedData roots must be disjoint" >&2
    exit 2
fi
runner_user="$(/usr/bin/id -un)"
runner_home="$(
    /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
        /usr/bin/python3 -I -c \
        'import os, pwd; print(pwd.getpwuid(os.getuid()).pw_dir)'
)"
runner_tmpdir="/private/tmp"
if [[ "$runner_home" != /* || "$runner_tmpdir" != /* ||
    ! -d "$runner_home" || ! -d "$runner_tmpdir" ||
    "$runner_home" == *$'\n'* || "$runner_tmpdir" == *$'\n'* ||
    ! "$runner_user" =~ ^[A-Za-z0-9._-]+$ ]]; then
    echo "F2 runner allowlisted environment is invalid" >&2
    exit 2
fi

utc_now() {
    /usr/bin/env -i LANG=C LC_ALL=C PATH=/usr/bin:/bin \
        /usr/bin/python3 -I -c \
        'from datetime import datetime, timezone; print(datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z"))'
}

trusted_git() {
    /usr/bin/env -i \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 \
        LANG=C \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        /usr/bin/git --no-replace-objects "$@"
}

write_digest() {
    local input_path="$1"
    local digest_path="$2"
    local digest
    local byte_count

    if ! digest="$(f2_sha256_file "$input_path")"; then
        return 1
    fi
    if ! byte_count="$(/usr/bin/stat -f '%z' "$input_path")"; then
        return 1
    fi
    {
        printf 'sha256=%s\n' "$digest"
        printf 'bytes=%s\n' "$byte_count"
    } > "$digest_path" || return 1
}
