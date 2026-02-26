#!/usr/bin/env bash
# ──────────────────────────────────────────────────────────────────────
# sonic-build.sh — One-shot SONiC ARM virtual-switch build via Lima VM
#
# Usage:
#   ./sonic-build.sh <commit_hash> [title]
#
# Examples:
#   ./sonic-build.sh abc1234
#   ./sonic-build.sh abc1234 "fix-bgp-crash"
#
# The script will:
#   1. Tear down any existing vm-sonic-build Lima VM
#   2. Create a fresh Ubuntu 22.04 ARM VM with nested virtualisation
#   3. Install all SONiC build prerequisites inside it
#   4. Resolve the commit in sonic-net/sonic-buildimage or your fork
#   5. Clone, checkout, and build target/sonic-vs-arm64.bin
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

UPSTREAM_REPO="https://github.com/sonic-net/sonic-buildimage.git"
FORK_REPO="https://github.com/Bojun-Feng/sonic-buildimage.git"

BUILD_JOBS=4
PLATFORM="vs"
PLATFORM_ARCH="arm64"
BUILD_TARGET="target/sonic-vs-arm64.bin"

# SONiC build flags (adjust as needed)
SONIC_BUILD_FLAGS=(
  "SONIC_BUILD_JOBS=${BUILD_JOBS}"
  "SONIC_BUILD_RETRY_COUNT=2"
  "PLATFORM=${PLATFORM}"
  "PLATFORM_ARCH=${PLATFORM_ARCH}"
  "INCLUDE_VS_DASH_SAI=n"
  "NOTRIXIE=1"
)

# ── Args ─────────────────────────────────────────────────────────────
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <commit_hash> [title]"
  exit 1
fi

COMMIT_HASH="$1"
TITLE="${2:-}"

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

mkdir -p "$RUN_DIR"

# ── Helpers ──────────────────────────────────────────────────────────
info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m    $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; }
fatal() { err "$@"; exit 1; }

run_in_vm() {
  # Run a command inside the VM as the default user.
  # Usage: run_in_vm [--workdir /path] command args...
  limactl shell "$VM_NAME" "$@"
}

# ── 1. Resolve commit ────────────────────────────────────────────────
info "Resolving commit ${COMMIT_HASH}..."

CLONE_URL=""
if git ls-remote "$UPSTREAM_REPO" | grep -q "^${COMMIT_HASH}"; then
  CLONE_URL="$UPSTREAM_REPO"
  ok "Found in sonic-net/sonic-buildimage"
elif git ls-remote "$FORK_REPO" | grep -q "^${COMMIT_HASH}"; then
  CLONE_URL="$FORK_REPO"
  ok "Found in Bojun-Feng/sonic-buildimage"
else
  # ls-remote only shows refs; for arbitrary commits we try a shallow fetch
  # inside the VM later and let it fail if truly missing.
  info "Commit not found in ls-remote (may be a mid-branch commit). Will try upstream first."
  CLONE_URL="$UPSTREAM_REPO"
fi

# ── 2. Tear down existing VM ────────────────────────────────────────
info "Tearing down any existing '${VM_NAME}' VM..."
if limactl list -q 2>/dev/null | grep -qx "$VM_NAME"; then
  limactl stop  "$VM_NAME" --force 2>/dev/null || true
  limactl delete "$VM_NAME" --force 2>/dev/null || true
  ok "Old VM removed."
else
  ok "No existing VM."
fi

# ── 3. Create & start fresh VM ──────────────────────────────────────
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

# ── 4. Verify docker works inside the VM ─────────────────────────────
info "Verifying Docker inside guest..."
run_in_vm -- sudo docker info >/dev/null 2>&1 \
  || fatal "Docker is not working inside the VM. Check ${LOG_VM}"
ok "Docker OK."

# ── 5. Clone & checkout ─────────────────────────────────────────────
GUEST_WORKDIR="$(limactl shell "$VM_NAME" -- bash -c 'echo $HOME' 2>/dev/null | tr -d '[:space:]')/sonic-buildimage"

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
    # If the commit isn't in upstream, try adding fork as a remote
    git remote add fork '${FORK_REPO}' 2>/dev/null || true
    git fetch fork
    git checkout '${COMMIT_HASH}'
  }
  git submodule update --init --recursive
" 2>&1 | tee -a "$LOG_VM"

ok "Repo ready at ${GUEST_WORKDIR}"

# ── 6. Configure ────────────────────────────────────────────────────
info "Running make init && make configure..."
info "  Streaming to: ${LOG_CONFIGURE}"

run_in_vm -- sg docker -c "
  set -eux
  cd '${GUEST_WORKDIR}'
  sudo modprobe overlay || true
  make init
  make configure PLATFORM=${PLATFORM} PLATFORM_ARCH=${PLATFORM_ARCH} NOTRIXIE=1 INCLUDE_VS_DASH_SAI=n
" 2>&1 | tee "$LOG_CONFIGURE"

ok "Configure complete."

# ── 7. Build ─────────────────────────────────────────────────────────
info "Starting build: ${BUILD_TARGET}"
info "  Streaming to: ${LOG_BUILD}"
info "  This will take a long time..."

# Build the make flags string
MAKE_FLAGS=""
for f in "${SONIC_BUILD_FLAGS[@]}"; do
  MAKE_FLAGS+="${f} "
done

run_in_vm -- sg docker -c "
  set -eux
  cd '${GUEST_WORKDIR}'
  rm -f rules/p4lang.mk rules/dash-sai.mk
  make ${MAKE_FLAGS} ${BUILD_TARGET}
" 2>&1 | tee "$LOG_BUILD"

ok "Build finished."

# ── 8. Copy artefacts ───────────────────────────────────────────────
info "Copying build artefact to ${RUN_DIR}..."

# The output dir is already mounted writable, but the build happens in the
# guest home dir. Use limactl copy to pull it out.
BIN_NAME="$(basename "$BUILD_TARGET")"
limactl copy "$VM_NAME:${GUEST_WORKDIR}/${BUILD_TARGET}" "${RUN_DIR}/${BIN_NAME}" \
  && ok "Artefact saved: ${RUN_DIR}/${BIN_NAME}" \
  || err "Could not copy ${BUILD_TARGET}. It may not have been produced."

# ── 9. Summary ───────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
info "Build run complete."
echo "  Commit:     ${COMMIT_HASH}"
echo "  VM:         ${VM_NAME} (still running — stop with: limactl stop ${VM_NAME})"
echo "  Logs:       ${RUN_DIR}/"
echo "    VM setup: ${LOG_VM}"
echo "    Configure:${LOG_CONFIGURE}"
echo "    Build:    ${LOG_BUILD}"
if [[ -f "${RUN_DIR}/${BIN_NAME}" ]]; then
  echo "  Artefact:   ${RUN_DIR}/${BIN_NAME}"
fi
echo "════════════════════════════════════════════════════════════════"

