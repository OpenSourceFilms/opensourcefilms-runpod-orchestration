#!/usr/bin/env python3
"""Offline GPU pod admission *planning* example. NEVER launches or reserves work.

Snapshot fields and response shape are EXAMPLES, not any Runpod or OSF broker API.
A real scheduler must recheck and atomically reserve through the authenticated
native GPU broker, record idempotent receipts and independently verify results.
"""
from __future__ import annotations

import argparse
import json
import math
import sys
from typing import Any


class InvalidSnapshot(ValueError):
    """A malformed or inconsistent snapshot that must never cause admission."""


ACTIVE_STATES = frozenset({"queued", "leased", "running", "uncertain"})


def _mapping(value: Any, label: str) -> dict:
    if not isinstance(value, dict):
        raise InvalidSnapshot(label + " must be an object")
    return value


def _text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or len(value) > 160:
        raise InvalidSnapshot(label + " must be a nonempty short string")
    return value


def _nonnegative(value: Any, label: str) -> int:
    if type(value) is not int or value < 0:
        raise InvalidSnapshot(label + " must be a nonnegative integer")
    return value


def _positive(value: Any, label: str) -> int:
    result = _nonnegative(value, label)
    if result == 0:
        raise InvalidSnapshot(label + " must be positive")
    return result


def _timestamp(value: Any, label: str) -> float:
    if type(value) not in (int, float):
        raise InvalidSnapshot(label + " must be a finite nonnegative number")
    # JSON integers are unbounded by Python's int type. math.isfinite(int)
    # attempts a float conversion, which raises OverflowError for very large
    # integer timestamps. Reject such snapshots with the normal CLI error
    # instead of leaking an uncaught traceback.
    try:
        converted = float(value)
    except (OverflowError, ValueError):
        raise InvalidSnapshot(label + " must be a finite nonnegative number") from None
    if not math.isfinite(converted) or converted < 0:
        raise InvalidSnapshot(label + " must be a finite nonnegative number")
    return converted


def _set(value: Any, label: str) -> set[str]:
    if not isinstance(value, list) or any(not isinstance(x, str) or not x for x in value):
        raise InvalidSnapshot(label + " must be an array of nonempty strings")
    return set(value)


def plan(snapshot: dict) -> dict:
    """Return a deterministic, advisory result. No scheduling side effects."""
    snapshot = _mapping(snapshot, "snapshot")
    if snapshot.get("schema") != "example.fleet-admission/1":
        raise InvalidSnapshot("unknown snapshot schema")
    now = _timestamp(snapshot.get("now_unix"), "now_unix")
    max_age = _positive(snapshot.get("max_age_seconds"), "max_age_seconds")
    request = _mapping(snapshot.get("request"), "request")
    key = _text(request.get("job_key"), "request.job_key")
    project = _text(request.get("project"), "request.project")
    required_vram = _positive(request.get("vram_mib"), "request.vram_mib")
    architecture = _text(request.get("architecture"), "request.architecture")
    required_tags = _set(request.get("required_tags", []), "request.required_tags")

    jobs = snapshot.get("existing_jobs")
    if not isinstance(jobs, list):
        raise InvalidSnapshot("existing_jobs must be an array")
    active_existing = []
    for index, item in enumerate(jobs):
        item = _mapping(item, "existing_jobs[%d]" % index)
        existing_key = _text(item.get("job_key"), "existing_jobs.job_key")
        state = _text(item.get("state"), "existing_jobs.state")
        if state not in ACTIVE_STATES | {"succeeded", "failed", "cancelled"}:
            raise InvalidSnapshot("unrecognised job state")
        if existing_key == key and state in ACTIVE_STATES:
            active_existing.append(state)

    pods = snapshot.get("pods")
    if not isinstance(pods, list):
        raise InvalidSnapshot("pods must be an array")
    checked, eligible = [], []
    ids = set()
    for index, raw in enumerate(pods):
        pod = _mapping(raw, "pods[%d]" % index)
        pod_id = _text(pod.get("pod_id"), "pod_id")
        if pod_id in ids:
            raise InvalidSnapshot("duplicate pod_id")
        ids.add(pod_id)
        observed_at = _timestamp(pod.get("observed_at_unix"), "observed_at_unix")
        vram_total = _positive(pod.get("vram_total_mib"), "vram_total_mib")
        broker_available = _nonnegative(pod.get("broker_admittable_mib"), "broker_admittable_mib")
        if broker_available > vram_total:
            raise InvalidSnapshot("broker_admittable_mib exceeds physical capacity")
        waiters = _nonnegative(pod.get("native_waiters"), "native_waiters")
        tags = _set(pod.get("tags"), "tags")
        allowed = _set(pod.get("allowed_projects"), "allowed_projects")
        arch = _text(pod.get("architecture"), "architecture")
        if type(pod.get("authenticated")) is not bool or type(pod.get("healthy")) is not bool:
            raise InvalidSnapshot("authenticated and healthy must be boolean")

        reasons = []
        if observed_at > now:
            reasons.append("future_observation")
        elif now - observed_at > max_age:
            reasons.append("stale_observation")
        if not pod["authenticated"]:
            reasons.append("unauthenticated")
        if not pod["healthy"]:
            reasons.append("unhealthy")
        if project not in allowed:
            reasons.append("project_not_allowed")
        if arch != architecture:
            reasons.append("architecture_mismatch")
        if not required_tags.issubset(tags):
            reasons.append("missing_tags")
        if waiters:
            reasons.append("native_waiters_present")
        if broker_available < required_vram:
            reasons.append("insufficient_broker_capacity")
        checked.append({"pod_id": pod_id, "eligible": not bool(reasons), "reasons": reasons})
        if not reasons:
            eligible.append((broker_available - required_vram, pod_id))

    if active_existing:
        return {
            "status": "already_registered",
            "job_key": key,
            "active_states": sorted(set(active_existing)),
            "selected_pod": None,
            "checked": checked,
            "disclaimer": "Advisory only: query the authoritative broker before taking any action.",
        }
    selected = min(eligible)[1] if eligible else None
    return {
        "status": "candidate_only" if selected else "no_eligible_pod",
        "job_key": key,
        "selected_pod": selected,
        "checked": checked,
        "disclaimer": "No reservation or process launch was performed. Native broker admission remains authoritative.",
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("snapshot", help="JSON fixture with example.fleet-admission/1 schema")
    args = parser.parse_args(argv)
    try:
        with open(args.snapshot, "r", encoding="utf-8") as fp:
            payload = json.load(fp)
        result = plan(payload)
    except (OSError, json.JSONDecodeError, InvalidSnapshot) as error:
        print(json.dumps({"status": "invalid_snapshot", "error": str(error)}), file=sys.stderr)
        return 3
    print(json.dumps(result, sort_keys=True, indent=2))
    return 2 if result["status"] == "no_eligible_pod" else 0


if __name__ == "__main__":
    raise SystemExit(main())
