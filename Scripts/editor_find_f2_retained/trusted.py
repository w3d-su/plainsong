from __future__ import annotations

from .artifacts import (
    artifact_sha256,
    path_identity,
    reject_tree_symlinks,
    require_artifact_entry_type,
    resolved_package_sha256,
    validate_generated_source_snapshot,
)
from .context import (
    SOURCE_ARCHIVE_SHA256,
    SOURCE_TREE_SHA256,
    TRUSTED_COMMAND_TIMEOUT_SECONDS,
    XCRESULTTOOL_TIMEOUT_SECONDS,
    Path,
    PurePosixPath,
    os,
    pwd,
    re,
    shutil,
    stat,
    subprocess,
    tempfile,
)
from .core import AuditError, loads_json, require, safe_relative_path, sha256_file
from .logs import validate_summary

def sanitized_subprocess_environment() -> dict[str, str]:
    account = pwd.getpwuid(os.getuid())
    require(
        account.pw_dir.startswith("/")
        and "\n" not in account.pw_dir
        and re.fullmatch(r"[A-Za-z0-9._-]+", account.pw_name) is not None,
        "local account identity is not safe for the audit subprocess environment",
    )
    return {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "HOME": account.pw_dir,
        "LANG": "C",
        "LC_ALL": "C",
        "LOGNAME": account.pw_name,
        "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
        "TMPDIR": "/private/tmp",
        "USER": account.pw_name,
    }


def run_trusted_command(command: list[str], label: str) -> bytes:
    try:
        completed = subprocess.run(
            command,
            check=False,
            capture_output=True,
            env=sanitized_subprocess_environment(),
            timeout=TRUSTED_COMMAND_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as error:
        raise AuditError(
            f"{label} timed out after {TRUSTED_COMMAND_TIMEOUT_SECONDS} seconds"
        ) from error
    require(
        completed.returncode == 0,
        f"{label} failed with status {completed.returncode}: "
        f"{completed.stderr.decode('utf-8', errors='replace').strip()}",
    )
    return completed.stdout


def verify_source_archive_commit(
    archive_path: Path,
    source_snapshot_path: Path,
    expected_archive_sha256: str,
    expected_source_tree_sha256: str,
) -> None:
    require(
        expected_archive_sha256 == SOURCE_ARCHIVE_SHA256,
        "recorded source archive is not the frozen c871 archive",
    )
    require(
        expected_source_tree_sha256 == SOURCE_TREE_SHA256,
        "recorded source tree is not the frozen c871 tree",
    )
    require(
        sha256_file(archive_path) == SOURCE_ARCHIVE_SHA256,
        "retained source archive differs from the frozen c871 archive",
    )
    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-source-audit.",
        dir="/private/tmp",
    ) as temporary:
        temporary_root = Path(temporary)
        extracted = temporary_root / "source"
        extracted.mkdir()
        run_trusted_command(
            ["/usr/bin/tar", "-xf", str(archive_path), "-C", str(extracted)],
            "source commit archive extraction",
        )
        require(
            artifact_sha256(extracted) == SOURCE_TREE_SHA256,
            "retained pre-generation source tree is not the frozen c871 tree",
        )
        validate_generated_source_snapshot(extracted, source_snapshot_path)


def resolve_artifact_path(root: Path, relative: str, label: str) -> Path:
    safe_relative_path(relative, label)
    candidate = root
    parts = PurePosixPath(relative).parts
    for index, part in enumerate(parts):
        candidate = candidate / part
        try:
            metadata = candidate.lstat()
        except OSError as error:
            raise AuditError(f"could not resolve {label} component {part!r}: {error}") from error
        require(not stat.S_ISLNK(metadata.st_mode), f"{label} contains a symlink component")
        if index != len(parts) - 1:
            require(stat.S_ISDIR(metadata.st_mode), f"{label} parent component is not a directory")
    return candidate


def hash_full_artifact(path: Path, hash_mode: str) -> str:
    if hash_mode == "file-sha256":
        return sha256_file(path)
    if hash_mode == "artifact-sha256":
        return artifact_sha256(path)
    require(
        hash_mode == "resolved-package-input-sha256",
        f"unknown full-artifact hash mode: {hash_mode}",
    )
    return resolved_package_sha256(path)


def copy_artifact_snapshot(
    source: Path,
    destination: Path,
    expected_type: str,
    hash_mode: str,
) -> None:
    require_artifact_entry_type(source, expected_type, "full artifact source")
    if hash_mode == "resolved-package-input-sha256":
        destination.mkdir()
        shutil.copytree(source / "artifacts", destination / "artifacts", symlinks=True)
        shutil.copytree(
            source / "checkouts",
            destination / "checkouts",
            symlinks=True,
            ignore=lambda _directory, names: {".git"} & set(names),
        )
        shutil.copyfile(
            source / "workspace-state.json",
            destination / "workspace-state.json",
            follow_symlinks=False,
        )
    elif expected_type == "file":
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination, follow_symlinks=False)
    else:
        shutil.copytree(source, destination, symlinks=True)
    require_artifact_entry_type(destination, expected_type, "private full-artifact snapshot")
    if expected_type == "directory":
        make_tree_owner_writable(destination)
    else:
        os.chmod(destination, destination.stat().st_mode | stat.S_IWUSR)


def make_tree_owner_writable(root: Path) -> None:
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        for name in directory_names + file_names:
            path = Path(directory) / name
            if not path.is_symlink():
                os.chmod(path, path.stat().st_mode | stat.S_IWUSR)
    os.chmod(root, root.stat().st_mode | stat.S_IWUSR)


def inspect_full_xcresult(
    xcresult_path: Path,
    expected_sha256: str,
    retained_summary: object,
    environment: dict,
    run_id: str,
) -> None:
    reject_tree_symlinks(xcresult_path, f"{run_id} raw xcresult")
    original_before = artifact_sha256(xcresult_path)
    require(original_before == expected_sha256, f"{run_id}: xcresult changed before fresh inspection")
    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-xcresult-audit.",
        dir="/private/tmp",
    ) as temporary:
        copy = Path(temporary) / "Result.xcresult"
        shutil.copytree(xcresult_path, copy, symlinks=True)
        reject_tree_symlinks(copy, f"{run_id} fresh xcresult copy")
        make_tree_owner_writable(copy)
        require(artifact_sha256(copy) == expected_sha256, f"{run_id}: fresh xcresult copy differs")
        xcresulttool_path = resolve_current_xcresulttool(environment)
        tool_identity = path_identity(xcresulttool_path, "current xcresulttool")
        require(
            resolve_current_xcresulttool(environment) == xcresulttool_path,
            f"{run_id}: xcresulttool identity changed immediately before invocation",
        )
        try:
            completed = subprocess.run(
                [
                    str(xcresulttool_path),
                    "get",
                    "test-results",
                    "summary",
                    "--compact",
                    "--path",
                    str(copy),
                ],
                check=False,
                capture_output=True,
                env=sanitized_subprocess_environment(),
                timeout=XCRESULTTOOL_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired as error:
            raise AuditError(
                f"{run_id}: xcresulttool timed out after "
                f"{XCRESULTTOOL_TIMEOUT_SECONDS} seconds"
            ) from error
        require(
            path_identity(xcresulttool_path, "post-invocation xcresulttool") == tool_identity
            and sha256_file(xcresulttool_path) == environment["xcresulttoolSHA256"]
            and resolve_current_xcresulttool(environment) == xcresulttool_path,
            f"{run_id}: xcresulttool identity changed across invocation",
        )
        require(
            completed.returncode == 0,
            f"{run_id}: xcresulttool failed on fresh copy: "
            f"{completed.stderr.decode('utf-8', errors='replace').strip()}",
        )
        live_summary = loads_json(completed.stdout, f"{run_id} fresh xcresult summary")
        validate_summary(live_summary, environment, f"{run_id} fresh xcresult summary")
        require(live_summary == retained_summary, f"{run_id}: retained summary differs from fresh xcresult")
    require(artifact_sha256(xcresult_path) == expected_sha256, f"{run_id}: source xcresult was mutated")


def resolve_current_xcresulttool(environment: dict) -> Path:
    selected_data = run_trusted_command(
        ["/usr/bin/xcode-select", "-p"],
        "current xcode-select lookup",
    )
    tool_data = run_trusted_command(
        ["/usr/bin/xcrun", "--find", "xcresulttool"],
        "current xcresulttool lookup",
    )
    try:
        selected = selected_data.decode("utf-8", errors="strict").rstrip("\n")
        tool = tool_data.decode("utf-8", errors="strict").rstrip("\n")
    except UnicodeDecodeError as error:
        raise AuditError(f"current Xcode tool lookup is not UTF-8: {error}") from error
    require("\n" not in selected and selected != "", "current xcode-select returned multiple/empty paths")
    require("\n" not in tool and tool != "", "current xcrun returned multiple/empty paths")
    require(
        selected == environment["selectedDeveloperDir"],
        "current xcode-select developer directory differs from recorded evidence",
    )
    require(
        tool == environment["xcresulttoolPath"],
        "current xcrun xcresulttool path differs from recorded evidence",
    )
    tool_path = Path(tool)
    require(
        tool_path.is_absolute(),
        "current xcrun xcresulttool is not an absolute regular-file path",
    )
    require_artifact_entry_type(tool_path, "file", "current xcrun xcresulttool")
    require(
        sha256_file(tool_path) == environment["xcresulttoolSHA256"],
        "current xcrun xcresulttool digest differs from recorded evidence",
    )
    return tool_path
