"""Business metrics with a closed label allow-list.

Unknown values collapse to a fixed bucket (``other``, ``failure``, or
``anonymous``). Do not add user id, order id, or free-form strings as
labels. The collector transform processor repeats this allow-list.
"""

from __future__ import annotations

from typing import Any, Protocol

CHANNELS = ("web", "api", "other")
METHODS = ("card", "wallet", "other")
RESULTS = ("success", "failure")
SEGMENTS = ("anonymous", "authenticated")


class _Counter(Protocol):
    def add(self, amount: float, attributes: dict[str, Any] | None = None) -> None: ...


class _Histogram(Protocol):
    def record(self, amount: float, attributes: dict[str, Any] | None = None) -> None: ...


class _Gauge(Protocol):
    def set(self, amount: float, attributes: dict[str, Any] | None = None) -> None: ...


class _Noop:
    def add(self, amount: float, attributes: dict[str, Any] | None = None) -> None:
        return None

    def record(self, amount: float, attributes: dict[str, Any] | None = None) -> None:
        return None

    def set(self, amount: float, attributes: dict[str, Any] | None = None) -> None:
        return None


def normalize_channel(value: str | None) -> str:
    if value in {"web", "api"}:
        return value
    return "other"


def normalize_method(value: str | None) -> str:
    if value in {"card", "wallet"}:
        return value
    return "other"


def normalize_result(failed: bool) -> str:
    return "failure" if failed else "success"


def normalize_segment(value: str | None) -> str:
    if value == "authenticated":
        return "authenticated"
    return "anonymous"


def order_attributes(channel: str | None) -> dict[str, str]:
    return {"channel": normalize_channel(channel)}


def payment_attributes(method: str | None, failed: bool) -> dict[str, str]:
    return {"method": normalize_method(method), "result": normalize_result(failed)}


def checkout_attributes(failed: bool) -> dict[str, str]:
    return {"result": normalize_result(failed)}


def segment_attributes(segment: str | None) -> dict[str, str]:
    return {"segment": normalize_segment(segment)}


class BusinessRecorder:
    """In-process instruments. Tests pass fakes; production passes OTel instruments."""

    def __init__(
        self,
        orders: _Counter | None = None,
        payments: _Counter | None = None,
        checkout: _Histogram | None = None,
        active_users: _Gauge | None = None,
    ) -> None:
        noop = _Noop()
        self.orders = orders or noop
        self.payments = payments or noop
        self.checkout = checkout or noop
        self.active_users = active_users or noop
        self._active = {"anonymous": 0, "authenticated": 0}

    def order_created(self, channel: str | None) -> dict[str, str]:
        attributes = order_attributes(channel)
        self.orders.add(1, attributes)
        return attributes

    def payment(self, method: str | None, failed: bool, duration_s: float) -> dict[str, str]:
        attributes = payment_attributes(method, failed)
        self.payments.add(1, attributes)
        self.checkout.record(duration_s, checkout_attributes(failed))
        return attributes

    def note_active(self, segment: str | None) -> dict[str, str]:
        attributes = segment_attributes(segment)
        key = attributes["segment"]
        self._active[key] += 1
        self.active_users.set(self._active[key], attributes)
        return attributes
