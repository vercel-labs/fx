"""harness.store: values this agent chooses to keep, saved in its session.

    import proto_fx as harness

    harness.store["plan"] = {"step": 3, "files": ["a.py"]}
    harness.store.get("plan", {})       # the value, or the default
    "plan" in harness.store             # True
    harness.store.keys()                # ['plan']
    del harness.store["plan"]

Each value is pickled (with dill when it is installed, else pickle) and kept
in the agent's session log, so it survives detaching and supervisor restarts,
a fork of the session keeps the values of its fork point, and undoing a turn
undoes the values that turn stored. A value up to 1 MiB pickled is kept, up
to 1024 keys and 64 MiB in all. A value that cannot be pickled raises
Unstorable and nothing is kept.
"""

from __future__ import annotations

import base64
from typing import Any, Iterator

from ._client import HarnessError, request

_missing = object()


class Unstorable(HarnessError, TypeError):
    """The value cannot be pickled, so the store did not keep it."""

    kind = "refused"


def _dumps(value: Any) -> bytes:
    errors = []
    try:
        import dill

        try:
            return dill.dumps(value)
        except Exception as err:  # noqa: BLE001 - fall back to plain pickle
            errors.append("dill: %s: %s" % (type(err).__name__, err))
    except ImportError:
        pass
    import pickle

    try:
        return pickle.dumps(value, protocol=pickle.HIGHEST_PROTOCOL)
    except Exception as err:  # noqa: BLE001 - report every reason together
        errors.append("pickle: %s: %s" % (type(err).__name__, err))
    raise Unstorable("harness.store cannot keep this %s value (%s)" % (type(value).__name__, "; ".join(errors)))


def _loads(data: bytes) -> Any:
    try:
        import dill

        return dill.loads(data)
    except ImportError:
        import pickle

        return pickle.loads(data)


class Store:
    """A mapping of string keys to values, kept in the agent's session."""

    def __setitem__(self, key: str, value: Any) -> None:
        data = _dumps(value)
        request("store.set", {"key": _key(key), "value": base64.b64encode(data).decode("ascii")})

    def __getitem__(self, key: str) -> Any:
        value = self.get(key, _missing)
        if value is _missing:
            raise KeyError(key)
        return value

    def get(self, key: str, default: Any = None) -> Any:
        reply = request("store.get", {"key": _key(key)})
        if not reply.get("found"):
            return default
        return _loads(base64.b64decode(reply["value"]))

    def __delitem__(self, key: str) -> None:
        if not request("store.del", {"key": _key(key)}).get("removed"):
            raise KeyError(key)

    def __contains__(self, key: object) -> bool:
        return isinstance(key, str) and key in self.keys()

    def keys(self) -> list[str]:
        return list(request("store.keys"))

    def __iter__(self) -> Iterator[str]:
        return iter(self.keys())

    def __len__(self) -> int:
        return len(self.keys())

    def __repr__(self) -> str:
        return "<harness.store keys=%r>" % (self.keys(),)


def _key(key: Any) -> str:
    if not isinstance(key, str):
        raise TypeError("harness.store keys are strings, not %s" % type(key).__name__)
    return key


store = Store()
