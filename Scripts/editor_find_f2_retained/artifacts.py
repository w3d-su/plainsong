from __future__ import annotations

from .context import (
    GENERATED_SOURCE_SNAPSHOT_ENTRIES,
    Path,
    PurePosixPath,
    hashlib,
    os,
    stat,
    subprocess,
)
from .core import AuditError, require, sha256_file

def update_field(digest: object, value: bytes) -> None:
    digest.update(len(value).to_bytes(8, byteorder="big"))
    digest.update(value)


def update_entry_identity(digest: object, path: Path, relative: str) -> os.stat_result:
    metadata = path.lstat()
    executable = stat.S_IMODE(metadata.st_mode) & 0o111
    update_field(digest, relative.encode("utf-8", errors="surrogateescape"))
    update_field(digest, f"{executable:o}".encode("ascii"))
    return metadata


def hash_artifact_entry(
    digest: object,
    path: Path,
    relative: str,
    exclude_git: bool = False,
) -> None:
    metadata = update_entry_identity(digest, path, relative)
    if stat.S_ISLNK(metadata.st_mode):
        update_field(digest, b"symlink")
        update_field(digest, os.readlink(path).encode("utf-8", errors="surrogateescape"))
    elif stat.S_ISREG(metadata.st_mode):
        update_field(digest, b"file")
        update_field(digest, metadata.st_size.to_bytes(8, byteorder="big"))
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    elif stat.S_ISDIR(metadata.st_mode):
        update_field(digest, b"directory")
        for child in sorted(path.iterdir(), key=lambda item: os.fsencode(item.name)):
            if exclude_git and child.name == ".git":
                continue
            hash_artifact_entry(digest, child, f"{relative}/{child.name}", exclude_git)
    else:
        raise AuditError(f"unsupported artifact entry type: {path}")


def artifact_sha256(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        hash_artifact_entry(digest, path, "artifact")
    except OSError as error:
        raise AuditError(f"could not hash artifact {path}: {error}") from error
    return digest.hexdigest()


def require_artifact_entry_type(path: Path, expected_type: str, label: str) -> None:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AuditError(f"could not inspect {label} at {path}: {error}") from error
    matches = (
        expected_type == "directory" and stat.S_ISDIR(metadata.st_mode)
    ) or (
        expected_type == "file" and stat.S_ISREG(metadata.st_mode)
    )
    require(matches, f"{label} is not a {expected_type}: {path}")


def path_identity(path: Path, label: str) -> tuple[int, int, int, int]:
    try:
        metadata = path.lstat()
    except OSError as error:
        raise AuditError(f"could not identify {label} at {path}: {error}") from error
    require(not stat.S_ISLNK(metadata.st_mode), f"{label} must not be a symlink: {path}")
    return metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_uid


def require_owner_controlled_directory(path: Path, label: str) -> None:
    require_artifact_entry_type(path, "directory", label)
    metadata = path.lstat()
    require(metadata.st_uid == os.getuid(), f"{label} is not owned by the current user")
    require(
        stat.S_IMODE(metadata.st_mode) & 0o022 == 0,
        f"{label} is group/world writable",
    )
    try:
        acl_check = subprocess.run(
            ["/usr/bin/find", str(path), "-maxdepth", "0", "-acl", "-print"],
            capture_output=True,
            check=False,
            timeout=10,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AuditError(f"could not inspect ACL for {label}: {error}") from error
    require(
        acl_check.returncode == 0 and acl_check.stdout == b"",
        f"{label} has an ACL or its ACL could not be inspected",
    )


def require_read_only_tree(root: Path, label: str) -> None:
    try:
        root_metadata = root.lstat()
    except OSError as error:
        raise AuditError(f"could not inspect {label}: {error}") from error
    require(
        stat.S_ISDIR(root_metadata.st_mode),
        f"{label} root is not a directory",
    )
    require(
        root_metadata.st_uid == os.getuid(),
        f"{label} root is not owned by the current user",
    )
    require(
        stat.S_IMODE(root_metadata.st_mode) & 0o222 == 0,
        f"{label} root is writable",
    )

    def walk_error(error: OSError) -> None:
        raise AuditError(f"could not enumerate {label}: {error}")

    for directory, directory_names, file_names in os.walk(
        root,
        followlinks=False,
        onerror=walk_error,
    ):
        for name in directory_names + file_names:
            path = Path(directory) / name
            try:
                metadata = path.lstat()
            except OSError as error:
                raise AuditError(f"could not inspect {label} entry {path}: {error}") from error
            require(
                not stat.S_ISLNK(metadata.st_mode),
                f"{label} contains a symlink: {path}",
            )
            require(
                stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode),
                f"{label} contains an unsupported entry type: {path}",
            )
            require(
                metadata.st_uid == os.getuid(),
                f"{label} contains an entry not owned by the current user: {path}",
            )
            require(
                stat.S_IMODE(metadata.st_mode) & 0o222 == 0,
                f"{label} contains a writable entry: {path}",
            )
    try:
        acl_check = subprocess.run(
            ["/usr/bin/find", str(root), "-acl", "-print"],
            capture_output=True,
            check=False,
            timeout=60,
            env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AuditError(f"could not inspect ACLs for {label}: {error}") from error
    require(
        acl_check.returncode == 0,
        f"could not inspect ACLs for {label}: {acl_check.stderr[:512]!r}",
    )
    require(
        acl_check.stdout == b"",
        f"{label} contains an ACL-bearing entry",
    )


def tree_entries(root: Path, label: str) -> dict[str, tuple[str, int, str]]:
    require_artifact_entry_type(root, "directory", label)
    entries: dict[str, tuple[str, int, str]] = {}

    def visit(directory: Path, prefix: PurePosixPath) -> None:
        try:
            children = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        except OSError as error:
            raise AuditError(f"could not enumerate {label} at {directory}: {error}") from error
        for child in children:
            relative = (prefix / child.name).as_posix()
            try:
                metadata = child.stat(follow_symlinks=False)
            except OSError as error:
                raise AuditError(f"could not inspect {label} entry {relative}: {error}") from error
            executable = stat.S_IMODE(metadata.st_mode) & 0o111
            path = Path(child.path)
            if stat.S_ISDIR(metadata.st_mode):
                entries[relative] = ("directory", executable, "")
                visit(path, prefix / child.name)
            elif stat.S_ISREG(metadata.st_mode):
                entries[relative] = ("file", executable, sha256_file(path))
            elif stat.S_ISLNK(metadata.st_mode):
                entries[relative] = (
                    "symlink",
                    executable,
                    os.readlink(path),
                )
            else:
                raise AuditError(f"unsupported {label} entry type: {relative}")

    visit(root, PurePosixPath())
    return entries


def reject_tree_symlinks(root: Path, label: str) -> None:
    for relative, (kind, _, _) in tree_entries(root, label).items():
        require(kind != "symlink", f"{label} contains forbidden symlink: {relative}")


def validate_generated_source_snapshot(canonical_root: Path, snapshot_root: Path) -> None:
    canonical = tree_entries(canonical_root, "canonical c871 source tree")
    snapshot = tree_entries(snapshot_root, "retained generated source snapshot")
    missing = sorted(set(canonical) - set(snapshot))
    require(not missing, f"generated source snapshot is missing tracked entries: {missing!r}")
    for relative, expected in canonical.items():
        require(
            snapshot[relative] == expected,
            f"generated source snapshot changed tracked bytes/type/mode: {relative}",
        )
    additions = set(snapshot) - set(canonical)
    require(
        additions == set(GENERATED_SOURCE_SNAPSHOT_ENTRIES),
        "generated source snapshot additions differ: "
        f"missing={sorted(set(GENERATED_SOURCE_SNAPSHOT_ENTRIES) - additions)!r} "
        f"unexpected={sorted(additions - set(GENERATED_SOURCE_SNAPSHOT_ENTRIES))!r}",
    )
    for relative, expected_type in GENERATED_SOURCE_SNAPSHOT_ENTRIES.items():
        actual_type, executable, _ = snapshot[relative]
        require(actual_type == expected_type, f"generated source entry type differs: {relative}")
        if expected_type == "file":
            require(executable == 0, f"generated source file is unexpectedly executable: {relative}")


def resolved_package_sha256(path: Path) -> str:
    require_artifact_entry_type(path, "directory", "resolved package input")
    allowed = {"artifacts", "checkouts", "repositories", "workspace-state.json"}
    names = {child.name for child in path.iterdir()}
    require(not names - allowed, f"unexpected resolved package entries: {sorted(names - allowed)!r}")
    checkouts = path / "checkouts"
    artifacts = path / "artifacts"
    state = path / "workspace-state.json"
    require_artifact_entry_type(checkouts, "directory", "resolved package checkouts")
    require_artifact_entry_type(artifacts, "directory", "resolved package artifacts")
    require_artifact_entry_type(state, "file", "resolved package workspace state")
    repositories = path / "repositories"
    if repositories.exists() or repositories.is_symlink():
        require_artifact_entry_type(
            repositories,
            "directory",
            "resolved package repositories",
        )
    digest = hashlib.sha256()
    metadata = update_entry_identity(digest, path, "artifact")
    require(stat.S_ISDIR(metadata.st_mode), "resolved package root is not a directory")
    update_field(digest, b"directory")
    entries = ((artifacts, False), (checkouts, True), (state, False))
    for child, exclude_git in sorted(entries, key=lambda item: os.fsencode(item[0].name)):
        hash_artifact_entry(digest, child, f"artifact/{child.name}", exclude_git)
    return digest.hexdigest()
