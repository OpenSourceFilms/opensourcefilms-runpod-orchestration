# Security boundaries of the historical RunPod worker scripts

**Status:** Archived deployment source, reviewed 26 October 2026.
These scripts document how OSF used a root-operated mainvolume/worker setup
during April–May 2026. They are **not** a hardened, supported or current
deployment template. The review is limited to the public source tree. It
does not assess or modify any currently running OSF pod, SSH configuration,
credential, model installation or backup.

## Relevant behaviours in the checked-in scripts

| Script / behaviour | Consequence | What a new deployment would need |
|---|---|---|
| `community_worker/print-b300-worker-bootstrap` and `print-b300-worker-bootstrap-b64`: private key is created only when `/workspace/_community_worker/transfer_ssh/id_ed25519` is absent | **One persistent key can be reused across multiple workers.** Despite earlier prose calling it a "fresh throwaway" worker key, each invocation does *not* produce a new credential. Its public key is appended/deduplicated in root's authorised keys. | Separate, scoped per-worker authentication and a reviewable removal/revocation process, with changes approved by the credential owner. Do not assume the historical scripts provide it. |
| Both bootstrap generators print an SSH **private** key in a ready-to-paste command; the b64 variant also embeds `HF_TOKEN` when available | The output, terminal scrollback, recordings, shell history and logs can expose credentials. **Base64 is only an encoding, not encryption.** `chmod 600` on the destination key does not protect earlier copies of the printed block. | An authenticated secret-delivery workflow that avoids printing secrets, or an explicitly risk-accepted, controlled transfer. Do not publish or log generated blocks. |
| `osf_pod_link/osf-main-up`: `chmod -R 777 /workspace/_h200_writeback` | Makes the historical writeback tree writable by **all local users/processes**, not just the worker identity; combined with a root SSH endpoint this is a permissive trust boundary. | Owner/group permissions, dedicated service account, restrictive shared directories and access review. No secure replacement is implemented here. |
| `osf-main-up` enables SSH and copies allowed worker keys to `/root/.ssh/authorized_keys` | Anyone holding an allowed private key can authenticate as **root** subject to the host's SSH/network configuration. Keys can persist in more than one file. | Least-privilege accounts, authentication/authorization policy, host firewall checks and a revocation plan. |
| Generated SSH config uses `StrictHostKeyChecking accept-new` | Initial connection uses trust-on-first-use rather than a separately pinned host key. | Independently verify and pin the main host's SSH host key before the first sensitive transfer. |
| `worker_bootstrap/bootstrap-heavy-comfy-worker.sh` clones/pulls external repositories from moving upstream branches | A future invocation may install changed code; source and model licence terms may also differ from the historical installation. | Pin and audit actual revisions, dependencies, model terms and checksums before executing. |
| Generated helpers interpolate caller input into remote shell commands | Untrusted path/pattern strings can be treated as shell syntax on the remote host. These helpers were intended for trusted operators, **not** untrusted service requests or multi-tenant inputs. | Replace remote string interpolation with constrained parameter handling and a tested command protocol. |

## Read this before reusing any script

The [README](../README.md) and [RUNPOD.md](../RUNPOD.md) describe the
original architecture and reproduction limitations. The scripts may install
system software, launch `sshd`, configure root SSH access, download
third-party code/models, print sensitive values and change filesystem
permissions. They are **not safe to paste onto an unfamiliar or shared host
without a separate security review**.

The public repository is useful as an engineering case study. It does
**not** establish the current OSF production fleet's configuration or
security posture. None of the historical credential, permission or boot
procedures have been changed in this publication review. In particular,
no key has been rotated, removed, replaced or revoked.

The repository's offline CI checks Bash syntax, public fixture tests and
common patterns of *accidentally committed* credential material. CI does
not inspect historical Git objects, current connected accounts, hidden
runtime secrets or the security of a deployed host. Passing CI must not
be described as a live security audit or as permission to use a model.

If adopting these ideas, build a separate, reviewed deployment with
least privilege, authenticated secret delivery, pinned host identities,
controlled output permissions, immutable dependency references and
resource/account-specific acceptance tests. Avoid copying the historical
root bootstrap verbatim.
