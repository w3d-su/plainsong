from __future__ import annotations

from .context import (
    PACK_INVENTORY_SHA256,
    SHA256_RE,
    Path,
    PurePosixPath,
    datetime,
    hashlib,
    json,
    os,
    re,
    stat,
    timezone,
)

class AuditError(Exception):
    """A falsified or incomplete retained-evidence claim."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)


def require_keys(value: object, keys: tuple[str, ...], label: str) -> dict:
    require(isinstance(value, dict), f"{label} must be an object")
    actual = set(value)
    expected = set(keys)
    require(
        actual == expected,
        f"{label} keys differ: missing={sorted(expected - actual)!r} "
        f"extra={sorted(actual - expected)!r}",
    )
    return value


def reject_json_constant(value: str) -> None:
    raise AuditError(f"non-finite JSON number is forbidden: {value}")


def unique_json_object(pairs: list[tuple[str, object]]) -> dict:
    result = {}
    for key, value in pairs:
        if key in result:
            raise AuditError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def loads_json(data: bytes, label: str) -> object:
    try:
        text = data.decode("utf-8", errors="strict")
        return json.loads(
            text,
            object_pairs_hook=unique_json_object,
            parse_constant=reject_json_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise AuditError(f"{label} is not strict UTF-8 JSON: {error}") from error


def load_json(path: Path, label: str) -> object:
    try:
        return loads_json(path.read_bytes(), label)
    except OSError as error:
        raise AuditError(f"could not read {label} at {path}: {error}") from error


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    try:
        with path.open("rb") as handle:
            while chunk := handle.read(1024 * 1024):
                digest.update(chunk)
    except OSError as error:
        raise AuditError(f"could not hash {path}: {error}") from error
    return digest.hexdigest()


def require_sha256(value: str, label: str) -> None:
    require(
        isinstance(value, str) and SHA256_RE.fullmatch(value) is not None,
        f"{label} is not a lowercase SHA-256: {value!r}",
    )


def safe_relative_path(value: object, label: str) -> str:
    require(isinstance(value, str) and value != "", f"{label} must be a path string")
    require("\\" not in value and "\x00" not in value, f"{label} is not POSIX-safe")
    path = PurePosixPath(value)
    require(not path.is_absolute(), f"{label} must be relative: {value}")
    require(
        all(part not in ("", ".", "..") for part in path.parts),
        f"{label} escapes its root: {value}",
    )
    require(path.as_posix() == value, f"{label} is not canonical: {value}")
    return value


def regular_pack_files(root: Path) -> set[str]:
    files: set[str] = set()

    def visit(directory: Path, prefix: PurePosixPath) -> None:
        try:
            entries = sorted(os.scandir(directory), key=lambda item: os.fsencode(item.name))
        except OSError as error:
            raise AuditError(f"could not inventory {directory}: {error}") from error
        for entry in entries:
            relative = (prefix / entry.name).as_posix()
            try:
                metadata = entry.stat(follow_symlinks=False)
            except OSError as error:
                raise AuditError(f"could not inspect {entry.path}: {error}") from error
            require(not stat.S_ISLNK(metadata.st_mode), f"pack symlink is forbidden: {relative}")
            if stat.S_ISDIR(metadata.st_mode):
                visit(Path(entry.path), prefix / entry.name)
            else:
                require(stat.S_ISREG(metadata.st_mode), f"non-file pack entry: {relative}")
                files.add(relative)

    visit(root, PurePosixPath())
    require("SHA256SUMS" in files, "pack is missing SHA256SUMS")
    return files


def validate_inventory(root: Path) -> dict[str, str]:
    inventory_path = root / "SHA256SUMS"
    try:
        data = inventory_path.read_bytes()
        text = data.decode("ascii", errors="strict")
    except (OSError, UnicodeDecodeError) as error:
        raise AuditError(f"could not read ASCII SHA256SUMS: {error}") from error
    require(
        sha256_bytes(data) == PACK_INVENTORY_SHA256,
        "SHA256SUMS is not the frozen final-six compact inventory",
    )
    require(text.endswith("\n"), "SHA256SUMS must end with LF")
    records: dict[str, str] = {}
    pattern = re.compile(r"([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9._/-]*)")
    for line_number, line in enumerate(text.splitlines(), start=1):
        match = pattern.fullmatch(line)
        require(match is not None, f"invalid SHA256SUMS line {line_number}: {line!r}")
        digest, relative = match.groups()
        safe_relative_path(relative, f"SHA256SUMS line {line_number}")
        require(relative != "SHA256SUMS", "SHA256SUMS cannot recursively inventory itself")
        require(relative not in records, f"duplicate SHA256SUMS path: {relative}")
        require(
            relative.casefold() not in {path.casefold() for path in records},
            f"case-colliding SHA256SUMS path: {relative}",
        )
        records[relative] = digest
    require(list(records) == sorted(records), "SHA256SUMS paths must be bytewise sorted")
    actual = regular_pack_files(root) - {"SHA256SUMS"}
    require(
        set(records) == actual,
        f"SHA256SUMS is not exact: missing={sorted(actual - set(records))!r} "
        f"stale={sorted(set(records) - actual)!r}",
    )
    for relative, expected in records.items():
        actual_digest = sha256_file(root / PurePosixPath(relative))
        require(actual_digest == expected, f"SHA256SUMS mismatch for {relative}")
    return records


def pack_file(root: Path, inventory: dict[str, str], relative: object, label: str) -> Path:
    value = safe_relative_path(relative, label)
    require(value in inventory, f"{label} is absent from SHA256SUMS: {value}")
    path = root.joinpath(*PurePosixPath(value).parts)
    require(path.is_file() and not path.is_symlink(), f"{label} is not a regular file: {value}")
    return path


def parse_key_values(path: Path, keys: tuple[str, ...], label: str) -> dict[str, str]:
    try:
        data = path.read_bytes()
        text = data.decode("utf-8", errors="strict")
    except (OSError, UnicodeDecodeError) as error:
        raise AuditError(f"could not read {label}: {error}") from error
    require(text.endswith("\n"), f"{label} must end with LF")
    result: dict[str, str] = {}
    order: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        require("=" in line, f"{label} line {line_number} has no equals sign")
        key, value = line.split("=", 1)
        require(re.fullmatch(r"[a-z0-9_]+", key) is not None, f"invalid {label} key: {key!r}")
        require(key not in result, f"duplicate {label} key: {key}")
        require(value != "", f"empty {label} value: {key}")
        result[key] = value
        order.append(key)
    require(tuple(order) == keys, f"{label} key order differs: {order!r}")
    return result


def parse_digest(path: Path, label: str) -> tuple[str, int]:
    record = parse_key_values(path, ("sha256", "bytes"), label)
    require_sha256(record["sha256"], f"{label} sha256")
    require(re.fullmatch(r"[0-9]+", record["bytes"]) is not None, f"invalid {label} byte count")
    return record["sha256"], int(record["bytes"])


def parse_rfc3339_utc(value: str, label: str, require_fraction: bool = False) -> datetime:
    fraction = r"\.[0-9]{6}" if require_fraction else r"(?:\.[0-9]{1,6})?"
    require(
        re.fullmatch(
            rf"[0-9]{{4}}-[0-9]{{2}}-[0-9]{{2}}T"
            rf"[0-9]{{2}}:[0-9]{{2}}:[0-9]{{2}}{fraction}Z",
            value,
        )
        is not None,
        f"{label} is not precise RFC3339 UTC" if require_fraction else f"{label} is not RFC3339 UTC",
    )
    try:
        timestamp = datetime.fromisoformat(value[:-1] + "+00:00")
    except ValueError as error:
        raise AuditError(f"{label} is invalid: {error}") from error
    require(timestamp.tzinfo == timezone.utc, f"{label} is not UTC")
    return timestamp


def parse_decimal_integer(value: str, label: str, positive: bool = False) -> int:
    require(re.fullmatch(r"[0-9]+", value) is not None, f"{label} is not a decimal integer")
    parsed = int(value)
    require(parsed > 0 if positive else parsed >= 0, f"{label} has the wrong sign")
    return parsed
