#!/bin/bash
# Syntax and structural self-check. Does not require a live Runpod pod or any
# real credentials — it only verifies the scripts parse correctly and that no
# secret material has been accidentally committed alongside them.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FAIL=0

echo "=== bash -n syntax check ==="
for f in \
  "$ROOT/osf_pod_link/osf-main-up" \
  "$ROOT/worker_bootstrap/bootstrap-heavy-comfy-worker.sh" \
  "$ROOT/worker_bootstrap/worker-up" \
  "$ROOT/community_worker/create-b300-comfy-worker" \
  "$ROOT/community_worker/print-b300-worker-bootstrap" \
  "$ROOT/community_worker/print-b300-worker-bootstrap-b64"
do
  if bash -n "$f"; then
    echo "OK   $f"
  else
    echo "FAIL $f"
    FAIL=1
  fi
done

echo
echo "=== no committed secret material ==="
if grep -rlE '\-\-\-\-\-BEGIN (OPENSSH|RSA|EC) PRIVATE KEY\-\-\-\-\-|^hf_[A-Za-z0-9]{20,}' "$ROOT" \
    --include='*' 2>/dev/null | grep -v '^Binary'; then
  echo "FAIL: possible private key or HF token found committed in this repo"
  FAIL=1
else
  echo "OK   no private key headers or HF token patterns found"
fi

echo
if [ "$FAIL" = "0" ]; then
  echo "selfcheck: PASS"
else
  echo "selfcheck: FAIL"
fi
exit "$FAIL"
