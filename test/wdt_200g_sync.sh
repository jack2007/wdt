#!/usr/bin/env bash
# Install runtime deps on peer DGX and rsync WDT binaries + shared libs.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=wdt_200g_env.sh
source "${SCRIPT_DIR}/wdt_200g_env.sh"

install_local_deps() {
  log_section "Local apt runtime packages"
  if command -v apt-get >/dev/null 2>&1; then
    sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      libgoogle-glog0v6 libgflags2.2 libdouble-conversion3 \
      libboost-system1.83.0 libboost-filesystem1.83.0 libssl3 \
      2>/dev/null || \
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
      libgoogle-glog-dev libgflags-dev libdouble-conversion-dev \
      libboost-system-dev libboost-filesystem-dev libssl-dev
    if ! command -v iperf3 >/dev/null; then
      echo "iperf3" | sudo debconf-set-selections 2>/dev/null || true
      echo "iperf3 iperf3/start_daemon boolean false" | sudo debconf-set-selections 2>/dev/null || true
      sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq iperf3
    fi
  fi
}

install_remote_deps() {
  log_section "Remote apt runtime packages on ${REMOTE_SSH}"
  if remote_has_wdt_runtime_libs; then
    echo "Remote runtime libraries already present; skipping apt."
    return 0
  fi
  remote "command -v apt-get >/dev/null" || {
    echo "Remote has no apt-get; install glog/gflags/double-conversion manually." >&2
    return 1
  }
  remote_sudo "apt-get update -qq && apt-get install -y -qq \
    libgoogle-glog0v6 libgflags2.2 libdouble-conversion3 \
    libboost-system1.83.0 libboost-filesystem1.83.0 libssl3" || \
  remote_sudo "apt-get update -qq && apt-get install -y -qq \
    libgoogle-glog-dev libgflags-dev libdouble-conversion-dev \
    libboost-system-dev libboost-filesystem-dev libssl-dev"
  remote "command -v iperf3 >/dev/null" || \
    remote_sudo "echo 'iperf3 iperf3/start_daemon boolean false' | debconf-set-selections; \
      apt-get install -y -qq iperf3"
}

verify_local_binary() {
  if [[ ! -x "${WDT_BIN}" ]]; then
    echo "Missing WDT binary: ${WDT_BIN}" >&2
    echo "Build first: /home/jack/src/msquic/src/tools/wdt/build_linux.sh" >&2
    exit 1
  fi
}

sync_artifacts() {
  log_section "Rsync WDT to ${REMOTE_SSH}:${WDT_BUILD_DIR}"
  remote "mkdir -p '${WDT_BUILD_DIR}/_bin/wdt/bench'"
  rsync -avz --progress \
    "${WDT_BIN}" \
    "${WDT_BUILD_DIR}/libwdt_min.so"* \
    "${WDT_BUILD_DIR}/libfolly4wdt.so" \
    "${REMOTE_SSH}:${WDT_BUILD_DIR}/"
  rsync -avz --progress \
    "${WDT_BIN}" \
    "${REMOTE_SSH}:${WDT_BUILD_DIR}/_bin/wdt/"
  if [[ -x "${WDT_GEN_FILES}" ]]; then
    rsync -avz --progress "${WDT_GEN_FILES}" \
      "${REMOTE_SSH}:${WDT_BUILD_DIR}/_bin/wdt/bench/"
  fi
}

verify_remote_binary() {
  log_section "Verify remote WDT"
  remote "export LD_LIBRARY_PATH='${WDT_BUILD_DIR}:\${LD_LIBRARY_PATH:-}'; \
    '${WDT_BIN}' --help 2>&1 | head -3"
  remote "export LD_LIBRARY_PATH='${WDT_BUILD_DIR}:\${LD_LIBRARY_PATH:-}'; \
    ldd '${WDT_BIN}' | grep -E 'not found|wdt|folly' || true"
}

main() {
  log_section "WDT 200G sync: ${LOCAL_HOST} -> ${REMOTE_HOST}"
  verify_local_binary
  install_local_deps
  install_remote_deps
  sync_artifacts
  verify_remote_binary
  echo ""
  echo "Sync complete. Remote WDT: ${REMOTE_SSH}:${WDT_BIN}"
}

main "$@"
