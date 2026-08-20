# Running on Runpod

This is the actual deployment guide for the scripts in this repo, written from
what they do and how they were run, not a generic Runpod tutorial.

## The two pod roles

**Mainvolume pod.** One long-lived pod holding a Runpod persistent (network)
volume with shared ComfyUI models, footage, and output storage. This is the
pod `osf_pod_link/osf-main-up` runs on.

**Worker pod(s).** Short-lived GPU pods created on demand, bootstrapped to
install ComfyUI, pull shared models from the mainvolume pod over SSH, do the
actual generation work, then push results back. This is what
`worker_bootstrap/bootstrap-heavy-comfy-worker.sh` sets up.

## Step 1: bring the mainvolume pod's SSH endpoint up

On the mainvolume pod:

```bash
bash osf_pod_link/osf-main-up
```

This starts `sshd` if it isn't already running, installs `openssh-server` and
`rsync` if missing, and writes `main.env` / `main_host.env` with the pod's own
Runpod-assigned networking (`RUNPOD_POD_ID`, `RUNPOD_PUBLIC_IP`,
`RUNPOD_TCP_PORT_22`, etc. — these are set automatically by Runpod inside the
pod's own environment, nothing to configure). See
`examples/main.env.example` for the shape of what gets written.

Optionally pass a worker's public SSH key as the first argument (or via the
`CLIENT_PUBKEY` environment variable) to authorize it immediately:

```bash
bash osf_pod_link/osf-main-up "ssh-ed25519 AAAA... some-worker"
```

## Step 2: generate a worker bootstrap block

Still on the mainvolume pod (or anywhere with access to these scripts):

```bash
bash community_worker/create-b300-comfy-worker
```

This prints a message about the B300-specific Runpod API limitation (see
below), then runs `print-b300-worker-bootstrap-b64`, which:

1. Generates a fresh, throwaway SSH key pair for the new worker
   (`community_worker/transfer_ssh/` — not included in this repo, generated
   fresh on each pod).
2. Authorizes that key's public half on the mainvolume pod automatically
   (calls `osf_pod_link/osf-main-up` for you).
3. Reads the current `HF_TOKEN` (from the environment, or
   `/workspace/_secrets/hf_token` if set) so the worker can download gated or
   rate-limited HuggingFace models without a separate login step.
4. Prompts interactively for which ComfyUI variants to install (General,
   WAN VACE, VideoMaMa + SAM3, an isolated EffectErase runtime) and whether to
   fetch shared models.
5. Prints a complete, self-contained shell block to stdout — base64-encoded
   SSH key, mainvolume connection details, install choices, and a final call
   into `worker_bootstrap/bootstrap-heavy-comfy-worker.sh` — ready to paste
   directly into a new pod's terminal.

There is also a non-base64 variant, `print-b300-worker-bootstrap`, which
writes the SSH key to disk on the worker via an interactive prompt sequence
instead of embedding it inline. The base64 variant is what was actually used
day to day — fewer steps, no separate `scp` needed.

## Step 3: launch the worker pod and paste the block

**The real constraint this repo was built around:** at the time this was
written, Runpod's REST API rejected B300 pod-creation requests even though
the same tier could be launched from the Runpod web UI without issue. There
was no API workaround — `create-b300-comfy-worker`'s first line states this
plainly rather than silently retrying or failing. The actual workflow is:
launch the B300 pod manually through the Runpod UI, then paste the generated
block into its terminal. Everything after that point is scripted.

Once pasted, the block installs system packages, restores the SSH key,
confirms the mainvolume link (`main-test-link`), pulls
`worker_bootstrap/bootstrap-heavy-comfy-worker.sh` from the mainvolume pod
over `scp`, and runs it with the install flags chosen in step 2.

## What the worker bootstrap actually installs

`worker_bootstrap/bootstrap-heavy-comfy-worker.sh` is additive and
re-runnable — set the `INSTALL_*`/`FETCH_*`/`PULL_*` environment variables
per component instead of running the whole thing from scratch each time, e.g.:

```bash
INSTALL_GENERAL=0 INSTALL_WAN=1 FETCH_WAN22_I2V=1 PULL_SAM3=0 \
  MAIN_POD_HOST=mainvolume bash worker_bootstrap/bootstrap-heavy-comfy-worker.sh
```

It clones ComfyUI (`comfyanonymous/ComfyUI`) plus whichever custom-node
repositories the selected variant needs (SeedVR2 upscaler, WanVideoWrapper,
VideoMaMa + SAM3 + VideoHelperSuite + KJNodes + rgthree-comfy +
controlnet_aux + was-node-suite, or an isolated EffectErase venv), links a
shared `models_shared/` directory across all installed variants so weights
are downloaded once, and pulls SAM3 / WAN 2.2 I2V models from the mainvolume
pod first before falling back to a HuggingFace download.

## Data movement helpers

Both `osf_pod_link/osf-main-up` (on the mainvolume side) and
`worker_bootstrap/bootstrap-heavy-comfy-worker.sh` (on the worker side, via
the generated bootstrap block) install small `main-*` commands on `$PATH`:

- `main-test-link` — confirms the SSH connection to mainvolume and shows disk
  usage.
- `main-ls <path>`, `main-find <path> <pattern>`,
  `main-find-footage <pattern>` — inspect files on the mainvolume pod without
  a full SSH session.
- `main-du <path>` — disk usage on the mainvolume side.
- `main-pull <remote-path> [local-dest]` — rsync from mainvolume to the
  worker.
- `main-push <local-path> [outputs|logs|workflows|...]` — rsync from the
  worker back to `mainvolume:/workspace/_h200_writeback/<subdir>/`, the
  writeback location `osf-main-up` creates automatically.

## Security note on the generated bootstrap block

`print-b300-worker-bootstrap-b64`'s output (step 2 above) is not a template —
it's a fully resolved shell block containing a real base64-encoded SSH
private key and, if `HF_TOKEN` is set, a real HuggingFace token, printed to
stdout in plaintext. That's by design (it's meant to be pasted straight into
a new pod's terminal), but it means the printed output itself is
credential-bearing for as long as it exists anywhere. Paste it directly; do
not redirect it to a file, log it, or commit it anywhere. Treat it the same
as you would a raw private key.

## Known limitations

- **Directory layout is load-bearing.** These scripts reference each other by
  absolute path — `/workspace/_osf_pod_link/osf-main-up`,
  `/workspace/_worker_bootstrap/bootstrap-heavy-comfy-worker.sh`, and so on.
  For the cross-references to resolve, this repo's three top-level
  directories need to be placed at `/workspace/_osf_pod_link`,
  `/workspace/_worker_bootstrap`, and `/workspace/_community_worker`
  respectively (matching the underscore-prefixed names exactly) rather than
  wherever a `git clone` happens to land by default. This is a real
  portability gap, stated plainly rather than hidden — fixing it would mean
  rewriting every cross-script path reference to resolve relative to
  `$BASH_SOURCE`, which wasn't done here in order to publish the scripts as
  they actually ran rather than a rewritten variant that was never tested
  in production.
- **No commit pinning on cloned third-party repos.** Unlike
  `opensourcefilms-comfyui-workflows`, `worker_bootstrap/bootstrap-heavy-comfy-worker.sh`
  clones ComfyUI and its custom nodes from each project's default branch
  (`clone_or_update` does a plain `git clone` / `git pull --ff-only`), not a
  pinned commit SHA. This means a re-run today may install different code
  than what actually ran in April/May 2026. Worth fixing before relying on
  this for reproducible builds; not fixed in this pass.
- **`--use-sage-attention` and SAM2-disabling patch are environment-specific
  workarounds**, not general best practice — documented as found, not
  endorsed as the right approach for every setup.
- **Not validated end-to-end against a live pod in this publishing pass** —
  `tests/selfcheck.sh` confirms every script parses (`bash -n`) and that no
  secret material is present in the repo, which is what's actually checkable
  without spinning up real Runpod infrastructure and real credentials. The
  scripts themselves were exercised for real between April 30 and May 5,
  2026 (see git history / commit dates), which is the actual evidence this
  repo documents — not a fresh re-run performed for publication.

## Runpod acknowledgment

This is Runpod-sponsored GPU infrastructure code — the entire purpose of
these scripts is provisioning and coordinating Runpod pods for OSF's video
production GPU work.
