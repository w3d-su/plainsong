"""Shared F2 audit failures."""


class AuditError(Exception):
    """A falsified or incomplete retained-evidence claim."""


def require(condition: bool, message: str) -> None:
    if not condition:
        raise AuditError(message)
