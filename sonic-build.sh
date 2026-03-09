#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# sonic-build.sh — SONiC ARM virtual-switch build via Lima VM
#
# Usage:
#   Remote build (clone from GitHub):
#     ./sonic-build.sh <commit_hash> [-t|--title <title>]
#
#   Local build (use existing ./sonic-buildimage):
#     ./sonic-build.sh -l|--local [-t|--title <title>]
#
# Examples:
#   ./sonic-build.sh abc1234
#   ./sonic-build.sh abc1234 -t "fix-bgp-crash"
#   ./sonic-build.sh --local
#   ./sonic-build.sh -l --title "my-local-build"
#
# Options:
#   -l, --local     Use local ./sonic-buildimage directory instead of cloning
#   -t, --title     Optional title for the build run (used in output directory name)
#   -h, --help      Show this help message
#
# For local builds (-l), you MUST have sonic-buildimage in the script directory.
# If it doesn't exist, follow these steps:
#
#   Step 1: Clone the repository (without submodules for faster download)
#     cd /Users/bojunfeng/cs/sonic-on-mac
#     git clone https://github.com/sonic-net/sonic-buildimage.git
#     cd sonic-buildimage
#
#   Step 2: Checkout the desired version and initialize submodules
#     git checkout <your-commit-hash>
#     git submodule update --init --recursive
#
#   Step 3: Run the build
#     cd ..
#     ./sonic-build.sh --local [-t <title>]
#
#   Example with a specific commit:
#     cd /Users/bojunfeng/cs/sonic-on-mac
#     git clone https://github.com/sonic-net/sonic-buildimage.git
#     cd sonic-buildimage
#     git checkout 061375b0077bf744055cc152e96e8e42570a795c
#     git submodule update --init --recursive
#     cd ..
#     ./sonic-build.sh -l -t "my-build"
#
# The script will:
#   1. Tear down any existing vm-sonic-build Lima VM
#   2. Create a fresh Ubuntu 22.04 ARM VM with nested virtualisation
#   3. Install all SONiC build prerequisites inside it
#   4. Either clone from GitHub or copy local repo into the VM
#   5. Build target/sonic-vs-arm64.bin
#   6. Stream real-time logs to ~/Documents/sonic-build-pipeline/<run>/
#   7. Copy the resulting .bin to the same directory
#
# Requirements:
#   - macOS with Apple Silicon (M3+ for nested virtualisation / KVM)
#   - Lima (brew install lima)
#   - ~300 GB free disk, ≥16 GB RAM recommended
# ──────────────────────────────────────────────────────────────────────
set -euo pipefail

# ── Configurable ─────────────────────────────────────────────────────
VM_NAME="vm-sonic-build"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YAML_TEMPLATE="${SCRIPT_DIR}/vm-sonic-build.yaml"
OUTPUT_ROOT="$HOME/Documents/sonic-build-pipeline"

LOCAL_SONIC_DIR="${SCRIPT_DIR}/sonic-buildimage"

UPSTREAM_REPO="https://github.com/sonic-net/sonic-buildimage.git"
FORK_REPO="https://github.com/Bojun-Feng/sonic-buildimage.git"

BUILD_JOBS=4
PLATFORM="vs"
PLATFORM_ARCH="amd64"
BUILD_TARGET="target/sonic-vs.img.gz"

# SONiC build flags (adjust as needed)
SONIC_BUILD_FLAGS=(
  "SONIC_BUILD_JOBS=${BUILD_JOBS}"
  "SONIC_BUILD_RETRY_COUNT=1"
  "PLATFORM=${PLATFORM}"
  "PLATFORM_ARCH=${PLATFORM_ARCH}"
  "NOBUSTER=1"
  "NOBULLSEYE=1"
)

# ── Helpers ──────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m  $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
fatal() { err "$@"; exit 1; }

run_in_vm() {
  limactl shell "$VM_NAME" "$@"
}

usage() {
  echo "Usage:"
  echo "  $0 <commit_hash> [-t|--title <title>]    # Clone from GitHub"
  echo "  $0 -l|--local [-t|--title <title>]       # Use local ./sonic-buildimage"
  echo ""
  echo "Options:"
  echo "  -l, --local     Use local ./sonic-buildimage directory"
  echo "  -t, --title     Optional title for the build run"
  echo "  -h, --help      Show this help message"
  exit 1
}

show_local_setup_instructions() {
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Please clone sonic-buildimage first:"
  echo ""
  echo "  Step 1: Clone the repository (without submodules for faster download)"
  echo "    cd ${SCRIPT_DIR}"
  echo "    git clone https://github.com/sonic-net/sonic-buildimage.git"
  echo "    cd sonic-buildimage"
  echo ""
  echo "  Step 2: Checkout the desired version and initialize submodules"
  echo "    git checkout <your-commit-hash>"
  echo "    git submodule update --init --recursive"
  echo ""
  echo "  Step 3: Run the build"
  echo "    cd .."
  echo "    ./sonic-build.sh --local [-t <title>]"
  echo ""
  echo "  Example with a specific commit:"
  echo "    cd ${SCRIPT_DIR}"
  echo "    git clone https://github.com/sonic-net/sonic-buildimage.git"
  echo "    cd sonic-buildimage"
  echo "    git checkout 061375b0077bf744055cc152e96e8e42570a795c"
  echo "    git submodule update --init --recursive"
  echo "    cd .."
  echo "    ./sonic-build.sh -l -t \"my-build\""
  echo ""
  echo "════════════════════════════════════════════════════════════════"
}

# ── Parse Args ───────────────────────────────────────────────────────
LOCAL_MODE=false
TITLE=""
COMMIT_HASH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -l|--local)
      LOCAL_MODE=true
      shift
      ;;
    -t|--title)
      if [[ -z "${2:-}" ]]; then
        err "Option $1 requires an argument"
        usage
      fi
      TITLE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    -*)
      err "Unknown option: $1"
      usage
      ;;
    *)
      if [[ -z "$COMMIT_HASH" ]]; then
        COMMIT_HASH="$1"
      else
        err "Unexpected argument: $1"
        usage
      fi
      shift
      ;;
  esac
done

# Validate args
if [[ "$LOCAL_MODE" == false && -z "$COMMIT_HASH" ]]; then
  err "Either specify a commit hash or use --local mode"
  usage
fi

if [[ "$LOCAL_MODE" == true && -n "$COMMIT_HASH" ]]; then
  err "Cannot specify both --local and a commit hash"
  usage
fi

# ── Derived paths ────────────────────────────────────────────────────
TS="$(date +%Y%m%d_%H%M%S)"
if [[ -n "$TITLE" ]]; then
  RUN_DIR="${OUTPUT_ROOT}/${TS}-${TITLE}"
else
  RUN_DIR="${OUTPUT_ROOT}/${TS}"
fi

LOG_CONFIGURE="${RUN_DIR}/sonic_configure_${TS}.log"
LOG_BUILD="${RUN_DIR}/sonic_build_${TS}.log"
LOG_VM="${RUN_DIR}/vm_setup_${TS}.log"
LOG_COPY="${RUN_DIR}/sonic_copy_${TS}.log"

mkdir -p "$RUN_DIR"

# ══════════════════════════════════════════════════════════════════════
# MODE-SPECIFIC: Validate source and set variables
# ══════════════════════════════════════════════════════════════════════

if [[ "$LOCAL_MODE" == true ]]; then
  # ── Local mode: verify local sonic-buildimage exists ───────────────
  info "Mode: LOCAL (using ${LOCAL_SONIC_DIR})"
  
  if [[ ! -d "$LOCAL_SONIC_DIR" ]]; then
    err "Local sonic-buildimage directory not found!"
    show_local_setup_instructions
    exit 1
  fi

  if [[ ! -d "${LOCAL_SONIC_DIR}/.git" ]]; then
    fatal "Directory exists but is not a git repository: ${LOCAL_SONIC_DIR}"
  fi

  # Get current commit info for logging
  CURRENT_COMMIT="$(cd "$LOCAL_SONIC_DIR" && git rev-parse HEAD 2>/dev/null || echo 'unknown')"
  CURRENT_BRANCH="$(cd "$LOCAL_SONIC_DIR" && git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'detached')"

  ok "Found local sonic-buildimage"
  info "  Commit: ${CURRENT_COMMIT}"
  info "  Branch: ${CURRENT_BRANCH}"

else
  # ── Remote mode: resolve commit ────────────────────────────────────
  info "Mode: REMOTE (cloning from GitHub)"
  info "Resolving commit ${COMMIT_HASH}..."

  CLONE_URL=""
  if git ls-remote "$UPSTREAM_REPO" | grep -q "^${COMMIT_HASH}"; then
    CLONE_URL="$UPSTREAM_REPO"
    ok "Found in sonic-net/sonic-buildimage"
  elif git ls-remote "$FORK_REPO" | grep -q "^${COMMIT_HASH}"; then
    CLONE_URL="$FORK_REPO"
    ok "Found in Bojun-Feng/sonic-buildimage"
  else
    info "Commit not found in ls-remote (may be a mid-branch commit). Will try upstream first."
    CLONE_URL="$UPSTREAM_REPO"
  fi
fi

# ══════════════════════════════════════════════════════════════════════
# COMMON: VM Setup
# ══════════════════════════════════════════════════════════════════════

# ── Tear down existing VM ────────────────────────────────────────────
info "Tearing down any existing '${VM_NAME}' VM..."
if limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  limactl stop  "$VM_NAME" --force 2>/dev/null || true
  limactl delete "$VM_NAME" --force 2>/dev/null || true
  ok "Old VM removed."
else
  ok "No existing VM."
fi

# ── Create & start fresh VM ──────────────────────────────────────────
info "Creating VM from ${YAML_TEMPLATE}..."
info "  Output directory: ${RUN_DIR}"
info "  This takes a few minutes (Ubuntu image download + Docker install)."

limactl create \
  --name="$VM_NAME" \
  "$YAML_TEMPLATE" \
  --tty=false \
  2>&1 | tee "$LOG_VM"

info "Starting VM..."
limactl start "$VM_NAME" --tty=false 2>&1 | tee -a "$LOG_VM"
ok "VM is up."

# ── Verify KVM / nested virtualization ───────────────────────────────
info "Checking hardware virtualization..."
run_in_vm -- bash -c '
  set -eux
  if [ -f /sys/module/kvm/parameters/enable_apicv ] || \
     [ -d /sys/module/kvm_intel ] || \
     [ -d /sys/module/kvm_amd ] || \
     [ -d /sys/module/kvm ]; then
    echo "KVM hardware virtualization confirmed."
  else
    echo "ERROR: Not running under KVM hardware virtualization!" >&2
    echo "This VM appears to be using QEMU TCG (emulation), which is too slow." >&2
    echo "Ensure your host has:" >&2
    echo "  1. CPU virtualization enabled in BIOS (VT-x / AMD-V)" >&2
    echo "  2. KVM module loaded: sudo modprobe kvm_intel (or kvm_amd)" >&2
    echo "  3. /dev/kvm exists and is accessible" >&2
    exit 1
  fi

  if [ -e /dev/kvm ]; then
    echo "Nested virtualization available (/dev/kvm present in guest)."
  else
    echo "ERROR: /dev/kvm not found in guest — nested virtualization is NOT available." >&2
    echo "To enable on the host:" >&2
    echo "  Intel: echo 1 | sudo tee /sys/module/kvm_intel/parameters/nested" >&2
    echo "  AMD:   echo 1 | sudo tee /sys/module/kvm_amd/parameters/nested" >&2
    exit 1
  fi
' 2>&1 | tee -a "$LOG_VM" \
  || fatal "VM is using emulation or lacks nested virtualization. Aborting."
ok "KVM and nested virtualization confirmed."

# ── Verify docker works inside the VM ────────────────────────────────
info "Verifying Docker inside guest..."
run_in_vm -- sudo docker info >/dev/null 2>&1 \
  || fatal "Docker is not working inside the VM. Check ${LOG_VM}"
ok "Docker OK."

# ══════════════════════════════════════════════════════════════════════
# MODE-SPECIFIC: Get source code into VM
# ══════════════════════════════════════════════════════════════════════

GUEST_HOME="$(limactl shell "$VM_NAME" -- bash -c 'echo $HOME' 2>/dev/null | tr -d '[:space:]')"
GUEST_WORKDIR="${GUEST_HOME}/sonic-buildimage"

if [[ "$LOCAL_MODE" == true ]]; then
  # ── Local mode: copy local repo to VM ──────────────────────────────
  info "Copying local sonic-buildimage to VM..."
  info "  Source: ${LOCAL_SONIC_DIR}"
  info "  Destination: ${VM_NAME}:${GUEST_WORKDIR}"
  info "  This may take several minutes depending on repo size..."
  info "  Streaming to: ${LOG_COPY}"

  TAR_FILE="${RUN_DIR}/sonic-buildimage.tar"

  info "Creating tarball of local repo (this may take a while)..."
  tar -cf "$TAR_FILE" -C "$SCRIPT_DIR" sonic-buildimage 2>&1 | tee "$LOG_COPY"
  ok "Tarball created: $(du -h "$TAR_FILE" | cut -f1)"

  info "Copying tarball to VM..."
  limactl copy "$TAR_FILE" "${VM_NAME}:${GUEST_HOME}/sonic-buildimage.tar" 2>&1 | tee -a "$LOG_COPY"
  ok "Tarball copied to VM."

  info "Extracting tarball in VM..."
  run_in_vm -- bash -c "
    set -eux
    cd '${GUEST_HOME}'
    tar -xf sonic-buildimage.tar
    rm sonic-buildimage.tar
  " 2>&1 | tee -a "$LOG_COPY"
  ok "Extraction complete."

  rm -f "$TAR_FILE"
  info "Cleaned up temporary tarball."

  run_in_vm -- bash -c "
    set -eux
    cd '${GUEST_WORKDIR}'
    git status
    git log -1 --oneline
  " 2>&1 | tee -a "$LOG_COPY"

  ok "Repo ready at ${GUEST_WORKDIR}"

else
  # ── Remote mode: clone & checkout ──────────────────────────────────
  info "Cloning ${CLONE_URL} (with submodules)..."
  run_in_vm -- sg docker -c "
    set -eux
    git clone --recurse-submodules '${CLONE_URL}' '${GUEST_WORKDIR}'
  " 2>&1 | tee -a "$LOG_VM"

  info "Checking out ${COMMIT_HASH}..."
  run_in_vm -- sg docker -c "
    set -eux
    cd '${GUEST_WORKDIR}'
    git checkout '${COMMIT_HASH}' || {
      git remote add fork '${FORK_REPO}' 2>/dev/null || true
      git fetch fork
      git checkout '${COMMIT_HASH}'
    }
    git submodule update --init --recursive
  " 2>&1 | tee -a "$LOG_VM"

  ok "Repo ready at ${GUEST_WORKDIR}"
fi

# ══════════════════════════════════════════════════════════════════════
# COMMON: Configure & Build
# ══════════════════════════════════════════════════════════════════════

MAKE_FLAGS=""
for f in "${SONIC_BUILD_FLAGS[@]}"; do
  MAKE_FLAGS+="${f} "
done

# ── Configure ────────────────────────────────────────────────────────
info "Running make init && make configure..."
info "  Streaming to: ${LOG_CONFIGURE}"

run_in_vm -- sg docker -c "
  set -eux
  cd '${GUEST_WORKDIR}'
  sudo modprobe overlay || true
  make init
  make ${MAKE_FLAGS} configure
" 2>&1 | tee "$LOG_CONFIGURE"

ok "Configure complete."

# ── Build ────────────────────────────────────────────────────────────
info "Starting build: ${BUILD_TARGET}"
info "  Streaming to: ${LOG_BUILD}"
info "  This will take a long time..."

run_in_vm -- sg docker -c "
  set -eux
  cd '${GUEST_WORKDIR}'
  make ${MAKE_FLAGS} ${BUILD_TARGET}
" 2>&1 | tee "$LOG_BUILD"

ok "Build finished."

# ── Copy artefacts ───────────────────────────────────────────────────
info "Copying build artefact to ${RUN_DIR}..."

BIN_NAME="$(basename "$BUILD_TARGET")"
limactl copy "$VM_NAME:${GUEST_WORKDIR}/${BUILD_TARGET}" "${RUN_DIR}/${BIN_NAME}" \
  && ok "Artefact saved: ${RUN_DIR}/${BIN_NAME}" \
  || err "Could not copy ${BUILD_TARGET}. It may not have been produced."

# ══════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════

echo ""
echo "════════════════════════════════════════════════════════════════"
info "Build run complete."

if [[ "$LOCAL_MODE" == true ]]; then
  echo "  Mode:       LOCAL"
  echo "  Source:     ${LOCAL_SONIC_DIR}"
  echo "  Commit:     ${CURRENT_COMMIT}"
  echo "  Branch:     ${CURRENT_BRANCH}"
else
  echo "  Mode:       REMOTE"
  echo "  Commit:     ${COMMIT_HASH}"
  echo "  Repository: ${CLONE_URL}"
fi

echo "  VM:         ${VM_NAME} (still running — stop with: limactl stop ${VM_NAME})"
echo "  Logs:       ${RUN_DIR}/"
echo "    VM setup: ${LOG_VM}"
if [[ "$LOCAL_MODE" == true ]]; then
  echo "    Copy:     ${LOG_COPY}"
fi
echo "    Configure:${LOG_CONFIGURE}"
echo "    Build:    ${LOG_BUILD}"
if [[ -f "${RUN_DIR}/${BIN_NAME}" ]]; then
  echo "  Artefact:   ${RUN_DIR}/${BIN_NAME}"
fi
echo "════════════════════════════════════════════════════════════════"
