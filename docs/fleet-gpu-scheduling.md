# Fleet GPU scheduling: admission and evidence

The original scripts in this repository describe OSF's April–May 2026
single-main-volume / ephemeral-worker bootstrap. This note documents the
**separate, later** design OSF used in October 2026 to admit jobs to whichever
GPU pod is actually available. The fleet scheduler's privileged production
service is **not distributed in this repository**. This is a reproducible
design pattern, not a claim that the bootstrap scripts implement these features.

## The problem

A task pinned to yesterday's pod stops working after the pod is destroyed.
A task that checks only `nvidia-smi` memory may also race with another
consumer, so two apparently safe launches can exceed available VRAM.
ComfyUI queue length alone cannot distinguish reserved VRAM from actually
allocated VRAM or prove which job owns a device.

The scheduling system must track *current* pod availability, but the
reservation must still be granted by the GPU owner's authoritative broker.

## Minimal contract

A submission describes the requested workload, not a selected host:

```json
{
  "project": "example-video",
  "job_key": "shot-042:seed-7",
  "argv": ["python", "-m", "example_runner", "--job", "shot-042"],
  "vram_mib": 32768,
  "timeout_seconds": 3600,
  "queue_wait_seconds": 120
}
```

This JSON is illustrative and **not a copy of OSF's native API or a
shell-executable submission format**. In an implementation, command arguments
must be constrained by the authenticated project policy.

At a minimum, every eligible pod observation needs: a stable current pod
identity, authenticated GPU-agent health, hardware/VRAM capacity, the broker's
current reservations and waiters, and a freshness timestamp.

## Admission algorithm

1. Discover running pods, rather than reusing a stored pod ID. A pod with a
   stale or unauthenticated agent is ineligible even if its GPU is idle.
2. Filter by architecture, VRAM, required software and project policy.
   Include the operator's VRAM reserve; do not treat `total - allocated`
   as a grant of capacity.
3. Choose an eligible candidate. The ranking policy (first-fit, best-fit,
   packing, or explicit priority) may change without changing ownership rules.
4. Submit once to the **chosen pod's native reservation queue**. That broker,
   not the discovery snapshot, makes the final atomic admission decision.
5. Retain the native job identifier, owner and queue position. Queueing is not
   proof of execution. A claim is not proof of a successful render.
6. Record a durable, metadata-only receipt with enqueue, claim, start, finish,
   exit status and independently checkable output identity. Do not store
   credentials, source footage, prompts containing personal data, or unbounded
   raw logs in a public ledger.
7. Reconcile ambiguous results by querying the authoritative ledger. Never
   blindly resubmit an uncertain job: it may still be executing.
8. Distinguish `EXIT 0`, failure, process termination, and *native output
   verified*. A rendered frame sequence can exist even when post-output
   cleanup returns nonzero. Neither signal implies visual/creative acceptance.

## Capacity example

Suppose a GPU reports 96 GiB total and 44 GiB physically allocated. A
75 GiB **reservation** held by a running job can be legitimate if its
allocation ramps during inference. An independent 32 GiB job must not be
admitted merely because physical allocation suggests about 52 GiB free.
The native broker's claims, waiters and safety reserve determine admission.

A second pod may have more CPUs and RAM than the always-on control pod. Route
CPU-heavy preparation and validation there as well when practical, without
requiring the task to use CUDA.

## Failure and security boundaries

- Pod discovery changes routing, never credentials or host-trust policy.
- Do not auto-accept an SSH host key or bypass an agent allowlist because a pod
  was discovered by its advertised address.
- Do not preempt foreign jobs, launch paid resources, or spawn duplicate
  schedulers to recover from an ambiguous result.
- Scope claims by project, enforce timeouts and release after actual
  termination, not just a client disconnect.
- Keep the public queue/status viewer read-only. Redact identifying metadata
  from logs and avoid making an administrative service publicly reachable.
- Avoid equating a local log with a durable accepted output: independently
  verify the delivered artifacts before marking the creative pipeline done.

## What was verified at OSF

During October 2026 development, OSF verified automatically selected GPU
dispatch, the native shared FIFO/VRAM reservation layer, durable scheduler
receipts, paged stdout/stderr capture, and a read-only job-viewer showing
queued, running and recently completed native jobs. Those are **operational
observations of OSF's separate deployed system**, not test results for code
provided in this repository, and not a claim of fault-free multi-pod failover.

## Executable, read-only reference

The [offline fleet admission demonstration](fleet-admission-offline-demo.md)
implements the candidate-filtering portion of this design with synthetic
snapshots. It has 17 standard-library tests for stale/untrusted agents,
project admission, native waiters, broker-reported VRAM, duplicate job keys
and malformed inputs. This is **not** a native GPU reservation queue or a
copy of OSF's production scheduler, and its output cannot authorise GPU
execution. It does not contact RunPod APIs or consume credits.

For the bootstrap code actually included here, follow the original
[README](../README.md), [RUNPOD](../RUNPOD.md) and
[tests/selfcheck.sh](../tests/selfcheck.sh).
