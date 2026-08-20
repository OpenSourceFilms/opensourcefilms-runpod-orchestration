#!/bin/bash
set -o pipefail

BOOTSTRAP_VERSION="2026-04-30-final-additive"

LOG_DIR="/workspace/_worker_logs"
LOG="$LOG_DIR/bootstrap_heavy_comfy_worker_$(date -u +%Y%m%dT%H%M%SZ).log"

mkdir -p "$LOG_DIR" /workspace/bin /workspace/tmp /workspace/mainvolume_pull

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" | tee -a "$LOG"
}

section() {
  echo | tee -a "$LOG"
  log "=== $* ==="
}

MAIN_POD_HOST="${1:-${MAIN_POD_HOST:-mainvolume}}"

WORKSPACE="/workspace"
COMFY_ROOT="$WORKSPACE/comfy"
SHARED_MODELS="$COMFY_ROOT/models_shared/models"

GENERAL_ROOT="$COMFY_ROOT/ComfyGeneral"
WAN_ROOT="$COMFY_ROOT/ComfyUI_WANVACE"
VIDEOMAMA_ROOT="$COMFY_ROOT/ComfyUI_VideoMaMa"

INSTALL_GENERAL="${INSTALL_GENERAL:-1}"
INSTALL_WAN="${INSTALL_WAN:-0}"
INSTALL_VIDEOMAMA="${INSTALL_VIDEOMAMA:-0}"
INSTALL_EFFECTERASE="${INSTALL_EFFECTERASE:-0}"
FETCH_WAN22_I2V="${FETCH_WAN22_I2V:-$INSTALL_WAN}"
PULL_SAM3="${PULL_SAM3:-1}"

export TMPDIR="/workspace/tmp"
export TEMP="/workspace/tmp"
export TMP="/workspace/tmp"
export HF_HOME="${HF_HOME:-/workspace/.cache/huggingface}"
export PIP_CACHE_DIR="${PIP_CACHE_DIR:-/workspace/.cache/pip}"

if [ -z "${HF_TOKEN:-}" ] && [ -s /workspace/_secrets/hf_token ]; then
  export HF_TOKEN="$(tr -d '[:space:]' < /workspace/_secrets/hf_token)"
fi

section "Bootstrap heavy Comfy worker"
log "Version: $BOOTSTRAP_VERSION"
log "Host: $(hostname)"
log "RUNPOD_POD_ID=${RUNPOD_POD_ID:-unknown}"
log "MAIN_POD_HOST initial=${MAIN_POD_HOST:-unset}"
log "INSTALL_GENERAL=$INSTALL_GENERAL INSTALL_WAN=$INSTALL_WAN INSTALL_VIDEOMAMA=$INSTALL_VIDEOMAMA INSTALL_EFFECTERASE=$INSTALL_EFFECTERASE FETCH_WAN22_I2V=$FETCH_WAN22_I2V PULL_SAM3=$PULL_SAM3"

section "Install system tools"

export DEBIAN_FRONTEND=noninteractive

apt-get update 2>&1 | tee -a "$LOG"
apt-get install -y \
  git git-lfs curl ca-certificates rsync openssh-client ffmpeg unzip \
  build-essential python3 python3-venv python3-dev python3-pip \
  ninja-build pkg-config libgl1 libglib2.0-0 libsm6 libxext6 libxrender1 \
  jq less procps psmisc \
  2>&1 | tee -a "$LOG" || true

git lfs install 2>&1 | tee -a "$LOG" || true

PYTHON_BIN="$(command -v python3.11 || command -v python3)"

section "Set up mainvolume SSH and transfer helpers"

BASE="/workspace/_osf_pod_link"
KEY_DIR="$BASE/client_ssh"
PERSIST_KEY="$KEY_DIR/id_ed25519"
PERSIST_PUB="$PERSIST_KEY.pub"
RUNTIME_KEY="/root/.ssh/osf_mainvolume_id_ed25519"

mkdir -p "$BASE" "$KEY_DIR" /root/.ssh /workspace/mainvolume_pull /workspace/mainvolume_writeback_local /workspace/mainvolume_index
chmod 700 /root/.ssh

if [ -s /root/.ssh/osf_mainvolume_id_ed25519 ] && [ ! -s "$PERSIST_KEY" ]; then
  mkdir -p "$KEY_DIR"
  install -m 600 /root/.ssh/osf_mainvolume_id_ed25519 "$PERSIST_KEY"
  ssh-keygen -y -f "$PERSIST_KEY" > "$PERSIST_PUB"
fi

if [ ! -s "$PERSIST_KEY" ]; then
  if [ -n "${OSF_MAIN_SSH_KEY_B64:-}" ]; then
    log "Using OSF_MAIN_SSH_KEY_B64 for persistent worker key"
    printf '%s' "$OSF_MAIN_SSH_KEY_B64" | base64 -d > "$PERSIST_KEY"
    chmod 600 "$PERSIST_KEY"
    ssh-keygen -y -f "$PERSIST_KEY" > "$PERSIST_PUB"
  else
    log "No persistent worker key found, generating one"
    ssh-keygen -t ed25519 -f "$PERSIST_KEY" -N "" -q -C "osf-heavy-worker"
  fi
fi

install -m 600 "$PERSIST_KEY" "$RUNTIME_KEY"
install -m 644 "$PERSIST_PUB" "$RUNTIME_KEY.pub"

if [ "$MAIN_POD_HOST" = "mainvolume" ]; then
  SSH_TARGET="mainvolume"
else
  SSH_TARGET="root@$MAIN_POD_HOST"
fi

cat > "$BASE/main_host.env" <<EOF
MAIN_POD_HOST=$MAIN_POD_HOST
MAIN_SSH_TARGET=$SSH_TARGET
EOF

cat > "$BASE/client.env" <<EOF
CLIENT_POD_ID=${RUNPOD_POD_ID:-unknown}
CLIENT_VOLUME_ID=${RUNPOD_VOLUME_ID:-unknown}
CLIENT_DC_ID=${RUNPOD_DC_ID:-unknown}
CLIENT_PUBLIC_IP=${RUNPOD_PUBLIC_IP:-unknown}
CLIENT_TCP_PORT_22=${RUNPOD_TCP_PORT_22:-unknown}
CLIENT_CONTAINER_HOSTNAME=$(hostname)
CLIENT_PUBKEY=$(cat "$PERSIST_PUB")
MAIN_POD_HOST=${MAIN_POD_HOST:-unknown}
MAIN_SSH_TARGET=$SSH_TARGET
updated_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF

cat > /workspace/bin/main-host <<'HELPER'
#!/bin/bash
BASE="/workspace/_osf_pod_link"
[ -f "$BASE/main_host.env" ] && . "$BASE/main_host.env"
echo "${MAIN_SSH_TARGET:-mainvolume}"
HELPER

cat > /workspace/bin/main-test-link <<'HELPER'
#!/bin/bash
T="$(main-host)"
ssh "$T" 'hostname; df -h /workspace; ls -ld /workspace/footage /workspace/_h200_writeback /workspace/_worker_bootstrap'
HELPER

cat > /workspace/bin/main-ls <<'HELPER'
#!/bin/bash
T="$(main-host)"
REMOTE="${1:-/workspace/footage}"
ssh "$T" "ls -lah \"$REMOTE\""
HELPER

cat > /workspace/bin/main-find-footage <<'HELPER'
#!/bin/bash
T="$(main-host)"
PATTERN="${1:-}"
MAX="${2:-200}"
if [ -z "$PATTERN" ]; then
  echo "Usage: main-find-footage PATTERN [MAX_RESULTS]"
else
  ssh "$T" "find /workspace/footage -iname '*$PATTERN*' -print | head -n $MAX"
fi
HELPER

cat > /workspace/bin/main-find <<'HELPER'
#!/bin/bash
T="$(main-host)"
REMOTE="${1:-/workspace/footage}"
PATTERN="${2:-*}"
MAX="${3:-200}"
ssh "$T" "find \"$REMOTE\" -iname '$PATTERN' -print | head -n $MAX"
HELPER

cat > /workspace/bin/main-du <<'HELPER'
#!/bin/bash
T="$(main-host)"
REMOTE="${1:-/workspace/footage}"
ssh "$T" "du -sh \"$REMOTE\" 2>/dev/null; du -sh \"$REMOTE\"/* 2>/dev/null | sort -h | tail -40"
HELPER

cat > /workspace/bin/main-pull <<'HELPER'
#!/bin/bash
T="$(main-host)"
SRC="${1:-}"
DST="${2:-/workspace/mainvolume_pull/}"
if [ -z "$SRC" ]; then
  echo "Usage: main-pull /workspace/remote/path [local_destination_dir]"
else
  mkdir -p "$DST"
  rsync -rltD -s --no-owner --no-group --no-perms --partial --info=progress2 -e "ssh" "$T":"$SRC" "$DST"
fi
HELPER

cat > /workspace/bin/main-push <<'HELPER'
#!/bin/bash
T="$(main-host)"
SRC="${1:-}"
SUBDIR="${2:-outputs}"
if [ -z "$SRC" ]; then
  echo "Usage: main-push /local/file/or/folder [outputs|logs|workflows|custom_subdir]"
else
  ssh "$T" "mkdir -p /workspace/_h200_writeback/$SUBDIR"
  rsync -rltD -s --no-owner --no-group --no-perms --partial --info=progress2 -e "ssh" "$SRC" "$T":/workspace/_h200_writeback/"$SUBDIR"/
fi
HELPER

chmod +x /workspace/bin/main-host /workspace/bin/main-test-link /workspace/bin/main-ls /workspace/bin/main-find-footage /workspace/bin/main-find /workspace/bin/main-du /workspace/bin/main-pull /workspace/bin/main-push
grep -q 'export PATH="/workspace/bin:$PATH"' /root/.bashrc 2>/dev/null || echo 'export PATH="/workspace/bin:$PATH"' >> /root/.bashrc
export PATH="/workspace/bin:$PATH"

if ! main-test-link 2>&1 | tee -a "$LOG"; then
  log "Mainvolume SSH test failed."
  echo
  echo "Authorise this public key on the mainvolume pod:"
  cat "$PERSIST_PUB"
  echo
  echo "On mainvolume run:"
  echo "  /workspace/_osf_pod_link/osf-main-up '$(cat "$PERSIST_PUB")'"
  echo
  echo "Then rerun this bootstrap."
  exit 21
fi

section "Create local Comfy layout"

mkdir -p "$COMFY_ROOT" "$SHARED_MODELS" /workspace/tmp /workspace/mainvolume_pull
for d in checkpoints clip clip_vision configs controlnet diffusion_models embeddings loras upscale_models vae vae_approx text_encoders sam3; do
  mkdir -p "$SHARED_MODELS/$d"
done
mkdir -p "$SHARED_MODELS/diffusion_models/Wan2.2"

write_extra_model_paths() {
  local root="$1"
  cat > "$root/extra_model_paths.yaml" <<YAML
comfy_shared:
  base_path: /workspace/comfy/models_shared
  checkpoints: models/checkpoints
  clip: models/clip
  clip_vision: models/clip_vision
  configs: models/configs
  controlnet: models/controlnet
  diffusion_models: models/diffusion_models
  embeddings: models/embeddings
  loras: models/loras
  upscale_models: models/upscale_models
  vae: models/vae
  vae_approx: models/vae_approx
  text_encoders: models/text_encoders
  sam3: models/sam3
YAML
}

patch_manager_config() {
  local root="$1"
  for cfg in \
    "$root/user/__manager/config.ini" \
    "$root/user/default/ComfyUI-Manager/config.ini"
  do
    mkdir -p "$(dirname "$cfg")"
    cat > "$cfg" <<'INI'
[default]
network_mode = personal_cloud
security_level = weak
use_uv = True
file_logging = True
INI
  done
}

clone_or_update() {
  local url="$1"
  local dest="$2"
  if [ -d "$dest/.git" ]; then
    git -C "$dest" pull --ff-only 2>&1 | tee -a "$LOG" || true
  elif [ -e "$dest" ]; then
    log "Path exists but is not a git repo, leaving unchanged: $dest"
  else
    git clone "$url" "$dest" 2>&1 | tee -a "$LOG"
  fi
}

ensure_hf_downloader() {
  HF_DL_VENV="/workspace/venvs/hf-download"
  mkdir -p /workspace/venvs
  if [ ! -d "$HF_DL_VENV" ]; then
    python3 -m venv "$HF_DL_VENV"
  fi
  "$HF_DL_VENV/bin/python" -m pip install --upgrade pip wheel >/dev/null
  "$HF_DL_VENV/bin/python" -m pip install --upgrade "huggingface_hub==0.36.2" hf_transfer >/dev/null
  echo "$HF_DL_VENV/bin/python"
}

install_comfy_base() {
  local root="$1"
  local label="$2"

  section "Install Comfy base: $label"

  clone_or_update "https://github.com/comfyanonymous/ComfyUI.git" "$root"

  if [ ! -d "$root/venv" ]; then
    "$PYTHON_BIN" -m venv "$root/venv"
  fi

  . "$root/venv/bin/activate"

  python -m pip install --upgrade pip wheel setuptools 2>&1 | tee -a "$LOG"
  python -m pip install -r "$root/requirements.txt" 2>&1 | tee -a "$LOG"
  python -m pip install comfyui_manager 2>&1 | tee -a "$LOG" || true

  write_extra_model_paths "$root"
  patch_manager_config "$root"

  deactivate
}

install_sageattention_fallback() {
  local root="$1"

  . "$root/venv/bin/activate"
  python -m pip install "setuptools<82" 2>&1 | tee -a "$LOG" || true
  python -m pip uninstall -y sageattention 2>&1 | tee -a "$LOG" || true
  python -m pip install --no-cache-dir "sageattention==1.0.6" 2>&1 | tee -a "$LOG" || true
  deactivate
}

ensure_shared_model_links() {
  section "Ensure shared model links"

  for ROOT in "$GENERAL_ROOT" "$WAN_ROOT" "$VIDEOMAMA_ROOT"; do
    [ -d "$ROOT" ] || continue
    mkdir -p "$ROOT/models"

    for D in diffusion_models text_encoders vae; do
      rm -rf "$ROOT/models/$D"
      ln -s "$SHARED_MODELS/$D" "$ROOT/models/$D"
    done

    mkdir -p "$ROOT/models/clip"
    ln -sf "$SHARED_MODELS/text_encoders/umt5_xxl_fp16.safetensors" "$ROOT/models/clip/umt5_xxl_fp16.safetensors"
  done
}

ensure_sam3_model() {
  section "Ensure SAM3 model"

  mkdir -p "$SHARED_MODELS/sam3"

  if [ ! -s "$SHARED_MODELS/sam3/sam3.pt" ]; then
    main-pull /workspace/comfy/models_shared/models/sam3/sam3.pt "$SHARED_MODELS/sam3/" 2>&1 | tee -a "$LOG" || true
  fi

  if [ ! -s "$SHARED_MODELS/sam3/sam3.pt" ]; then
    if [ -n "${HF_TOKEN:-}" ]; then
      HF_PY="$(ensure_hf_downloader)"
      "$HF_PY" - <<'PY' 2>&1 | tee -a "$LOG"
from pathlib import Path
from huggingface_hub import hf_hub_download
import os
out = hf_hub_download(
    repo_id="facebook/sam3",
    filename="sam3.pt",
    local_dir="/workspace/comfy/models_shared/models/sam3",
    local_dir_use_symlinks=False,
    token=os.environ.get("HF_TOKEN"),
)
print("downloaded:", out)
print("size:", Path(out).stat().st_size)
PY
    else
      log "HF_TOKEN missing, cannot download SAM3."
    fi
  fi

  if [ -s "$SHARED_MODELS/sam3/sam3.pt" ]; then
    SRC="$SHARED_MODELS/sam3/sam3.pt"
    for ROOT in "$GENERAL_ROOT" "$WAN_ROOT" "$VIDEOMAMA_ROOT"; do
      if [ -d "$ROOT" ]; then
        mkdir -p "$ROOT/models/sam3"
        mkdir -p "$ROOT/models/sam3/models/sam3"
        ln -f "$SRC" "$ROOT/models/sam3/sam3.pt" 2>/dev/null || cp -f "$SRC" "$ROOT/models/sam3/sam3.pt"
        ln -f "$SRC" "$ROOT/models/sam3/models/sam3/sam3.pt" 2>/dev/null || cp -f "$SRC" "$ROOT/models/sam3/models/sam3/sam3.pt"
      fi
    done
  fi
}

ensure_wan_models() {
  section "Ensure WAN 2.2 I2V models"

  mkdir -p \
    "$SHARED_MODELS/diffusion_models/Wan2.2" \
    "$SHARED_MODELS/text_encoders" \
    "$SHARED_MODELS/vae"

  local missing=0

  [ -s "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors" ] || missing=1
  [ -s "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors" ] || missing=1
  [ -s "$SHARED_MODELS/text_encoders/umt5_xxl_fp16.safetensors" ] || missing=1
  [ -s "$SHARED_MODELS/vae/wan_2.1_vae.safetensors" ] || missing=1

  if [ "$missing" = "1" ]; then
    log "Trying to pull WAN models from mainvolume first"

    main-pull /workspace/comfy/models_shared/models/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors "$SHARED_MODELS/diffusion_models/Wan2.2/" 2>&1 | tee -a "$LOG" || true
    main-pull /workspace/comfy/models_shared/models/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors "$SHARED_MODELS/diffusion_models/Wan2.2/" 2>&1 | tee -a "$LOG" || true
    main-pull /workspace/comfy/models_shared/models/text_encoders/umt5_xxl_fp16.safetensors "$SHARED_MODELS/text_encoders/" 2>&1 | tee -a "$LOG" || true
    main-pull /workspace/comfy/models_shared/models/vae/wan_2.1_vae.safetensors "$SHARED_MODELS/vae/" 2>&1 | tee -a "$LOG" || true
  fi

  missing=0
  [ -s "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors" ] || missing=1
  [ -s "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors" ] || missing=1
  [ -s "$SHARED_MODELS/text_encoders/umt5_xxl_fp16.safetensors" ] || missing=1
  [ -s "$SHARED_MODELS/vae/wan_2.1_vae.safetensors" ] || missing=1

  if [ "$missing" = "1" ]; then
    log "Still missing WAN models, trying Hugging Face through isolated downloader venv"

    HF_PY="$(ensure_hf_downloader)"
    export HF_HUB_ENABLE_HF_TRANSFER=1

    "$HF_PY" - <<'PY' 2>&1 | tee -a "$LOG"
from pathlib import Path
from huggingface_hub import hf_hub_download
import os
import shutil

jobs = [
    ("Comfy-Org/Wan_2.2_ComfyUI_Repackaged", "split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors", Path("/workspace/comfy/models_shared/models/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors")),
    ("Comfy-Org/Wan_2.2_ComfyUI_Repackaged", "split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors", Path("/workspace/comfy/models_shared/models/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors")),
    ("Comfy-Org/Wan_2.2_ComfyUI_Repackaged", "split_files/text_encoders/umt5_xxl_fp16.safetensors", Path("/workspace/comfy/models_shared/models/text_encoders/umt5_xxl_fp16.safetensors")),
    ("Comfy-Org/Wan_2.1_ComfyUI_repackaged", "split_files/vae/wan_2.1_vae.safetensors", Path("/workspace/comfy/models_shared/models/vae/wan_2.1_vae.safetensors")),
]

token = os.environ.get("HF_TOKEN")

for repo, filename, dst in jobs:
    dst.parent.mkdir(parents=True, exist_ok=True)
    if dst.exists() and dst.stat().st_size > 1024 * 1024:
        print("exists:", dst, dst.stat().st_size)
        continue

    print("downloading:", repo, filename)
    out = Path(hf_hub_download(
        repo_id=repo,
        filename=filename,
        local_dir="/workspace/_hf_download_tmp",
        local_dir_use_symlinks=False,
        token=token,
        resume_download=True,
    ))

    tmp = dst.with_suffix(dst.suffix + ".tmp")
    if tmp.exists():
        tmp.unlink()
    shutil.move(str(out), str(tmp))
    tmp.rename(dst)
    print("ready:", dst, dst.stat().st_size)
PY
  fi

  ensure_shared_model_links

  section "Verify WAN 2.2 I2V models"
  for f in \
    "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors" \
    "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors" \
    "$SHARED_MODELS/text_encoders/umt5_xxl_fp16.safetensors" \
    "$SHARED_MODELS/vae/wan_2.1_vae.safetensors"
  do
    if [ -s "$f" ]; then
      ls -lh "$f" | tee -a "$LOG"
    else
      log "MISSING: $f"
    fi
  done

  if [ -s "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors" ] && \
     [ -s "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors" ] && \
     [ -s "$SHARED_MODELS/text_encoders/umt5_xxl_fp16.safetensors" ] && \
     [ -s "$SHARED_MODELS/vae/wan_2.1_vae.safetensors" ]; then

    log "Caching WAN models back to mainvolume"
    ssh "$(main-host)" 'mkdir -p /workspace/comfy/models_shared/models/diffusion_models/Wan2.2 /workspace/comfy/models_shared/models/text_encoders /workspace/comfy/models_shared/models/vae' || true

    rsync -rltD -s --no-owner --no-group --no-perms --partial --info=progress2 -e "ssh" "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_high_noise_14B_fp16.safetensors" "$(main-host)":/workspace/comfy/models_shared/models/diffusion_models/Wan2.2/ 2>&1 | tee -a "$LOG" || true
    rsync -rltD -s --no-owner --no-group --no-perms --partial --info=progress2 -e "ssh" "$SHARED_MODELS/diffusion_models/Wan2.2/wan2.2_i2v_low_noise_14B_fp16.safetensors" "$(main-host)":/workspace/comfy/models_shared/models/diffusion_models/Wan2.2/ 2>&1 | tee -a "$LOG" || true
    rsync -rltD -s --no-owner --no-group --no-perms --partial --info=progress2 -e "ssh" "$SHARED_MODELS/text_encoders/umt5_xxl_fp16.safetensors" "$(main-host)":/workspace/comfy/models_shared/models/text_encoders/ 2>&1 | tee -a "$LOG" || true
    rsync -rltD -s --no-owner --no-group --no-perms --partial --info=progress2 -e "ssh" "$SHARED_MODELS/vae/wan_2.1_vae.safetensors" "$(main-host)":/workspace/comfy/models_shared/models/vae/ 2>&1 | tee -a "$LOG" || true
  fi
}

if [ "$INSTALL_GENERAL" = "1" ]; then
  install_comfy_base "$GENERAL_ROOT" "General"

  section "Install General custom nodes"

  clone_or_update "https://github.com/numz/ComfyUI-SeedVR2_VideoUpscaler.git" "$GENERAL_ROOT/custom_nodes/seedvr2_videoupscaler"

  . "$GENERAL_ROOT/venv/bin/activate"
  if [ -f "$GENERAL_ROOT/custom_nodes/seedvr2_videoupscaler/requirements.txt" ]; then
    python -m pip install -r "$GENERAL_ROOT/custom_nodes/seedvr2_videoupscaler/requirements.txt" 2>&1 | tee -a "$LOG" || true
  fi
  python -m pip install --no-cache-dir \
    "transformers==4.57.6" \
    "huggingface-hub==0.36.2" \
    "diffusers==0.37.1" \
    "peft==0.19.1" \
    "accelerate==1.13.0" \
    "tokenizers==0.22.2" \
    "setuptools<82" \
    2>&1 | tee -a "$LOG" || true
  deactivate

  install_sageattention_fallback "$GENERAL_ROOT"
fi

if [ "$INSTALL_WAN" = "1" ]; then
  install_comfy_base "$WAN_ROOT" "WAN VACE"

  section "Install WAN custom nodes"

  clone_or_update "https://github.com/kijai/ComfyUI-WanVideoWrapper.git" "$WAN_ROOT/custom_nodes/ComfyUI-WanVideoWrapper"

  . "$WAN_ROOT/venv/bin/activate"
  if [ -f "$WAN_ROOT/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt" ]; then
    python -m pip install -r "$WAN_ROOT/custom_nodes/ComfyUI-WanVideoWrapper/requirements.txt" 2>&1 | tee -a "$LOG" || true
  fi
  deactivate

  install_sageattention_fallback "$WAN_ROOT"
fi

if [ "$FETCH_WAN22_I2V" = "1" ]; then
  ensure_wan_models
fi

if [ "$INSTALL_EFFECTERASE" = "1" ]; then
  section "Install isolated EffectErase runtime"

  mkdir -p /workspace/video_object_removal_bench/repos /workspace/video_object_removal_bench/venvs
  clone_or_update "https://github.com/FudanCVL/EffectErase.git" "/workspace/video_object_removal_bench/repos/EffectErase"

  "$PYTHON_BIN" -m venv /workspace/video_object_removal_bench/venvs/effecterase
  . /workspace/video_object_removal_bench/venvs/effecterase/bin/activate
  python -m pip install --upgrade pip wheel "setuptools<82" 2>&1 | tee -a "$LOG" || true
  python -m pip install -e /workspace/video_object_removal_bench/repos/EffectErase 2>&1 | tee -a "$LOG" || true
  deactivate
fi

if [ "$INSTALL_VIDEOMAMA" = "1" ]; then
  section "Install VideoMaMa Comfy base"

  clone_or_update "https://github.com/comfyanonymous/ComfyUI.git" "$VIDEOMAMA_ROOT"

  if [ ! -d "$VIDEOMAMA_ROOT/venv" ]; then
    "$PYTHON_BIN" -m venv "$VIDEOMAMA_ROOT/venv"
  fi

  . "$VIDEOMAMA_ROOT/venv/bin/activate"

  python -m pip install --upgrade pip wheel setuptools 2>&1 | tee -a "$LOG"
  python -m pip install torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0 --index-url https://download.pytorch.org/whl/cu124 2>&1 | tee -a "$LOG"
  python -m pip install -r "$VIDEOMAMA_ROOT/requirements.txt" 2>&1 | tee -a "$LOG" || true
  python -m pip install comfyui_manager 2>&1 | tee -a "$LOG" || true

  deactivate

  write_extra_model_paths "$VIDEOMAMA_ROOT"
  patch_manager_config "$VIDEOMAMA_ROOT"

  section "Install VideoMaMa custom nodes"

  clone_or_update "https://github.com/okdalto/ComfyUI-VideoMaMa.git" "$VIDEOMAMA_ROOT/custom_nodes/ComfyUI-VideoMaMa"
  clone_or_update "https://github.com/wouterverweirder/comfyui_sam3.git" "$VIDEOMAMA_ROOT/custom_nodes/comfyui-sam3"
  clone_or_update "https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git" "$VIDEOMAMA_ROOT/custom_nodes/ComfyUI-VideoHelperSuite"
  clone_or_update "https://github.com/kijai/ComfyUI-KJNodes.git" "$VIDEOMAMA_ROOT/custom_nodes/comfyui-kjnodes"
  clone_or_update "https://github.com/rgthree/rgthree-comfy.git" "$VIDEOMAMA_ROOT/custom_nodes/rgthree-comfy"
  clone_or_update "https://github.com/Fannovel16/comfyui_controlnet_aux.git" "$VIDEOMAMA_ROOT/custom_nodes/comfyui_controlnet_aux"
  clone_or_update "https://github.com/WASasquatch/was-node-suite-comfyui.git" "$VIDEOMAMA_ROOT/custom_nodes/was-ns"

  . "$VIDEOMAMA_ROOT/venv/bin/activate"

  for req in \
    "$VIDEOMAMA_ROOT/custom_nodes/ComfyUI-VideoMaMa/requirements.txt" \
    "$VIDEOMAMA_ROOT/custom_nodes/comfyui-sam3/requirements.txt" \
    "$VIDEOMAMA_ROOT/custom_nodes/ComfyUI-VideoHelperSuite/requirements.txt" \
    "$VIDEOMAMA_ROOT/custom_nodes/comfyui-kjnodes/requirements.txt" \
    "$VIDEOMAMA_ROOT/custom_nodes/rgthree-comfy/requirements.txt" \
    "$VIDEOMAMA_ROOT/custom_nodes/comfyui_controlnet_aux/requirements.txt" \
    "$VIDEOMAMA_ROOT/custom_nodes/was-ns/requirements.txt"
  do
    [ -f "$req" ] && python -m pip install -r "$req" 2>&1 | tee -a "$LOG" || true
  done

  python -m pip install --no-cache-dir \
    "numpy==2.1.3" \
    "Pillow==11.1.0" \
    "tqdm==4.67.1" \
    "safetensors==0.5.3" \
    "einops==0.8.1" \
    "huggingface-hub==0.29.3" \
    "transformers==4.49.0" \
    "accelerate==1.4.0" \
    "diffusers==0.34.0" \
    "opencv-python-headless==4.10.0.84" \
    "imageio==2.37.0" \
    "imageio-ffmpeg==0.6.0" \
    "av==14.0.1" \
    2>&1 | tee -a "$LOG" || true

  python -m pip install torch==2.4.0 torchvision==0.19.0 torchaudio==2.4.0 --index-url https://download.pytorch.org/whl/cu124 2>&1 | tee -a "$LOG"
  python -m pip check 2>&1 | tee -a "$LOG" || true

  deactivate

  SAM2_SETUP="$VIDEOMAMA_ROOT/custom_nodes/ComfyUI-VideoMaMa/utils/sam2_setup.py"
  if [ -f "$SAM2_SETUP" ] && ! grep -q "SAM2 disabled for this install" "$SAM2_SETUP"; then
    cat >> "$SAM2_SETUP" <<'PY'

# SAM2 disabled for this install.
# This worker uses SAM3 externally and must not auto-clone or pip-install SAM2.
SAM2_AVAILABLE = False
build_sam2_video_predictor = None
PY
  fi
fi

if [ "$PULL_SAM3" = "1" ]; then
  ensure_sam3_model
fi

ensure_shared_model_links

section "Write launch and repair scripts"

cat > /workspace/bin/fix-comfy-manager-policy <<'REPAIR'
#!/bin/bash
for ROOT in \
  /workspace/comfy/ComfyGeneral \
  /workspace/comfy/ComfyUI_WANVACE \
  /workspace/comfy/ComfyUI_VideoMaMa
do
  [ -d "$ROOT" ] || continue
  for CFG in \
    "$ROOT/user/__manager/config.ini" \
    "$ROOT/user/default/ComfyUI-Manager/config.ini"
  do
    mkdir -p "$(dirname "$CFG")"
    cat > "$CFG" <<'INI'
[default]
network_mode = personal_cloud
security_level = weak
use_uv = True
file_logging = True
INI
  done
  rm -rf "$ROOT/user/__manager/cache" "$ROOT/user/default/ComfyUI-Manager/cache"
done
REPAIR

chmod +x /workspace/bin/fix-comfy-manager-policy

cat > /workspace/bin/start-comfy-general <<'LAUNCH'
#!/bin/bash
mkdir -p /workspace/tmp
export TMPDIR=/workspace/tmp TEMP=/workspace/tmp TMP=/workspace/tmp
fix-comfy-manager-policy 2>/dev/null || true
source /workspace/comfy/ComfyGeneral/venv/bin/activate
python /workspace/comfy/ComfyGeneral/main.py --listen 0.0.0.0 --port 8188 --enable-manager --enable-manager-legacy-ui --use-sage-attention
LAUNCH

cat > /workspace/bin/start-comfy-wan <<'LAUNCH'
#!/bin/bash
mkdir -p /workspace/tmp
export TMPDIR=/workspace/tmp TEMP=/workspace/tmp TMP=/workspace/tmp
fix-comfy-manager-policy 2>/dev/null || true
cd /workspace/comfy/ComfyUI_WANVACE
source venv/bin/activate
python main.py --listen 0.0.0.0 --port 8288 --enable-manager --enable-manager-legacy-ui --use-sage-attention
LAUNCH

cat > /workspace/bin/start-comfy-videomama <<'LAUNCH'
#!/bin/bash
mkdir -p /workspace/tmp
export TMPDIR=/workspace/tmp TEMP=/workspace/tmp TMP=/workspace/tmp
fix-comfy-manager-policy 2>/dev/null || true
source /workspace/comfy/ComfyUI_VideoMaMa/venv/bin/activate
python /workspace/comfy/ComfyUI_VideoMaMa/main.py --listen 0.0.0.0 --port 8388 --enable-manager --enable-manager-legacy-ui
LAUNCH

chmod +x /workspace/bin/start-comfy-general /workspace/bin/start-comfy-wan /workspace/bin/start-comfy-videomama

section "Final summary"

du -sh /workspace/comfy /workspace/tmp /workspace/mainvolume_pull 2>/dev/null | tee -a "$LOG" || true
df -h /workspace 2>&1 | tee -a "$LOG" || true

log "Bootstrap complete."
log "Launch commands:"
log "  start-comfy-general"
log "  start-comfy-wan"
log "  start-comfy-videomama"

main-push "$LOG_DIR" logs/heavy_worker_bootstrap 2>&1 | tee -a "$LOG" || true
