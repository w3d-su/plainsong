from __future__ import annotations

from .context import (
    XCRESULTTOOL,
    XCRESULTTOOL_SHA256,
    Path,
    atexit,
    ctypes,
    hashlib,
    json,
    os,
    pwd,
    re,
    shutil,
    stat,
    subprocess,
    tempfile,
)


AT_FDCWD = -2
RENAME_EXCL = 0x00000004
_STAGED_OUTPUTS: dict[Path, tuple[Path, int, int]] = {}


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def require_no_acl(path: Path, label: str) -> None:
    try:
        result = subprocess.run(
            ["/usr/bin/find", str(path), "-maxdepth", "0", "-acl", "-print"],
            check=False,
            capture_output=True,
            timeout=10,
            env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"could not inspect ACL for {label} {path}: {error}") from error
    require(result.returncode == 0, f"could not inspect ACL for {label}: {result.stderr!r}")
    require(result.stdout == b"", f"{label} has an ACL: {path}")


def canonical_directory(path: Path, label: str) -> Path:
    require(path.is_absolute(), f"{label} must be absolute: {path}")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise RuntimeError(f"could not inspect {label} {path}: {error}") from error
    require(resolved == path, f"{label} must be canonical without symlinks: {path}")
    require(stat.S_ISDIR(metadata.st_mode), f"{label} is not a directory: {path}")
    require(metadata.st_uid == os.getuid(), f"{label} is not owned by this user: {path}")
    require(metadata.st_mode & 0o022 == 0, f"{label} is group/world writable: {path}")
    require_no_acl(path, label)
    return path


def canonical_file(path: Path, label: str) -> Path:
    require(path.is_absolute(), f"{label} must be absolute: {path}")
    try:
        resolved = path.resolve(strict=True)
        metadata = path.lstat()
    except OSError as error:
        raise RuntimeError(f"could not inspect {label} {path}: {error}") from error
    require(resolved == path, f"{label} must be canonical without symlinks: {path}")
    require(stat.S_ISREG(metadata.st_mode), f"{label} is not a regular file: {path}")
    require(metadata.st_uid == os.getuid(), f"{label} is not owned by this user: {path}")
    require(metadata.st_mode & 0o022 == 0, f"{label} is group/world writable: {path}")
    require_no_acl(path, label)
    return path


def paths_overlap(left: Path, right: Path) -> bool:
    return left == right or left in right.parents or right in left.parents


def cleanup_staged_output(path: Path) -> None:
    record = _STAGED_OUTPUTS.pop(path, None)
    if record is None or not path.exists() or path.is_symlink():
        return
    _, expected_device, expected_inode = record
    metadata = path.lstat()
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.getuid()
        or metadata.st_dev != expected_device
        or metadata.st_ino != expected_inode
    ):
        return
    shutil.rmtree(path)


def output_directory(path: Path, disjoint_from: tuple[Path, ...]) -> Path:
    require(path.is_absolute(), f"output must be absolute: {path}")
    require(
        re.fullmatch(r"[A-Za-z0-9._-]+", path.name) is not None,
        f"output must use a simple leaf name: {path}",
    )
    parent = canonical_directory(path.parent, "output parent")
    candidate = parent / path.name
    require(candidate == path, f"output must use a canonical path: {path}")
    for root in disjoint_from:
        require(
            not paths_overlap(candidate, root),
            f"output must be disjoint from input root: {root}",
        )
    require(not path.exists() and not path.is_symlink(), f"refusing existing output: {path}")
    staging = Path(
        tempfile.mkdtemp(
            prefix=f".{path.name}.assembling-",
            dir=parent,
        )
    )
    canonical_directory(staging, "staged output")
    metadata = staging.lstat()
    require(stat.S_IMODE(metadata.st_mode) == 0o700, "staged output is not mode 0700")
    _STAGED_OUTPUTS[staging] = (path, metadata.st_dev, metadata.st_ino)
    atexit.register(cleanup_staged_output, staging)
    return staging


def publish_output(staging: Path) -> Path:
    record = _STAGED_OUTPUTS.get(staging)
    require(record is not None, "unknown staged output")
    requested, expected_device, expected_inode = record
    canonical_directory(staging, "staged output")
    metadata = staging.lstat()
    require(
        metadata.st_dev == expected_device and metadata.st_ino == expected_inode,
        "staged output identity changed before publication",
    )
    canonical_directory(requested.parent, "output parent")
    require(
        not requested.exists() and not requested.is_symlink(),
        f"refusing existing output at publication: {requested}",
    )
    libc = ctypes.CDLL(None, use_errno=True)
    rename_exclusive = libc.renameatx_np
    rename_exclusive.argtypes = (
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    )
    rename_exclusive.restype = ctypes.c_int
    result = rename_exclusive(
        AT_FDCWD,
        os.fsencode(staging),
        AT_FDCWD,
        os.fsencode(requested),
        RENAME_EXCL,
    )
    if result != 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number), requested)
    _STAGED_OUTPUTS.pop(staging)
    return requested


def reject_tree_symlinks(root: Path, label: str) -> None:
    for directory, directory_names, file_names in os.walk(root, followlinks=False):
        directory_path = Path(directory)
        for name in directory_names + file_names:
            path = directory_path / name
            require(not path.is_symlink(), f"{label} contains a symlink: {path}")


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def parse_key_values(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        require("=" in line, f"malformed key/value line in {path}: {line!r}")
        key, value = line.split("=", 1)
        require(key and key not in result, f"duplicate/empty key in {path}: {key!r}")
        result[key] = value
    return result


def parse_tokens(line: str) -> dict[str, str]:
    result: dict[str, str] = {}
    for token in line.split():
        if "=" not in token:
            continue
        key, value = token.split("=", 1)
        require(key and key not in result, f"duplicate/empty token key: {key!r}")
        result[key] = value
    return result


def write_json(path: Path, value: object) -> None:
    path.write_text(
        json.dumps(value, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )


def write_key_values(path: Path, values: tuple[tuple[str, str], ...]) -> None:
    path.write_text(
        "".join(f"{key}={value}\n" for key, value in values),
        encoding="utf-8",
    )


def make_tree_writable(root: Path) -> None:
    for directory, directory_names, file_names in os.walk(root):
        for name in directory_names + file_names:
            path = Path(directory) / name
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | 0o200)
    root.chmod(root.stat().st_mode | 0o200)


def summary_from_fresh_copy(xcresult: Path) -> bytes:
    canonical_directory(xcresult, "source xcresult")
    reject_tree_symlinks(xcresult, "source xcresult")
    canonical_file(XCRESULTTOOL, "xcresulttool")
    require(
        sha256_file(XCRESULTTOOL) == XCRESULTTOOL_SHA256,
        "xcresulttool differs from the pinned measured identity",
    )
    user = pwd.getpwuid(os.getuid())
    with tempfile.TemporaryDirectory(
        prefix="plainsong-f2-pack-summary.",
        dir="/private/tmp",
    ) as temporary:
        copy = Path(temporary) / "Result.xcresult"
        shutil.copytree(xcresult, copy, symlinks=False)
        make_tree_writable(copy)
        completed = subprocess.run(
            [
                str(XCRESULTTOOL),
                "get",
                "test-results",
                "summary",
                "--compact",
                "--path",
                str(copy),
            ],
            check=False,
            capture_output=True,
            env={
                "HOME": user.pw_dir,
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": "/private/tmp",
                "USER": user.pw_name,
                "LOGNAME": user.pw_name,
            },
            timeout=120,
        )
        if completed.returncode != 0:
            raise RuntimeError(
                "xcresulttool summary failed: "
                + completed.stderr.decode("utf-8", errors="replace")
            )
        json.loads(completed.stdout.decode("utf-8", errors="strict"))
        return completed.stdout


def full_artifact(
    original: str,
    relative: str,
    mode: str,
    digest: str,
) -> dict[str, str]:
    return {
        "originalPath": original,
        "artifactRootPath": relative,
        "hashMode": mode,
        "sha256": digest,
    }
