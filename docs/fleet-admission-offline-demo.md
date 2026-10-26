# Offline fleet GPU admission planner (synthetic reference)

This folder demonstrates **candidate selection**, not a scheduler, a RunPod API
client or a GPU allocation service. It is independently runnable with the
Python 3 standard library; it has no network, process launch, model or
credential dependencies.

The earlier RunPod bootstrap scripts in this repository are historical.
The privileged native OSF GPU broker and its live dispatch/control plane are
not published here. No code in this reference example connects to either.

## Try it

From the repository root:

```bash
python3 -B examples/fleet_admission.py examples/fleet_snapshot.example.json
python3 -B -m unittest discover -s tests -p 'test_fleet_admission.py' -v
```

The example selects `demo-gpu-b` (26,000 MiB broker-admittable capacity,
24,000 MiB requested, lowest fit slack), rejects stale
`demo-gpu-c`, and merely reports `demo-gpu-a` as another eligible
candidate. All names, timestamps and capacities are fabricated.

## Deliberately narrow contract

`examples/fleet_snapshot.example.json` documents the
`example.fleet-admission/2` **illustrative format**, *not* a RunPod or OSF
service API:

| Field | Meaning |
|---|---|
| `now_unix`, `max_age_seconds` | Reference time and strict maximum allowed observation age |
| `request.job_key`, `request.project` | Project-scoped duplicate-detection identity: the pair `(project, job_key)` must match |
| `request.vram_mib`, `architecture`, `required_tags` | Minimum native broker capacity and requested GPU/software compatibility |
| `existing_jobs[]` | Requires `project`, `job_key` and `state` on every record. Queued, leased, running or uncertain blocks resubmission **only for that same project-and-key pair**. Missing project identity invalidates the entire snapshot. |
| `pods[].pod_id`, `observed_at_unix` | Current pod ID and observation age; future/stale observations fail closed |
| `pods[].authenticated`, `healthy` | **Trusted producer assertions**, not credentials; untrusted input must never assert them |
| `pods[].allowed_projects`, `architecture`, `tags` | Explicit access controls and compatibility evidence |
| `pods[].broker_admittable_mib` | Broker-reported currently claimable amount **after native claims and reserves**; not the VRAM reported by `nvidia-smi` |
| `pods[].native_waiters` | A non-empty native FIFO queue blocks this example's immediate-placement advice |

Version 2 corrects a v1 ambiguity: two projects could use the same `job_key`,
but v1's projectless `existing_jobs` records made unrelated active jobs
appear to be duplicates. The v2 planner rejects old snapshots instead of
silently assuming those keys are globally unique. Job project attribution
must come from an authoritative ledger, not a caller-supplied guess.

The simulation filters ineligible pods, ranks eligible pods by *smallest spare
broker-reported capacity*, and breaks ties by pod ID for reproducibility.
It returns `candidate_only`, `no_eligible_pod`, `already_registered` or
`invalid_snapshot`. CLI exit codes are respectively 0, 2, 0 and 3.

Timestamp input validation is deliberately fail-closed. Numeric strings,
nonfinite values, negative timestamps and JSON integers too large for a
finite floating-point timestamp produce `invalid_snapshot` (exit 3),
rather than an uncaught Python traceback. The synthetic regression
suite includes both oversized `now_unix` and `observed_at_unix` cases.
It also rejects projectless existing-job records and v1 schemas.
This is an error-handling improvement, not real broker authentication or
an expansion of permissible admission decisions.

## Critical limitations

**This never reserves capacity, starts an OSF job, starts a RunPod pod, checks
a real remote agent or verifies an output.** It is **not safe** to convert a
`candidate_only` answer directly into a shell command or an allocation
decision. In particular:

1. Fetch job state and agent observations from an authenticated, authorised,
   integrity-protected source. The example does not cryptographically prove
   a JSON snapshot's authenticity, including the `authenticated` boolean.
2. Re-check all relevant state atomically through the *chosen GPU's native
   broker*. A snapshot is advisory and can become stale between selection
   and admission; the broker must reject contention.
3. Implement idempotent native job keys and durable receipts, especially when
   a submit call has an ambiguous transport outcome. Do not resubmit blindly.
4. Enforce actual per-project allowlists and safe command restrictions at
   the broker, not by trusting the caller's project name or `argv`.
5. Independently verify produced file hashes and native output continuity.
   A successful process exit or broker claim is not creative acceptance.
6. Never spawn a paid instance, skip an existing FIFO waiter, mutate a
   running service, or expose operator tokens as a recovery mechanism.

A live production deployment needs *additional* host trust, authentication,
storage, telemetry, secure transactions, failure handling and operational
acceptance. The simulator alone is not a supported production scheduler.

## API currency

RunPod's official documentation states that REST API v1 is deprecated and
scheduled to retire **15 November 2026**. New integrations should use the
REST v2 interface and current SDK documentation, not hard-code examples from
this repository's April–May 2026 bootstrap era. See
[RunPod API overview](https://github.com/runpod/docs/blob/main/api-reference/overview.mdx)
and the [maintained Python SDK](https://github.com/runpod/runpod-python).
This reference planner makes **no RunPod API requests** at all.

For the underlying architectural rationale see
[fleet GPU scheduling](fleet-gpu-scheduling.md).
