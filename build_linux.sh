#!/usr/bin/env bash
# Automated WDT build for Linux (x86_64 / aarch64).
# Installs system dependencies when apt is available, clones/builds Folly if needed,
# and compiles WDT out-of-tree into ../wdt-build by default.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WDT_SRC="$(cd "${SCRIPT_DIR}/.." && pwd)"
TOOLS_DIR="$(cd "${WDT_SRC}/.." && pwd)"
FOLLY_DIR="${FOLLY_DIR:-${TOOLS_DIR}/folly}"
FOLLY_TAG="${FOLLY_TAG:-v2022.01.03.00}"
BUILD_DIR="${BUILD_DIR:-${TOOLS_DIR}/wdt-build}"
BUILD_TESTING="${BUILD_TESTING:-ON}"

install_system_deps() {
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get not found; install deps manually (see build/BUILD.md)" >&2
    return 0
  fi
  local pkgs=(
    build-essential cmake git
    libgoogle-glog-dev libgflags-dev libdouble-conversion-dev
    libboost-system-dev libboost-filesystem-dev libssl-dev libgtest-dev
  )
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -qq
    sudo apt-get install -y -qq "${pkgs[@]}"
  else
    apt-get update -qq
    apt-get install -y -qq "${pkgs[@]}"
  fi
}

ensure_folly() {
  if [[ -f "${FOLLY_DIR}/folly/Conv.h" ]]; then
    echo "Using existing Folly at ${FOLLY_DIR}"
  else
    echo "Cloning Folly ${FOLLY_TAG} into ${FOLLY_DIR}..."
    git clone --depth 1 --branch "${FOLLY_TAG}" \
      https://github.com/facebook/folly.git "${FOLLY_DIR}"
  fi
  if [[ "$(git -C "${FOLLY_DIR}" rev-parse HEAD 2>/dev/null)" != "$(git -C "${FOLLY_DIR}" rev-parse "${FOLLY_TAG}" 2>/dev/null)" ]]; then
    echo "Checking out Folly ${FOLLY_TAG}..."
    git -C "${FOLLY_DIR}" fetch --depth 1 origin "refs/tags/${FOLLY_TAG}:refs/tags/${FOLLY_TAG}" 2>/dev/null || \
      git -C "${FOLLY_DIR}" fetch --tags --depth 1 origin
    git -C "${FOLLY_DIR}" checkout "${FOLLY_TAG}"
  fi
}

configure_and_build() {
  mkdir -p "${BUILD_DIR}"
  cmake -S "${WDT_SRC}" -B "${BUILD_DIR}" \
    -DBUILD_TESTING="${BUILD_TESTING}" \
    -DFOLLY_SOURCE_DIR="${FOLLY_DIR}"
  cmake --build "${BUILD_DIR}" -j "$(nproc)"
  echo ""
  echo "Build complete."
  echo "  Binary: ${BUILD_DIR}/_bin/wdt/wdt"
  echo "  Libraries: ${BUILD_DIR}/libwdt*.so"
}

main() {
  install_system_deps
  ensure_folly
  configure_and_build
}

main "$@"
